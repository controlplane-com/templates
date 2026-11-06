# Control Plane Task Runner

A self-hosted HTTP task queue and scheduler, similar to Google Cloud Tasks. Enqueue a task over HTTP and the workers deliver it to your target URL with retries, delayed and scheduled execution, per-client rate limiting, and a circuit breaker. This template deploys the API, the workers, and the Redis Sentinel cluster they persist to.

## Architecture

- **API workload** — HTTP endpoint for enqueuing tasks and for the admin endpoints; private by default (`api.public.enabled: false`), reachable from the same GVC
- **Worker workload** — background processor that delivers tasks to their target URLs; no public access
- **Redis + Sentinel** (bundled subchart) — highly available task persistence and coordination
- **Secret** (optional, on by default) — holds the bundled Redis and Sentinel passwords
- **Identity + policy** — grants both workloads `reveal` on exactly the secrets they read

## Prerequisites

**Create the admin API key secret BEFORE you install.** The `/admin/*` endpoints create, edit and delete clients and rate-limit tiers, and they are guarded by the `X-Admin-Key` header. The key is an `opaque` secret whose payload *is* the key:

```sh
printf '%s' "$(openssl rand -hex 32)" | \
  cpln secret create-opaque --name my-cpln-task-runner-admin-key --encoding plain -f -
```

Use `printf`, not `echo` — `echo` appends a newline, which becomes part of the key and then has to be sent in every admin request.

Read it back in plaintext with `-o yaml`; without it the payload is redacted:

```sh
cpln secret reveal my-cpln-task-runner-admin-key -o yaml
```

If the named secret does not exist, the deployment wedges silently — see Important Notes for how to diagnose that.

Nothing else is required. The bundled Redis and Sentinel passwords are ordinary values (nobody types them), but they are used exactly as written, so change them from their `change-me-…` defaults.

## Configuration

**Image** — the same image runs both workloads:

```yaml
image: controlplanecorporation/cpln-task-runner:0.4
```

**API** — the HTTP front end:

```yaml
api:
  enabled: true
  replicas:
    min: 1
    max: 3
  port: 8080
  public:
    enabled: false           # DEFAULT. /v1/enqueue authenticates nothing — see Important Notes before enabling
    pathPrefix: ""           # not used for routing by this chart version
  admin:
    # REQUIRED prerequisite secret — an `opaque` secret (encoding: plain) whose
    # payload is the admin API key. "" disables admin auth and is rejected while
    # public.enabled is true.
    apiKeySecretName: my-cpln-task-runner-admin-key
  resources:
    cpu: 500m
    memory: 512Mi
  env:
    logLevel: info           # debug / info / warn / error
    otelEndpoint: ""         # empty disables tracing
    connectRetries: 30       # Redis connection attempts at startup
    retryIntervalSec: 2      # seconds between those attempts
```

**Worker** — the delivery side:

```yaml
worker:
  enabled: true
  replicas:
    min: 1
    max: 5
  port: 8082                 # health checks only
  resources:
    cpu: 1
    memory: 1Gi
  env:
    logLevel: info
    concurrency: 10          # concurrent tasks per replica
    taskTimeoutSec: 1800     # per-task timeout
    maxRetry: 5              # delivery attempts before a task is archived
    allowPrivateUrls: false  # allow tasks to target private/internal URLs
    cbFailureThreshold: 5    # circuit breaker: failures before opening
    cbTimeoutSec: 30         # circuit breaker: seconds before retrying
    connectRetries: 30
    retryIntervalSec: 2
    otelEndpoint: ""
```

**Bundled Redis credentials** — created for you unless you bring your own secret:

```yaml
createSecret: true                  # false = supply your own secret instead
secretName: task-runner-secrets     # org-level name of the secret this chart creates (not release-prefixed)

redis:
  redisPassword: change-me-cpln-task-runner-redis
  sentinelPassword: change-me-cpln-task-runner-sentinel
  redis:
    auth:
      fromSecret:
        enabled: true
        name: task-runner-secrets   # with createSecret: false, your secret's name
        passwordKey: redis-password
    persistence:
      enabled: true
  sentinel:
    auth:
      fromSecret:
        enabled: true
        name: task-runner-secrets
        passwordKey: redis-sentinel-password
    persistence:
      enabled: true
```

With `createSecret: false`, create a `dictionary` secret yourself holding the keys named by `passwordKey` above, and point both `fromSecret.name` values at it:

```bash
cpln secret create-dictionary --name SECRET_NAME \
  --entry redis-password='YOUR-REDIS-PASSWORD' \
  --entry redis-sentinel-password='YOUR-SENTINEL-PASSWORD'
```

`secretName` is an org-level name and is not prefixed with the release name, so a second install in the same org needs a different `secretName`, with both `fromSecret.name` values changed to match.

## Connecting

| What | Address | Credentials |
|---|---|---|
| API (public, only with `api.public.enabled: true`) | `status.canonicalEndpoint` of `RELEASE_NAME-task-runner-api` | none for `/v1/*`; `X-Admin-Key` for `/admin/*` |
| API (internal) | `RELEASE_NAME-task-runner-api.GVC_NAME.cpln.local:8080` | same |
| Redis Sentinel | `RELEASE_NAME-sentinel.GVC_NAME.cpln.local:26379` (master name `mymaster`) | the Sentinel password above |
| Admin key | your `opaque` secret | `cpln secret reveal my-cpln-task-runner-admin-key -o yaml` |

Read the public endpoint, when enabled:

```bash
cpln workload get RELEASE_NAME-task-runner-api --gvc GVC_NAME -o yaml
```

To reach the private API from your machine, open a tunnel:

```bash
cpln port-forward RELEASE_NAME-task-runner-api 8080:8080 --gvc GVC_NAME
curl http://127.0.0.1:8080/health/ready
```

The examples below use `CANONICAL_ENDPOINT`; substitute the `status.canonicalEndpoint` value (a full `https://` URL), or `http://127.0.0.1:8080` through the tunnel.

### Enqueue a task

```bash
curl -X POST CANONICAL_ENDPOINT/v1/enqueue \
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

### Admin endpoints

Every `/admin/*` request needs the `X-Admin-Key` header:

```bash
# List clients
curl CANONICAL_ENDPOINT/admin/clients \
  -H "X-Admin-Key: YOUR-ADMIN-KEY"

# Create or update a client
curl -X POST CANONICAL_ENDPOINT/admin/clients/set \
  -H "X-Admin-Key: YOUR-ADMIN-KEY" \
  -H "Content-Type: application/json" \
  -d '{"client_id": "new-service", "tier": "premium", "enabled": true}'
```

### Rate-limiting tiers

Tiers are assigned per client through the admin API:

| Tier | Requests/min | Max concurrent |
|------|-------------|----------------|
| free | 10 | 1 |
| basic | 100 | 5 |
| premium | 1,000 | 20 |
| enterprise | 5,000 | 50 |

### OpenTelemetry

Set `otelEndpoint` on either workload to export traces, and set the GVC's **Tracing Provider** to Control Plane. The built-in HTTP collector endpoint is `tracing.controlplane:4318`.

## Upgrading from 1.2.x

Two behaviours change, and either will break an existing workflow if you relied on the old default:

- **Admin authentication is now enforced.** 1.2.x shipped `api.env.adminApiKey: ""`, which left `/admin/*` **unauthenticated on a public API** — anyone who found the endpoint could create clients and change rate-limit tiers. That key is now a prerequisite secret named by `api.admin.apiKeySecretName`, and an install that still sets `api.env.adminApiKey` (or `redis.admin.fromSecret`) fails immediately with a message naming the replacement. Create the secret with the *same* key you were using, and admin scripts keep working; create a new one and every caller must be updated. Leaving `apiKeySecretName` empty is still possible for an internal-only deployment, but is rejected while `api.public.enabled` is true.
- **`api.public.enabled` now defaults to `false`** (it was `true`). An upgrade that relied on the old default loses its public endpoint; set `api.public.enabled: true` explicitly to keep it, knowing `/v1/enqueue` is unauthenticated (see Important Notes).
- The bundled Redis and Sentinel passwords now default to `change-me-…` instead of `mypassword`. An existing install keeps whatever you set; a fresh install with the defaults untouched runs on a password published in this repo.

## Important Notes

- A missing prerequisite secret wedges the deployment **silently**: `cpln logs` returns zero lines because the container never starts. The only diagnostic is `status.versions[].message` from `cpln workload get-deployments RELEASE_NAME-task-runner-api --gvc GVC_NAME -o yaml`, which names the missing secret. After creating it the workload recovers on its own after several minutes, or immediately with `cpln workload force-redeployment RELEASE_NAME-task-runner-api --gvc GVC_NAME`.
- **`/v1/enqueue` has NO authentication, and an unknown `client_id` is auto-registered rather than rejected.** Posting a never-seen ID returns `status: enqueued` and creates that client. So nothing gates the queue — with public access on, any stranger can make a worker issue arbitrary outbound HTTP with a method, headers and body of their choosing. This is why `public.enabled` now defaults to `false`. No setting fixes it; the application has no client authentication. If you need public submission, front it with your own authenticating proxy.
- Workers fetch the URLs they are given. `allowPrivateUrls: false` keeps them off internal addresses; turning it on lets any enqueued task reach anything the worker can route to.
- Change the `change-me-…` Redis and Sentinel passwords before the first install. Once the volumes are initialised, changing them requires uninstalling (which deletes the volume sets) and reinstalling.
- The first `helm upgrade` after an install can re-apply the bundled Redis resources even with identical values, which restarts them; the API returns errors while Redis comes back.
- Access changes can take a few minutes to propagate, so a freshly toggled `public.enabled` looks unchanged at first.

## Links

- [Control Plane documentation](https://docs.controlplane.com/)
- [Secrets reference](https://docs.controlplane.com/reference/secret)
- [Workload firewall and security](https://docs.controlplane.com/concepts/security)
- [Redis template](https://github.com/controlplane-com/templates/tree/main/redis)
- [Task Runner image on Docker Hub](https://hub.docker.com/r/controlplanecorporation/cpln-task-runner)
