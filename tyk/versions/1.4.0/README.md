# Tyk

Tyk is an open-source API gateway that fronts your APIs with authentication, rate limiting, quotas and analytics. This template deploys a Tyk Gateway whose API definitions and policies come from secrets you control, backed by a Redis + Sentinel store.

## Architecture

- **Gateway workload** (`standard`) — Tyk Gateway serving HTTP on `listenPort` (8080 by default), autoscaling 1-3 replicas on CPU.
- **Redis** (bundled subchart) — the token, rate-limit, quota and analytics store; 2 replicas with persistence.
- **Redis Sentinel** (bundled subchart) — 3 replicas providing automatic Redis failover; the gateway connects through Sentinel, not to Redis directly.
- **Identity + policy** — grants the gateway `reveal` on exactly the secrets it reads: your admin secret, your API and policy secrets, and your Redis and Sentinel password secrets.
- **No template-created credential secret** — the admin API key and the Redis and Sentinel passwords live only in prerequisite secrets you create.

## Prerequisites

**Five secrets must exist BEFORE you install** — the deployment wedges waiting on a secret that does not exist, and `cpln logs` shows nothing; the missing secret is named only in `status.versions[].message` of `cpln workload get-deployments WORKLOAD_NAME --gvc GVC_NAME -o yaml`. `apiSecretName` and `policySecretName` default to the placeholder names `my-tyk-apis` and `my-tyk-policies`, so they count unless you set them to `""`. All five are referenced by name only, so none of their contents pass through Helm values or land in the release.

### 1. Admin API key (`adminSecretName`)

This is `TYK_GW_SECRET`, the key for the Gateway Control API (`/tyk/*`, sent as the `X-Tyk-Authorization` header). Whoever holds it can create, list and revoke every API key on the gateway, so generate a strong random value:

```bash
printf '%s' "$(openssl rand -hex 32)" | cpln secret create-opaque --name SECRET_NAME --encoding plain -f -
```

### 2. API definitions (`apiSecretName`)

A **dictionary** secret whose keys are `*.json` filenames and whose values are Tyk API definitions. It is mounted at `/opt/tyk-gateway/apps`. Write it to a file and apply it, since the values are multi-line JSON:

```yaml
kind: secret
name: my-tyk-apis
description: my-tyk-apis
tags: {}
type: dictionary
data:
  app1.json: >-
    { "api_id": "app1", "name": "app1", "org_id": "default", "use_keyless":
    true, "use_jwt": false, "disable_rate_limit": true, "definition": {
    "location": "header", "key": "version" }, "version_data": { "not_versioned":
    true, "versions": { "Default": { "name": "Default", "use_extended_paths":
    true } } }, "proxy": { "listen_path": "/app1", "target_url":
    "http://app1.example-gvc.cpln.local:80", "strip_listen_path": true },
    "active": true}
  app2.json: >-
    { "api_id": "app2", "name": "app2", "org_id": "default", "use_keyless":
    true, "active": true, "version_data": { "not_versioned": true, "versions": {
    "Default": { "name": "Default", "use_extended_paths": true } } }, "proxy": {
    "listen_path": "/app2", "target_url":
    "http://app2.example-gvc.cpln.local:8080", "strip_listen_path": true,
    "preserve_host_header": false, "enable_load_balancing": false,
    "check_host_against_uptime_tests": false }}
```

```bash
cpln apply -f my-tyk-apis.yaml
```

### 3. Policies (`policySecretName`)

An **opaque** secret (`encoding: plain`) holding a single JSON object of policies, mounted at `/opt/tyk-gateway/policies/policies.json`:

```yaml
kind: secret
name: my-tyk-policies
description: my-tyk-policies
tags: {}
type: opaque
data:
  encoding: plain
  payload: |-
    {
      "app1-rate-limit": {
        "org_id": "default",
        "active": true,
        "rate": 20,
        "per": 100,
        "quota_max": 0,
        "quota_renewal_rate": 0,
        "quota_remaining": 0,
        "access_rights": {
          "app1": {
            "api_id": "app1",
            "api_name": "app1",
            "versions": ["Default"]
          }
        }
      }
    }
```

```bash
cpln apply -f my-tyk-policies.yaml
```

You can manage these two secrets independently after install, as long as their names stay the same. To omit either one, explicitly set its value to `""` and it is left out of the workload configuration; leaving the default name in place without creating the secret wedges the install.

### 4. Redis and Sentinel passwords (`redis.redis.auth.fromSecret.name`, `redis.sentinel.auth.fromSecret.name`)

Two **dictionary** secrets, each with the key `password`: one read by Redis and the gateway, one read by Sentinel and the gateway. Generate both:

```bash
cpln secret create-dictionary --name my-tyk-redis-credentials --entry password="$(openssl rand -hex 24)"
cpln secret create-dictionary --name my-tyk-sentinel-credentials --entry password="$(openssl rand -hex 24)"
```

Upgrading from 1.3.0, do **not** generate new ones: follow [Upgrading from 1.3.0](#upgrading-from-130).

## Configuration

### Image and port

```yaml
image: tykio/tyk-gateway:v5.10.0

listenPort: 8080 # REQUIRED - the port the gateway listens on
```

### Prerequisite secrets

```yaml
adminSecretName: my-tyk-admin-secret # REQUIRED - opaque secret (encoding: plain) holding the admin API key

apiSecretName: my-tyk-apis # dictionary secret holding your API definition JSON files; "" = serve the image's demo APIs
policySecretName: my-tyk-policies # opaque secret holding your policies JSON; "" = no policies
```

### Gateway

```yaml
allowMasterKeys: false # true lets a key created with no access_rights reach EVERY API on this gateway

resources:
  cpu: 50m
  memory: 128Mi

autoscaling:
  maxScale: 3
  metric: cpu
  minScale: 1
  scaleToZeroDelay: 300
  target: 100

multiZone: false # OPTIONAL - Deploys replicas across multiple zones (confirm availability in your location)
```

### Access

```yaml
externalAccess: false # true publishes the gateway — INCLUDING its /tyk admin API — to the internet
internalAccess: # OPTIONAL - Sets the internal firewall scope
  type: same-gvc # options: none, same-gvc, same-org, workload-list
  workloads: [] # used with workload-list, e.g. //gvc/GVC_NAME/workload/WORKLOAD_NAME
```

`externalAccess` defaults to `false` because the gateway and its admin API share one port: publishing the gateway publishes `/tyk/*` with it, and the admin secret becomes the only thing in front of it.

### Bundled Redis and Sentinel

```yaml
redis:
  redis:
    resources:
      cpu: 200m
      memory: 256Mi
    replicas: 2
    auth:
      fromSecret:
        enabled: true
        name: my-tyk-redis-credentials # REQUIRED - dictionary secret holding the Redis password
        passwordKey: password # key inside that secret
    firewall:
      internal_inboundAllowType: same-gvc
    persistence:
      enabled: true
  sentinel:
    resources:
      cpu: 200m
      memory: 256Mi
    replicas: 3
    auth:
      fromSecret:
        enabled: true
        name: my-tyk-sentinel-credentials # REQUIRED - dictionary secret holding the Sentinel password
        passwordKey: password # key inside that secret
    firewall:
      internal_inboundAllowType: same-gvc
    persistence:
      enabled: true
```

## Connecting

| Path | Address | Notes |
|---|---|---|
| Public gateway | `status.canonicalEndpoint` | Only when `externalAccess: true`. Read it with `cpln workload get RELEASE_NAME-tyk-api-gateway --gvc GVC_NAME -o yaml`. |
| Internal gateway | `http://RELEASE_NAME-tyk-api-gateway.GVC_NAME.cpln.local:8080` | Subject to `internalAccess.type`. Use `listenPort` if you changed it. |
| Proxied API | `<gateway address>/<listen_path>` | `listen_path` comes from each API definition, e.g. `/app1`. |
| Admin API | `<gateway address>/tyk/keys`, `/tyk/apis`, `/tyk/reload` | Send header `X-Tyk-Authorization: <the payload of your adminSecretName secret>`. |
| Redis / Sentinel | `RELEASE_NAME-redis.GVC_NAME.cpln.local:6379`, `RELEASE_NAME-sentinel.GVC_NAME.cpln.local:26379` | Internal only; passwords are in your Redis and Sentinel password secrets. |

Reveal the admin key when you need it:

```bash
cpln secret reveal SECRET_NAME -o yaml
```

## Rotating the Redis password

Redis reads its password from the secret at every start, but Sentinel keeps the one it first started with on its volume, so a new password is applied live in three places before the gateway restarts. `rx` and `sx` run a command on one Redis node or Sentinel (`LOCATION` is your GVC's location; nodes and Sentinels are numbered from 0 up to `redis.redis.replicas` and `redis.sentinel.replicas` minus one):

```bash
rx() { cpln workload exec RELEASE_NAME-redis --gvc GVC_NAME --location LOCATION \
  --container redis --replica "RELEASE_NAME-redis-$1" -- "${@:2}"; }
sx() { cpln workload exec RELEASE_NAME-sentinel --gvc GVC_NAME --location LOCATION \
  --container sentinel --replica "RELEASE_NAME-sentinel-$1" -- "${@:2}"; }
# 1. On EVERY Redis node: accept the new password alongside the old one, and replicate with it
rx 0 redis-cli --no-auth-warning -a OLD_PASSWORD ACL SETUSER default ">NEW_PASSWORD"
rx 0 redis-cli --no-auth-warning -a OLD_PASSWORD CONFIG SET masterauth NEW_PASSWORD
# 2. On EVERY Sentinel (SENTINEL_PASSWORD is the value in your Sentinel password secret)
sx 0 redis-cli -p 26379 --no-auth-warning -a SENTINEL_PASSWORD SENTINEL SET mymaster auth-pass NEW_PASSWORD
# 3. Put the new password in the secret and read it back
cpln secret edit SECRET_NAME
cpln secret reveal SECRET_NAME -o yaml
# 4. Restart the gateway, which keeps the old password until it restarts
cpln workload force-redeployment RELEASE_NAME-tyk-api-gateway --gvc GVC_NAME
# 5. Once get-deployments shows a higher version, alone and ready: retire the old password on EVERY Redis node
rx 0 redis-cli --no-auth-warning -a NEW_PASSWORD ACL SETUSER default "<OLD_PASSWORD"
```

The Sentinel password itself is kept in Sentinel's configuration on its volume, and this template has no procedure for changing it: keep the value it was installed with.

## Upgrading from 1.3.0

`redis.redis.auth.password` and `redis.sentinel.auth.password` were removed: the two passwords are now prerequisite secrets. Carrying the old keys forward fails the render.

1.3.0 created `RELEASE_NAME-redis-auth-password` and `RELEASE_NAME-sentinel-auth-password` itself, so **this upgrade deletes them**. Before upgrading, copy the passwords your release runs with **today** into two secrets under **new** names. Do not generate new ones: Sentinel keeps the passwords it first started with on its volume, so a new value locks the gateway out of its store.

```bash
cpln secret reveal RELEASE_NAME-redis-auth-password -o yaml
cpln secret reveal RELEASE_NAME-sentinel-auth-password -o yaml
cpln secret create-dictionary --name my-tyk-redis-credentials --entry password='YOUR_CURRENT_REDIS_PASSWORD'
cpln secret create-dictionary --name my-tyk-sentinel-credentials --entry password='YOUR_CURRENT_SENTINEL_PASSWORD'
```

**If you never overrode them, they are literally `change-me-tyk-redis` and `change-me-tyk-sentinel`** — put those in the new secrets, then change the Redis one as described in [Rotating the Redis password](#rotating-the-redis-password).

Then upgrade with `redis.redis.auth.fromSecret.name` and `redis.sentinel.auth.fromSecret.name` set to the new names (the defaults above) and both `auth.password` blocks removed. If 1.3.0 ran with a password turned off, set the matching `auth.fromSecret.enabled: false` instead. The upgrade restarts Redis, Sentinel and the gateway, briefly interrupting key and rate-limit lookups. A new workload version can also wait up to about 10 minutes with `is not allowed to reveal the secret` in `get-deployments` while access to the new secrets propagates; the previous version keeps serving meanwhile.

## Important Notes

- **Leaving `apiSecretName` empty does not serve nothing — it serves Tyk's demo API.** The gateway falls back to the API definitions baked into the upstream image, so `Tyk Test API` answers requests and the install looks healthy while serving none of your APIs. Set the secret, or expect that.

- **Create all five prerequisite secrets before installing** — the workload wedges waiting on a secret that does not exist, and looks broken rather than failing loudly.
- **Changing a secret needs a redeployment.** Secrets are read when a replica starts: after editing one, force a redeployment of the gateway (see below); for the Redis password follow [Rotating the Redis password](#rotating-the-redis-password).
- **`externalAccess: true` puts the Tyk admin API on the internet.** `/tyk/*` is served on the same port as your proxied APIs and cannot be split off, so anyone who guesses or leaks the admin key can mint keys for every API. Prefer leaving it `false` and reaching the gateway from inside the GVC.
- **`allowMasterKeys: true` grants blanket access.** With it on, any key created through `/tyk/keys` without an `access_rights` section can call **every** API on this gateway. It defaults to `false`, matching upstream Tyk; versions of this template before 1.3.0 forced it on.
- **Egress is closed.** The gateway's outbound firewall is empty, so it can only proxy to upstream targets inside its own GVC (`*.cpln.local`). Add `outboundAllowCIDR`/`outboundAllowHostname` to the workload to reach APIs on the public internet.
- **API definitions and policies are read at boot.** After editing either secret, run `cpln workload force-redeployment RELEASE_NAME-tyk-api-gateway --gvc GVC_NAME`. A running replica's mounted secret does not change until it redeploys, and `/tyk/reload` reloads only the one replica that answers the request, so it is not a substitute.
- **Access changes can take several minutes** to propagate after an `externalAccess` or `internalAccess` change; re-test before concluding a change did not apply.
- **The first `helm upgrade` after an install restarts the bundled Redis**, briefly interrupting rate-limit and key lookups even when nothing changed. Later no-op upgrades do not.

## Links

- [Tyk Gateway documentation](https://tyk.io/docs/)
- [Gateway configuration options](https://tyk.io/docs/tyk-oss-gateway/configuration/)
- [Tyk Gateway API (admin endpoints)](https://tyk.io/docs/api-management/gateway-config-managing-classic/)
- [API definition objects](https://tyk.io/docs/api-management/gateway-config-tyk-classic/)
- [Security policies](https://tyk.io/docs/api-management/policies/)
