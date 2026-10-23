## Nginx Reverse Proxy

Creates an nginx reverse proxy workload that routes incoming traffic to internally accessible workloads by path. Includes an optional example backend for quick testing.

### Architecture

- **Proxy workload** (`RELEASE_NAME-nginx`) — the nginx reverse proxy, routing to the targets listed in `locations`. Always open to the internet.
- **Secret** — the `nginx.conf`: generated from the values below, or your own from `nginxConf`.
- **Identity and policy** — `reveal` on the configuration secret.
- **Example backend workload** (`RELEASE_NAME-example`) *(optional)* — a demo target reachable only from the proxy, created when `enableExample: true`.

This template does not create a GVC.

### Prerequisites

None for a default install, which deploys the example backend and routes to it.

To proxy to your own services, set `enableExample: false` and add each target to `locations`. Those workloads must already exist in the same GVC, and each one's internal firewall must allow traffic from `RELEASE_NAME-nginx` (for example `same-gvc`, or a workload list that includes the proxy).

### Configuration

**Proxy workload** — configure the nginx container image and timeout:
```yaml
proxyWorkload:
  image: nginx:1.31.7 # pinned: `latest` makes installs non-reproducible
  port: 80 # leave at 80: nginx.conf and the health probes are fixed to port 80
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

**Custom proxy locations** — define your own routing rules by adding entries to `locations`. Each entry proxies a path to a workload running in the same GVC. Put only the bare workload name in `workload`; the chart builds `WORKLOAD_NAME.GVC_NAME.cpln.local` itself:
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

**Custom nginx.conf** — to run your own configuration instead of the generated one, put the whole file in `nginxConf`. Helm template syntax in it is rendered, so it can still use `.Values.locations` and `.Values.global.cpln.gvc`. Keep `listen 80` and a `location /health` that returns 200, because the health probes check them:
```yaml
nginxConf: "" # a full nginx.conf replacing the generated one (Helm template syntax is rendered); empty = generated from the settings above
```

### Built-in Routes

Two routes are always active regardless of configuration:

- `GET /health` → returns `200 {"success":true,"message":"OK"}`
- `GET /fail` → returns `500 {"success":false,"message":"Error"}`

A 500, 502, 503 or 504 from an upstream workload is answered with the `/fail` body; the status code is kept.

### Connecting

| What | Address |
|---|---|
| Public endpoint | `https://` + `status.canonicalEndpoint` of `RELEASE_NAME-nginx` (always open to the internet) |
| Private tunnel | `cpln port-forward RELEASE_NAME-nginx 8080:80 --gvc GVC_NAME`, then `http://localhost:8080` |
| Credentials | None; any authentication is up to the services behind the proxy |

Read the canonical endpoint:

```bash
cpln workload get RELEASE_NAME-nginx --gvc GVC_NAME -o yaml
```

### Important Notes

- **`enableExample: true` is the default** and deploys a demo backend that answers every request none of your `locations` match. Set it to `false` to route `/` to your own service; a `/` location while it is on stops the proxy from starting.
- **Put only the bare workload name in `locations[].workload`.** The chart appends `.GVC_NAME.cpln.local` itself, so typing a fully qualified name produces a doubled hostname.
- **Each target's internal firewall must allow `RELEASE_NAME-nginx`**, or its route returns the `/fail` response.
- **The proxy is always public.** The chart opens it to `0.0.0.0/0` and has no value to make it private.
- **`proxyWorkload.port` does not move the listener.** nginx listens on 80 and the probes check 80 regardless, so leave it at `80`.
- **A routing change rolls the proxy onto the new config by itself** after `helm upgrade`; with one replica, requests may fail for a few seconds during the swap.
- **The example backend image is unpinned.** `gcr.io/knative-samples/helloworld-go` publishes only `:latest`, so the demo target can change under you. It does not affect the proxy itself, which is pinned.

### Links

- [Nginx Documentation](https://nginx.org/en/docs/)
- [Nginx Location Directive](https://nginx.org/en/docs/http/ngx_http_core_module.html#location)
- [Nginx Reverse Proxy Guide](https://docs.nginx.com/nginx/admin-guide/web-server/reverse-proxy/)
