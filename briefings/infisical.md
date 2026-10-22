# Infisical — Maintainer Briefing

## What it is
- Open-source secrets-management platform (store, version, scope, and serve app secrets via web UI + REST API).
- License: **MIT core** (a permissive open-source license — free to self-host, no key/registration). A few SSO/SCIM features are enterprise-gated and are NOT shipped.

## Common use cases
- Central secrets store teams point apps at (UI/CLI/API) instead of scattering `.env` files.
- Per-environment (dev/staging/prod) secret scoping with access controls and version history.
- A self-hostable Vault/Doppler alternative co-located with its Postgres + Redis on cpln.
- Injecting secrets into other cpln workloads / CI at deploy or runtime.

## Architecture on cpln
| Resource | Purpose |
|---|---|
| `{release}-infisical` (standard workload, :8080) | Infisical server — UI + API; `replicas` knob (1 default, ≥2 = HA) |
| `{release}-postgres` (postgres subchart) | Durable secret store — all persistent state lives here |
| `{release}-redis` + `{release}-sentinel` (redis subchart) | Cache + BullMQ job queues; connected Sentinel-aware (master `mymaster`) |
| user secret `postgres.config.credentialsSecretName` (dictionary, prerequisite since 1.2.0) | DB creds `username`/`password`/`database`: postgres initializes from it, the app reads the same keys as env vars and assembles `DB_CONNECTION_URI` from `$(VAR)` placeholders at container start |
| user secret `secrets.name` (dictionary, prerequisite) | Root-of-trust: `ENCRYPTION_KEY` + `AUTH_SECRET` |
| user secret `redis.redis.auth.fromSecret.name` (dictionary, OPTIONAL prerequisite since 1.2.0) | Redis password, key `password`, only when `redis.redis.auth.fromSecret.enabled: true`; the redis subchart's `fromSecret` feeds Redis + Sentinel and grants their identities reveal, Infisical reads it as `REDIS_PASSWORD` |
| identity + policy | `reveal` on exactly the secrets above (least privilege) |

- Stateless app tier over shared Postgres + Redis → scales horizontally with no peer discovery.
- HTTP only: public access uses the auto `*.cpln.app` HTTPS endpoint (no `loadBalancer.direct`).

## Key knobs
| Knob | Default | Note |
|---|---|---|
| `infisical.replicas` | `1` | ≥2 = HA (stateless); rolling-restart + replica-down tested |
| `infisical.siteUrl` | `""` | Empty = derive from platform canonical endpoint; set for custom domain (with `https://`) |
| `secrets.name` | `my-infisical-secrets` | Prerequisite dictionary secret — MUST exist before install |
| `smtp.enabled` (+ `host/port/fromAddress/…`) | `false` | Optional outbound email (invites, verification, reset); optional auth via `smtp.auth.secretName` dictionary secret (`SMTP_USERNAME`/`SMTP_PASSWORD`), empty = unauthenticated (mail-catcher) |
| `publicAccess.enabled` / `internalAccess.type` | `true` / `same-gvc` | Standard exposure pattern |
| `postgres.config.credentialsSecretName` | `my-infisical-db-credentials` | REQUIRED prerequisite dictionary secret (`username`/`password`/`database`) — must exist before install. `postgres.credentials` was removed in 1.2.0 and now fails the render |
| `redis.redis.auth.fromSecret.enabled` / `.name` | `false` / `""` | Redis AUTH off by default; on = password from the named prerequisite secret. `redis.redis.auth.password` was removed in 1.2.0 and fails the render |
| `postgres.*` / `redis.*` | bundled | Pass-through to the dependency templates |

## Troubleshooting / considerations
- **Prerequisite secret must exist BEFORE install.** `secrets.name` is a dictionary secret with `ENCRYPTION_KEY` (`openssl rand -hex 16`) and `AUTH_SECRET` (`openssl rand -base64 32`). Missing → deployment wedges waiting on a nonexistent secret and looks broken.
- **`ENCRYPTION_KEY` and `AUTH_SECRET` are WRITE-ONCE — never rotate.** Rotating `ENCRYPTION_KEY` corrupts every stored secret (it is the key they are encrypted with); rotating `AUTH_SECRET` invalidates all sessions. Same trap as gitea `SECRET_KEY` / litellm `SALT_KEY`.
- **First user to sign up becomes super-admin.** No admin env vars — bootstrap is the web signup page on first visit. With public access on, create your admin account IMMEDIATELY and then disable open signups in the admin panel, or someone else could claim admin first.
- **Redis is REQUIRED, not optional** (unlike litellm). Infisical won't boot without a Redis connection; the template hard-wires the Sentinel dependency.
- **Migrations run on every boot** (knex, unconditional). On a cold multi-replica (`replicas≥2`) install, replicas race the initial migration — knex's migration lock serializes them; spike-verified at build time. Single-replica default sidesteps it.
- **Keep `maxMemory` at 2Gi.** A cold `replicas≥2` boot running migrations OOMs at 1Gi (hit in testing) — the shipped default is 2Gi; don't trim it back down.
- **Secret data survives an app restart/reinstall but lives in Postgres** — to wipe all stored secrets you must also reinstall the Postgres dependency (its volumeset), not just the app.
- **Redis holds only cache/queue state, not secrets** — a Redis blip degrades background jobs briefly but never risks stored secrets (those are in Postgres). Redis ships authless behind the same-GVC firewall; `redis.redis.auth.fromSecret.enabled: true` (+ `name`) requires AUTH.
- **`SITE_URL` drives cookies and links.** If login cookies or UI links look wrong, check `siteUrl`/the derived canonical endpoint — a mismatched `SITE_URL` breaks Secure-cookie login behind the HTTPS LB.
- **DB credentials are a prerequisite secret since 1.2.0 (work item 5284).** Rule (maintainer 2026-10-14): when the bundled `postgres` subchart takes only a credentials-secret NAME, the parent requires the user to create that same secret — no plaintext `postgres.credentials`. 1.1.0's two chart-built secrets (the subchart's and a duplicate `{release}-infisical-db` with `postgresUsername`/`postgresPassword`) are both gone; the app now reads `username`/`password`/`database` from the user's secret.
- **`DB_CONNECTION_URI` is assembled at container start**, `postgres://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@host:5432/$(POSTGRES_DB)` over `cpln://secret/...` env vars (plane/langfuse/fusionauth precedent). The values are not URL-encoded, so the password and database must be URL-safe — the README says so; `openssl rand -hex` passwords are. [UNPROVEN for infisical until the 1.2.0 test round: the database name moving from a rendered literal to `$(POSTGRES_DB)`.]
- **Upgrade 1.1.0 → 1.2.0 deletes the chart-created DB secret.** The user must create a NEW-name secret holding the CURRENT values and point `credentialsSecretName` at it; reusing the old name races the delete. The wizard blocks an unchanged name on an upgrade from <1.2.0. Expect a postgres restart and up to ~10 min of `is not allowed to reveal the secret` on the new version while the grant propagates (old version keeps serving).
- **Password rotation:** `ALTER ROLE` first, then `cpln secret edit`, then right away force-redeploy `{release}-infisical` (not postgres). (Single-instance; measured on umami 2026-10-16: skipping the postgres redeploy cut the outage from ~135 s to a few seconds. Postgres reads the secret only at first init; open app connections survive `ALTER ROLE`, only new ones fail.) Editing the secret alone changes nothing (references resolve at replica start; the data dir keeps the initial password).
- **Redis password became an (optional) prerequisite secret in 1.2.0 (5284 round 3).** `redis.redis.auth.password` fails at render (`infisical.validateRedisSecret`, mirrored in the wizard; also included from `templates/validate/redis/auth.yaml` because Helm renders subchart templates first and the subchart's "Only one authentication method" would otherwise win). A 1.1.0 install with auth ON must create a NEW-name secret holding the CURRENT password (the upgrade deletes `{release}-redis-auth-password`). Rotation [UNPROVEN on the platform; order verified on local Docker redis:7.4, 1 master + 1 replica + 1 sentinel incl. a failover]: every node `ACL SETUSER default >NEW` + `CONFIG SET masterauth NEW`, every Sentinel `SENTINEL SET mymaster auth-pass NEW`, secret edit, force-redeploy Infisical, then `ACL SETUSER default <OLD`. No Redis restart.
- **Sentinel auth is refused unconditionally since 1.2.1** (`infisical.validateSentinelAuth`, also from `templates/validate/redis/auth.yaml`; wizard rule in the Redis step). Through 1.2.0 the check sat inside the Redis-auth-on branch, so with Redis auth off `redis.sentinel.auth.password.enabled: true` + `.value` rendered the plaintext into `{release}-sentinel-auth-password`. Infisical never sends a Sentinel password, so Sentinel auth was never a working shape; no fromSecret path is offered. Render-only change: the default render is identical to 1.2.0 apart from chart-version tags.
- **Missing DB secret wedges silently** (zero log lines) — diagnose via `status.versions[].message` in `cpln workload get-deployments`.
- **Availability posture:** app tier is multi-instance-capable in the free MIT core and cpln-feasible → HA is offered via `replicas`. Default is the proven single-replica shape; set ≥2 for near-zero-downtime.
