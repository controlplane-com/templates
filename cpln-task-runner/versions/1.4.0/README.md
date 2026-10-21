# Control Plane Task Runner

A self-hosted HTTP task queue and scheduler, similar to Google Cloud Tasks. Enqueue a task over HTTP and the workers deliver it to your target URL with retries, delayed and scheduled execution, per-client rate limiting, and a circuit breaker. This template deploys the API, the workers, and the Redis Sentinel cluster they persist to.

## Architecture

- **API workload** — HTTP endpoint for enqueuing tasks and for the admin endpoints; private by default (`api.public.enabled: false`), reachable from the same GVC
- **Worker workload** — background processor that delivers tasks to their target URLs; no public access
- **Redis + Sentinel** (bundled subchart) — highly available task persistence and coordination
- **Identity + policy** — grants both workloads `reveal` on exactly the secrets they read (the prerequisite secrets below)

## Prerequisites

Three secrets must exist **BEFORE you install**. If one is missing, the deployment wedges silently — see Important Notes for how to diagnose that.

**1. Redis and Sentinel passwords** — two `dictionary` secrets, each with the key `password`: one holds the bundled Redis password, the other the Sentinel password. Redis, Sentinel, the API and the Worker read both:

```sh
cpln secret create-dictionary --name my-cpln-task-runner-redis-credentials --entry password="$(openssl rand -hex 24)"
cpln secret create-dictionary --name my-cpln-task-runner-sentinel-credentials --entry password="$(openssl rand -hex 24)"
```

Upgrading from 1.3.0? Do not generate new passwords — see [Upgrading from 1.3.0](#upgrading-from-130).

**2. Admin API key.** The `/admin/*` endpoints create, edit and delete clients and rate-limit tiers, and they are guarded by the `X-Admin-Key` header. The key is an `opaque` secret whose payload *is* the key:

```sh
printf '%s' "$(openssl rand -hex 32)" | \
  cpln secret create-opaque --name my-cpln-task-runner-admin-key --encoding plain -f -
```

Use `printf`, not `echo` — `echo` appends a newline, which becomes part of the key and then has to be sent in every admin request.

Read it back in plaintext with `-o yaml`; without it the payload is redacted:

```sh
cpln secret reveal my-cpln-task-runner-admin-key -o yaml
```


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

**Bundled Redis** — Redis and Sentinel read their passwords from the prerequisite secrets:

```yaml
redis:
  redis:
    auth:
      fromSecret:
        enabled: true          # must stay true
        name: my-cpln-task-runner-redis-credentials   # prerequisite dictionary secret for Redis
        passwordKey: password  # key holding the Redis password
    persistence:
      enabled: true
  sentinel:
    auth:
      fromSecret:
        enabled: true          # must stay true
        name: my-cpln-task-runner-sentinel-credentials   # prerequisite dictionary secret for Sentinel
        passwordKey: password  # key holding the Sentinel password
    persistence:
      enabled: true
```

## Connecting

| What | Address | Credentials |
|---|---|---|
| API (public, only with `api.public.enabled: true`) | `status.canonicalEndpoint` of `RELEASE_NAME-task-runner-api` | none for `/v1/*`; `X-Admin-Key` for `/admin/*` |
| API (internal) | `RELEASE_NAME-task-runner-api.GVC_NAME.cpln.local:8080` | same |
| Redis Sentinel | `RELEASE_NAME-sentinel.GVC_NAME.cpln.local:26379` (master name `mymaster`) | `password` in your Sentinel credentials secret |
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

## Rotating the Redis and Sentinel passwords

Redis reads its password from the secret at every start, but Sentinel keeps the passwords it first started with on its volume, so editing the secrets alone locks the API and Worker out. Apply the new passwords live on every node first, then restart the API and Worker. `rx` and `sx` run a command on one Redis node or Sentinel (`LOCATION` is your GVC's location; nodes and Sentinels are numbered from 0 up to `redis.redis.replicas` and `redis.sentinel.replicas` minus one):

```bash
rx() { cpln workload exec RELEASE_NAME-redis --gvc GVC_NAME --location LOCATION \
  --container redis --replica "RELEASE_NAME-redis-$1" -- "${@:2}"; }
sx() { cpln workload exec RELEASE_NAME-sentinel --gvc GVC_NAME --location LOCATION \
  --container sentinel --replica "RELEASE_NAME-sentinel-$1" -- "${@:2}"; }
# The loops cover the default 3 Redis nodes and 3 Sentinels; list one number per node if you changed the counts
# 1. On every Redis node: accept the new Redis password alongside the old one, and replicate with it
for n in 0 1 2; do
  rx $n redis-cli --no-auth-warning -a OLD_REDIS_PASSWORD ACL SETUSER default ">NEW_REDIS_PASSWORD"
  rx $n redis-cli --no-auth-warning -a OLD_REDIS_PASSWORD CONFIG SET masterauth NEW_REDIS_PASSWORD
done
# 2. On every Sentinel: monitor Redis with the new Redis password, and accept the new Sentinel password alongside the old one
for n in 0 1 2; do
  sx $n redis-cli -p 26379 --no-auth-warning -a OLD_SENTINEL_PASSWORD SENTINEL SET mymaster auth-pass NEW_REDIS_PASSWORD
  sx $n redis-cli -p 26379 --no-auth-warning -a OLD_SENTINEL_PASSWORD ACL SETUSER default ">NEW_SENTINEL_PASSWORD"
done
# 3. Put the new passwords in the two secrets (key password) and read them back
cpln secret edit my-cpln-task-runner-redis-credentials
cpln secret edit my-cpln-task-runner-sentinel-credentials
cpln secret reveal my-cpln-task-runner-redis-credentials -o yaml
cpln secret reveal my-cpln-task-runner-sentinel-credentials -o yaml
# 4. Restart the API and Worker, which keep the old passwords until they restart
cpln workload force-redeployment RELEASE_NAME-task-runner-api RELEASE_NAME-task-runner-worker --gvc GVC_NAME
# 5. Once get-deployments shows both at a higher version, alone and ready, retire the old passwords.
#    FLUSHCONFIG writes Sentinel's own password change to its volume, so it survives a restart
for n in 0 1 2; do rx $n redis-cli --no-auth-warning -a NEW_REDIS_PASSWORD ACL SETUSER default "<OLD_REDIS_PASSWORD"; done
# Sentinels authenticate to each other with this password; without it they lose quorum once the old one is retired
for n in 0 1 2; do sx $n redis-cli -p 26379 --no-auth-warning -a NEW_SENTINEL_PASSWORD SENTINEL CONFIG SET sentinel-pass NEW_SENTINEL_PASSWORD; done
for n in 0 1 2; do
  sx $n redis-cli -p 26379 --no-auth-warning -a NEW_SENTINEL_PASSWORD ACL SETUSER default "<OLD_SENTINEL_PASSWORD"
  sx $n redis-cli -p 26379 --no-auth-warning -a NEW_SENTINEL_PASSWORD SENTINEL FLUSHCONFIG
done
# 6. Check that the Sentinels can still fail over: this prints OK 3 usable Sentinels
sx 0 redis-cli -p 26379 --no-auth-warning -a NEW_SENTINEL_PASSWORD SENTINEL CKQUORUM mymaster
```

If both `fromSecret.name` values point at one secret, edit that one secret in step 3, each password under its own key.

## Upgrading from 1.3.0

1.4.0 no longer takes the Redis and Sentinel passwords as values, and no longer creates the `task-runner-secrets` secret. Use the CURRENT passwords: Redis and Sentinel keep the ones they started with, so new ones would lock the API and Worker out. To change them, upgrade first, then follow [Rotating the Redis and Sentinel passwords](#rotating-the-redis-and-sentinel-passwords).

**With `createSecret: true` (the default)**, the upgrade **deletes** `task-runner-secrets`, so copy the passwords into two new secrets **before** upgrading:

1. Read the current passwords. `redis-password` is the Redis password, `redis-sentinel-password` the Sentinel password:

   ```sh
   cpln secret reveal task-runner-secrets -o yaml
   ```

2. Create the two new secrets with those values:

   ```sh
   cpln secret create-dictionary --name my-cpln-task-runner-redis-credentials --entry password='YOUR_CURRENT_REDIS_PASSWORD'
   cpln secret create-dictionary --name my-cpln-task-runner-sentinel-credentials --entry password='YOUR_CURRENT_SENTINEL_PASSWORD'
   ```

3. Remove `createSecret`, `secretName`, `redis.redisPassword` and `redis.sentinelPassword` from your values, and point `redis.redis.auth.fromSecret.name` and `redis.sentinel.auth.fromSecret.name` at the new secrets (the defaults above). The chart refuses to render while any of the removed keys is still set, and refuses the name `task-runner-secrets`.

**With `createSecret: false`** and a secret of your own, keep it: remove the same four keys, keep both `fromSecret.name` values pointing at your secret, and set both `passwordKey` values to its key names explicitly (`redis-password` and `redis-sentinel-password` if you kept the 1.3.0 defaults; 1.4.0 defaults both to `password`). Nothing is deleted.

## Upgrading from 1.2.x

Two behaviours change, and either will break an existing workflow if you relied on the old default:

- **Admin authentication is now enforced.** 1.2.x shipped `api.env.adminApiKey: ""`, which left `/admin/*` **unauthenticated on a public API** — anyone who found the endpoint could create clients and change rate-limit tiers. That key is now a prerequisite secret named by `api.admin.apiKeySecretName`, and an install that still sets `api.env.adminApiKey` (or `redis.admin.fromSecret`) fails immediately with a message naming the replacement. Create the secret with the *same* key you were using, and admin scripts keep working; create a new one and every caller must be updated. Leaving `apiKeySecretName` empty is still possible for an internal-only deployment, but is rejected while `api.public.enabled` is true.
- **`api.public.enabled` now defaults to `false`** (it was `true`). An upgrade that relied on the old default loses its public endpoint; set `api.public.enabled: true` explicitly to keep it, knowing `/v1/enqueue` is unauthenticated (see Important Notes).
- Then follow [Upgrading from 1.3.0](#upgrading-from-130): the Redis and Sentinel passwords your 1.2.x release runs with (`mypassword` if never changed) go into the two credentials secrets.

## Important Notes

- A missing prerequisite secret wedges the deployment **silently**: `cpln logs` returns zero lines because the container never starts. The only diagnostic is `status.versions[].message` from `cpln workload get-deployments RELEASE_NAME-task-runner-api --gvc GVC_NAME -o yaml`, which names the missing secret. After creating it the workload recovers on its own after several minutes, or immediately with `cpln workload force-redeployment RELEASE_NAME-task-runner-api --gvc GVC_NAME`.
- **`/v1/enqueue` has NO authentication, and an unknown `client_id` is auto-registered rather than rejected.** Posting a never-seen ID returns `status: enqueued` and creates that client. So nothing gates the queue — with public access on, any stranger can make a worker issue arbitrary outbound HTTP with a method, headers and body of their choosing. This is why `public.enabled` now defaults to `false`. No setting fixes it; the application has no client authentication. If you need public submission, front it with your own authenticating proxy.
- Workers fetch the URLs they are given. `allowPrivateUrls: false` keeps them off internal addresses; turning it on lets any enqueued task reach anything the worker can route to.
- Never change the Redis or Sentinel password by editing the secrets alone: Sentinel keeps the passwords it first started with on its volume, so that locks the API and Worker out. Follow [Rotating the Redis and Sentinel passwords](#rotating-the-redis-and-sentinel-passwords). After rotating the **admin key**, run `cpln workload force-redeployment RELEASE_NAME-task-runner-api --gvc GVC_NAME`; a running workload keeps the old value until it is redeployed.
- The first `helm upgrade` after an install can re-apply the bundled Redis resources even with identical values, which restarts them; the API returns errors while Redis comes back.
- Access changes can take a few minutes to propagate, so a freshly toggled `public.enabled` looks unchanged at first.

## Links

- [Control Plane documentation](https://docs.controlplane.com/)
- [Secrets reference](https://docs.controlplane.com/reference/secret)
- [Workload firewall and security](https://docs.controlplane.com/concepts/security)
- [Redis template](https://github.com/controlplane-com/templates/tree/main/redis)
- [Task Runner image on Docker Hub](https://hub.docker.com/r/controlplanecorporation/cpln-task-runner)
