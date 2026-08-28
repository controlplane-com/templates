# Apache Airflow

Apache Airflow 3.x with the CeleryExecutor: Redis as the task broker, PostgreSQL as the metadata database, KEDA autoscaling for workers, and optional git-sync DAG delivery. The UI ships closed to the internet.

## Architecture

- **Airflow Webserver** (`stateful`) — one container running the API server, scheduler, dag-processor and triggerer; serves the UI and REST API on port 8080.
- **Celery Workers** (`stateful`) — execute DAG tasks; scaled by KEDA on the Redis queue length.
- **Redis** (`stateful`) — Celery broker, on a persistent volumeset.
- **PostgreSQL** (`stateful`) — Airflow metadata database, on a persistent volumeset.
- **Airflow volumeset** (`shared`) — the Airflow home, mounted by the webserver and every worker so they see the same DAGs and logs.
- **GVC** — created by this template, because KEDA is enabled at the GVC level.
- **Identity + policy** — grants the workloads `reveal` on exactly the secrets they mount: the metadata database credentials, your auth secret, and (optionally) your git token.
- **git-sync sidecar** (optional) — polls a Git repository and syncs DAGs onto the shared volume.

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

### Git token secret — optional, private DAG repositories only

An **opaque** secret whose payload is a personal access token, referenced by `gitSync.auth.secretName`. Leave that empty for a public repository or when git-sync is off.

```bash
printf '%s' "YOUR_GIT_TOKEN" | cpln secret create-opaque --name my-airflow-git-token --encoding plain -f -
```

## Configuration

### GVC

```yaml
gvc:
  name: airflow          # must be a NEW name — see Important Notes
  locations:
    - name: aws-eu-central-1
```

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
    username: username
    password: change-me-airflow-db  # set at FIRST install; see Upgrading below
    database: airflow
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
    workerConcurrency: 1            # tasks each worker runs concurrently, when KEDA is enabled
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
```

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
  enabled: true
  minScale: 1                       # minimum number of Celery workers
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

## Upgrading from 1.4.x

1.4.x carried `airflow.auth.jwtSecret`, `airflow.auth.fernetKey`, `airflow.admin.password` and `gitSync.auth.token` as values. All four were removed; a values file still setting any of them fails at render with the replacement. There are no compatibility fallbacks.

- **The fernet key cannot be rotated.** If your 1.4.x install ran on the shipped `CHANGE_ME` default, every Connection and Variable in the metadata database is encrypted under a key published in a public repository — and moving to a new key makes all of them unreadable. There is no in-place fix: export what you need, install 1.5.0 with a fresh key, and re-enter the Connections and Variables. Treat any credential those Connections held as compromised and rotate it at the source.
- **The database password cannot be changed in place either.** `POSTGRES_PASSWORD` is only read when the data directory is initialized, so pointing `postgres.config.password` at a new value on an existing volume leaves the database on the old one and Airflow can no longer connect. Set it at first install.
- **The UI now ships closed.** Put your own CIDRs in `firewallConfig.inboundAllowCIDR` if you were relying on the old `0.0.0.0/0` default.

## Important Notes

- **A wide fan-out can silently lose tasks.** Measured on this image: a 24-task burst finished 7 failed / 9 success, with the failures never starting at all (`hostname: ""`, `start_date: null`). The cause is a concurrent-import race inside the Celery executor's Redis transport — `module 'redis' has no attribute 'client'` from `kombu/transport/redis.py` — not anything this template configures. Until it is fixed upstream, avoid wide simultaneous fan-outs, or stagger task submission. **The tasks fail silently: nothing surfaces in the UI as an error.**
- **A missing auth secret can take up to about ten minutes to self-heal** (measured 10 min 17 s) once you create it. `cpln workload force-redeployment` clears it in roughly 90 seconds if you do not want to wait.
- **This template creates its GVC** (KEDA is a GVC-level setting). Point `gvc.name` at a NEW name: Helm adopts a GVC that already exists, and `helm uninstall` then deletes it along with every unrelated workload in it.
- **Create the auth secret before installing.** Without it the deployment wedges and `cpln logs` returns zero lines. The only diagnostic is `status.versions[].message` from `cpln workload get-deployments {release}-airflow-webserver --gvc {gvc} -o yaml` (`get-deployments`, not plain `get`). It self-heals about 5.5–8.5 minutes after the secret appears, or immediately with `cpln workload force-redeployment`.
- **Set `postgres.config.password` at first install.** It is bundled plumbing no human types, but the shipped `change-me-airflow-db` is a published value and cannot be changed once the volume is initialized.
- **A firewall change takes 30 s to a few minutes to propagate** — a UI that still returns 403 right after a `helm upgrade` is not broken yet.
- **The first `helm upgrade` after an install re-applies resources even with identical values**, restarting the webserver and the database; expect a couple of minutes of unavailability.
- **DAG data survives reinstall.** The volumesets are deleted by `cpln helm uninstall`, so export anything you need first.

## Links

- [Apache Airflow documentation](https://airflow.apache.org/docs/)
- [Airflow security model](https://airflow.apache.org/docs/apache-airflow/stable/security/index.html)
- [Fernet key and encryption at rest](https://airflow.apache.org/docs/apache-airflow/stable/security/secrets/fernet.html)
- [KEDA documentation](https://keda.sh/docs/)
- [git-sync documentation](https://github.com/kubernetes/git-sync)
