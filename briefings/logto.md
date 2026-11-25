# Logto — Maintainer Briefing

## What it is
- Logto OSS 1.45.0: open-source sign-in and user management over OIDC (the standard login protocol apps speak) and OAuth, with an Admin Console and a Management API. MPL-2.0 (weak copyleft: changes to Logto's own files must be shared; apps using it are unaffected).
- Image `ghcr.io/logto-io/logto:1.45.0` (digest `sha256:9a9aff94…5854`, same on Docker Hub `svhd/logto`). Runs as root, alpine/busybox, node 22; no curl, psql or bash.

## Common use cases
- Add sign-in and sign-up to web, mobile and single-page apps.
- Issue tokens to APIs and machine-to-machine (backend-to-backend) clients.
- Social and passwordless login, MFA (second factor), B2B organizations with roles.

## Architecture on cpln
| Resource | Purpose |
|---|---|
| `{release}-logto` (standard, 2 replicas, :3001) | Sign-in pages, OIDC, Management API. Runs the first-admin bootstrap. |
| `{release}-logto-admin` (standard, 1 replica, :3002, default on) | Public Admin Console on its own canonical URL. Waits until an admin exists before serving. |
| `domain` × 0–2 | Only when `customDomain.core` / `customDomain.adminConsole` are set |
| identity + policy | `reveal` on the admin secret and the DB credentials secret only |
| `postgresHA` 3.0.0 (default; new clusters PostgreSQL 18, a 1.x cluster keeps 17) or `postgres` 4.0.2 (PostgreSQL 19, major-version boot guard) | All Logto state, including OIDC signing keys and the admin account |

- **Boot (both workloads, inline script, no secret):** derive `ENDPOINT`/`ADMIN_ENDPOINT` → Postgres SSLRequest gate + `select 1` (420 s cap) → under `pg_advisory_lock`: `db seed --swe`, `db alteration deploy latest`, and (core only) the bootstrap → `exec node .`
- **First-admin bootstrap:** Logto has no admin env var. The core workload starts a temporary localhost-only Logto and registers the secret's account through the Admin Console's own Experience-API flow (`admin-console` client, admin tenant), so Logto's `provisionForFirstAdminUser` gives it exactly what a manual Console claim gives. It then verifies the DB (one admin user, `SignIn` mode, tenant Admin role). It skips when any admin-tenant user exists.
- **URLs:** each workload derives the other's canonical URL by rewriting the workload-name prefix of its own `CPLN_GLOBAL_ENDPOINT`.
- **Availability:** multi-replica is free in OSS and needs no peer traffic (state only in Postgres); default 2 replicas + HA Postgres.

## Key knobs
`replicas` (1–4) · `resources` · `admin.secretName` · `publicAccess.enabled` · `adminConsole.publicAccess.enabled` · `customDomain.core` / `.adminConsole` · `internalAccess` · `postgresHA` / `postgres` (+ `credentialsSecretName`, backups) · `postgres.image: postgres:19` (2.0.0; a 1.x single-instance release must keep `postgres:18`)

## Troubleshooting / considerations
- **No logs, deployment stuck:** a prerequisite secret is missing; read `status.versions[].message` via `cpln workload get-deployments`.
- **Admin workload "ready" but its URL 503s:** it is waiting for the admin account (`waiting for the first admin account` in its log). The cause is on the core workload: look for `FATAL bootstrap …` there.
- **Bootstrap FATAL `password.rejected`:** the password is breached, too weak, or `api.pwnedpasswords.com` was unreachable (Logto fails closed). Fix the secret, then `force-redeployment` the core workload.
- **`EADDRINUSE :3002` on the admin workload:** something unset `PORT`. The platform injects `PORT` = the first container port (3002 there), and Logto reads `PORT` for its core server, so the chart pins `PORT=3001` / `ADMIN_PORT=3002` on both workloads.
- **The admin secret is read once.** Rotating it changes nothing; the password is changed in the Console. No verified recovery for a lost admin password.
- **CORS:** with the public Console on, `ADMIN_ENDPOINT` is set, so Logto drops localhost from the admin origins. A port-forwarded Console can sign in but cannot call the API. Turn the public Console off for a working port-forward Console.
- **Database failover:** Logto's pg pool emits an unhandled `error` when the server drops a connection, which used to crash every replica at once (≈60–70 s outage + cold boot). The boot script runs `node --import /tmp/logto-guard.mjs .`, which swallows only lost-connection errors (`Connection terminated`, `ECONNRESET`, `57P01`…; anything else still exits 1). Measured 10-30: SIGSTOP of the Patroni leader → ~58 s of failed sign-ins (the failover itself), zero Logto restarts, recovered on its own. Log line: `[logto-guard] database connection lost`.
- **Changing `publicAccess` or `customDomain.core` changes the OIDC issuer:** every app's config must change.
- **Custom domains (tested 10-30 on data-test.uk):** a TXT `_cpln.{apex}` = org name plus a CNAME per hostname to `{gvcAlias}.cpln.app` is all it needs; the issuer becomes the core domain, and reinstalls need no re-verification. `cpln helm upgrade` reports the domains `Updated` on every run: only the `cpln/release` tag moves, the spec is unchanged.
- **Webhooks to internal targets (`webhooks.allowInternalTargets`, default off):** Logto refuses webhook URLs that resolve to special-use addresses, and every `*.cpln.local` name resolves into the mesh's `240.240.0.0/16` (the Istio DNS auto-allocation range). On, the chart sets `SSRF_ALLOWED_ADDRESSES=240.240.0.0/16`, exactly that range. Risk: whoever manages webhooks (Console admin, or an app with Management API access) can then make Logto call any internal workload it can reach. Tested 10-30 both ways after a full rollout (a mid-rollout test hits the old replica). Logto also disables dynamic client registration while an allowlist is set.
- **OSS = one Console admin;** inviting more admins is the paid Self-Hosted Pro feature.
- **Uninstall deletes the database volumes,** and with them all users and signing keys.
- **2.0.0 (2026-11-25, work item 5605): both database modes move.** Single-instance: postgres 3.4.1 → 4.0.2 (PostgreSQL 19, backup image `postgres-backup:19.1.0`). A plain upgrade of a 1.x single-instance release is refused by the subchart's guard (PG 18 data: server not started, volume untouched, `[pg-guard] REFUSING TO START` every 30 s); `postgres.upgradeHint` makes the guard's FIX lines name `--set postgres.image=postgres:18`, `Upgrade > Database server > Postgres image` and README "Upgrading from 1.x". HA (the default, unchanged): pg-ha 2.8.1 → 3.0.0, image `0.8` → `0.9` (bundles PG 14-18), so a default 1.x upgrade needs no pin and the cluster stays on 17; members restart one by one. Also from pg-ha 3.0.0: logical backup image `18.2.0`, and the backup identity drops `aws::ReadOnlyAccess` (AWS users update the bucket IAM policy to pg-ha's action list first). Moving to 18 / 19 = side-by-side release with the SAME two secrets (dump/restore keeps users, apps and signing keys; the issuer changes unless custom domains are moved over after the old release is uninstalled); no in-place pg_upgrade.
- **Wizard (2.0.0):** imports postgres 4.0.2 (excluding `image` + `resources`, bound in the parent's "Database server" step with the 1.x upgrade note and the cross-major warning) and pg-ha 3.0.0; a parent migration keeps a 1.x single-instance release's installed `postgres.image` (`tw carry`: `postgres:18` kept); the `enabled` echo switches are hidden; HA upgrade notes (17 kept; AWS IAM) on the Database step.
- **cpln-connector:** Logto's own identity never had it; both subcharts' backup identities dropped it (postgres 3.4.3, pg-ha 3.0.0).
- **E2E (2.0.0):** baseline stays HA with a plain `upgradeFrom: 1.0.0` (pg-ha 2.8.1 → 3.0.0; `ha-postgres-major` = 17 after the upgrade, 18 fresh); a `[single]` variant proves PG 19, the guard handing over, and the bootstrap admin in the 19 database, plus every Logto feature check. The refused single-instance upgrade from 1.0.0 cannot be expressed (the starting install always uses 1.0.0's HA baseline), so it is a live test row.
