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
| `my-fusionauth-db-credentials` (dictionary, **chart-created**, 2.4.0+) | `username`/`password`/`database` for the bundled DB; built from `postgres.credentials.*` and handed to the postgres subchart by name |
| `{release}-fusionauth-identity` + `-policy` | `reveal` on exactly the DB credential secret and the startup script |
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
| `postgres.credentials.{username,password,database}` | `username` / `change-me-fusionauth-db` / `test` | **2.4.1** — password placeholder fixed; bundled plumbing, correctly plain values |
| `postgres.config.credentialsSecretName` | `my-fusionauth-db-credentials` | **2.4.0** — name of the dictionary secret the CHART creates and the subchart reads; org-wide, so unique per release |
| `postgres.backup.*` | `enabled: false`, provider aws/gcp | pass-through to the postgres template's native backup |

## Troubleshooting / considerations
- **2.4.0 adopted postgres 3.4.1 and absorbed the break rather than passing it on.** 3.4.0 deleted its `{release}-pg-config` secret and now takes only a secret NAME. Because a parent cannot template a subchart value, the name is a plain value (`postgres.config.credentialsSecretName`) that BOTH sides read: fusionauth's `secret-db.yaml` renders it, the subchart's env refs and policy consume it, and `fusionauth.secretPostgres.name` points the app at it. Net user-visible change is one rename (`postgres.config.*` → `postgres.credentials.*`); **no new prerequisite**, because no human ever types this password.
- **A stale 2.3.x values file fails with the SUBCHART's message, not fusionauth's.** Helm renders `charts/…` before `templates/…`, so the postgres chart's "create a dictionary secret" advice always wins — advice that is wrong here, since this template creates it. The README's "Upgrading from 2.3.x" table carries the correction; a parent-side guard would be dead code.
- **The secret name is org-wide, not release-scoped** (forced by the Helm limitation above). Two fusionauth releases in one org left at the default both render `my-fusionauth-db-credentials`, and the second install is **REFUSED** (`cannot be updated because it is being managed by a different release`) and creates nothing. Nothing is shared, overwritten or deleted; you simply cannot install the second until you give it a distinct name.
- **The password default was fixed in 2.4.1** — `change-me-fusionauth-db` instead of `password` — with the migration note 2.4.0's briefing said this needed. `username` and `database` were deliberately left alone: they are baked into the initialized data directory and `database` also forms the JDBC URL, so changing them would break an upgrade for no security gain. An install that never overrode the password has a database whose password is literally `password`; the README tells such a user either to pin `postgres.credentials.password: password` explicitly or to rotate with `ALTER ROLE` first.
- **These credentials stay plain values, correctly.** The chart creates the secret from them, the bundled Postgres is the only consumer, and no human types the password anywhere else — the bundled-datastore exception applies. `database` additionally cannot come from a secret at all: it is interpolated into the JDBC URL at render time, where a `cpln://` reference would be literal text.
- **Egress is closed by default (`outboundAllowCIDR: []`).** External IdP federation (Google OAuth, SAML to a remote IdP) fails until it is opened. This is the first thing to check when "social login does nothing".
- **The workload is `serverless` with `maxScale: 3`** — i.e. it can run three FusionAuth nodes under load. FusionAuth's multi-node story wants matching cache/search configuration, and this template ships none. Nobody has tested a scaled-out instance; treat >1 replica as **unverified**, and pin `maxScale: 1` if a user reports cache-coherence oddities.
- **First boot waits on Postgres by design.** The startup script polls `pg_isready` for up to 5 minutes; a FusionAuth container that looks stuck early in an install is usually just waiting for the database.
- **The first `helm upgrade` after an install re-applies the bundled Postgres** (catalog-wide behaviour, not a fusionauth defect) — expect the app to be briefly unreachable while the database restarts. Later upgrades are clean.
- **The README predates the seven-section convention** and is still structured as Overview / Getting Started / Backing Up Postgres / Restoring. 2.4.0 only added the credentials note and the upgrade table; a full rewrite is outstanding.
