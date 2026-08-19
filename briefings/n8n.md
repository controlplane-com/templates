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
| DB subchart — exactly ONE mode | `postgresHA` (default, prod): pg-ha 2.4.2 = 3 Patroni + 3 etcd + 2 HAProxy · `postgres` 3.4.1 (dev): single instance |
| `postgres.config.credentialsSecretName` secret (dictionary, **chart-created**) | Bundled single-instance DB `username`/`password`/`database`. Created by THIS chart since 1.2.0 (postgres 3.4.x stopped creating it); HA mode still uses pg-ha's own `{release}-postgres-config` |
| Volumeset /home/node/.n8n (10Gi) | Binary/execution data (lives on disk in n8n 2.x) |
| Start secret + 2 prerequisite secrets | Env-managed owner (no unauthenticated /setup window ever) read from a user-created dictionary secret; boot script derives WEBHOOK_URL from the canonical endpoint at runtime |
| Identity + policy | Reveal on exactly: start script, DB config, and the user's owner + encryption-key secrets |

**Key knobs:** `postgresHA.postgres.{username,password,database}` (HA) / `postgres.credentials.{username,password,database}` + `postgres.config.credentialsSecretName` (single-instance, default `my-n8n-db-credentials`) — exactly-one enforced, HA default · `encryptionKey.secretName` (prerequisite **opaque** secret, default `my-n8n-encryption-key`) · `owner.secretName` (prerequisite **dictionary** secret, default `my-n8n-owner`; keys `email` + `passwordHash`) · `owner.{firstName,lastName}` · `timezone: UTC` · `volumeset.capacity: 10` · `publicAccess.enabled: true` · `internalAccess.type: same-gvc` · backups per provider (off)

**Troubleshooting / considerations**
- **The encryption key is the crown jewels**: losing it bricks every stored credential; changing it after first boot prevents startup. It's a prerequisite secret — back it up
- **Synchronous webhook responses must finish <30s** (platform edge 504s at 30s; the workflow still completes server-side) — long flows should use n8n's respond-immediately mode
- n8n crash-loops briefly at install while the DB converges — normal, self-heals (its retry IS the DB wait); pg-ha 2.4.1's proxy logs "waiting for patroni endpoints" before starting (designed)
- HAProxy backends: 2-of-3 showing DOWN is the **designed** leader-check state (only the primary shows UP) — not a fault
- Upgrades restart the single main (~1 min editor/webhook outage); only queue mode scales horizontally (not shipped; enterprise multi-main excluded by license policy)
- Uninstall deletes the DB and volumesets — enable backups if data matters
- **Owner is a PREREQUISITE DICTIONARY SECRET as of 1.1.0** (`email` + `passwordHash`). n8n rejects a plaintext password — the hash must be bcrypt; `htpasswd -bnBC 10 "" 'pw' | tr -d ':\n'` emits the `$2y$` form and n8n's bcryptjs accepts `2a`/`2b`/`2y` alike (verified against bcryptjs 3.0.3)
- Because `N8N_INSTANCE_OWNER_MANAGED_BY_ENV` re-applies the owner at EVERY start, editing the secret + restarting rotates the password — and an upgrader who hashes a *different* password silently changes their own login. 1.0.x's `owner.email`/`owner.password` now hard-`fail` the render with the replacement named
- A missing prerequisite secret wedges the deploy with ZERO log lines; the only diagnostic is `status.versions[].message` from `cpln workload get-deployments` (not plain `get`). Self-heals in ~6–10 min, or `force-redeployment` (~90 s)
- No license key needed ever (free-tier registration is optional, in-app)
- **The bundled DB password stays a VALUE — but since 1.2.0 this chart builds the secret.** postgres 3.4.x takes only `config.credentialsSecretName` and creates nothing; n8n renders `templates/secret-db.yaml` from `postgres.credentials.*` and passes the name down. Users gained no prerequisite. **The HA branch of `n8n.postgres.secret.name` was deliberately left alone** — pg-ha 2.4.2 has not adopted the convention and still creates `{release}-postgres-config`
- **Secret names are org-wide and cannot be templated.** Helm resolves subchart values before rendering and postgres does not `tpl` the name, so it cannot contain `.Release.Name`. A second n8n release left on the default `my-n8n-db-credentials` is **refused at install** ("cannot be updated because it is being managed by a different release") and creates nothing — not silent data loss
- **An upgrader carrying the 1.1.0 keys gets postgres's own error**, not an n8n one: Helm renders `charts/` before `templates/`, so the subchart's `config.username was REMOVED in postgres 3.4.0` always wins. 3.4.1 appends a clause telling bundled users not to create a secret. A parent-side guard would be dead code — do not add one
- **`postgres.backup.minio.accessKey`/`secretKey` were removed too** (postgres 3.4.0) — that path needs a prerequisite dictionary secret named by `postgres.backup.minio.credentialsSecretName`. `postgresHA.backup.minio` still takes the keys inline
- pg-ha is still pinned at 2.4.2 and deliberately not bumped here (it still carries `aws::ReadOnlyAccess` on its backup identity)
- Image default is `n8nio/n8n` (Docker Hub) — the docker.n8n.io registry rejects cloud pulls
