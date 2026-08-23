## Nginx Reverse Proxy

Creates an nginx reverse proxy workload that routes incoming traffic to internally accessible workloads by path. Includes an optional example backend for quick testing.

### Architecture

- **Proxy workload** — the nginx reverse proxy, routing to the targets listed in `locations`.
- **Secret** — the generated `nginx.conf`.
- **Identity and policy** — `reveal` on the configuration secret.
- **Example backend workload** *(optional)* — a demo target, created when `enableExample: true`.

This template does not create a GVC.

### Prerequisites

None for a default install, which deploys the example backend and routes to it.

To proxy to your own services, set `enableExample: false` and add each target to `locations`. Those workloads must already exist in the GVC.

### Configuration

**Proxy workload** — configure the nginx container image, port, and timeout:
```yaml
proxyWorkload:
  image: nginx:1.31.4 # pinned: `latest` makes installs non-reproducible
  port: 80
  capacityAI: false
  timeoutSeconds: 5
```

**Resources** — adjust CPU and memory per replica:
```yaml
resources:
  cpu: 100m
  memory: 128Mi
```

**Autoscaling** — set replica counts and concurrency limits:
```yaml
autoscaling:
  minScale: 1
  maxScale: 1
  maxConcurrency: 1000
```

**Example workload** — set `enableExample` to `true` to deploy a sample helloworld backend and automatically route all `/` traffic to it. Useful for verifying the proxy is working before connecting your own services:
```yaml
enableExample: true
```

**Custom proxy locations** — define your own routing rules by adding entries to `locations`. Each entry proxies a path to a workload running in the same GVC:
```yaml
locations:
  - path: /
    workload: my-workload
    port: 8080
    regexModifier: ""
  - path: /api
    workload: my-api
    port: 3000
    regexModifier: ""
```

The `regexModifier` field maps to nginx location modifiers (e.g., `~` for case-sensitive regex, `~*` for case-insensitive). Leave it empty for prefix matching.

### Built-in Routes

Two routes are always active regardless of configuration:

- `GET /health` → returns `200 {"success":true,"message":"OK"}`
- `GET /fail` → returns `500 {"success":false,"message":"Error"}`

Any 5XX errors from upstream workloads are intercepted and returned as the `/fail` response.

### Connecting

The nginx proxy is exposed externally on port 443 via Control Plane's TLS termination:

```
https://RELEASE_NAME-nginx.GVC_NAME.cpln.app
```

### Supported External Services
- [Nginx Documentation](https://nginx.org/en/docs/)

### Important Notes

- **`enableExample: true` is the default** and deploys a demo backend that all traffic routes to. Set it to `false` before pointing the proxy at your own services.
- **Targets must be reachable inside the GVC.** Use the fully-qualified internal hostname (`WORKLOAD.GVC.cpln.local`); the bare workload name is not reliably resolvable.
- **The example backend image is unpinned.** `gcr.io/knative-samples/helloworld-go` publishes only `:latest`, so the demo target can change under you. It does not affect the proxy itself, which is pinned.
