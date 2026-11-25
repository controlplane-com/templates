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
| `{release}-keycloak-startup` secret (opaque) | Boot script: DB wait (Postgres SSLRequest bytes, not a TCP connect) + cluster advertise-address derivation |
| user's `admin.secretName` secret (dictionary, **prerequisite**) | Bootstrap admin `username` + `password`; first boot only |
| user's DB credentials secret (dictionary, **prerequisite** since 1.5.0) | `username`/`password`/`database`, named by `postgresHA.config.credentialsSecretName` (HA) or `postgres.config.credentialsSecretName` (single). The active subchart initializes from it; `KC_DB_URL` is assembled at start from `$(POSTGRES_DB_NAME)`, so the database name must be URL-safe |
| identity + policy | `reveal` on exactly three secrets: admin, startup, DB credentials. No `cpln-connector` anywhere (keycloak's identity never had it; both subcharts' backup identities dropped it) |
| `postgresHA` subchart (default) — postgres-highly-available **3.0.0** since 2.0.0 | 3 Patroni + 3 etcd + HAProxy on `patroni-postgres:0.9`. New clusters PostgreSQL 18; a 1.x cluster keeps 17 in place (the image bundles 14-18) |
| `postgres` subchart (opt-in) — postgres **4.0.2** since 2.0.0 | One PostgreSQL 19 instance with a major-version boot guard |

- Exactly one store enabled (XOR at render). **No volumeset** — realms, users and sessions all live in Postgres.
- Clustering uses **JGroups JDBC_PING through the shared database** (no UDP gossip). Each replica advertises `replica-{i}.{workload}.{location}.{gvc}.cpln.local`, derived from `$HOSTNAME` — valid only because the tier is `stateful`.

## Key knobs
| Knob | Default | Note |
|---|---|---|
| `image` | `quay.io/keycloak/keycloak:26.8.1` | `keycloak.validateImage` refuses official tags < 26.7.2 (CVE-2026-18963) |
| `replicas` | `2` | 2+ = Infinispan cluster, zero-downtime restarts; 1 = clustering disabled |
| `resources` | 1000m/500m cpu · 2Gi/1Gi mem | JVM heap = 70% of the limit; **do not go below 1.5Gi** |
| `admin.secretName` | `my-keycloak-admin` | Prerequisite dictionary secret |
| `publicAccess.enabled` / `internalAccess.type` | `true` / `same-gvc` | Public on purpose (browser SSO); `none` rejected when `replicas > 1` |
| `postgresHA.enabled` / `postgres.enabled` | HA on, single off | HA default kept (auth provider: downtime cascades); `postgresHA.proxy.enabled` must stay true |
| `postgresHA.image` | `controlplanecorporation/patroni-postgres:0.9` | `keycloak.validatePostgresHAImage` refuses empty and 0.1-0.7 (CVE-2026-103484) |
| `postgres.image` | `postgres:19` | A 1.x single-instance release must keep `postgres:18` |
| `*.config.credentialsSecretName` | `my-keycloak-db-credentials` | Only the active mode's key matters; `postgres.credentials` fails at render |
| backups | off | `postgresHA.backup.*` (logical image `postgres-backup:18.2.0`, 512Mi) / `postgres.backup.*` (image `19.1.0`) |

## 2.0.0 (2026-11-25, work item 5605): PostgreSQL 19 single mode, pg-ha 3.0.0
- **Default (HA) upgrade needs no pin:** pg-ha 2.5.0 → 3.0.0, members restart one by one onto `0.9` and a 1.x cluster stays on 17. With AWS backups the backup identity loses `aws::ReadOnlyAccess`, so the bucket IAM policy must carry pg-ha 3.0.0's action list before upgrading (README links pg-ha's AWS S3 section; keycloak's README has no IAM JSON of its own).
- **Single-instance upgrade is refused unpinned:** postgres 3.4.1 → 4.0.2 (PG 19). On 1.x's PG 18 data the guard does not start the server, leaves the volume untouched and logs `[pg-guard] REFUSING TO START` every 30 s. `postgres.upgradeHint` makes the FIX lines name `--set postgres.image=postgres:18`, `Upgrade > Database server > Postgres image` and README "Upgrading from 1.x". NOTES.txt prints the pin in single mode.
- **Move to 19 / 18** = side-by-side release with the same two secrets, then `pg_dump | psql` into the new database while both Keycloaks are stopped. The new release has a new endpoint, so every OIDC client must move to the new issuer URL. No in-place pg_upgrade.
- **Wizard:** imports postgres 4.0.2 (excludes `image` + `resources`, bound in the parent's **Database server** step with the upgrade note, cross-major warning and restated resource limits) and pg-ha 3.0.0 (replaces the hand-bound HA fields and backup sections; `pgbouncer` excluded + yamlOnly). The echo switches are hidden. A parent migration `>=1.0.0 <2.0.0` keeps `postgres.image` (falls back to `postgres:18`, since 1.x values never set it); `tw carry` from 1.5.1 gives 18. An upgrade note warns HA + AWS-backup users.
- **E2E:** baseline stays HA with a plain `upgradeFrom: 1.5.1` (`ha-postgres-major`: 17 after the upgrade, 18 fresh); a `[single]` variant proves PG 19, the guard handing over, the master realm in the 19 database, and an admin token (bash `/dev/tcp` from the postgres container: neither image has curl). The refused single-instance upgrade from 1.5.1 cannot be expressed (the starting install uses 1.5.1's HA baseline), so it is a live test row.

## Troubleshooting / considerations
- **Workload wedged with ZERO log lines** → a prerequisite secret does not exist; only `status.versions[].message` from `cpln workload get-deployments … -o yaml` shows it. Self-heals in ~5.5–10.5 min, or force a redeployment (~90 s).
- **Admin password is first-boot only** (`KC_BOOTSTRAP_ADMIN_*`); change it in the admin console. The bootstrap admin is temporary by design.
- **Long first boot is normal**; liveness during the DB wait is suppressed via the `/tmp/kc-db-wait` sentinel — do not turn the exec probe into an HTTP probe.
- **Open (maintainer ruling): the DB-wait gate (600 s) outlasts the startup window (≈330 s)**, so a slow first boot restarts before the gate's own message prints. Chart logic, not changed.
- **Secret names are org-wide**: a second release on the same DB secret is not refused; give each release its own.
- **Rotation:** `ALTER ROLE` first, `cpln secret edit`, then force-redeploy `{release}-keycloak`. In HA mode also `ALTER ROLE repl`, and switch the leader to `-0` first (members restart 2→1→0; preStop switchover has no candidate) — README section. Patroni's `:8008/config` keeps the install-time password (README step 7 removes it).
- **1.5.1 is not rollback-safe** to 1.5.0 (schema migration; logins 500 after a rollback; re-upgrade recovers). Known drift (deferred): `livenessProbe.successThreshold`, `readinessProbe.httpGet.scheme` on keycloak.

## History
- 1.1.0 admin login → prerequisite secret · 1.2.0 postgres 3.4.1 · 1.3.0 pg-ha 2.5.0 · 1.3.1 HA MinIO keys → secret · 1.4.0 `resources.cpu/memory` → `maxCpu/maxMemory` · 1.5.0 DB credentials → prerequisite secret (an upgrade from 1.4.0 deletes the chart-made secret: new NAME required, wizard-enforced), first wizard · 1.5.1 Keycloak 26.8.1 (CVE-2026-18963) and `patroni-postgres:0.8` (CVE-2026-103484) · 2.0.0 above.
