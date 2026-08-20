# Keycloak — Maintainer Briefing

## What it is
- Open-source identity and access management: single sign-on, OIDC/SAML identity provider, user federation (LDAP/AD), social login, fine-grained authorization. Apache-2.0, CNCF incubating.
- Runs Keycloak 26 in **production mode** (`kc.sh start`, not `start-dev`) against PostgreSQL. Clustered by default over embedded Infinispan.

## Common use cases
- One login across a company's internal apps (the apps become OIDC clients).
- An auth backend for a product: user registry, password reset, MFA, token issuance.
- Bridging an existing LDAP/AD directory into modern OIDC/SAML apps.
- Sitting in front of other catalog templates that speak OIDC (grafana, gitea, unleash…).

## Architecture on cpln
| Resource | Purpose |
|---|---|
| `{release}-keycloak` workload (stateful, :8080 http) | Keycloak server; ports 7800 + 57800 (tcp) added only when `replicas > 1` |
| `{release}-keycloak-startup` secret (opaque) | Boot script: DB wait + cluster advertise-address derivation |
| user's `admin.secretName` secret (dictionary, **prerequisite**) | Bootstrap admin `username` + `password` — created by the user, never by the chart |
| identity + policy | `reveal` on exactly three secrets: admin, startup, DB config |
| `my-keycloak-db-credentials` secret (dictionary, **chart-created**, 1.2.0+) | `username`/`password`/`database` for the bundled single-instance DB; built from `postgres.credentials.*` and handed to the postgres subchart by name. Single-instance path only |
| `postgresHA` subchart (default, **2.4.2** — creates its own `{release}-postgres-config`) or `postgres` subchart (dev, **3.4.1** since 1.2.0 — creates no secret of its own) | All durable state; exactly one enabled (XOR validated) |

- **No volumeset** — realms, users and sessions all live in Postgres.
- Clustering uses **JGroups JDBC_PING through the shared database** (no UDP gossip, which the platform does not support on internal ports). Each replica advertises `replica-{i}.{workload}.{location}.{gvc}.cpln.local`, derived in the startup script from `$HOSTNAME` — valid only because the tier is `stateful`.

## Key knobs
| Knob | Default | Note |
|---|---|---|
| `image` | `quay.io/keycloak/keycloak:26.6.3` | |
| `replicas` | `2` | 2+ = Infinispan cluster, zero-downtime restarts; 1 = clustering disabled (local cache) |
| `resources` | 1000m/500m cpu · 2Gi/1Gi mem | JVM heap = 70% of the limit; **do not go below 1.5Gi** |
| `admin.secretName` | `my-keycloak-admin` | **Prerequisite dictionary secret** (`username`, `password`) — 1.1.0 |
| `publicAccess.enabled` | `true` | Browsers must reach the login/OIDC endpoints; kept public deliberately |
| `internalAccess.type` | `same-gvc` | `none` is rejected at render when `replicas > 1` |
| `postgresHA.*` / `postgres.*` | HA on, single off | Exactly one; `postgresHA.proxy.enabled` must stay true |
| `postgres.credentials.{username,password,database}` | `keycloak` / `change-me-keycloak-db` / `keycloak` | **1.2.0** — was `postgres.config.*`; bundled plumbing, still plain values |
| `postgres.config.credentialsSecretName` | `my-keycloak-db-credentials` | **1.2.0** — name of the dictionary secret the CHART creates and the subchart reads; org-wide, so unique per release |
| `postgres.backup.minio.credentialsSecretName` | `my-keycloak-minio-credentials` | **1.2.0** — genuine prerequisite, only when the single-instance `backup.provider: minio` |

## Troubleshooting / considerations
- **Workload wedged with ZERO log lines** → the prerequisite admin secret does not exist. `cpln logs` shows nothing because the container never starts; the only diagnostic is `status.versions[].message` from `cpln workload get-deployments … -o yaml` (**not** plain `get`). Self-heals in ~5.5–10.5 min once the secret exists, or force a redeployment (~90 s).
- **Admin password is first-boot only.** `KC_BOOTSTRAP_ADMIN_*` is consulted only when no admin exists; editing the secret on a live install changes nothing. Change it in the admin console. Same trap as listmonk/unleash/metabase.
- **The bootstrap admin is temporary by design** — Keycloak logs a standing warning until a permanent admin is created and the temporary one removed.
- **Long first boot is normal.** The startup script waits for Postgres by speaking the Postgres SSL handshake (the image ships no `psql`/`pg_isready`/`curl`), and a plain TCP connect is *not* a valid readiness signal — the HAProxy leader endpoint accepts connections before a Patroni primary is routable. HA first boot runs several minutes.
- **Liveness during the DB wait is deliberately suppressed** via the `/tmp/kc-db-wait` sentinel; do not "simplify" the exec probe into an HTTP probe or the workload crash-loops before the database is up.
- **Do not raise `replicas` with `internalAccess.type: none`** — replicas must reach each other on 7800/57800; render-validated.
- **`aws::ReadOnlyAccess`** does not appear on this template's identity, and `postgres` 3.4.1 dropped it in 3.4.0. `postgres-highly-available` 2.4.2 — the DEFAULT store here — still carries it on its identity.
- **1.2.0 adopted postgres 3.4.1, and keycloak absorbed the break rather than passing it on.** 3.4.0 deleted its `{release}-pg-config` secret and now takes only a secret NAME. Because a parent cannot template a subchart value, the name is a plain value (`postgres.config.credentialsSecretName`) that BOTH sides read: keycloak's `secret-db.yaml` renders it, the subchart's env refs and policy consume it, and `keycloak.db.secretName` points the app at it. Net user-visible change is one rename on the single-instance path; **no new prerequisite**, because no human ever types this password.
- **The secret name is org-wide, not release-scoped** (forced by the Helm limitation above). Two keycloak releases left on the default name: the second is **refused at install** — `cannot be updated because it is being managed by a different release` — and creates nothing. Nothing is shared, overwritten or deleted. No render-time guard for it.
- **A stale 1.1.0 values file fails with the SUBCHART's message, not keycloak's.** Helm renders `charts/…` before `templates/…`, so a parent-side guard would be dead code and was deliberately not added. 3.4.1's message appends a clause telling bundled users not to create a secret themselves; the README's "Upgrading from 1.1.0" table carries the rename.
- **The HA branch was deliberately left alone.** `postgres-highly-available` 2.4.2 has not adopted the convention: `postgresHA.postgres.username/password/database` are still values, it creates `{release}-postgres-config` itself, and its MinIO backup keys are still plain values. When pg-ha adopts it, `keycloak.db.secretName`'s HA branch and the `postgresHA` values block are the two places to change.
- **Public access is intentional.** Unlike the templates flipped private this cycle, the credential here is user-created, and a private Keycloak cannot serve browser SSO to anything.
