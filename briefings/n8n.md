# n8n — Maintainer Briefing

**What it is:** n8n (fair-code, Sustainable Use License — free to self-host, NOT OSI open source) — visual workflow automation: 400+ integrations, webhook triggers, scheduled jobs. Zapier-class, self-hosted.

**Common use cases**
- Webhook-driven integrations (Stripe/GitHub/forms → actions) — webhooks are production endpoints even though the editor is developer-facing
- Scheduled automations and data syncs between SaaS tools
- Internal tools/glue built by developers, credentials stored encrypted in-app

**Architecture on cpln**

| Resource | Purpose |
|---|---|
| Stateful workload ×1 (main) | Editor + API + webhooks, :5678, public canonical HTTPS by default (n8n auth-gates itself) |
| DB subchart — exactly ONE mode | `postgresHA` (default, prod): pg-ha 2.5.0 = 3 Patroni + 3 etcd + 2 HAProxy · `postgres` 3.4.1 (dev): single instance |
| DB credentials secret (dictionary, **user-created** since 1.4.0) | `username`/`password`/`database` for the bundled DB, in **both** modes. Named by `postgresHA.config.credentialsSecretName` (HA) or `postgres.config.credentialsSecretName` (single); the active subchart initializes from it and n8n reads all three keys as `cpln://secret` env refs |
| Volumeset /home/node/.n8n (10Gi) | Binary/execution data (lives on disk in n8n 2.x) |
| Start secret + 3 prerequisite secrets | Env-managed owner (no unauthenticated /setup window ever) read from a user-created dictionary secret; boot script derives WEBHOOK_URL from the canonical endpoint at runtime |
| Identity + policy | Reveal on exactly: start script, and the user's owner, DB-credentials and encryption-key secrets |

**Key knobs:** `postgresHA.config.credentialsSecretName` / `postgres.config.credentialsSecretName` (HA / single-instance prerequisite **dictionary** secret, both default `my-n8n-db-credentials`; set the one for the active mode) · `postgresHA.enabled` / `postgres.enabled` — exactly-one enforced, HA default · `encryptionKey.secretName` (prerequisite **opaque** secret, default `my-n8n-encryption-key`) · `owner.secretName` (prerequisite **dictionary** secret, default `my-n8n-owner`; keys `email` + `passwordHash`) · `owner.{firstName,lastName}` · `timezone: UTC` · `volumeset.capacity: 10` · `publicAccess.enabled: true` · `internalAccess.type: same-gvc` · backups per provider (off)

**Troubleshooting / considerations**
- **The encryption key is the crown jewels**: losing it bricks every stored credential; changing it after first boot prevents startup. It's a prerequisite secret — back it up
- **Synchronous webhook responses must finish <30s** (platform edge 504s at 30s; the workflow still completes server-side) — long flows should use n8n's respond-immediately mode
- n8n crash-loops briefly at install while the DB converges — normal, self-heals (its retry IS the DB wait); pg-ha's proxy logs "waiting for patroni endpoints" before starting (designed)
- HAProxy backends: 2-of-3 showing DOWN is the **designed** leader-check state (only the primary shows UP) — not a fault
- Upgrades restart the single main (~1 min editor/webhook outage); only queue mode scales horizontally (not shipped; enterprise multi-main excluded by license policy)
- Uninstall deletes the DB and volumesets — enable backups if data matters
- **Owner is a PREREQUISITE DICTIONARY SECRET as of 1.1.0** (`email` + `passwordHash`). n8n rejects a plaintext password — the hash must be bcrypt; `htpasswd -bnBC 10 "" 'pw' | tr -d ':\n'` emits the `$2y$` form and n8n's bcryptjs accepts `2a`/`2b`/`2y` alike (verified against bcryptjs 3.0.3)
- Because `N8N_INSTANCE_OWNER_MANAGED_BY_ENV` re-applies the owner at EVERY start, editing the secret + restarting rotates the password — and an upgrader who hashes a *different* password silently changes their own login. 1.0.x's `owner.email`/`owner.password` now hard-`fail` the render with the replacement named
- **Wizard (1.4.0, first descriptor):** imports postgres 3.4.1 for single mode (`config.credentialsSecretName` and `pgbouncer` excluded); pg-ha 2.5.0 has no descriptor, so its keys are bound as plain parent fields (temporal 2.0.0 pattern); a `dbMode` virtual enum writes both `enabled` flags
- A missing prerequisite secret wedges the deploy with ZERO log lines; the only diagnostic is `status.versions[].message` from `cpln workload get-deployments` (not plain `get`). Self-heals in ~6–10 min, or `force-redeployment` (~90 s)
- No license key needed ever (free-tier registration is optional, in-app)
- **1.4.0: the DB credentials became a prerequisite secret (maintainer ruling 2026-10-14, work item 5284).** Rule: when a dependency requires a pre-existing credential secret, the parent requires it too, rather than rebuilding it from plaintext values. 1.2.0–1.3.1 rendered `templates/secret-db.yaml` from `postgres.credentials.*` (now deleted), which put the DB password in the Helm release. `postgres.credentials` now fails at render (`n8n.validateRemovedKeys`, mirrored in the wizard). No URL is assembled from the credentials — n8n takes `DB_POSTGRESDB_{USER,PASSWORD,DATABASE}` as separate env vars — so no `$(VAR)` composition was needed and no render-time checks had to be dropped
- **Upgrading 1.3.x → 1.4.0 deletes the chart-created DB secret**, because the new chart no longer renders it. The user must create a secret under a NEW name holding the CURRENT credentials (the data dir keeps the password it was initialized with) and point the active mode's `credentialsSecretName` at it; the wizard enforces the new name. Expect the new reveal grant to stall the new workload version ~10 min (`is not allowed to reveal the secret`, the authorization edge-cache trap measured on gitea 1.3.0), then clear by itself
- **History:** 1.2.0 (postgres 3.4.x) and 1.3.0 (pg-ha 2.5.0) moved the subcharts to a secret NAME only, and n8n absorbed that by building the secret from `postgres.credentials.*`; 1.4.0 hands it to the user instead. Pre-1.2.0 keys (`postgres.config.username` etc., `postgresHA.postgres.*`) now go straight into the prerequisite secret
- **Secret names are org-wide and cannot be templated.** Helm resolves subchart values before rendering and postgres does not `tpl` the name, so it cannot contain `.Release.Name`. Since 1.4.0 the user owns the secret, so two releases pointed at one secret would silently SHARE credentials (no longer refused at install as in 1.2.0–1.3.1) — the README tells users to give each release its own
- **An upgrader carrying the 1.1.0 keys gets postgres's own error**, not an n8n one: Helm renders `charts/` before `templates/`, so the subchart's `config.username was REMOVED in postgres 3.4.0` always wins. Its "create a dictionary secret" advice is now correct for n8n too. A parent-side guard would be dead code — do not add one
- **MinIO backup keys are a prerequisite dictionary secret on both paths** (`accessKey`/`secretKey`) — `postgres.backup.minio.credentialsSecretName` since 1.2.0 (postgres 3.4.0), `postgresHA.backup.minio.credentialsSecretName` since 1.3.1 (pg-ha 2.5.0). Inline keys fail the render
- pg-ha is pinned at 2.5.0, which still attaches `aws::ReadOnlyAccess` to its backup identity when `postgresHA.backup.provider: aws`
- Image default is `n8nio/n8n` (Docker Hub) — the docker.n8n.io registry rejects cloud pulls
- **HA password rotation must also update the `repl` role (measured on listmonk 1.6.0, 2026-10-14).** postgres-highly-available 2.5.0 uses the same secret password for its replication user `repl`; after `ALTER ROLE <user>` + secret edit + redeploy, the standbys failed with `password authentication failed for user "repl"` while the app kept working on the leader. `ALTER ROLE repl PASSWORD '<new>'` on the leader restored streaming in ~12 s. README and wizard help say so.
