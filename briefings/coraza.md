# Coraza WAF — maintainer briefing

**What it is.** A web application firewall — Coraza with the OWASP Core Rule Set — deployed as a reverse
proxy in front of a workload you already run. Traffic enters the WAF, is inspected, and is forwarded on.

**Common use cases.** Putting request inspection in front of an app that has none, satisfying a
"WAF required" control without changing the app, and adding custom blocking rules for a specific endpoint.

## Architecture

| Resource | Notes |
|---|---|
| workload | Coraza + CRS on Caddy, listening on `WAFPort`, proxying to `targetWorkload:targetPort` |
| secret `-startup` | the `postStart` hook that configures the image's reverse-proxy handler |
| secret `-custom-rules` | your own rules, layered on top of the Core Rule Set |
| identity + policy | `reveal` on those two secrets |

Does not create a GVC, and does not deploy the workload it protects.

## Key knobs (shipped defaults, 1.2.0)

| Knob | Default | Notes |
|---|---|---|
| `image` | `coraza-crs@sha256:21e95b21…` | = tag `4.25-caddy-alpine-202607180107`, CRS 4.25.0, Caddy v2.11.2 |
| `targetWorkload` | `my-workload.my-gvc.cpln.local` | must be fully qualified |
| `targetPort` / `WAFPort` | `8080` / `80` | upstream port, and the port clients reach |
| `resources` | `50m` / `128Mi` | limits only, so bare `cpu`/`memory` naming is correct |
| `multiZone` | `false` | spread replicas across zones |
| `diskBodyInspection` | `true` | buffer oversized bodies to disk so they are still inspected |

## The 1.2.0 incident, and why the hook changed

A customer's `coraza-waf` restart-looped with `PostStartHook failed`. On their side the cause was pinning
the **moving** tag `4.25-caddy-alpine-lts`; upstream repointed it and the deployment broke. But the
template is why a repointed digest could break anything: the `postStart` hook made three undeclared
assumptions about the image's internals. 1.2.0 turns each into a checked precondition with a named failure.

| Assumption (≤1.1.1) | Failure mode | 1.2.0 |
|---|---|---|
| admin API answers on `127.0.0.1:2019` — **unbounded** `until` loop | hangs until the platform kills the hook; that *is* the customer's symptom | 30 s deadline, then exit 1 naming the likely cause |
| `reverse_proxy` sits at the **hardcoded** `…/handle/1` | only true for the current Caddyfile | reads `…/handle/N/handler`, patches the entry that *is* `reverse_proxy`, exits 1 if none |
| a failed patch logged `[WARN]` and **exited 0** | WAF serves unconfigured while reporting healthy | non-200 exits 1; the config is also read back and compared to the intended upstream |

**Non-zero is deliberate** (reasoning is in the script's comments): it restarts the container, which is
loud, whereas exiting 0 leaves a security appliance silently misconfigured. Fail closed and visible.

**How bad the hardcoded index was — measured, not argued.** Pointing the patch at `handle/0` (the `waf`
handler) returns **`HTTP/1.1 200 OK`** and rewrites that entry into a second `reverse_proxy`. The list
becomes `0 -> reverse_proxy, 1 -> reverse_proxy`: the WAF is gone, traffic still flows, every status
surface reads healthy. A positional patch can delete the firewall, not merely misconfigure the proxy.

## Troubleshooting traps

- **Pin a datecode or a digest, never `-lts` or `caddy-alpine`.** Moving tags get repointed and change the
  image under a deployment nobody touched. This is the one knob that has caused a customer outage.
- **Only `*-caddy-alpine-*` variants work** — `-nginx-`/`-apache-` have no Caddy and no admin API
  (`4.28-nginx-202607180107` has neither `caddy`, `wget`, nor `nc`). The trap: the newest CRS releases are
  nginx/apache only, so chasing the highest CRS number lands on an image this template cannot drive.
  `4.25` is the newest CRS with a Caddy build.
- **The image has no `jq`** (busybox `sh` plus `wget`, `nc`, `curl`), so handler resolution queries
  `…/handle/N/handler` one index at a time rather than parsing JSON.
- **This only protects traffic that goes through it.** If the protected workload stays publicly reachable
  on its own endpoint, requests bypass inspection entirely.
- **`targetWorkload` must be fully qualified**; a bare name is not reliably resolvable and the symptom is
  a WAF that starts fine and 502s every request.
- **`diskBodyInspection: false` trades coverage for memory** — oversized bodies are not inspected at all
  rather than buffered. A silent inspection gap, not a performance tweak.
- **Custom rules layer on top of CRS**, so a colliding rule ID silently overrides a CRS rule.
- **The startup secret is a literal (`|-`) block as of 1.2.0**, not the folded (`>`) block ≤1.1.1 used.
  Folding joined same-indent lines with spaces, so the script's line structure depended on YAML folding —
  workable, but easy to break with an innocuous edit and hard to extract faithfully for testing.

**Not verified:** the 30 s deadline is sized to fire before any platform-side lifecycle-hook timeout, but
that timeout was never measured — all 1.2.0 verification ran in Docker against the real images, not on a
live GVC. If the platform kills a `postStart` hook sooner than 30 s, the `[FATAL]` line never reaches the
log and the operator sees the same opaque failure. Worth one live install to settle.
