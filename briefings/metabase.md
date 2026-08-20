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
| user's `admin.secretName` secret (dictionary, **prerequisite**) | Admin bootstrap `email` + plaintext password (the setup API needs plaintext) — user-created since 1.1.0, never by the chart |
| secret `{release}-metabase-start` (opaque) | Start script: MB_SITE_URL derivation + localhost admin bootstrap |
| identity + policy | `reveal` on exactly: the user's admin secret, start script, DB config, the user's encryption-key secret |
| `my-metabase-db-credentials` secret (dictionary, **chart-created**, 1.2.0+) | `username`/`password`/`database` for the bundled single-instance DB; built from `postgres.credentials.*` and handed to the postgres subchart by name. Single-instance path only |
| subchart `postgresHA` (default, **2.4.2** — creates its own `{release}-postgres-config`) / `postgres` (dev, **3.4.1** since 1.2.0 — creates no secret of its own) | App DB — n8n dual-mode mechanics verbatim (exactly-one validation, HAProxy leader endpoint) |

- **No volumeset** — all state in Postgres; H2 never used.
- First-boot admin created in-container via `POST /api/setup` (auto-generated token, cleared on use); **readiness probe requires `has-user-setup:true`** → no externally reachable setup window, fail-closed.

## Key knobs

`image` | `resources` (2Gi/1CPU default; JVM) | `encryptionKey.secretName` (prerequisite opaque secret, ≥16 chars) | `admin.secretName` (prerequisite dictionary secret: `email` + `password`) + `admin.firstName`/`admin.lastName` (plain values) | `siteName` | `publicAccess.enabled` (default true) | `internalAccess.type` | `postgresHA.*` / `postgres.*` (creds, replicas, capacity, backups — pass-through)

**1.2.0 database knobs:** `postgres.credentials.{username,password,database}` (was `postgres.config.*`; defaults `metabase` / `change-me-metabase-db-password` / `metabase`) · `postgres.config.credentialsSecretName` (default `my-metabase-db-credentials` — the secret the CHART creates and the subchart reads; org-wide, so unique per release) · `postgres.backup.minio.credentialsSecretName` (default `my-metabase-minio-credentials` — a genuine prerequisite, only when the single-instance `backup.provider: minio`).

## Troubleshooting / considerations

- **Workload wedged with ZERO log lines** → the prerequisite `admin.secretName` or `encryptionKey.secretName` secret does not exist. The container never starts, so `cpln logs` is empty; the diagnostic is `status.versions[].message` from `cpln workload get-deployments … -o yaml` (**not** plain `get`). Self-heals in ~5.5–10.5 min once created, or force a redeployment (~90 s).
- **Workload never ready + `cpln-bootstrap: ERROR` in logs** → admin bootstrap failed; most common: the password in the admin secret is too weak for Metabase's server-side complexity check (needs letters **and** digits, 8+), it contains a `"` or `\` (the start script rejects those before POSTing — they would break the setup JSON body), or the `POST /api/setup` body shape changed upstream. Unready = intentionally unexposed (fail-closed), not a probe bug.
- **Encryption key is crown jewels**: user-created opaque secret; losing/changing it forces re-entering every saved database connection. Never rotate casually (offline `rotate-encryption-key` command exists upstream).
- **Admin password changes post-install happen in the Metabase UI**, not in the secret — the admin secret only matters at first boot; editing it does NOT change an existing admin (has-user-setup is permanent, bootstrap skips). 1.1.0 moved `admin.email`/`admin.password` out of values into that prerequisite secret (2026-08-07 ruling: a credential guarding a public human-facing login); `fail` guards name the replacement, no shims.
- **Reinstall against retained subchart data** = setup already done: bootstrap skips, old credentials apply. Full reset requires uninstall (deletes subchart volumesets) + reinstall.
- **First boot / upgrades run app-DB migrations** — liveness initialDelay is deliberately long (240s); don't "fix" slow first boot by tightening probes.
- **JVM memory**: heap is set to 75% of container memory via hardcoded `JAVA_OPTS`; OOM under load → raise `resources.memory`, upstream sizing is +2GB per 20 concurrent users.
- **Do not set `MB_SETUP_TOKEN`** (upstream bug leaves the frontend stuck on /setup); the design reads the auto-generated token instead.
- **Never disable `postgresHA.proxy.enabled`** — HAProxy is Metabase's stable DB endpoint (validation blocks it).
- **1.2.0 adopted postgres 3.4.1, and metabase absorbed the break rather than passing it on.** 3.4.0 deleted its `{release}-pg-config` secret and now takes only a secret NAME. Because a parent cannot template a subchart value, the name is a plain value (`postgres.config.credentialsSecretName`) that BOTH sides read: metabase's `secret-db.yaml` renders it, the subchart's env refs and policy consume it, and `metabase.postgres.secret.name` points the app at it. Net user-visible change is one rename on the single-instance path; **no new prerequisite**, because no human ever types this password.
- **The secret name is org-wide, not release-scoped** (forced by the Helm limitation above). Two metabase releases left on the default name: the second is **refused at install** — `cannot be updated because it is being managed by a different release` — and creates nothing. Nothing is shared, overwritten or deleted. No render-time guard for it.
- **A stale 1.1.0 values file fails with the SUBCHART's message, not metabase's.** Helm renders `charts/…` before `templates/…`, so a parent-side guard would be dead code and was deliberately not added. 3.4.1's message appends a clause telling bundled users not to create a secret themselves; the README's "Upgrading from 1.1.0" table carries the rename.
- **The HA branch was deliberately left alone.** `postgres-highly-available` 2.4.2 has not adopted the convention: `postgresHA.postgres.*` are still values, it creates `{release}-postgres-config` itself, and its MinIO backup keys are still plain values. When pg-ha adopts it, `metabase.postgres.secret.name`'s HA branch and the `postgresHA` values block are the two places to change. Note `MB_DB_DBNAME` still comes from the secret on the HA path and from `postgres.credentials.database` directly on the single path — the single-instance secret now *has* a `database` key, so that branch could be collapsed later, but it was left as the proven shape.
- Uninstall deletes the app DB (dashboards/questions/users); the prerequisite encryption-key secret survives (user-owned). Enable subchart backups if data matters.
