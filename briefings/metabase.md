# Metabase — Maintainer Briefing

## What it is

- Self-hosted BI/analytics (dashboards, SQL editor, scheduled reports) over the user's own databases. **Free open-source edition only**, licensed AGPL (a strong open-source license: anyone offering a modified version as a service must publish their changes) — the `metabase/metabase` image; paid Pro/Enterprise features and their separate image are excluded entirely.

## Common use cases

- Team dashboards and ad-hoc SQL over Postgres/MySQL/BigQuery/etc. the user already runs
- Scheduled report/dashboard subscriptions by email
- Lightweight internal analytics UI in the same GVC as the data (internal-only mode)
- Pointing at the bundled subchart Postgres as a first data source for evaluation

## Architecture on cpln

| Resource | Purpose |
|---|---|
| workload `{release}-metabase` | Standard (stateless), 1 replica, port 3000 http, JVM |
| secret `{release}-metabase-admin` (dictionary) | Admin bootstrap email + plaintext password (setup API needs plaintext) |
| secret `{release}-metabase-start` (opaque) | Start script: MB_SITE_URL derivation + localhost admin bootstrap |
| identity + policy | `reveal` on exactly: admin, start, DB config, user's encryption-key secret |
| subchart `postgresHA` (default) / `postgres` (dev) | App DB — n8n dual-mode mechanics verbatim (exactly-one validation, HAProxy leader endpoint) |

- **No volumeset** — all state in Postgres; H2 never used.
- First-boot admin created in-container via `POST /api/setup` (auto-generated token, cleared on use); **readiness probe requires `has-user-setup:true`** → no externally reachable setup window, fail-closed.

## Key knobs

`image` | `resources` (2Gi/1CPU default; JVM) | `encryptionKey.secretName` (prerequisite opaque secret, ≥16 chars) | `admin.*` (bootstrap login) | `siteName` | `publicAccess.enabled` (default true) | `internalAccess.type` | `postgresHA.*` / `postgres.*` (creds, replicas, capacity, backups — pass-through)

## Troubleshooting / considerations

- **Workload never ready + `cpln-bootstrap: ERROR` in logs** → admin bootstrap failed; most common: `admin.password` too weak for Metabase's server-side complexity check, or the `POST /api/setup` body shape changed upstream. Unready = intentionally unexposed (fail-closed), not a probe bug.
- **Encryption key is crown jewels**: user-created opaque secret; losing/changing it forces re-entering every saved database connection. Never rotate casually (offline `rotate-encryption-key` command exists upstream).
- **Admin password changes post-install happen in the Metabase UI**, not via values — `admin.*` only matters at first boot; re-running with new values does NOT change an existing admin (has-user-setup is permanent, bootstrap skips).
- **Reinstall against retained subchart data** = setup already done: bootstrap skips, old credentials apply. Full reset requires uninstall (deletes subchart volumesets) + reinstall.
- **First boot / upgrades run app-DB migrations** — liveness initialDelay is deliberately long (240s); don't "fix" slow first boot by tightening probes.
- **JVM memory**: heap is set to 75% of container memory via hardcoded `JAVA_OPTS`; OOM under load → raise `resources.memory`, upstream sizing is +2GB per 20 concurrent users.
- **Do not set `MB_SETUP_TOKEN`** (upstream bug leaves the frontend stuck on /setup); the design reads the auto-generated token instead.
- **Never disable `postgresHA.proxy.enabled`** — HAProxy is Metabase's stable DB endpoint (validation blocks it).
- Uninstall deletes the app DB (dashboards/questions/users); the prerequisite encryption-key secret survives (user-owned). Enable subchart backups if data matters.
