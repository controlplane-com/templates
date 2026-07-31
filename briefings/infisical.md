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
| `{release}-infisical-db` secret (dictionary) | Bundled-DB creds → assembles `DB_CONNECTION_URI` |
| user secret `secrets.name` (dictionary, prerequisite) | Root-of-trust: `ENCRYPTION_KEY` + `AUTH_SECRET` |
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
| `postgres.*` / `redis.*` | bundled | Pass-through to the dependency templates; `redis.redis.auth.password.enabled: true` = require AUTH |

## Troubleshooting / considerations
- **Prerequisite secret must exist BEFORE install.** `secrets.name` is a dictionary secret with `ENCRYPTION_KEY` (`openssl rand -hex 16`) and `AUTH_SECRET` (`openssl rand -base64 32`). Missing → deployment wedges waiting on a nonexistent secret and looks broken.
- **`ENCRYPTION_KEY` and `AUTH_SECRET` are WRITE-ONCE — never rotate.** Rotating `ENCRYPTION_KEY` corrupts every stored secret (it is the key they are encrypted with); rotating `AUTH_SECRET` invalidates all sessions. Same trap as gitea `SECRET_KEY` / litellm `SALT_KEY`.
- **First user to sign up becomes super-admin.** No admin env vars — bootstrap is the web signup page on first visit. With public access on, create your admin account IMMEDIATELY and then disable open signups in the admin panel, or someone else could claim admin first.
- **Redis is REQUIRED, not optional** (unlike litellm). Infisical won't boot without a Redis connection; the template hard-wires the Sentinel dependency.
- **Migrations run on every boot** (knex, unconditional). On a cold multi-replica (`replicas≥2`) install, replicas race the initial migration — knex's migration lock serializes them; spike-verified at build time. Single-replica default sidesteps it.
- **Keep `maxMemory` at 2Gi.** A cold `replicas≥2` boot running migrations OOMs at 1Gi (hit in testing) — the shipped default is 2Gi; don't trim it back down.
- **Secret data survives an app restart/reinstall but lives in Postgres** — to wipe all stored secrets you must also reinstall the Postgres dependency (its volumeset), not just the app.
- **Redis holds only cache/queue state, not secrets** — a Redis blip degrades background jobs briefly but never risks stored secrets (those are in Postgres). Redis ships authless behind the same-GVC firewall; `redis.redis.auth.password.enabled: true` requires AUTH.
- **`SITE_URL` drives cookies and links.** If login cookies or UI links look wrong, check `siteUrl`/the derived canonical endpoint — a mismatched `SITE_URL` breaks Secure-cookie login behind the HTTPS LB.
- **Availability posture:** app tier is multi-instance-capable in the free MIT core and cpln-feasible → HA is offered via `replicas`. Default is the proven single-replica shape; set ≥2 for near-zero-downtime.
