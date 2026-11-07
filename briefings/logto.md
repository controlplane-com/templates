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
| `postgresHA` 2.8.1 (default) or `postgres` 3.4.1 | All Logto state, including OIDC signing keys and the admin account |

- **Boot (both workloads, inline script, no secret):** derive `ENDPOINT`/`ADMIN_ENDPOINT` → Postgres SSLRequest gate + `select 1` (420 s cap) → under `pg_advisory_lock`: `db seed --swe`, `db alteration deploy latest`, and (core only) the bootstrap → `exec node .`
- **First-admin bootstrap:** Logto has no admin env var. The core workload starts a temporary localhost-only Logto and registers the secret's account through the Admin Console's own Experience-API flow (`admin-console` client, admin tenant), so Logto's `provisionForFirstAdminUser` gives it exactly what a manual Console claim gives. It then verifies the DB (one admin user, `SignIn` mode, tenant Admin role). It skips when any admin-tenant user exists.
- **URLs:** each workload derives the other's canonical URL by rewriting the workload-name prefix of its own `CPLN_GLOBAL_ENDPOINT`.
- **Availability:** multi-replica is free in OSS and needs no peer traffic (state only in Postgres); default 2 replicas + HA Postgres.

## Key knobs
`replicas` (1–4) · `resources` · `admin.secretName` · `publicAccess.enabled` · `adminConsole.publicAccess.enabled` · `customDomain.core` / `.adminConsole` · `internalAccess` · `postgresHA` / `postgres` (+ `credentialsSecretName`, backups)

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
- The bundled postgres-highly-available 2.8.1 shows probe-field drift (`scheme`, `initialDelaySeconds`, `successThreshold`); it is in the subchart, not this chart.
