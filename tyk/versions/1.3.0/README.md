# Tyk

Tyk is an open-source API gateway that fronts your APIs with authentication, rate limiting, quotas and analytics. This template deploys a Tyk Gateway whose API definitions and policies come from secrets you control, backed by a Redis + Sentinel store.

## Architecture

- **Gateway workload** (`standard`) — Tyk Gateway serving HTTP on `listenPort` (8080 by default), autoscaling 1-3 replicas on CPU.
- **Redis** (bundled subchart) — the token, rate-limit, quota and analytics store; 2 replicas with persistence.
- **Redis Sentinel** (bundled subchart) — 3 replicas providing automatic Redis failover; the gateway connects through Sentinel, not to Redis directly.
- **Identity + policy** — grants the gateway `reveal` on exactly the secrets it mounts: your admin secret, your API and policy secrets, and the bundled Redis/Sentinel passwords.
- **No template-created credential secret** — the admin API key lives only in the prerequisite secret you create.

## Prerequisites

**Three secrets must exist BEFORE you install** — the deployment wedges waiting on a secret that does not exist. All three are referenced by name only, so none of their contents pass through Helm values or land in the release.

### 1. Admin API key (`adminSecretName`)

This is `TYK_GW_SECRET`, the key for the Gateway Control API (`/tyk/*`, sent as the `X-Tyk-Authorization` header). Whoever holds it can create, list and revoke every API key on the gateway, so generate a strong random value:

```bash
printf '%s' "$(openssl rand -hex 32)" | cpln secret create-opaque --name my-tyk-admin-secret --encoding plain -f -
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

You can manage these two secrets independently after install, as long as their names stay the same. To omit either one, set its value to `""` and it will be left out of the workload configuration.

## Configuration

### Image and port

```yaml
image: tykio/tyk-gateway:v5.10.0

listenPort: 8080 # REQUIRED - the port the gateway listens on
```

### Prerequisite secrets

```yaml
adminSecretName: my-tyk-admin-secret # REQUIRED - opaque secret (encoding: plain) holding the admin API key

apiSecretName: my-tyk-apis # REQUIRED - dictionary secret holding your API definition JSON files
policySecretName: my-tyk-policies # REQUIRED - opaque secret holding your policies JSON
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
      password:
        enabled: true
        value: change-me-tyk-redis
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
      password:
        enabled: true
        value: change-me-tyk-sentinel
    firewall:
      internal_inboundAllowType: same-gvc
    persistence:
      enabled: true
```

This Redis serves only this gateway and is never reachable from outside the GVC, so its passwords stay template values — but they are used exactly as written, so replace both `change-me-…` placeholders before installing.

## Connecting

| Path | Address | Notes |
|---|---|---|
| Public gateway | `https://<canonical-endpoint>` | Only when `externalAccess: true`. Read it from `status.canonicalEndpoint` in `cpln workload get <release>-tyk-api-gateway -o yaml`. |
| Internal gateway | `http://<release>-tyk-api-gateway.<gvc>.cpln.local:8080` | Subject to `internalAccess.type`. Use `listenPort` if you changed it. |
| Proxied API | `<gateway address>/<listen_path>` | `listen_path` comes from each API definition, e.g. `/app1`. |
| Admin API | `<gateway address>/tyk/keys`, `/tyk/apis`, `/tyk/reload` | Send header `X-Tyk-Authorization: <the payload of your adminSecretName secret>`. |
| Redis / Sentinel | `<release>-redis.<gvc>.cpln.local:6379`, `<release>-sentinel.<gvc>.cpln.local:26379` | Internal only; passwords are the `redis.*.auth.password.value` values. |

Reveal the admin key when you need it:

```bash
cpln secret reveal my-tyk-admin-secret
```

## Important Notes

- **Create all three prerequisite secrets before installing** — the workload wedges waiting on a secret that does not exist, and looks broken rather than failing loudly.
- **`externalAccess: true` puts the Tyk admin API on the internet.** `/tyk/*` is served on the same port as your proxied APIs and cannot be split off, so anyone who guesses or leaks the admin key can mint keys for every API. Prefer leaving it `false` and reaching the gateway from inside the GVC.
- **`allowMasterKeys: true` grants blanket access.** With it on, any key created through `/tyk/keys` without an `access_rights` section can call **every** API on this gateway. It defaults to `false`, matching upstream Tyk; versions of this template before 1.3.0 forced it on.
- **Egress is closed.** The gateway's outbound firewall is empty, so it can only proxy to upstream targets inside its own GVC (`*.cpln.local`). Add `outboundAllowCIDR`/`outboundAllowHostname` to the workload to reach APIs on the public internet.
- **API definitions and policies are read at boot.** After editing either secret, redeploy the gateway workload (or call `/tyk/reload`) for the change to take effect.
- **Access changes take up to a couple of minutes** to propagate after an `externalAccess` or `internalAccess` change.
- **The first `helm upgrade` after an install restarts the bundled Redis**, briefly interrupting rate-limit and key lookups even when nothing changed. Later no-op upgrades do not.

## Links

- [Tyk Gateway documentation](https://tyk.io/docs/)
- [Gateway configuration options](https://tyk.io/docs/tyk-oss-gateway/configuration/)
- [Tyk Gateway API (admin endpoints)](https://tyk.io/docs/api-management/gateway-config-managing-classic/)
- [API definition objects](https://tyk.io/docs/api-management/gateway-config-tyk-classic/)
- [Security policies](https://tyk.io/docs/api-management/policies/)
