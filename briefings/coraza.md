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

Does not create a GVC, and does not deploy the workload it protects. The container's `command`/`args` run
the image's own entrypoint behind a `tail` — see the hook-visibility trap below; do not "simplify" it away.

## Key knobs (shipped defaults, 1.2.0)

| Knob | Default | Notes |
|---|---|---|
| `image` | `coraza-crs@sha256:21e95b21…` | = tag `4.25-caddy-alpine-202607180107`, CRS 4.25.0, Caddy v2.11.2 |
| `targetWorkload` | `my-workload.my-gvc.cpln.local` | must be fully qualified |
| `targetPort` / `WAFPort` | `8080` / `80` | upstream port, and the port clients reach |
| `resources` | `500m` / `512Mi` | limits only, so bare `cpu`/`memory` naming is correct |
| `timeoutSeconds` | `30` | request timeout; was hardcoded at 5 before 1.2.0 |
| `multiZone` | `false` | spread replicas across zones |

`diskBodyInspection` was **removed** in 1.2.0: it only set `SecRequestBodyNoFilesLimit`, which this
Coraza build does not enforce. At `NoFilesLimit=1000` a 5 KB benign body returns 200 (a Reject would be
403) while the same body carrying SQLi returns 403 — read and inspected five times past the "limit". If a
future image starts honouring the directive, the knob becomes real again.

## The 1.2.0 incident, and why the hook changed

A customer's `coraza-waf` restart-looped with `PostStartHook failed`. On their side the cause was pinning
the **moving** tag `4.25-caddy-alpine-lts`; upstream repointed it and the deployment broke. But the
template is why a repointed digest could break anything: the `postStart` hook made three undeclared
assumptions about the image's internals. 1.2.0 turns each into a checked precondition with a named failure.

| Assumption (≤1.1.1) | Failure mode | 1.2.0 |
|---|---|---|
| admin API answers on `127.0.0.1:2019` — unbounded `until` loop | see the folded-scalar bug below | 30 s deadline, then exit 1 naming the likely cause |
| `reverse_proxy` sits at the **hardcoded** `…/handle/1` | only true for the current Caddyfile | reads `…/handle/N/handler`, patches the entry that *is* `reverse_proxy`, exits 1 if none |
| a failed patch logged `[WARN]` and **exited 0** | WAF serves unconfigured while reporting healthy | non-200 exits 1; the config is also read back and compared to the intended upstream |

**1.1.1's wait loop never ran, on any image.** Its `payload:` was a YAML **folded** (`>`) scalar, which
kept a newline inside the `until` condition (`until wget … ⏎ 2>/dev/null; do`). The newline terminates the
`wget`, so the condition's status comes from a bare redirection — always 0, loop body never entered. 1.1.1
therefore did not hang; it **failed open in 0 s**, reporting `ready: True` with an unconfigured proxy.
1.2.0 uses a literal (`|-`) block: anything reformatting this secret must keep literal block scalars.

**A positional patch deletes the WAF rather than misconfiguring it — confirmed live.** PATCHing `handle/0`
returns `200 OK` and leaves `0 -> reverse_proxy, 1 -> reverse_proxy`; every attack that had returned 403
then returned **200 with the upstream's real body**, rule evaluations dropped to zero, and every health
surface stayed green. Hence the handler-resolution loop.

## Troubleshooting traps

- **A `postStart` hook's output reaches NO log surface** — not `cpln logs`, `get-deployments`, or the
  event log the platform's own message points at, all three checked with positive controls. **And
  `/proc/1/fd/1` does not fix it here**: caddy marks its process non-dumpable, so the kernel makes
  `/proc/1/fd` root:root 0500 even though PID 1 runs as caddy(1000) (control: an alpine PID 1 at uid 1000
  *is* writable). So the hook writes `/tmp/coraza-hook.log` and the container command `tail -F`s it before
  `exec`ing the entrypoint. Those two ends must stay in step, and overriding `command`/`args` removes the
  only surface carrying the diagnosis.
- **Body inspection is CPU-bound, and `timeoutSeconds` is the wall it hits.** ~8.5 ms/KB at `cpu: 1000m`,
  scaling inversely with CPU and relatively worse below ~250m. Rule of thumb:
  `largest body ≈ 120 KB × cpu-cores × timeoutSeconds`. The pre-1.2.0 defaults (`50m`, hardcoded 5 s)
  504'd every POST body over ~30 KB — measured 504 at 50 KB, 200 KB, 400 KB and 600 KB, all at ~5.2-5.3 s,
  with CPU alone fixing them. GET traffic is unaffected, so smoke tests never catch it. `timeoutSeconds`
  also caps how long the protected upstream may take, so a low value 504s slow application endpoints too.
- **Memory scales with body size.** A single inspected 3 MB body peaked at 123.8 MiB against a 128 MiB
  limit — 97%, with no concurrency at all. Hence the 512Mi default.
- **CRS rule 920450 blocks any request carrying `Expect: 100-continue`.** Size held constant, an identical
  2 KB body is 200 without the header and 403 with it; clients add it for large uploads. `SecRuleRemoveById
  920450` in the custom-rules secret fixes it (verified: the bundled custom rule and SQLi blocking both
  still fire afterwards). The rules.d file loads *after* CRS, which is what makes removal work.
- **Pin a datecode or a digest, never `-lts` or `caddy-alpine`.** Moving tags get repointed and change the
  image under a deployment nobody touched. This is the one knob that has caused a customer outage.
- **Only `*-caddy-alpine-*` variants work** — `-nginx-`/`-apache-` have no Caddy and no admin API, and
  the newest CRS releases are nginx/apache only, so chasing the highest CRS number lands on an image this
  template cannot drive. `4.25` is the newest with a Caddy build; on nginx the symptom is a misleading
  `invalid host in upstream`, because `BACKEND` carries a scheme that variant rejects.
- **Smaller ones:** it only protects traffic routed through it, so the protected workload must not stay
  publicly reachable; `targetWorkload` must be fully qualified; the image has no `jq` (hence the
  index-at-a-time handler resolution); Envoy normalizes paths before Caddy sees them, so an unencoded
  `/../../etc/passwd` arrives already collapsed (not a bypass, but the encoded form is what CRS inspects);
  and a custom rule whose ID collides with a CRS rule silently overrides it.

**Needs live re-verification.** The `tail` forwarder was proven in Docker on the pinned digest, not on a
GVC: that the platform accepts the `command`/`args` override with the hook still gated by `postStart`, and
that `[INFO]`/`[FATAL]` then appear in `cpln logs`. The 30 s deadline is already settled — a probe hook ran
602 s unkilled.
