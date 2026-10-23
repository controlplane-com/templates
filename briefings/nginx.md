# nginx — maintainer briefing

**What it is.** An nginx reverse proxy that fronts other workloads in the same GVC, routing by path to the
targets listed in `locations`. Ships with a demo backend so a default install does something visible.

**Common use cases.** Putting several internal workloads behind one public endpoint, path-based routing to
services that would otherwise each need their own endpoint, and adding a proxy layer in front of a workload
that should not be publicly reachable itself.

## Architecture

| Resource | Notes |
|---|---|
| workload `-nginx` | the nginx proxy; autoscaling knobs exposed; always public |
| secret | the generated `nginx.conf`, built from `locations` |
| identity + policy | `reveal` on the configuration secret |
| workload `-example` *(optional)* | demo backend, created when `enableExample: true` |

Does not create a GVC.

## Key knobs (shipped defaults)

| Knob | Default | Notes |
|---|---|---|
| `proxyWorkload.image` | `nginx:1.31.7` | pinned in 1.1.2 (1.31.4; was `nginx:latest`); 1.31.7 since 1.1.3 |
| `enableExample` | `true` | deploys the demo backend and routes **all** traffic to it |
| `locations` | `[]` | your own proxy targets |
| `autoscaling` | — | the proxy is stateless and scales horizontally |

## Troubleshooting traps

- **`enableExample: true` is the default and owns `/`.** It is a plain `location /`, so it only gets requests no
  user location matches (longest prefix wins — measured in 1.1.3: `/api` reached the user target with the example
  on). A user `/` location while it is on makes nginx refuse to start (`duplicate location "/"`); on an upgrade the
  old replica keeps serving and the error is only in `get-deployments`. (Before 1.1.3 this trap read "swallows all
  traffic", which was wrong.)
- **`locations[].workload` takes the BARE workload name.** `files/_nginxConf.txt` appends
  `.{gvc}.cpln.local` itself (for both `proxy_pass` and the `Host` header), so a user who types an FQDN gets a
  doubled hostname and a 502 (served as the `/fail` body).
- **Targets must allow the proxy in their internal firewall.** Only the example backend is set up for this
  (`workload-list` naming the proxy); a user's own targets need `same-gvc` or a list that includes it.
- **`proxyWorkload.port` is inert.** nginx.conf hardcodes `listen 80` and both probes hardcode port 80; the value
  only changes the declared container port. Chart follow-up candidate.
- **The proxy is always public.** `inboundAllowCIDR: 0.0.0.0/0` is hardcoded with no access knob, and no
  internal firewall is set. Chart follow-up candidate.
- **A routing change rolls the proxy by itself.** The `cpln/checksum` tag on the proxy workload changes with the
  config, so `helm upgrade` makes a new deployment version; measured in 1.1.3 (~40 s to switch, a ~10 s 503/504
  blip at the swap on one replica). No forced redeployment needed.
- **A target that does not exist does NOT stop the proxy.** Mesh DNS answers any name under `{gvc}.cpln.local`, so
  nginx starts and the route returns the `/fail` body with a 502 (measured in 1.1.3). The status code of an upstream
  5XX is kept; only the body is replaced (`error_page` has no `=code`).
- **The example backend image cannot be pinned.** `gcr.io/knative-samples/helloworld-go` publishes only
  `:latest`, so the demo target can change under you. It does not affect the proxy, which is pinned.
- **Config errors surface at container start, not at render.** `locations` is templated into `nginx.conf`, so
  a malformed entry produces a container that will not start rather than a failed `helm install`.

## Version history
- **1.1.3** (2026-10): nginx 1.31.7, fixing the six advisories open in 1.31.4 (CVE-2026-15176, -93479, -95101, -97629, -97205, -90439; all medium, all fixed in 1.31.7 / 1.30.6). The shipped `nginx.conf` uses none of the affected features (alias+rewrite, HTTP/3, TLS session tickets, AIO), so default installs were not exposed; custom configs might be. No image guard: medium severity, and 1.1.2 had no wizard storing `image` in release values. First version with a `wizard.yaml`. The chart-files annotation `file-nginxConf` is removed (the console sends any version with chart files to the classic YAML screen, so the wizard never opened); the same capability is now the value `nginxConf` (empty = the generated `files/_nginxConf.txt`; set = rendered with `tpl` in its place, exactly as the file was). The classic screen stored the file as `nginxConf: |-` in release values, so an edited config carries over by itself; the wizard's `<1.1.3` migration clears an UNEDITED one (exact match with 1.0.0's or 1.1.0–1.1.2's shipped file) so the generated config applies. Maintainer ruling 2026-10-23: support both the wizard and a custom config.
