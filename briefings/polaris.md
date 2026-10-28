# Apache Polaris — Maintainer Briefing

## What it is
- **Apache Polaris** — an Apache Iceberg **REST catalog**: the service that tells query engines which tables exist, where their metadata lives in object storage, and who may read them. Image `apache/polaris:1.7.0`, Quarkus/JVM, stateless; all state lives in a PostgreSQL metastore.
- License: **Apache-2.0** — free to self-host, nothing to register, buy or activate.
- Its value here is **stack completion**: it is the piece that lets `trino` query Iceberg tables sitting in `seaweedfs`, MinIO or any S3 bucket. That exact path is tested end to end.

## Common use cases
- Give the `trino` template Iceberg tables — one catalog entry and Trino does `CREATE SCHEMA` / `CREATE TABLE` / `INSERT` / `SELECT` against tables in object storage.
- Turn a bucket of Parquet into a lakehouse rather than just a bucket.
- Let several engines (Trino, Spark, and other Iceberg REST clients) read and write the *same* tables without copying data between them.
- One central place to name and permission tables, instead of pasting table locations into every job.

## Architecture on cpln
| Resource | Purpose |
|---|---|
| `{release}-polaris` (standard, `replicas`, :8181 + :8182 `http`) | Iceberg REST + management API on **8181**; Quarkus health/metrics on **8182**. No volumeset — stateless |
| `{release}-polaris-bootstrap` (standard, always 1) | Runs `apache/polaris-admin-tool:1.7.0` until it succeeds, then `sleep infinity`. Creates the realm schema + root principal |
| secret `{release}-polaris-bootstrap-script` (opaque, plain) | The bootstrap shell script; interpolates the root credentials at runtime so they never enter a workload spec |
| 2 × identity + 2 × policy | Split principals: **only** bootstrap can reveal the root credentials; **only** the server can reveal the signing key and object-storage credentials |
| `postgres` 3.4.1 subchart (default) **or** `postgres-highly-available` 2.5.0 (`alias: postgresHA`) | The metastore — every catalog, namespace, table pointer, principal and grant |
| metastore credentials secret (dictionary, **user-created prerequisite since 1.3.0**) | `username`/`password`/`database`, named by `postgres.config.credentialsSecretName` (single) or `postgresHA.config.credentialsSecretName` (HA). Read by the database subchart, the server and the bootstrap admin tool; both Polaris policies grant `reveal` on it by name. 1.1.0–1.2.1 rendered it from `postgres.credentials.*` (`templates/secret-db.yaml`, deleted in 1.3.0) |

- A default render is **11 resources** (was 12 in 1.2.1: the chart-created metastore secret is gone), with exactly one database subchart. No GVC, no volumeset of its own.
- Internal endpoint: `http://{release}-polaris.{gvc}.cpln.local:8181`. Probes hit `/q/health/ready` and `/q/health/live` on 8182; `capacityAI: false` (the JVM sizes heap from the cgroup limit at start); `timeoutSeconds: 60` because table commits and large namespace listings run past the 5 s default.

## Prerequisites — three secrets that MUST exist before install
| Secret | Type | Contents |
|---|---|---|
| `postgres.config.credentialsSecretName` / `postgresHA.config.credentialsSecretName` (default `my-polaris-db-credentials` in both) | dictionary | `username`, `password`, `database` — **database must be URL-safe** (it lands in the JDBC URL). PostgreSQL reads it only at first initialization |
| `rootCredentials.secretName` (default `my-polaris-root-credentials`) | dictionary | `CLIENT_ID`, `CLIENT_SECRET` — become the realm's root principal; **neither may contain a comma** (the admin tool takes `realm,clientId,clientSecret` as one argument, and the script fails loudly on this) |
| `tokenSigningKey.secretName` (default `my-polaris-signing-key`) | opaque, `encoding: plain` | 32+ random chars, mounted at `/polaris/symmetric.key` |

All three are render-validated as required, and the placeholder defaults keep the bare `helm template` gate passing — but installing without creating them wedges the deployment waiting on a secret that does not exist.

## Key knobs
| Knob | Default | Meaning |
|---|---|---|
| `image` / `bootstrap.image` | `apache/polaris:1.7.0` / `apache/polaris-admin-tool:1.7.0` | keep the two tags in lockstep |
| `replicas` | `1` | fixed count (`metric: disabled`, `minScale = maxScale = replicas`), not reactive autoscaling |
| `resources.*` | 500m/1000m · 1Gi/2Gi | `minCpu`/`maxCpu` · `minMemory`/`maxMemory`; render-validated incl. the 4:1 cpu cap |
| `jvm.maxRAMPercentage` | `70` | heap = this % of `maxMemory` via `JAVA_MAX_MEM_RATIO`; validated 40–80 (verified as `-XX:MaxRAMPercentage=70.0` on the java line) |
| `realm` | `POLARIS` | exactly one realm, header optional; **permanent** after first install |
| `storage.credentialsSecretName` / `.region` | `""` / `us-east-1` | optional dictionary secret with `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` for Polaris's own metadata I/O; empty = no `AWS_*` env at all and one fewer policy target |
| `publicAccess.enabled` | `false` | publishes the REST + management API on the automatic `*.cpln.app` endpoint |
| `internalAccess.type` / `.workloads` | `same-gvc` / `[]` | `none` \| `same-gvc` \| `same-org` \| `workload-list` |
| `postgres.enabled` / `postgresHA.enabled` | **`true` / `false`** | exactly one, enforced at render; HA is one flag away |
| `postgres.config.credentialsSecretName` / `postgresHA.config.credentialsSecretName` | `my-polaris-db-credentials` (both) | the user's prerequisite metastore secret per mode. `postgres.credentials` was REMOVED in 1.3.0 and fails the render (`polaris.validateDatabaseSecret`) |
| `storage.credentialsSecretName` source | — | SeaweedFS's `s3.credentialsSecretName` can be reused as-is; MinIO's secret holds `username`/`password`, so MinIO users need a separate `AWS_*` dictionary |
| `postgres.volumeset.capacity`, `.backup.*`, `postgresHA.replicas`, `.backup.*` | 10 GiB, backups off | straight pass-through to the database subchart |

## Availability posture
- **The Polaris server scales horizontally and it is real**, because replicas share nothing but the metastore and the signing key. Proven per-replica, not through the load balancer: a token minted on replica A was accepted 20/20 on replica B, and a catalog created via A was immediately visible on B.
- Measured through service DNS at `replicas: 2`: **rolling `helm upgrade` → 403/403 2xx, 0 non-2xx** (rollout converged in 95 s, new replicas confirmed to carry the changed JVM flag); **scale 2 → 1 → 384/384 2xx, 0 non-2xx**. 787 requests total, zero failures.
- **The metastore defaults to single-instance `postgres`** (per the bundled-datastore ruling — a catalog outage is minutes of downtime on a snapshotted volume, not data loss). `postgresHA.enabled: true` with `postgres.enabled: false` swaps in 3 Patroni replicas + 3 etcd + an HAProxy leader endpoint; the template requires `postgresHA.proxy.enabled` to stay true, since that endpoint is Polaris's stable database address.
- Convergence: **~90 s from `helm install` to `ready: true`** on the default path (bootstrap completed at 73 s). **~6 min (348 s) on the `postgresHA` path** — Patroni alone takes 213 s.

## Troubleshooting / considerations
- **A default install restarts twice in the first ~32 s and that is correct.** While Postgres warms, the server logs `Failed to start quarkus` and the bootstrap workload logs `attempt failed (metastore not ready yet?) - retrying in 10s`; both self-heal, and the clean `polaris-server 1.7.0 … started` line follows. **Do not interrupt it** — on the HA path the same red-looking window lasts 5–6 minutes and looks like a failed install to a first-time user.
- **Port order in `workload-polaris.yaml` is load-bearing and must not be swapped.** Only the FIRST declared port is published on the canonical endpoint, so 8181-first is the sole reason the unauthenticated management interface stays private. Verified with `publicAccess` on: `/q/metrics`, `/q/health`, `/q/health/ready`, `/q/health/live` and `/q/info` all return **404** publicly, while internal `:8182/q/metrics` returns **200** and internal `:8181/q/metrics` returns 404. Reordering would silently publish metrics and health to the internet. There is a warning comment at the port declaration; keep it.
- **"401 Unauthorized after a restart" means the signing key was not shared.** The template sets `POLARIS_AUTHENTICATION_TOKEN_BROKER_TYPE=symmetric-key` unconditionally — not only at `replicas > 1` — because the upstream default (`rsa-key-pair`) generates a key per JVM process, so even a single replica would reject tokens it minted before its own restart. Tokens are HS256, confirmed from the decoded JWT header.
- **Bootstrap is idempotent at 1.7.0, which is why 1.7.0 is pinned.** Re-runs log `Realm 'X' is already bootstrapped; skipping` (observed across two live `helm upgrade`s), so restarts and upgrades are harmless. It is a separate workload rather than a sidecar so that `replicas > 1` cannot race N admin tools against an empty schema, and not a cron because cron workloads cannot be triggered at install time.
- **Root credentials are write-once.** They apply at first bootstrap only; changing them afterwards does nothing — the realm keeps the original root login. Rotate by creating a new principal through the management API.
- **Renaming `realm` looks like data loss but is not** — a new realm bootstraps empty and the old catalogs are simply invisible; change it back and they return. Confirmed behavior: a request with no `Polaris-Realm` header resolves to the configured realm (200), the matching header is 200, a wrong one is **404**. Trino's Iceberg REST connector cannot send that header, which is why the template ships exactly one realm with the header optional.
- **No `406 Not Acceptable` on internal hops** — the `X-Forwarded-Proto` trap that bit the Trino template did not fire against Quarkus over `…cpln.local:8181`. This was an `[UNPROVEN]` spec assumption and is now confirmed.
- **STS credential vending is deliberately out of v1.** Polaris's headline feature needs a working STS service, which in-GVC SeaweedFS/MinIO do not provide. Polaris and each engine hold their own static S3 keys, so Trino needs `vended-credentials-enabled=false` and its own bucket credentials. That is the answer to "why does Trino need S3 credentials at all".
- **Creating a catalog is a day-2 API call**, not an install knob: token from `/api/catalog/v1/oauth/tokens`, then `POST /api/management/v1/catalogs` and a `PUT …/catalog-roles/{name}` grant (both returned 201 in testing, using the README commands verbatim).
- **Polaris does not migrate its own database schema** — treat a future Polaris version bump as an explicit schema step, not something boot handles.
- **Uninstall deletes the metastore volume and every catalog definition with it** (Iceberg data files in the bucket survive, but nothing knows about them). The chart's own uninstall removes all subchart resources cleanly — the janitor found nothing to do.
- Credential hygiene verified against the **live** workload JSON: zero occurrences of the client secret, signing key or database password in any spec — only `cpln://secret/...` references, and the two reveal policies target exactly the secrets each principal needs.

## 1.3.0 — metastore credentials become a prerequisite secret (work item 5284)
- **The rule (maintainer ruling 2026-10-14):** when a dependency (`postgres` 3.4.x, `postgres-highly-available` 2.5.x) takes only a credentials-secret NAME, the parent requires the user to create that secret. This narrows the "bundled plumbing" exception; polaris no longer renders `templates/secret-db.yaml` from `postgres.credentials.*`.
- **The database name now comes from the secret, so the JDBC URL is assembled at container start:** `POSTGRES_DB_NAME=cpln://secret/<name>.database` and `QUARKUS_DATASOURCE_JDBC_URL=jdbc:postgresql://<host>:5432/$(POSTGRES_DB_NAME)` — the platform expands `$(VAR)` in env values (keycloak 1.5.0 / fusionauth 2.5.0 precedent). Both the server and the bootstrap admin tool get it from `polaris.env.datasource`. The helper var is deliberately not `QUARKUS_*`/`POLARIS_*` so neither framework reads it as config. `[UNPROVEN]` on polaris itself until the test round: the expanded URL must reach both JVMs.
- **The upgrade trap:** 1.2.1 created the secret, so the 1.3.0 upgrade DELETES it. The user must create a NEW-name secret holding the CURRENT values (README snippet uses `RELEASE_NAME-postgres-credentials`, a name 1.2.1 never rendered) and point the mode's `credentialsSecretName` at it. Reusing the old name is refused by the wizard (rule keyed on `context.fromVersion < 1.3.0`).
- **Upgrade cost:** the bundled PostgreSQL restarts (it now reads the new secret), so Polaris briefly loses its metastore; and a new workload version can wait ~10 min on `is not allowed to reveal the secret` while the new grant propagates (previous version keeps serving).
- **Rotation:** single — `ALTER ROLE`, `cpln secret edit`, then right away force-redeploy `-polaris` only (not postgres; measured on umami 2026-10-16: the postgres redeploy was the whole outage). HA — leader switchover to `-0` first, `ALTER ROLE` on the user AND `repl`, then redeploy (README section, spike-tested on the batch). The bootstrap workload holds no connection once done, so it needs no redeploy.
- **Missing secret:** wedges silently (zero log lines); diagnose with `status.versions[].message` from `get-deployments`; recovery after creating it can take ~12 min.
- **Wizard:** first descriptor for polaris (1.3.0): virtual `dbMode` chooser (single default), postgres 3.4.1 imported with `pgbouncer` excluded + `yamlOnly`, every `fail` define mirrored (`polaris.validate`, `polaris.validate.resources`, `polaris.validateDatabaseSecret`).

## postgres 3.4.1 adoption (1.1.0)
- *(Superseded in 1.3.0 — the secret is now a prerequisite; kept for history.)* **The bundled metastore credential secret is chart-created, not a prerequisite.** The single-instance path moved `postgres.config.{username,password,database}` → `postgres.credentials.{...}`; this chart renders `templates/secret-db.yaml` from those values and passes only the NAME down as `postgres.config.credentialsSecretName`. Users gained **no** new prerequisite — the metastore password is still a value, unlike `rootCredentials.secretName` and `tokenSigningKey.secretName`, which stay prerequisites and were untouched.
- *(Superseded in 1.3.0 — the helper is gone; the URL takes `$(POSTGRES_DB_NAME)`.)* **`polaris.postgres.database` is a SECOND consumer beyond the secret-name helper.** The JDBC URL (`QUARKUS_DATASOURCE_JDBC_URL`, used identically by the server and the bootstrap admin tool) interpolates the database NAME at render time, where a `cpln://secret` reference cannot resolve — so that helper reads `postgres.credentials.database` (was `postgres.config.database`). Username and password still come from the secret. Anyone renaming these knobs again must move this read too.
- **HA branch (superseded in 1.2.0):** `polaris.postgres.secret.name` returns `postgresHA.config.credentialsSecretName` in HA mode, and since pgHA 2.5.0 `secret-db.yaml` renders that secret in both modes. Both policies (server and bootstrap) target the helper. The comment inside `secret-db.yaml` still describes the pre-2.5.0 HA behaviour (non-rendering).
- **Secret names are org-wide and cannot be templated.** Helm resolves subchart values before rendering and postgres does not `tpl` the name, so it cannot contain `.Release.Name`. (Through 1.2.1 a second release left on the default name was refused at install because the first release owned the chart-created secret; since 1.3.0 the user owns it, so two releases on one name would simply share credentials — the README tells users to give each release its own.)
- **An upgrader carrying the 1.0.x keys gets postgres's own error**, not a polaris one: Helm renders `charts/` before `templates/`, so the subchart's `config.username was REMOVED in postgres 3.4.0` always wins. 3.4.1 appends a clause telling bundled users not to create a secret. A parent-side guard would be dead code — do not add one.
- **`postgres.backup.minio.accessKey`/`secretKey` were removed too** (postgres 3.4.0) — that path now needs a prerequisite dictionary secret named by `postgres.backup.minio.credentialsSecretName`. Since 1.2.1 `postgresHA.backup.minio` takes the same shape via `postgresHA.backup.minio.credentialsSecretName`.
- **Both `backup.minio.endpoint` defaults are short names** (`http://my-minio-workload:9000`); users must set the full `WORKLOAD.GVC.cpln.local` address.

## 1.3.1 — HA database image override (CVE-2026-103484, work item 5376)
- **`postgresHA.image: controlplanecorporation/patroni-postgres:0.8`** (new key). The vendored `postgres-highly-available` 2.5.0 defaults to `0.7`, which carries pgvector 0.8.0 (CVE-2026-103484: a role that can build an IVFFlat index can run code on the server); `0.8` carries PGDG pgvector 0.8.7 and is otherwise the same image. Maintainer decision 2026-10-27: override the image in the parent and keep the vendored subchart version; moving to `postgres-highly-available` 2.8.1 is a later batch.
- **`polaris.validatePostgresHAImage`** (HA mode only) refuses `controlplanecorporation/patroni-postgres` tags `0.1`-`0.7` (with or without `docker.io/`) using `pg-ha.validateImage`'s matching, and also an emptied `postgresHA.image`, because the subchart would then fall back to its `0.7` default. Mirrored by the wizard rule on the new `postgresHA.image` field (Database step, HA group).
- **Single-instance mode is unaffected**: it runs the official `postgres:18`, which ships no pgvector. Polaris does not create the `vector` extension (grep of the chart, plus upstream source), so the README tells only users who created it themselves to run `ALTER EXTENSION vector UPDATE;`.
- **The upgrade restarts the Patroni members, not the proxy: a brief write interruption while the leader changes.** Nothing limits the rollout of a stateful workload (`maxUnavailableReplicas` is dropped there), so the members do not restart one at a time; the HAProxy proxy workload does not restart (stays `Unchanged`; measured on the chatwoot and keycloak rounds). The app workload restarts as on any version upgrade; with a single app replica that is the longer interruption. Not deployed in this change; the E2E suite onboarded in 1.3.1 (`polaris/tests/`, HA baseline, `upgradeFrom: 1.3.0`) proves the upgrade and the `pgvector-0-8-7-available` check in CI.

