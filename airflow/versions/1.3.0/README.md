# Airflow App

Deploys Apache Airflow with CeleryExecutor using Redis as the broker and PostgreSQL database, with optional integration of KEDA for autoscaling Celery workers.

## What's Included

This template provisions a complete Airflow stack:

- **Apache Airflow Webserver** – The web UI for managing DAGs, monitoring task execution, and viewing logs
- **Celery Workers** – Distributed task execution workers that process your DAG tasks
- **Redis** – Message broker for the Celery task queue
- **PostgreSQL** – Backend database for Airflow metadata
- **KEDA Autoscaling** (optional) – Automatically scales Celery workers based on queue length

## Configuring the Values File

Update the `values.yaml` file before installation:

### GVC Settings

| Property | Description |
|----------|-------------|
| `gvc.name` | Name of the GVC (must be unique per deployment) |
| `gvc.locations` | List of cloud locations to deploy to (e.g., `aws-eu-central-1`) |

### PostgreSQL Configuration

| Property | Description |
|----------|-------------|
| `postgres.image` | PostgreSQL Docker image |
| `postgres.resources.cpu` | CPU allocation for PostgreSQL |
| `postgres.resources.memory` | Memory allocation for PostgreSQL |
| `postgres.config.username` | Database username |
| `postgres.config.password` | Database password (change from default) |

### Redis Configuration

| Property | Description |
|----------|-------------|
| `redis.image` | Redis Docker image |
| `redis.resources.cpu` | CPU allocation for Redis |
| `redis.resources.memory` | Memory allocation for Redis |

### Airflow Configuration

| Property | Description |
|----------|-------------|
| `airflow.webserver.image` | Airflow webserver Docker image |
| `airflow.webserver.resources.cpu` | CPU allocation for webserver |
| `airflow.webserver.resources.memory` | Memory allocation for webserver |
| `airflow.celeryWorker.image` | Celery worker Docker image |
| `airflow.celeryWorker.resources.cpu` | CPU allocation per worker |
| `airflow.celeryWorker.resources.memory` | Memory allocation per worker |
| `airflow.webPort` | Port for accessing the Airflow web interface |

### Volume Configuration

| Property | Description |
|----------|-------------|
| `volumeset.airflow.capacity` | Storage capacity for Airflow data (GiB, minimum 10) |
| `volumeset.postgres.capacity` | Storage capacity for PostgreSQL data (GiB, minimum 10) |

### Authentication

| Property | Description |
|----------|-------------|
| `volumeset.auth.jwtSecret` | Secret key for signing JWT tokens. **Ensure this value is changed**. Generate with `openssl rand -base64 48` |
| `volumeset.auth.jwtExpirationDelta` | JWT token expiration time in seconds |
| `volumeset.auth.jwtRefreshThreshold` | Threshold before token expires to allow refresh (seconds) |

### Scheduler Settings

| Property | Description |
|----------|-------------|
| `volumeset.scheduler.dagDirListInterval` | How often to scan the DAG folder (seconds) |
| `volumeset.scheduler.minFileProcessInterval` | Minimum interval between DAG file processing (seconds) |

### Celery Settings

| Property | Description |
|----------|-------------|
| `volumeset.celery.workerConcurrency` | Number of tasks each worker can run concurrently |

### KEDA Autoscaling

> **Note:** KEDA is not supported in `gcp/us-central1`.

| Property | Description |
|----------|-------------|
| `keda.enabled` | Enable or disable KEDA autoscaling |
| `keda.minScale` | Minimum number of Celery workers |
| `keda.maxScale` | Maximum number of Celery workers |
| `keda.scaleToZeroDelay` | Time before scaling to zero when idle (seconds) |
| `keda.listLength` | Queue length threshold to trigger scaling |
| `keda.cooldownPeriod` | Cooldown between scaling events (seconds) |
| `keda.initialCooldownPeriod` | Cooldown after startup before scaling (seconds) |
| `keda.pollingInterval` | Interval at which KEDA queries metrics (seconds) |

## Connecting to Airflow

Once the deployment is running, access the Airflow web UI through the canonical endpoint under the webserver workload:

```
https://<app-name>-airflow-webserver.<gvc-name>.cpln.app
```

### API Access

Airflow 3.x uses JWT-based authentication for API access. To interact with the Airflow API:

1. Obtain a JWT token by authenticating with the API
2. Include the token in subsequent requests via the `Authorization: Bearer <token>` header

The JWT settings (`jwtSecret`, `jwtExpirationDelta`, `jwtRefreshThreshold`) in your values file control token behavior.

## Important Notes

- **Unique GVC Name:** If deploying multiple instances of this template, you must assign a unique `gvc.name` for each deployment
- **Security:** Always change the default `postgres.config.password` and generate a new `jwtSecret` before deploying to production

## Supported External Services

- [Apache Airflow Documentation](https://airflow.apache.org/docs/)
- [Redis Documentation](https://redis.io/docs/latest/)