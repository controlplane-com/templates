# FusionAuth — Maintainer Briefing

## What it is
- Self-hosted identity and access management: user store, login/registration flows, OAuth2, OIDC and SAML, plus an admin UI with a setup wizard.
- Edition shipped is the free **Community** edition. It is free to self-host (passes the catalog's cost-to-the-user test) but it is *not* an OSI license, and some features (advanced MFA, SCIM, several enterprise SSO features) are paid-plan gated — check upstream pricing before claiming a capability in docs.
- One of the catalog's oldest templates (created 2025-08-15); it predates most of the current conventions, which is visible in its README and values.

## Common use cases
- Drop-in auth for an application: hosted login pages, OAuth2/OIDC authorization-code flow, JWT issuance.
- SAML or social/IdP federation (Google, Microsoft, …) configured through the admin panel.
- A self-hosted alternative to Auth0/Okta where the user store must stay on the customer's own infrastructure.

## Architecture on cpln
| Resource | Purpose |
|---|---|
| `{release}-fusionauth` (**serverless** workload) | FusionAuth app on http :9011; autoscaling min 1 / max 3, `capacityAI: true`, `scaleToZeroDelay: 300` |
| `{release}-fusionauth-startup` (opaque secret) | Start script mounted at `/opt/fusionauth/start-fusionauth.sh`: polls `pg_isready` up to 60×5 s, then execs FusionAuth's `start.sh` |
| DB credentials secret (dictionary, **user-created** since 2.5.0) | `username`/`password`/`database` — named by `postgres.config.credentialsSecretName`; the postgres subchart and FusionAuth both read it |
| `{release}-fusionauth-identity` + `-policy` | `reveal` on exactly the startup script and the user's DB secret (by name) |
| `{release}-postgres` (postgres subchart, **3.4.1** since 2.4.0) | Backing database — reused template, unconditional (there is no `postgres.enabled` knob and no `condition` on the dependency) |

- No volumeset on the app tier — all state is in Postgres. No HA database path: this template has only the single-instance `postgres` dependency.
- Image is **`controlplanecorporation/fusionauth:0.2`**, a Control-Plane-published image, not an upstream tag. `appVersion` is `1.60.2` (the FusionAuth version inside it). Bumping FusionAuth means rebuilding that image, not editing a tag.

## Key knobs
| Knob | Default | Note |
|---|---|---|
| `image` | `controlplanecorporation/fusionauth:0.2` | our image, see above |
| `resources.cpu` / `resources.memory` | `512m` / `1024Mi` | limit-only block, so bare names are correct |
| `firewall.external.inboundAllowCIDR` | `0.0.0.0/0` | **public by default** — the admin UI and login pages are on the internet |
| `firewall.external.outboundAllowCIDR` | `[]` | **egress is closed by default**; external IdP federation needs this opened |
| `firewall.internal.type` | `same-gvc` | internal scope for the app workload |
| `postgres.config.credentialsSecretName` | `my-fusionauth-db-credentials` | REQUIRED prerequisite dictionary secret (`username`, `password`, `database`), **2.5.0+**. Must exist BEFORE install; a missing one wedges with zero log lines |
| `postgres.backup.*` | `enabled: false`, provider `aws` | pass-through to the postgres template's native backup; the subchart also accepts `minio` (keys in a prerequisite secret — not exposed in fusionauth's values, untested through this chart). The README's AWS IAM policy was the 6-action one until 2026-10-01; it now matches the subchart's 10-action policy (adds `GetBucketLocation` + multipart actions) |

## Troubleshooting / considerations
- **2.5.0: the DB credentials became a prerequisite secret (maintainer ruling 2026-10-14, work item 5284).** Rule: when a dependency requires a pre-existing credential secret, the parent requires it too rather than rebuilding it from plaintext values. 2.4.x kept `postgres.credentials.*` as values under the bundled-plumbing exception and rendered the secret itself (`secret-db.yaml`, now deleted), which put the DB password in the Helm release. `postgres.credentials` now fails at render (`fusionauth.validateRemovedKeys`, mirrored in the wizard; the subchart ignores that key, so the parent guard is live).
- **The JDBC URL is assembled at container start, not at render.** `DATABASE_URL` is `jdbc:postgresql://{release}-postgres.{gvc}.cpln.local:5432/$(POSTGRES_DB_NAME)`, where `POSTGRES_DB_NAME` is a `cpln://secret/….database` env var (the platform's `$(VAR)` expansion; declaration order is irrelevant since the API stores env alphabetically). Proven live 2026-10-14: the container saw the fully expanded URL for a non-default database and FusionAuth created its 91 tables there. So the database name must be URL-safe — a README prerequisite now, since there is no plaintext value left to check at render. `DATABASE_USERNAME`/`DATABASE_PASSWORD` are direct secret refs as before.
- **Upgrading 2.4.x → 2.5.0 deletes the chart-created DB secret**, because the new chart no longer renders it. The user must create a secret under a NEW name holding the CURRENT credentials (the data dir keeps the password it was initialized with; a 2.4.0 install that never overrode it has the literal password `password`, and 2.4.x defaults were `username`/`test`) and point `postgres.config.credentialsSecretName` at it. The wizard enforces the new name with an `oldSelf` rule. The new reveal grant can stall the new version ~10 min on `is not allowed to reveal the secret` (authorization edge cache; seen on gitea 1.3.0); the fusionauth upgrade test (2026-10-14) did not hit it — FusionAuth ready +42 s, postgres +137 s, data intact, two no-op upgrades fully `Unchanged`.
- **Password rotation: `ALTER ROLE`, `cpln secret edit`, then right away force-redeploy FusionAuth only — never postgres.** (Single-instance; measured on umami 2026-10-16: skipping the postgres redeploy cut the outage from ~135 s to a few seconds. Postgres reads the secret only at first init; open app connections survive `ALTER ROLE`, only new ones fail.) If postgres does restart around the same time, FusionAuth can start before it and `/api/status` reads 453 "Unhealthy Hikari Pool Connection" for ~4 min (it self-heals in-process). Secret data changes with `cpln secret edit`; `cpln secret update` cannot change data.
- **A stale 2.3.x values file (`postgres.config.username` etc.) fails with the SUBCHART's message** — its "create a dictionary secret" advice is now correct for fusionauth too.
- **Egress is closed by default (`outboundAllowCIDR: []`).** External IdP federation (Google OAuth, SAML to a remote IdP) fails until it is opened. This is the first thing to check when "social login does nothing".
- **The workload is `serverless` with `maxScale: 3`** — i.e. it can run three FusionAuth nodes under load. FusionAuth's multi-node story wants matching cache/search configuration, and this template ships none. Nobody has tested a scaled-out instance; treat >1 replica as **unverified**, and pin `maxScale: 1` if a user reports cache-coherence oddities.
- **First boot waits on Postgres by design.** The startup script polls `pg_isready` for up to 5 minutes; a FusionAuth container that looks stuck early in an install is usually just waiting for the database.
- **The first `helm upgrade` after an install re-applies the bundled Postgres** (catalog-wide behaviour, not a fusionauth defect) — expect the app to be briefly unreachable while the database restarts. Later upgrades are clean.
- **The README predates the seven-section convention** and is still structured as Overview / Getting Started / Backing Up Postgres / Restoring. 2.5.0 rewrote only Prerequisites, the DB config block and the upgrade sections; a full rewrite is outstanding.
- **2.5.0 is the first version with a `wizard.yaml`** (imports postgres 3.4.1; pgbouncer excluded + `yamlOnly`; `gvc` 1/1).
