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
| Owner + start secrets | Env-managed owner (bcrypt at render — no unauthenticated /setup window ever); boot script derives WEBHOOK_URL from the canonical endpoint at runtime |
| Identity + policy | Reveal on exactly: owner, start, DB config, user's encryption-key secret |

**Key knobs:** `postgresHA.*`/`postgres.*` (exactly-one enforced) · `encryptionKey.secretName` (prerequisite **opaque** secret) · `owner.{email,password}` · `publicAccess` (default true) · backups per provider

**Troubleshooting / considerations**
- **The encryption key is the crown jewels**: losing it bricks every stored credential; changing it after first boot prevents startup. It's a prerequisite secret — back it up
- **Synchronous webhook responses must finish <30s** (platform edge 504s at 30s; the workflow still completes server-side) — long flows should use n8n's respond-immediately mode
- n8n crash-loops briefly at install while the DB converges — normal, self-heals (its retry IS the DB wait); pg-ha 2.4.1's proxy logs "waiting for patroni endpoints" before starting (designed)
- HAProxy backends: 2-of-3 showing DOWN is the **designed** leader-check state (only the primary shows UP) — not a fault
- Upgrades restart the single main (~1 min editor/webhook outage); only queue mode scales horizontally (not shipped; enterprise multi-main excluded by license policy)
- Uninstall deletes the DB and volumesets — enable backups if data matters
- Owner password rotates via values change + helm upgrade; no license key needed ever (free-tier registration is optional, in-app)
- Image default is `n8nio/n8n` (Docker Hub) — the docker.n8n.io registry rejects cloud pulls
