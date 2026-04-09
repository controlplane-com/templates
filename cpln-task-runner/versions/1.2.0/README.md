# Control Plane Task Runner

A self-hosted task queue and scheduler service similar to Google Cloud Tasks, deployed on Control Plane.

## Overview

Task Runner provides HTTP-based task enqueuing with automatic retry, delayed/scheduled execution, per-client rate limiting, and multi-queue support with priority levels.

## Architecture

This template deploys two workloads:

- **API**: HTTP endpoint for enqueuing tasks, managing clients, and health checks
- **Worker**: Background processor that executes tasks from the queue

Both workloads connect to a Redis Sentinel cluster for high-availability task persistence and coordination. The template includes a Redis dependency that deploys a Redis Sentinel setup.

## Configuration

#### API Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| `api.enabled` | `true` | Enable/disable API workload |
| `api.port` | `8080` | Container port |
| `api.replicas.min` | `1` | Minimum replicas |
| `api.replicas.max` | `3` | Maximum replicas |
| `api.public.enabled` | `true` | Enable public internet access |
| `api.public.pathPrefix` | `""` | Path prefix for public endpoint (empty for root) |
| `api.resources.cpu` | `500m` | CPU allocation |
| `api.resources.memory` | `512Mi` | Memory allocation |
| `api.env.logLevel` | `info` | Log level (debug/info/warn/error) |
| `api.env.adminApiKey` | `""` | Admin API key for protected endpoints |
| `api.env.connectRetries` | `30` | Redis connection retry attempts |
| `api.env.retryIntervalSec` | `2` | Redis retry interval in seconds |
| `api.env.otelEndpoint` | `""` | OpenTelemetry collector endpoint |

#### Worker Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| `worker.enabled` | `true` | Enable/disable Worker workload |
| `worker.port` | `8082` | Container port (for health checks) |
| `worker.replicas.min` | `1` | Minimum replicas |
| `worker.replicas.max` | `5` | Maximum replicas |
| `worker.resources.cpu` | `1000m` | CPU allocation |
| `worker.resources.memory` | `1Gi` | Memory allocation |
| `worker.env.logLevel` | `info` | Log level |
| `worker.env.concurrency` | `10` | Concurrent workers per replica |
| `worker.env.taskTimeoutSec` | `1800` | Task timeout (30 min default) |
| `worker.env.maxRetry` | `5` | Maximum retry attempts |
| `worker.env.allowPrivateUrls` | `false` | Allow targeting private URLs |
| `worker.env.cbFailureThreshold` | `5` | Circuit breaker failure threshold |
| `worker.env.cbTimeoutSec` | `30` | Circuit breaker timeout |
| `worker.env.connectRetries` | `30` | Redis connection retry attempts |
| `worker.env.retryIntervalSec` | `2` | Redis retry interval in seconds |
| `worker.env.otelEndpoint` | `""` | OpenTelemetry collector endpoint |

#### Secret Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| `createSecret` | `true` | Create a secret for Redis passwords and admin API key |
| `secretName` | `task-runner-secrets` | Name of the secret to create (only used if `createSecret` is `true`) |

#### Redis Configuration

| Parameter | Default | Description |
|-----------|---------|-------------|
| `redis.redisPassword` | `mypassword` | Redis password (used if `createSecret` is `true`) |
| `redis.sentinelPassword` | `mypassword` | Redis Sentinel password (used if `createSecret` is `true`) |
| `redis.redis.auth.fromSecret.name` | `task-runner-secrets` | Secret name for Redis password (used if `createSecret` is `false`) |
| `redis.redis.auth.fromSecret.passwordKey` | `redis-password` | Secret key for Redis password (used if `createSecret` is `false`) |
| `redis.sentinel.auth.fromSecret.name` | `task-runner-secrets` | Secret name for Sentinel password (used if `createSecret` is `false`) |
| `redis.sentinel.auth.fromSecret.passwordKey` | `redis-sentinel-password` | Secret key for Sentinel password (used if `createSecret` is `false`) |
| `redis.admin.fromSecret.name` | `task-runner-secrets` | Secret name for admin API key (used if `createSecret` is `false`) |
| `redis.admin.fromSecret.apiKeyKey` | `admin-api-key` | Secret key for admin API key (used if `createSecret` is `false`) |

**Note**: When `createSecret` is `true`, the template automatically creates a secret with Redis passwords and admin API key. When `createSecret` is `false`, configure the `redis.*.fromSecret` values to match your existing secret structure.

## Usage

### Enqueue a Task

```bash
curl -X POST https://your-api-endpoint/v1/enqueue \
  -H "Content-Type: application/json" \
  -d '{
    "client_id": "my-service",
    "queue": "default",
    "task": {
      "url": "https://api.example.com/webhook",
      "method": "POST",
      "headers": {"Content-Type": "application/json"},
      "body": "{\"event\": \"user.created\"}"
    }
  }'
```

### Admin Endpoints

When `ADMIN_API_KEY` is configured, admin endpoints require the `X-Admin-Key` header:

```bash
# List clients
curl https://your-api-endpoint/admin/clients \
  -H "X-Admin-Key: your-admin-key"

# Create/update client
curl -X POST https://your-api-endpoint/admin/clients/set \
  -H "X-Admin-Key: your-admin-key" \
  -H "Content-Type: application/json" \
  -d '{
    "client_id": "new-service",
    "tier": "premium",
    "enabled": true
  }'
```

## Rate Limiting Tiers

Rate limiting tiers are configured per-client via the admin API (see Admin Endpoints above). The available tiers and their limits are:

| Tier | Requests/min | Max Concurrent |
|------|-------------|----------------|
| free | 10 | 1 |
| basic | 100 | 5 |
| premium | 1,000 | 20 |
| enterprise | 5,000 | 50 |

## OpenTelemetry

To enable Control Plane’s native tracing through OpenTelemetry, specify an `otelEndpoint` in your values for each workload.

In your GVC configuration, ensure the `Tracing Provider` is set to `Control Plane`.

Once enabled, you can point your service to the default HTTP collector endpoint:
```
tracing.controlplane:4318
```