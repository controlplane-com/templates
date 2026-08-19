# airflow

Self-hosted **Apache Airflow 3.x** with the CeleryExecutor. One webserver workload runs the API server, scheduler, dag-processor and triggerer together; Celery workers run tasks and are scaled by **KEDA** on the Redis queue length. Apache-2.0, nothing gated.

Note this is one of the few `createsGvc: true` templates — KEDA is a GVC-level setting, so the chart must own its GVC.

## Common use cases

- Scheduled ETL / data pipelines with dependency graphs and retries.
- Orchestrating jobs across external systems (warehouses, APIs, cloud services) via Airflow Connections.
- Bursty batch work where workers should scale to zero between runs — that is what KEDA buys here.
- DAGs delivered from a Git repository (git-sync sidecar) rather than baked into an image.

## Architecture

| Resource | Type | Notes |
|---|---|---|
| `{gvc.name}` | **gvc** | Created by the chart. `spec.keda.enabled` lives here, which is why. |
| `{rel}-airflow-webserver` | workload (`stateful`) | UI + REST API on :8080, plus scheduler/dag-processor/triggerer in one container. The only tier with any external inbound. |
| `{rel}-airflow-celery-worker` | workload (`stateful`) | Task execution. KEDA autoscaling via `defaultOptions.autoscaling.keda`, Redis `listName: default`. |
| `{rel}-airflow-postgres` | workload (`stateful`) + `-vs` volumeset (ext4) | Metadata DB. **The one thing that must be backed up.** |
| `{rel}-airflow-redis` | workload (`stateful`) + `-vs` volumeset (ext4) | Celery broker. Transient. |
| `{rel}-airflow-vs` | volumeset (**shared**) | Airflow home — DAGs and logs — mounted by the webserver AND every worker. Shared filesystem is mandatory here. |
| `{rel}-airflow-config` | secret (dictionary) | Metadata DB `username`/`password` only. No key material since 1.5.0. |
| identity + policy | | `reveal` on the config secret, the user's auth secret, and (optionally) the git token secret. No cloud bindings. |

## Key knobs (defaults as shipped in 1.5.0)

| Knob | Default | Notes |
|---|---|---|
| `gvc.name` | `airflow` | Must be a NEW name — see traps. |
| `gvc.locations` | `[aws-eu-central-1]` | Single location. |
| `airflow.auth.secretName` | `my-airflow-auth` | **Required prerequisite** dictionary secret: `jwtSecret`, `fernetKey`, `adminPassword`. |
| `airflow.admin.username` | `admin` | Stays a value — it is interpolated into `AIRFLOW__CORE__SIMPLE_AUTH_MANAGER_USERS` as `admin:ADMIN`, which cannot be a secret ref. |
| `postgres.config.password` | `change-me-airflow-db` | Bundled plumbing, stays a value. Only read at initdb. |
| `firewallConfig.inboundAllowCIDR` | `[]` | **Closed by default as of 1.5.0** (was `0.0.0.0/0`). |
| `keda.enabled` / `minScale` / `maxScale` | `true` / `1` / `3` | `scaleToZeroDelay: 300`. |
| `gitSync.enabled` | `false` | `gitSync.auth.secretName` is an OPTIONAL opaque secret (a PAT), `""` = public repo. |
| `airflow.webserver.resources` | `cpu: 2000m`, `memory: 3Gi` | Bare `cpu`/`memory`: limit only, no reservation exposed. |
| `postgres.resources` | `250m/500m`, `512Mi/1024Mi` | min+max block, so `minCpu`/`maxCpu` naming. 2:1, inside the stateful 4:1 cap. |

## Troubleshooting traps

- **The fernet key cannot be rotated.** It encrypts every Connection and Variable in the metadata DB. Change it and all of them become unreadable — there is no re-encrypt path in this template. Anyone upgrading from ≤1.4.0 who kept the shipped `CHANGE_ME` default has those credentials encrypted under a value published in a public repo: they must be re-entered under a fresh key AND rotated at the source.
- **`postgres.config.password` only takes effect at first install.** `POSTGRES_PASSWORD` is read at initdb only; changing it on an existing volume leaves the DB on the old password while Airflow's connection string uses the new one, and the app fails auth. Looks like a template bug, is not.
- **Missing prerequisite secret = zero log lines.** `cpln logs` returns nothing because the container never starts. Diagnose with `cpln workload get-deployments {rel}-airflow-webserver --gvc {gvc} -o yaml` → `status.versions[].message`. `get-deployments`, not plain `get`. Self-heals in ~5.5–8.5 min, or ~90 s with `force-redeployment`.
- **`createsGvc: true` is dangerous.** Installing with `gvc.name` matching an existing GVC makes Helm adopt it, and `helm uninstall` then deletes that GVC and everything in it — observed even with `helm.sh/resource-policy: keep`. Never point it at a shared or test slot.
- **The UI is remote code execution.** It triggers DAGs and can decrypt every stored Connection, and auth is Airflow's `SimpleAuthManager` (no SSO/LDAP, password file regenerated from env each boot). Hence the closed default. Reach it with `cpln port-forward {rel}-airflow-webserver 8080:8080 --gvc {gvc}` — the container sets `AIRFLOW__API__HOST: 0.0.0.0`, so loopback is served and the tunnel works.
- **All three volumesets ship with no `snapshots` block.** The `shared` one cannot take one; the postgres and redis ext4 ones could and do not. The metadata DB therefore has no snapshot schedule — flagged for the catalog-wide snapshots sweep, deliberately not fixed in 1.5.0.
- **Old-values guard.** `airflow.auth.jwtSecret`, `airflow.auth.fernetKey`, `airflow.admin.password` and `gitSync.auth.token` all `fail` at render with the replacement named. No compatibility shims — the version bump is the migration.
