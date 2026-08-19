# Control Plane Task Runner

A self-hosted HTTP task queue and scheduler, similar to Google Cloud Tasks. Enqueue a task over HTTP and the workers deliver it to your target URL with retries, delayed and scheduled execution, per-client rate limiting, and a circuit breaker. This template deploys the API, the workers, and the Redis Sentinel cluster they persist to.

## Architecture

- **API workload** — HTTP endpoint for enqueuing tasks and for the admin endpoints; public by default
- **Worker workload** — background processor that delivers tasks to their target URLs; internal only
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
    enabled: true            # reachable from the internet; see Important Notes
    pathPrefix: ""           # path prefix for the public endpoint (empty = root)
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
secretName: task-runner-secrets     # name of the secret this chart creates

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

With `createSecret: false`, create a `dictionary` secret yourself holding the keys named by `passwordKey` above, and point both `fromSecret.name` values at it.

## Connecting

| What | Address | Credentials |
|---|---|---|
| API (public) | the workload's `*.cpln.app` canonical endpoint | none for `/v1/*`; `X-Admin-Key` for `/admin/*` |
| API (internal) | `{release}-task-runner-api.{gvc}.cpln.local:8080` | same |
| Redis Sentinel | `{release}-sentinel.{gvc}.cpln.local:26379` | the Sentinel password above |
| Admin key | your `opaque` secret | `cpln secret reveal my-cpln-task-runner-admin-key -o yaml` |

Find the public endpoint under `status.canonicalEndpoint` of `cpln workload get {release}-task-runner-api --gvc {gvc} -o yaml`.

### Enqueue a task

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

### Admin endpoints

Every `/admin/*` request needs the `X-Admin-Key` header:

```bash
# List clients
curl https://your-api-endpoint/admin/clients \
  -H "X-Admin-Key: YOUR-ADMIN-KEY"

# Create or update a client
curl -X POST https://your-api-endpoint/admin/clients/set \
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

One behaviour changes, and it will break an existing workflow if you relied on the old default:

- **Admin authentication is now enforced.** 1.2.x shipped `api.env.adminApiKey: ""`, which left `/admin/*` **unauthenticated on a public API** — anyone who found the endpoint could create clients and change rate-limit tiers. That key is now a prerequisite secret named by `api.admin.apiKeySecretName`, and an install that still sets `api.env.adminApiKey` (or `redis.admin.fromSecret`) fails immediately with a message naming the replacement. Create the secret with the *same* key you were using, and admin scripts keep working; create a new one and every caller must be updated. Leaving `apiKeySecretName` empty is still possible for an internal-only deployment, but is rejected while `api.public.enabled` is true.
- The bundled Redis and Sentinel passwords now default to `change-me-…` instead of `mypassword`. An existing install keeps whatever you set; a fresh install with the defaults untouched runs on a password published in this repo.

## Important Notes

- A missing prerequisite secret wedges the deployment **silently**: `cpln logs` returns zero lines because the container never starts. The only diagnostic is `cpln workload get-deployments {release}-task-runner-api --gvc {gvc} -o yaml` → `status.versions[].message`, which names the missing secret. After creating it, recovery takes 5.5–8.5 minutes, or run `cpln workload force-redeployment {release}-task-runner-api --gvc {gvc}` to cut that to about 90 seconds.
- **`/v1/enqueue` has NO authentication, and an unknown `client_id` is auto-registered rather than rejected.** Measured: posting a never-seen ID returns `status: enqueued` and creates that client. So nothing gates the queue — with public access on, any stranger can make a worker issue arbitrary outbound HTTP with a method, headers and body of their choosing. This is why `public.enabled` now defaults to `false`. No setting fixes it; the application has no client authentication. If you need public submission, front it with your own authenticating proxy.
- Workers fetch the URLs they are given. `allowPrivateUrls: false` keeps them off internal addresses; turning it on lets any enqueued task reach anything the worker can route to.
- Change the `change-me-…` Redis and Sentinel passwords before the first install. Once the volumes are initialised, changing them requires uninstalling (which deletes the volume sets) and reinstalling.
- The first `helm upgrade` after an install re-applies the bundled Redis resources even with identical values, which restarts them; the API returns errors for a minute or two while Redis comes back. Later upgrades are clean.
- Access changes take roughly 30 seconds to a few minutes to propagate, so a freshly toggled `public.enabled` looks unchanged at first.

## Links

- [Control Plane documentation](https://docs.controlplane.com/)
- [Secrets reference](https://docs.controlplane.com/reference/secret)
- [Workload firewall and security](https://docs.controlplane.com/concepts/security)
- [Redis template](https://github.com/controlplane-com/templates/tree/main/redis)
- [Task Runner image on Docker Hub](https://hub.docker.com/r/controlplanecorporation/cpln-task-runner)
