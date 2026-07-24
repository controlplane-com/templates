# Unleash — Maintainer Briefing

## What it is
- Open-source feature-flag server (toggle features on/off, gradual rollouts, A/B tests) with an admin web UI; all state in PostgreSQL.
- License: v8 Docker image stays Apache-2.0 (permissive), but the v8 source moved to AGPL (a strong open-source license: anyone offering a modified version as a network service must share their changes). We ship the unmodified image — see spec Open Question 1.

## Common use cases
- Roll a feature out to 10% of users, then ramp up, without redeploying.
- Kill switch: instantly disable a broken feature in production.
- A/B testing and per-user/per-segment targeting via SDKs in the user's own apps.
- Separate `development` / `production` flag states (the only 2 environments in the free edition).

## Architecture on cpln
| Resource | Purpose |
|---|---|
| `{release}-unleash` workload (standard, :4242 http) | Server: admin UI + Admin/Client/Frontend APIs on one port |
| `{release}-unleash-admin` secret | First-boot admin username/password |
| user's `apiTokens.secretName` secret (optional, prerequisite) | First-boot SDK tokens — user-created dictionary secret with keys `backend` + `frontend`; template only references it by name |
| `{release}-unleash-start` secret | Boot script — sets the public URL at runtime |
| identity + policy | Reveal (read) access on exactly the secrets above + the DB credential secret |
| postgresHA (default) or postgres subchart | The database — holds every flag, user, and token |

- Fully stateless server: no volumeset; `replicas: 2+` scales it behind the load balancer (default 1).
- Dual database mode like n8n/metabase/temporal: HA Postgres default, single Postgres for dev; exactly one must be enabled.

## Key knobs
`image` · `replicas` (1 default, 2+ = HA) · `admin.username/password` (first boot only) · `apiTokens.secretName` (first boot only; prerequisite dictionary secret with keys `backend`/`frontend`, token format `project:environment.secret`) · `publicAccess.enabled` (default true) · `internalAccess.type` · `postgresHA.*` / `postgres.*` (incl. backups)

## Troubleshooting / considerations
- **First-boot-only seeds:** admin password and `apiTokens` are written to the database once. Changing these values and upgrading does nothing — change the password in the UI; create new tokens in the UI. A full reset requires uninstall (deletes the DB volume) + reinstall.
- **Token values never pass through helm:** `apiTokens.secretName` only names a secret the user pre-creates (maintainer ruling — client credentials follow the prerequisite-secret convention). Default empty = no seeding; create tokens in the UI instead.
- **Backend vs frontend token confusion** is the #1 SDK support call: backend tokens (server-side SDKs, `/api/client`) must stay secret; frontend tokens (`/api/frontend`) are safe to embed in browsers. A 401 usually means the wrong token type or wrong environment in the token string.
- **Only 2 environments in the free edition** (`development`, `production`). SSO, role-based access control (per-user permission tiers), multiple projects, change requests, and audit logs are all paid-Enterprise — never tell a user these are one config flag away.
- **Public URL links:** password-reset/invite links use `UNLEASH_URL`, derived at boot from the canonical endpoint. If links look wrong after toggling `publicAccess`, restart the workload so the boot script re-derives it.
- **DB connections:** each replica opens at most 4 Postgres connections (upstream default), so replica count is never a connection-limit concern at sane scale.
- **v8 needs PostgreSQL 15+** — both our dependency charts qualify (pg-ha = PG 17, postgres = PG 18); relevant if external-DB support is added later.
- **HA-mode first boot takes ~5–7 min at any replica count** (test-proven): transient `Failed to migrate db` errors while the database cluster starts are expected and self-heal; there is NO replicas-specific first-boot race (fresh install at 2 converged unaided, zero migration conflicts — never advise install-at-1-then-scale).
- **Availability numbers (test-proven):** rolling redeploy @2 replicas = 55/55 polls served; replica kill @2 = 30/30; even a single-replica upgrade served 63/63 (the platform surges the replacement before stopping the old one).
