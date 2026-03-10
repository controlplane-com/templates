# Apache Airflow

Deploys Apache Airflow 3.x with CeleryExecutor using Redis as the message broker and PostgreSQL as the metadata database, with optional KEDA autoscaling and git-sync DAG delivery.

## What's Included

- **Airflow Webserver** – Hosts the web UI, API server, scheduler, dag-processor, and triggerer
- **Celery Workers** – Distributed task execution workers that process DAG tasks
- **Redis** – Message broker for the Celery task queue (persistent volume)
- **PostgreSQL** – Metadata database for Airflow state (persistent volume)
- **KEDA Autoscaling** (optional) – Scales Celery workers automatically based on Redis queue length
- **git-sync** (optional) – Sidecar that continuously syncs DAGs from a Git repository

## Pre-Deployment Checklist

Before deploying, update the following **required** values in `values.yaml`:

| Value | How to generate |
|-------|----------------|
| `airflow.auth.jwtSecret` | `openssl rand -base64 48` |
| `airflow.auth.fernetKey` | `python3 -c 'from cryptography.fernet import Fernet; print(Fernet.generate_key().decode())'` |
| `airflow.admin.password` | Choose a strong password |
| `postgres.config.password` | Choose a strong password |

## Configuration Reference

### GVC Settings

| Property | Description |
|----------|-------------|
| `gvc.name` | Name of the GVC (must be unique per deployment) |
| `gvc.locations` | Cloud locations to deploy to (e.g. `aws-eu-central-1`) |

### PostgreSQL

| Property | Description |
|----------|-------------|
| `postgres.image` | PostgreSQL Docker image |
| `postgres.resources.minCpu` / `maxCpu` | CPU request / limit |
| `postgres.resources.minMemory` / `maxMemory` | Memory request / limit |
| `postgres.config.username` | Database username |
| `postgres.config.password` | Database password |
| `postgres.config.database` | Database name |
| `postgres.volumeset.capacity` | Storage capacity in GiB (minimum 10) |

### Redis

| Property | Description |
|----------|-------------|
| `redis.image` | Redis Docker image |
| `redis.resources.cpu` / `memory` | CPU and memory allocation |
| `redis.volumeset.capacity` | Storage capacity in GiB (minimum 10) |

### Airflow

| Property | Description |
|----------|-------------|
| `airflow.webserver.image` | Airflow Docker image (e.g. `apache/airflow:3.0.3`) |
| `airflow.webserver.resources.cpu` / `memory` | Webserver CPU and memory |
| `airflow.celeryWorker.image` | Celery worker Docker image |
| `airflow.celeryWorker.resources.cpu` / `memory` | Worker CPU and memory |
| `airflow.webPort` | Port for the Airflow web interface (default `8080`) |

#### Authentication

| Property | Description |
|----------|-------------|
| `airflow.auth.jwtSecret` | **Required.** Secret for signing JWT tokens |
| `airflow.auth.jwtExpirationDelta` | JWT token lifetime in seconds |
| `airflow.auth.jwtRefreshThreshold` | Seconds before expiry to allow token refresh |
| `airflow.auth.fernetKey` | **Required.** Encrypts connections and variables stored in the database |

#### Admin User

| Property | Description |
|----------|-------------|
| `airflow.admin.username` | Initial admin username |
| `airflow.admin.password` | **Required.** Initial admin password |

The admin user is created on first startup using Airflow's `SimpleAuthManager`. The credentials are written to a password file on the shared volume and re-applied on every container restart, so the password always reflects the current value in `values.yaml`.

> **Note:** `SimpleAuthManager` is the default auth manager in Airflow 3.x and is suitable for development and internal deployments. For production deployments requiring SSO or LDAP, consider integrating an external auth provider via OAuth/OIDC.

#### Scheduler

| Property | Description |
|----------|-------------|
| `airflow.scheduler.dagDirListInterval` | How often to scan the DAG folder (seconds) |
| `airflow.scheduler.minFileProcessInterval` | Minimum interval between DAG file processing (seconds) |

#### Celery

| Property | Description |
|----------|-------------|
| `airflow.celery.workerConcurrency` | Tasks each worker runs concurrently (when KEDA is enabled) |

### Volumes

| Property | Description |
|----------|-------------|
| `volumeset.airflow.capacity` | Shared volume for Airflow home directory in GiB (minimum 10) |

The Airflow volume uses a shared (`NFS-style`) filesystem, allowing both the webserver and Celery workers to access DAGs and logs from the same volume.

### Firewall

| Property | Description |
|----------|-------------|
| `firewallConfig.inboundAllowCIDR` | List of CIDRs allowed to access the Airflow UI. Defaults to `0.0.0.0/0` (public). Restrict in production. |

### DAG Delivery (git-sync)

DAGs are delivered via a `git-sync` sidecar that continuously polls a Git repository and syncs files to the shared Airflow volume. This is the recommended approach for managing DAGs in production.

| Property | Description |
|----------|-------------|
| `gitSync.enabled` | Enable git-sync DAG delivery (default `false`) |
| `gitSync.repo` | Git repository URL (e.g. `https://github.com/org/dags`) |
| `gitSync.branch` | Branch to sync (default `main`) |
| `gitSync.period` | Sync interval (default `60s`) |
| `gitSync.subPath` | Subfolder within the repo containing DAGs (leave empty if DAGs are at the repo root) |
| `gitSync.auth.token` | Personal access token for private repos (leave empty for public repos) |

When git-sync is disabled, DAGs can be placed manually in the `/opt/airflow/dags` directory on the Airflow volume.

### KEDA Autoscaling

> **Note:** KEDA is not supported in `gcp/us-central1`.

| Property | Description |
|----------|-------------|
| `keda.enabled` | Enable KEDA autoscaling (default `true`) |
| `keda.minScale` | Minimum number of Celery workers |
| `keda.maxScale` | Maximum number of Celery workers |
| `keda.scaleToZeroDelay` | Seconds of idle time before scaling to zero |
| `keda.listLength` | Redis queue length threshold that triggers scaling |
| `keda.cooldownPeriod` | Cooldown between scaling events (seconds) |
| `keda.initialCooldownPeriod` | Cooldown after startup before scaling begins (seconds) |
| `keda.pollingInterval` | How often KEDA queries Redis metrics (seconds) |

## Accessing Airflow

Once deployed, the Airflow UI is available at the canonical endpoint of the webserver workload:

```
https://<gvc-name>-airflow-webserver.<gvc-name>.cpln.app
```

Log in with the `airflow.admin.username` and `airflow.admin.password` set in `values.yaml`.

### API Access

Airflow 3.x uses JWT-based authentication. To obtain a token:

```bash
curl -X POST https://<your-airflow-url>/auth/token \
  -H "Content-Type: application/json" \
  -d '{"username": "admin", "password": "your-password"}'
```

Use the returned token for subsequent API requests:

```bash
curl https://<your-airflow-url>/api/v2/dags \
  -H "Authorization: Bearer <token>"
```

## Production Considerations

- **Change all `CHANGE_ME` values** before deploying — `jwtSecret`, `fernetKey`, and `admin.password` are all required
- **Restrict `firewallConfig.inboundAllowCIDR`** to trusted IP ranges to limit access to the Airflow UI
- **Enable git-sync** for reliable, version-controlled DAG delivery
- **Auth**: `SimpleAuthManager` is not recommended for deployments requiring enterprise SSO. Evaluate an OAuth/OIDC integration for those use cases

## References

- [Apache Airflow Documentation](https://airflow.apache.org/docs/)
- [Redis Documentation](https://redis.io/docs/latest/)
- [KEDA Documentation](https://keda.sh/docs/)
- [git-sync Documentation](https://github.com/kubernetes/git-sync)
