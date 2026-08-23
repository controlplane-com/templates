# nginx — maintainer briefing

**What it is.** An nginx reverse proxy that fronts other workloads in the same GVC, routing by path to the
targets listed in `locations`. Ships with a demo backend so a default install does something visible.

**Common use cases.** Putting several internal workloads behind one public endpoint, path-based routing to
services that would otherwise each need their own endpoint, and adding a proxy layer in front of a workload
that should not be publicly reachable itself.

## Architecture

| Resource | Notes |
|---|---|
| workload `-proxy` | the nginx proxy; autoscaling knobs exposed |
| secret | the generated `nginx.conf`, built from `locations` |
| identity + policy | `reveal` on the configuration secret |
| workload `-example` *(optional)* | demo backend, created when `enableExample: true` |

Does not create a GVC.

## Key knobs (shipped defaults)

| Knob | Default | Notes |
|---|---|---|
| `proxyWorkload.image` | `nginx:1.31.4` | pinned in 1.1.2; was `nginx:latest` |
| `enableExample` | `true` | deploys the demo backend and routes **all** traffic to it |
| `locations` | `[]` | your own proxy targets |
| `autoscaling` | — | the proxy is stateless and scales horizontally |

## Troubleshooting traps

- **`enableExample: true` is the default and swallows all traffic.** A user who adds `locations` but leaves
  the example on will not reach their own services. Turning it off is step one of any real use.
- **Targets must be fully qualified.** `WORKLOAD.GVC.cpln.local` — the bare workload name is not reliably
  resolvable, and this is the most common cause of a 502 here.
- **The example backend image cannot be pinned.** `gcr.io/knative-samples/helloworld-go` publishes only
  `:latest`, so the demo target can change under you. It does not affect the proxy, which is pinned.
- **Config errors surface at container start, not at render.** `locations` is templated into `nginx.conf`, so
  a malformed entry produces a container that will not start rather than a failed `helm install`.
