# Coraza WAF — maintainer briefing

**What it is.** A web application firewall — Coraza with the OWASP Core Rule Set — deployed as a reverse
proxy in front of a workload you already run. Traffic enters the WAF, is inspected, and is forwarded on.

**Common use cases.** Putting request inspection in front of an app that has none, satisfying a
"WAF required" control without changing the app, and adding custom blocking rules for a specific endpoint.

## Architecture

| Resource | Notes |
|---|---|
| workload | Coraza + CRS, listening on `WAFPort`, proxying to `targetWorkload:targetPort` |
| secret `-startup` | the generated proxy and WAF configuration |
| secret `-custom-rules` | your own rules, layered on top of the Core Rule Set |
| identity + policy | `reveal` on those two secrets |

Does not create a GVC, and does not deploy the workload it protects.

## Key knobs (shipped defaults)

| Knob | Default | Notes |
|---|---|---|
| `image` | `coraza-crs@sha256:eed7280…` | **pinned by digest**, so it cannot drift |
| `targetWorkload` | `my-workload.my-gvc.cpln.local` | must be fully qualified |
| `targetPort` | `8080` | the port the protected workload serves |
| `WAFPort` | `80` | the port clients should reach |
| `resources` | `50m` / `128Mi` | small; inspection of large bodies needs more |
| `diskBodyInspection` | `true` | buffer oversized bodies to disk so they are still inspected |

## Troubleshooting traps

- **This only protects traffic that goes through it.** It is a proxy, not an interceptor. If the protected
  workload stays publicly reachable on its own endpoint, requests bypass inspection entirely — and nothing
  in the deployment will tell you that is happening.
- **`targetWorkload` must be fully qualified** (`WORKLOAD.GVC.cpln.local`). A bare workload name is not
  reliably resolvable, and the symptom is a WAF that starts fine and 502s every request.
- **`diskBodyInspection: false` trades coverage for memory.** With it off, request bodies above the
  in-memory limit are not inspected at all, rather than being buffered — a silent inspection gap, not a
  performance tweak.
- **Custom rules layer on top of CRS**, so a rule ID that collides with a CRS rule overrides it silently.
- **The image is digest-pinned**, so CRS rule updates require a deliberate values change. That is the right
  default for a security control, but it does mean new CRS releases are not picked up automatically.
