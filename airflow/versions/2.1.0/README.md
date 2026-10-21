# Apache Airflow

> **Upgrading from 2.0.0:** the metadata database credentials are now a secret you create before
> upgrading, under a **new** name — see [Upgrading from 2.0.0](#upgrading-from-200).

Apache Airflow 3.x with the CeleryExecutor: Redis as the task broker, PostgreSQL as the metadata database, optional KEDA autoscaling for workers, and optional git-sync DAG delivery. The UI ships closed to the internet.

## Architecture

- **Airflow Webserver** (`stateful`) — one replica running the API server, scheduler, dag-processor and triggerer; serves the UI and REST API on port 8080.
- **Celery Workers** (`stateful`) — execute DAG tasks; a fixed replica count, or scaled by KEDA on the Redis queue length.
- **Redis** (`stateful`) — Celery broker, on a persistent volumeset.
- **PostgreSQL** (`stateful`) — Airflow metadata database, on a persistent volumeset. It initializes from your database credentials secret, and the webserver and workers connect with the same secret.
- **Airflow volumeset** (`shared`) — the Airflow home, mounted by the webserver and every worker so they see the same DAGs and logs.
- **Identity + two policies** — `reveal` on exactly the secrets the workloads mount (your database credentials secret, the webserver's startup script, your auth secret, and optionally your git token), and `view` on the one GVC the release is installed into, so the webserver can check its own topology at boot.
- **git-sync sidecar** (optional) — polls a Git repository and syncs DAGs onto the shared volume.

Everything is deployed into the GVC you install into and pinned to the single `location` you configure. This chart does **not** create a GVC.

## Prerequisites

### Auth secret — REQUIRED, must exist BEFORE you install

A **dictionary** secret holding three keys. If it does not exist at install time the deployment wedges silently — `cpln logs` returns nothing at all — so create it first:

```bash
cpln secret create-dictionary --name my-airflow-auth \
  --entry jwtSecret="$(openssl rand -base64 48)" \
  --entry fernetKey="$(openssl rand -base64 32 | tr '+/' '-_')" \
  --entry adminPassword="$(openssl rand -base64 18)"
```

| Key | What it does |
|---|---|
| `jwtSecret` | Signs Airflow API access tokens — anyone holding it can mint one. |
| `fernetKey` | Encrypts the Connections and Variables your DAGs use — database passwords, cloud keys, API tokens. Must be 32 random bytes in url-safe base64. **It cannot be rotated** without making every already-stored Connection and Variable unreadable. |
| `adminPassword` | The Airflow UI login for `airflow.admin.username`. Record it; it is not shown anywhere. |

Read it back with `cpln secret reveal my-airflow-auth -o yaml` — the `-o yaml` is required, the default output prints only metadata. Then set `airflow.auth.secretName` to the name you used.

### Database credentials secret — REQUIRED, must exist BEFORE you install

A **dictionary** secret holding `username`, `password` and `database`. The bundled PostgreSQL initializes from it, and the webserver and workers connect with it. Like the auth secret, a missing one wedges the deployment silently:

```bash
cpln secret create-dictionary --name my-airflow-db-credentials \
  --entry username=airflow \
  --entry password="$(openssl rand -hex 24)" \
  --entry database=airflow
```

Set its name in `postgres.config.credentialsSecretName`. Secret names are org-wide, so give each Airflow release its own secret. The three values are part of Airflow's connection URLs, so use letters, digits, `-` and `_` only. PostgreSQL reads the secret only when its data is first initialized — see [Rotating the database password](#rotating-the-database-password).

### A GVC with the location you configure

`location` must already be a location of the GVC you install into. Nothing else is required for a default install: one location is all this chart needs, and extra locations in the GVC are ignored.

### KEDA on the GVC — only if you set `keda.enabled: true`

KEDA is a **GVC-level** setting, so this chart cannot turn it on for you. Enable it on the GVC first, then install with `keda.enabled: true`:

```bash
cpln gvc get MY_GVC -o yaml-slim > gvc.yaml   # then set spec.keda.enabled: true in the file
cpln apply -f gvc.yaml
cpln gvc get MY_GVC -o yaml | grep -A1 'keda:'
```

Edit the file the first command wrote — **never hand-write a partial GVC file.** `cpln apply` replaces a GVC's `spec`, so a file carrying only `spec.keda` wipes `spec.staticPlacement.locationLinks` and every workload in that GVC loses its placement.

### Git token secret — optional, private DAG repositories only

An **opaque** secret whose payload is a personal access token, referenced by `gitSync.auth.secretName`. Leave that empty for a public repository or when git-sync is off.

```bash
printf '%s' "YOUR_GIT_TOKEN" | cpln secret create-opaque --name my-airflow-git-token --encoding plain -f -
```

## Configuration

### Location

```yaml
location: aws-us-east-1  # must already be a location of the GVC you install into
```

Airflow runs in exactly **one** location. That is not a simplification: a `shared` volumeset provisions one volume *per location*, so the Airflow home — DAGs and task logs — written in one location is invisible in another, and the metadata database and broker are each a single volume bound to a single replica. Every workload is pinned here; a GVC location you do not name runs nothing.

### PostgreSQL (metadata database)

```yaml
postgres:
  image: postgres:18
  resources:
    minCpu: 250m
    maxCpu: 500m
    minMemory: 512Mi
    maxMemory: 1024Mi
  config:
    credentialsSecretName: my-airflow-db-credentials  # prerequisite dictionary secret: username, password, database
  volumeset:
    capacity: 10                    # GiB, minimum 10
```

### Redis (Celery broker)

```yaml
redis:
  image: redis:7.4
  resources:
    cpu: 250m
    memory: 512Mi
  volumeset:
    capacity: 10                    # GiB, minimum 10
```

### Airflow

```yaml
airflow:
  webserver:
    image: apache/airflow:3.0.3
    resources:
      cpu: 2000m
      memory: 3Gi
  celeryWorker:
    image: controlplanecorporation/celery:v1
    replicas: 1                     # fixed worker count; ignored when keda.enabled is true
    resources:
      cpu: 256m
      memory: 512Mi
  webPort: 8080                     # serves the UI and REST API

  auth:
    secretName: my-airflow-auth     # the prerequisite dictionary secret above
    jwtExpirationTime: 86400        # API token lifetime in seconds (Airflow's own default)

  admin:
    username: admin                 # its password is `adminPassword` in the secret

  scheduler:
    dagDirListInterval: 10          # how often to rescan the DAG folder (seconds)
    minFileProcessInterval: 10      # minimum interval between processing a DAG file (seconds)

  celery:
    workerConcurrency: 1            # tasks each worker runs concurrently
```

The admin user is provisioned by Airflow's `SimpleAuthManager`, re-applied from the secret on every container start. It has no SSO or LDAP support — front it with an OAuth/OIDC auth manager if you need one.

### Storage

```yaml
volumeset:
  airflow:
    capacity: 10                    # shared Airflow home (DAGs + logs), GiB, minimum 10
```

### Access

```yaml
firewallConfig:
  inboundAllowCIDR: []              # [] = closed; add CIDRs to expose the UI, e.g. - 203.0.113.0/24

internalAccess:
  type: same-gvc                    # options: same-gvc, same-org, workload-list
  workloads: []                     # only with workload-list, e.g. - //gvc/GVC_NAME/workload/WORKLOAD_NAME
```

Under `workload-list` this release's own four workloads are always added for you — they have to reach the metadata database, the broker and each other — and so is the KEDA operator when `keda.enabled` is true.

### DAG delivery (git-sync)

```yaml
gitSync:
  enabled: false
  repo: ""                          # e.g. https://github.com/YOUR_ORG/dags
  branch: main
  period: 60s                       # how often to sync
  subPath: ""                       # optional subfolder within the repo containing DAGs
  auth:
    secretName: ""                  # opaque secret holding a PAT; empty = public repo
```

With git-sync off, put DAGs directly in `/opt/airflow/dags` on the shared volume.

### KEDA autoscaling

```yaml
keda:
  enabled: false                    # requires KEDA enabled on the GVC — see Prerequisites
  minScale: 1                       # minimum number of Celery workers; 0 = scale to zero when idle
  maxScale: 3                       # maximum number of Celery workers
  scaleToZeroDelay: 300             # idle time before scaling to zero (seconds)
  listLength: 3                     # Redis queue length that triggers a scale-up
  cooldownPeriod: 1                 # cooldown between scaling events (seconds)
  initialCooldownPeriod: 1          # cooldown after startup before scaling begins (seconds)
  pollingInterval: 4                # how often KEDA queries Redis (seconds)
```

## Connecting

| What | Where |
|---|---|
| Airflow UI + REST API | `status.canonicalEndpoint` of the webserver workload — `cpln workload get {release}-airflow-webserver --gvc {gvc} -o yaml`. Returns 403 until you add a CIDR. |
| Airflow UI, no public access | `cpln port-forward {release}-airflow-webserver 8080:8080 --gvc {gvc}`, then `http://localhost:8080` |
| Metadata database (in-GVC) | `{release}-airflow-postgres.{gvc}.cpln.local:5432` |
| Redis broker (in-GVC) | `{release}-airflow-redis.{gvc}.cpln.local:6379` |
| Login | `airflow.admin.username` + the `adminPassword` key of your auth secret |

### First run

1. Install with `firewallConfig.inboundAllowCIDR: []` (the default).
2. `cpln port-forward {release}-airflow-webserver 8080:8080 --gvc {gvc}` and log in at `http://localhost:8080`.
3. To expose the UI, `helm upgrade` with your own CIDRs in `firewallConfig.inboundAllowCIDR`, then allow 30 s to a few minutes for the firewall to propagate.

API tokens are issued by `POST /auth/token` with the same credentials and passed as `Authorization: Bearer <token>` on `/api/v2/...`.

## Rotating the database password

PostgreSQL keeps the password it was initialized with, and a running workload keeps the values it started with, so a rotation takes three steps in order:

1. Change it in the database: `cpln workload exec RELEASE_NAME-airflow-postgres --gvc GVC_NAME --container postgresql -- psql -U DB_USERNAME -d DB_NAME -c "ALTER ROLE \"DB_USERNAME\" PASSWORD 'NEW_PASSWORD'"` (`DB_USERNAME` and `DB_NAME` are the secret's `username` and `database`).
2. Update the `password` key of the secret: `cpln secret edit SECRET_NAME`.
3. Right away, redeploy the webserver and the workers: `cpln workload force-redeployment RELEASE_NAME-airflow-webserver RELEASE_NAME-airflow-celery-worker --gvc GVC_NAME`, and wait until `get-deployments` shows a higher version number for each, alone and ready. Do not redeploy the database: PostgreSQL reads the secret only when it is first initialized, so restarting it only adds downtime.

Connections Airflow already has open keep working after `ALTER ROLE`; new ones fail until the redeploy finishes, so rotate in a quiet window. Without step 3 the old password stays in use indefinitely: updating a secret does not restart the workloads that read it.

## Upgrading from 2.0.0

`postgres.config.username`, `postgres.config.password` and `postgres.config.database` were removed: the metadata database credentials are now a prerequisite secret. Carrying the old keys forward fails the render.

2.0.0 created that secret itself (`RELEASE_NAME-airflow-config`), so **this upgrade deletes it**, and the chart refuses that name for the new secret. Before upgrading, create a secret under a **new** name holding the values your database was initialized with — not new ones, or Airflow loses its database connection:

```bash
cpln secret reveal RELEASE_NAME-airflow-config -o yaml   # username and password the database runs with today
cpln secret create-dictionary --name RELEASE_NAME-airflow-db \
  --entry username='YOUR_CURRENT_USERNAME' --entry password='YOUR_CURRENT_PASSWORD' --entry database='YOUR_CURRENT_DATABASE'
```

`YOUR_CURRENT_DATABASE` is `postgres.config.database` of the 2.0.0 release — `airflow` unless you changed it; the old secret does not hold it. Then upgrade with `postgres.config.credentialsSecretName` set to the new name and the three old keys removed. An upgrade that passes no values at all uses the default name `my-airflow-db-credentials`, so create the secret under that name instead if you upgrade that way.

The upgrade restarts PostgreSQL, the webserver and the workers (they now read the new secret), so Airflow is unavailable for a couple of minutes. The new version of a workload can also wait about 10 minutes with `is not allowed to reveal the secret` in `get-deployments` while access to the new secret propagates; the previous version keeps running meanwhile, and it clears by itself (or wait about 5 minutes, then `cpln workload force-redeployment` the waiting workload).

## Migrating from 1.x

**Never `helm upgrade` a 1.x release onto 2.x.** 1.x created its own GVC; 2.x does not declare one, and Helm deletes what a chart no longer declares — so the upgrade would destroy that GVC and every workload, volumeset and identity in it, including your metadata database and DAGs, while reporting success. The chart refuses to render if your values still carry the `gvc` key, but an upgrade that passes no values at all sees only the new chart's defaults and cannot be stopped. Migrate to a **new release** instead:

1. Install this version as a **new release** into an existing GVC, pointing `airflow.auth.secretName` at the **same auth secret** the 1.x release used, and `postgres.config.credentialsSecretName` at a new database credentials secret (see Prerequisites). The `fernetKey` must be identical or every stored Connection and Variable becomes unreadable.
2. Move the metadata database. The commands read each container's own `POSTGRES_USER` / `POSTGRES_DB`, so nothing is hardcoded. `cpln workload exec` mangles raw binary output and drops stdin unless `--stdin` is passed, so the dump travels base64-encoded in both directions:

   ```bash
   cpln workload exec OLD-airflow-postgres --gvc OLD_GVC --container postgresql --quiet \
     -- sh -c 'pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc | base64' | base64 -d > airflow.dump
   base64 < airflow.dump | cpln workload exec NEW-airflow-postgres --gvc NEW_GVC --container postgresql --stdin --quiet \
     -- sh -c 'base64 -d | pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists --no-owner --no-acl'
   ```

3. Move the DAGs. With `gitSync.enabled: true` there is nothing to do — the sidecar re-clones. Otherwise copy them off the old shared volume onto the new one:

   ```bash
   cpln workload exec OLD-airflow-webserver --gvc OLD_GVC --container airflow --quiet \
     -- sh -c 'tar -cf - -C /opt/airflow/dags . | base64' | base64 -d > dags.tar
   base64 < dags.tar | cpln workload exec NEW-airflow-webserver --gvc NEW_GVC --container airflow --stdin --quiet \
     -- sh -c 'base64 -d | tar -xf - -C /opt/airflow/dags'
   ```

4. Force a redeployment of the new webserver so the scheduler re-reads the restored database, and confirm your DAGs and Connections are present in the UI.
5. Only then uninstall the old release. That deletes the GVC 1.x created, and everything in it.

Other 2.0.0 changes: `gvc.locations` became the single top-level `location`; `keda.enabled` now defaults to **false** and requires KEDA enabled on your GVC; `airflow.celeryWorker.replicas` sets the worker count when KEDA is off; and `internalAccess` is new.

## Important Notes

- **Enable KEDA on the GVC before setting `keda.enabled: true`.** The workload is accepted either way with no error: without KEDA on the GVC the workers never autoscale and sit at `keda.minScale` forever — at `minScale: 0` that is zero workers and every task queues silently. The webserver checks the GVC at boot and refuses a fresh install that has this wrong.
- **`location` must be a location of your GVC.** The platform stores a placement for a location that does not exist without any error, and the release then runs nothing at all, anywhere, with no failed deployment to look at. The webserver reads the GVC at boot and says so.
- **A wide fan-out can silently lose tasks.** Measured on this worker image: a 24-task burst finished 7 failed / 9 success, with the failures never starting at all (`hostname: ""`, `start_date: null`). The cause is a concurrent-import race inside the Celery executor's Redis transport — `module 'redis' has no attribute 'client'` from `kombu/transport/redis.py` — not anything this template configures. Until it is fixed upstream, avoid wide simultaneous fan-outs, or stagger task submission. **The tasks fail silently: nothing surfaces in the UI as an error.**
- **Create the auth and database credentials secrets before installing.** Without either the deployment wedges and `cpln logs` returns zero lines. The only diagnostic is `status.versions[].message` from `cpln workload get-deployments` (`get-deployments`, not plain `get`). It self-heals in roughly 5.5 to 10.5 minutes after the secret appears, or immediately with a forced redeployment.
- **Rotating the database password needs `ALTER ROLE` plus a forced redeployment of the webserver and workers** — see [Rotating the database password](#rotating-the-database-password).
- **A firewall change takes 30 s to a few minutes to propagate** — a UI that still returns 403 right after an upgrade is not broken yet.
- **The first upgrade after an install can re-apply resources even with identical values**, restarting the webserver and the database; expect a couple of minutes of unavailability.
- **Uninstalling deletes all three volumesets** — the metadata database, the broker and the shared Airflow home. Export anything you need first.

## Links

- [Apache Airflow documentation](https://airflow.apache.org/docs/)
- [Airflow security model](https://airflow.apache.org/docs/apache-airflow/stable/security/index.html)
- [Fernet key and encryption at rest](https://airflow.apache.org/docs/apache-airflow/stable/security/secrets/fernet.html)
- [KEDA documentation](https://keda.sh/docs/)
- [git-sync documentation](https://github.com/kubernetes/git-sync)
