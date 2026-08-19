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
| DB subchart — exactly ONE mode | `postgresHA` (default, prod): pg-ha 2.4.1 = 3 Patroni + 3 etcd + 2 HAProxy · `postgres` (dev): single instance |
| Volumeset /home/node/.n8n (10Gi) | Binary/execution data (lives on disk in n8n 2.x) |
| Start secret + 2 prerequisite secrets | Env-managed owner (no unauthenticated /setup window ever) read from a user-created dictionary secret; boot script derives WEBHOOK_URL from the canonical endpoint at runtime |
| Identity + policy | Reveal on exactly: start script, DB config, and the user's owner + encryption-key secrets |

**Key knobs:** `postgresHA.*`/`postgres.*` (exactly-one enforced, HA default) · `encryptionKey.secretName` (prerequisite **opaque** secret, default `my-n8n-encryption-key`) · `owner.secretName` (prerequisite **dictionary** secret, default `my-n8n-owner`; keys `email` + `passwordHash`) · `owner.{firstName,lastName}` · `timezone: UTC` · `volumeset.capacity: 10` · `publicAccess.enabled: true` · `internalAccess.type: same-gvc` · backups per provider (off)

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
- The bundled DB password stays a value — it is plumbing no human types, and the postgres/pg-ha subcharts are pinned at 3.3.0 / 2.4.2 (both still carry `aws::ReadOnlyAccess` on their backup identity; deliberately not bumped here)
- Image default is `n8nio/n8n` (Docker Hub) — the docker.n8n.io registry rejects cloud pulls
