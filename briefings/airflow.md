# airflow

Self-hosted **Apache Airflow 3.x** with the CeleryExecutor. One webserver workload runs the API server, scheduler, dag-processor and triggerer together; Celery workers run tasks at a fixed replica count, or scaled by **KEDA** on the Redis queue length when the GVC has KEDA turned on. Apache-2.0, nothing gated.

**2.0.0 is the GVC conversion.** 1.x created its own GVC, because KEDA is a GVC-level setting and the chart wanted to own it. It no longer does: 2.0.0 deploys into the GVC you install into, KEDA became an opt-in that requires a GVC prerequisite, and the whole release is pinned to a single `location`.

## Common use cases

- Scheduled ETL / data pipelines with dependency graphs and retries.
- Orchestrating jobs across external systems (warehouses, APIs, cloud services) via Airflow Connections.
- Bursty batch work where workers should scale to zero between runs — that is what KEDA buys here, at the cost of a GVC prerequisite.
- DAGs delivered from a Git repository (git-sync sidecar) rather than baked into an image.

## Architecture

| Resource | Type | Notes |
|---|---|---|
| `{rel}-airflow-webserver` | workload (`stateful`) | UI + REST API on :8080, plus scheduler/dag-processor/triggerer in one container. Pinned to **1 replica**. The only tier with external inbound, and the only one that runs the boot-time GVC checks. |
| `{rel}-airflow-celery-worker` | workload (`stateful`) | Task execution. Fixed `airflow.celeryWorker.replicas`, or KEDA on Redis `listName: default`. |
| `{rel}-airflow-postgres` | workload (`stateful`) + `-vs` volumeset (ext4) | Metadata DB. **The one thing that must be backed up.** |
| `{rel}-airflow-redis` | workload (`stateful`) + `-vs` volumeset (ext4) | Celery broker. Transient. |
| `{rel}-airflow-vs` | volumeset (**shared**) | Airflow home — DAGs and logs — mounted by the webserver AND every worker. A shared volumeset provisions **one volume per LOCATION**, which is why the release is single-location. |
| `{rel}-airflow-config` | secret (dictionary) | Metadata DB `username`/`password` only. |
| `{rel}-airflow-webserver-startup` | secret (opaque, plain) | The webserver's startup script — the topology guards plus Airflow's own boot sequence. New in 2.0.0. |
| identity + 2 policies | | `reveal` on the config secret, the startup script, the user's auth secret and (optionally) the git token; `view` on the ONE install GVC (never `target: all`). |

Every workload carries `defaultOptions.minScale/maxScale: 0` and a single complete `localOptions` entry for `location` — so a GVC location the values do not name runs **nothing**.

## Key knobs (defaults as shipped in 2.0.0)

| Knob | Default | Notes |
|---|---|---|
| `location` | `aws-us-east-1` | Single location NAME (string). Was `gvc.locations` in 1.x. Must already be a GVC location. |
| `airflow.auth.secretName` | `my-airflow-auth` | **Required prerequisite** dictionary secret: `jwtSecret`, `fernetKey`, `adminPassword`. |
| `airflow.admin.username` | `admin` | Stays a value — interpolated into `AIRFLOW__CORE__SIMPLE_AUTH_MANAGER_USERS` as `admin:ADMIN`, which cannot be a secret ref. |
| `airflow.celeryWorker.replicas` | `1` | New in 2.0.0. Fixed worker count; ignored when `keda.enabled`. |
| `postgres.config.password` | `change-me-airflow-db` | Bundled plumbing, stays a value. Only read at initdb. |
| `firewallConfig.inboundAllowCIDR` | `[]` | Closed by default since 1.5.0. |
| `internalAccess.type` / `.workloads` | `same-gvc` / `[]` | New in 2.0.0. Under `workload-list` the release's own four workloads are merged in automatically, plus `cpln://internal/keda` on the Redis tier when KEDA is on. |
| `keda.enabled` / `minScale` / `maxScale` | **`false`** / `1` / `3` | Was `true` in 1.x. Requires `spec.keda.enabled: true` on the GVC. |
| `gitSync.enabled` | `false` | `gitSync.auth.secretName` is an OPTIONAL opaque secret (a PAT), `""` = public repo. |
| `airflow.webserver.resources` | `cpu: 2000m`, `memory: 3Gi` | Bare `cpu`/`memory`: limit only. |
| `postgres.resources` | `250m/500m`, `512Mi/1024Mi` | min+max block, so `minCpu`/`maxCpu` naming. 2:1, inside the stateful 4:1 cap. |

## Troubleshooting traps

- **Airflow is single-location and that is structural.** A `shared` volumeset provisions one volume PER LOCATION (docs, `reference/volumeset`), so two locations means two Airflow homes that cannot see each other's DAGs or logs — and the metadata DB and broker are each one volume on one replica. There is no multi-location shape to offer; do not add one without solving DAG/log sharing first.
- **KEDA is a GVC-level setting and the chart can no longer set it.** `keda.enabled: true` now means "my GVC already has `spec.keda.enabled: true`". Measured 2026-08-28: a `metric: keda` workload is **accepted without error** into a GVC where KEDA is off, and simply sits at `minScale` — at `minScale: 0` that is `desiredScale: None`, zero replicas, no versions, no message. The webserver's boot check exists precisely because nothing else reports it.
- **Never hand-write a partial GVC file for `cpln apply`.** Measured 2026-08-28: applying a GVC file carrying only `spec.keda` **wiped `spec.staticPlacement.locationLinks`** — `cpln apply` replaces a GVC's `spec` rather than merging it. Always `cpln gvc get X -o yaml-slim > f.yaml`, edit, apply.
- **`target` is rejected under `metric: keda`.** `"spec.defaultOptions.autoscaling.target" failed custom validation because target is not allowed when metric is 'keda'` — invisible to `helm template`. The chart omits it on the KEDA branch and sends it on the disabled branch.
- **`keda` IS accepted inside `localOptions[].autoscaling`** (measured 2026-08-28, stored verbatim). That is what makes the 0/0-defaultOptions pattern compatible with KEDA at all; without it the two would be mutually exclusive.
- **The webserver boot guards are fatal ONLY on a fresh Airflow home.** "Fresh" = no `/opt/airflow/.cpln-airflow-initialized`, which is written after `airflow db migrate` succeeds. On an established install the same conditions WARN and Airflow keeps scheduling — a location that is momentarily absent must never stop a live cluster. Eight cases were exercised against `apache/airflow:3.0.3` at build time.
- **The GVC read is bounded and the bound was tested against slow failures.** `timeout 8 curl --max-time 6`, three tries, `sleep 2` → 24 s worst case; measured in the pinned image against a blackholed address (connect hangs) and an accept-never-respond server at 6 s each, versus an unbounded control still hanging at 25 s. An NXDOMAIN control returned in 0 s and proves nothing.
- **The fernet key cannot be rotated.** It encrypts every Connection and Variable in the metadata DB. Change it and all of them become unreadable — there is no re-encrypt path. This is also why a 1.x → 2.0.0 migration must point at the SAME auth secret.
- **`postgres.config.password` only takes effect at first install.** `POSTGRES_PASSWORD` is read at initdb only; changing it on an existing volume leaves the DB on the old password while Airflow's connection string uses the new one. Looks like a template bug, is not.
- **Missing prerequisite secret = zero log lines.** `cpln logs` returns nothing because the container never starts. Diagnose with `get-deployments` → `status.versions[].message`, not plain `get`. Self-heals in ~5.5–10.5 min, or ~90 s with a forced redeployment.
- **A wide fan-out silently loses tasks** on `controlplanecorporation/celery:v1` — a concurrent-import race in `kombu/transport/redis.py`. Measured 7 failed / 9 success on a 24-task burst, failures never starting and nothing surfacing in the UI. Upstream, not this template.
- **The UI is remote code execution.** It triggers DAGs and can decrypt every stored Connection, and auth is Airflow's `SimpleAuthManager` (no SSO/LDAP). Hence the closed default. Reach it with `cpln port-forward {rel}-airflow-webserver 8080:8080` — the container sets `AIRFLOW__API__HOST: 0.0.0.0`, so loopback is served and the tunnel works.
- **All three volumesets ship with no `snapshots` block.** The `shared` one cannot take one; the Postgres and Redis ext4 ones could and do not. The metadata DB therefore has no snapshot schedule — flagged for the catalog-wide snapshots sweep, deliberately not fixed here.
- **Old-values guards.** `gvc` (the whole 1.x key), `locations` (plural), `airflow.auth.jwtSecret`, `airflow.auth.fernetKey`, `airflow.admin.password`, `gitSync.auth.token`, `airflow.auth.jwtExpirationDelta` and `airflow.auth.jwtRefreshThreshold` all `fail` at render with the replacement named. No compatibility shims — the version bump IS the migration.
- **The 1.x → 2.0.0 data move (pg_dump/pg_restore, tar of the DAG folder) has NOT been executed end to end.** What is verified: `pg_dump`/`pg_restore`/`psql` exist in `postgres:18`, `tar` exists in `apache/airflow:3.0.3`, and `cpln workload exec --stdin` exists. The piping itself is a named test row.
