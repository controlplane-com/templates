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
| `postgres` 3.4.1 subchart (default) **or** `postgres-highly-available` 2.4.2 (`alias: postgresHA`) | The metastore — every catalog, namespace, table pointer, principal and grant |
| `postgres.config.credentialsSecretName` secret (dictionary, **chart-created**) | Bundled single-instance metastore `username`/`password`/`database`. Created by THIS chart since 1.1.0 (postgres 3.4.x stopped creating it); HA mode still uses pg-ha's own `{release}-postgres-config` |

- A default render is **13 resources**, with exactly one database subchart. No GVC, no volumeset of its own.
- Internal endpoint: `http://{release}-polaris.{gvc}.cpln.local:8181`. Probes hit `/q/health/ready` and `/q/health/live` on 8182; `capacityAI: false` (the JVM sizes heap from the cgroup limit at start); `timeoutSeconds: 60` because table commits and large namespace listings run past the 5 s default.

## Prerequisites — two secrets that MUST exist before install
| Secret | Type | Contents |
|---|---|---|
| `rootCredentials.secretName` (default `my-polaris-root-credentials`) | dictionary | `CLIENT_ID`, `CLIENT_SECRET` — become the realm's root principal; **neither may contain a comma** (the admin tool takes `realm,clientId,clientSecret` as one argument, and the script fails loudly on this) |
| `tokenSigningKey.secretName` (default `my-polaris-signing-key`) | opaque, `encoding: plain` | 32+ random chars, mounted at `/polaris/symmetric.key` |

Both are render-validated as required, and the placeholder defaults keep the bare `helm template` gate passing — but installing without creating them wedges the deployment waiting on a secret that does not exist.

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
| `postgres.credentials.{username,password,database}` / `postgresHA.postgres.*` | `polaris` / `change-me-polaris-db` / `polaris` | placeholder password — change before installing. Still plain VALUES; the chart builds the secret from them (1.1.0; was `postgres.config.*`) |
| `postgres.config.credentialsSecretName` | `my-polaris-db-credentials` | name of that chart-created secret; **org-wide**, so give each release its own |
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

## postgres 3.4.1 adoption (1.1.0)
- **The bundled metastore credential secret is chart-created, not a prerequisite.** The single-instance path moved `postgres.config.{username,password,database}` → `postgres.credentials.{...}`; this chart renders `templates/secret-db.yaml` from those values and passes only the NAME down as `postgres.config.credentialsSecretName`. Users gained **no** new prerequisite — the metastore password is still a value, unlike `rootCredentials.secretName` and `tokenSigningKey.secretName`, which stay prerequisites and were untouched.
- **`polaris.postgres.database` is a SECOND consumer beyond the secret-name helper.** The JDBC URL (`QUARKUS_DATASOURCE_JDBC_URL`, used identically by the server and the bootstrap admin tool) interpolates the database NAME at render time, where a `cpln://secret` reference cannot resolve — so that helper reads `postgres.credentials.database` (was `postgres.config.database`). Username and password still come from the secret. Anyone renaming these knobs again must move this read too.
- **The HA branch of `polaris.postgres.secret.name` was deliberately left alone**: pg-ha 2.4.2 has not adopted the convention and still creates `{release}-postgres-config`. Both policies (server and bootstrap) target the helper, so they picked up the new name with no edit.
- **Secret names are org-wide and cannot be templated.** Helm resolves subchart values before rendering and postgres does not `tpl` the name, so it cannot contain `.Release.Name`. A second polaris release left on the default `my-polaris-db-credentials` is **refused at install** ("cannot be updated because it is being managed by a different release") and creates nothing — not silent data loss.
- **An upgrader carrying the 1.0.x keys gets postgres's own error**, not a polaris one: Helm renders `charts/` before `templates/`, so the subchart's `config.username was REMOVED in postgres 3.4.0` always wins. 3.4.1 appends a clause telling bundled users not to create a secret. A parent-side guard would be dead code — do not add one.
- **`postgres.backup.minio.accessKey`/`secretKey` were removed too** (postgres 3.4.0) — that path now needs a prerequisite dictionary secret named by `postgres.backup.minio.credentialsSecretName`. `postgresHA.backup.minio` still takes the keys inline.
