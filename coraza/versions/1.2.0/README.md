# Coraza WAF

A web application firewall — [Coraza](https://coraza.io/) with the OWASP Core Rule Set — deployed as a
reverse proxy in front of a workload you already run. Traffic enters the WAF, is inspected against CRS
and any rules you add, and is forwarded to the workload behind it.

## Architecture

- **WAF workload** — Coraza + CRS on Caddy, listening on `WAFPort` and proxying to `targetWorkload:targetPort`.
- **Startup secret** — a `postStart` hook that points the image's reverse-proxy handler at your target workload.
- **Custom-rules secret** — your own rules, layered on top of the Core Rule Set.
- **Identity and policy** — `reveal` on those two secrets.

This template does not create a GVC and does not deploy the workload it protects.

## Prerequisites

**The workload you intend to protect must already exist.** `targetWorkload` must be its fully-qualified
internal address (`WORKLOAD.GVC.cpln.local`) and `targetPort` the port it serves. That workload's
internal access must be `same-gvc`, `same-org`, or explicitly allow this WAF workload, or the WAF
cannot reach it.

## Configuration

### Image

```yaml
# Pinned by digest = tag 4.25-caddy-alpine-202607180107 (OWASP CRS 4.25.0, Caddy v2.11.2).
# Only the *-caddy-alpine-* variants work with this template, and only a datecode or a
# digest is safe to pin — moving tags such as -lts get repointed upstream.
image: ghcr.io/coreruleset/coraza-crs@sha256:21e95b2117c8c818f263944f45bd233608b3d18dd95653f71539972eb0cdfca1
```

### Proxy target

```yaml
# MUST BE CHANGED
targetWorkload: my-workload.my-gvc.cpln.local # Workload internal name of the workload to proxy traffic to

targetPort: 8080 # Port of the workload to proxy traffic to

WAFPort: 80 # Port on the WAF workload to expose to the internet
```

### Resources, timeout and placement

```yaml
# Coraza inspects request bodies on the CPU, so these size the largest body the WAF
# can inspect inside timeoutSeconds. See "Request size, CPU and timeout" in the README
# before lowering them — 50m/128Mi, the pre-1.2.0 defaults, 504 on any body over ~30 KB.
resources:
  cpu: 500m
  memory: 512Mi

# Request timeout, in seconds, for everything passing through the WAF. It caps both the
# time Coraza spends inspecting a request body and the time the upstream has to answer;
# anything slower gets a 504 from the WAF, not from your application.
timeoutSeconds: 30

multiZone: false
```

### Body inspection

```yaml
diskBodyInspection: true # When true, request bodies exceeding the in-memory limit are buffered to disk for inspection. Disable to keep all body inspection in memory.
```

## Choosing an image tag

This is the one setting that has broken a running deployment, so it is worth getting right.

**Pin a datecode or a digest. Never pin a moving tag.** Upstream publishes both:

| Tag form | Example | Safe to pin? |
|---|---|---|
| Digest | `coraza-crs@sha256:21e95b21…` | Yes — cannot change |
| Datecode | `4.25-caddy-alpine-202607180107` | Yes — a datecode is a specific build |
| Moving | `4.25-caddy-alpine-lts`, `caddy-alpine` | **No** — upstream repoints these |

A moving tag changes the image under a deployment that you have not touched. The next replica to start
pulls a different build, and the WAF's behaviour changes with no change on your side — including its
internal Caddy configuration, which this template's startup hook has to configure.

**Only the Caddy variants work.** The `-nginx-` and `-apache-` builds of `coraza-crs` ship no Caddy
binary and no admin API, so the startup hook cannot configure them. This matters because the newest CRS
releases are published *only* as nginx and apache variants — reaching for the highest CRS version number
lands on an image this template cannot drive. Take the newest `*-caddy-alpine-*` datecode instead.

## Request size, CPU and timeout

Inspecting a request body is CPU work proportional to its size, and `timeoutSeconds` cuts the request off
part-way through. Those two numbers together set the largest request body this WAF can accept — and a body
over the limit is a **504 from the WAF**, which looks like an application fault rather than a WAF setting.
GET traffic is unaffected, so a smoke test never reveals it.

Measured on the platform, same body, only `resources.cpu` changed, with `timeoutSeconds` at its old
hardcoded value of 5:

| POST body | `cpu: 50m` (pre-1.2.0 default) | `cpu: 1000m` |
|---|---|---|
| 1 KB | 200 (1.89 s) | 200 (0.15 s) |
| 50 KB | **504** (5.20 s) | 200 (0.57 s) |
| 200 KB | **504** (5.30 s) | 200 (1.75 s) |
| 400 KB | **504** (5.30 s) | 200 (3.75 s) |
| 600 KB | **504** (5.32 s) | 200 (5.14 s) |

Every failure lands at the 5 s timeout, and CPU alone moves them — inspection cost is roughly **8.5 ms per
KB at `cpu: 1000m`**, scaling inversely with CPU and getting relatively worse below about `250m`, where CPU
throttling starts to bite. As a working rule:

```
largest body ≈ 120 KB × (cpu in millicores ÷ 1000) × timeoutSeconds
```

The shipped defaults — `cpu: 500m`, `timeoutSeconds: 30` — give roughly **1.7 MB**, which covers ordinary
form posts and JSON APIs. If you need more, raise `resources.cpu` first (it makes requests faster rather
than merely more patient), then `timeoutSeconds`, and raise `resources.memory` with them: a 3 MB body
inspected in one request peaked at 124 MiB, which is why the default is no longer 128Mi.

Two ceilings you cannot raise from here: Coraza stops inspecting bodies above **13 MB**
(`SecRequestBodyLimit`, fixed in the image), and `timeoutSeconds` also caps how long your own upstream has
to answer — set it above the slowest response your application produces.

## Connecting

| What | Value |
|---|---|
| Public | the WAF workload's endpoint on `WAFPort` — this is the address clients should use |
| Internal (same GVC) | `RELEASE_NAME-coraza-waf.GVC_NAME.cpln.local:WAFPort` |
| Upstream | whatever you set as `targetWorkload` and `targetPort` |

Send traffic to the WAF, not to the workload behind it.

## Custom rules

Edit the created secret with the suffix `coraza-custom-rules`. It ships with an example rule that blocks
any request whose URI contains `attack`:

```
SecRule REQUEST_URI "@rx attack" "id:1001,phase:1,deny,msg:'Blocked attack attempt'"
```

Rules use [seclang directives](https://coraza.io/docs/seclang/directives/). After changing the secret,
restart the workload replicas — rules are read at startup.

## Logging

All Coraza logging goes to `/dev/stdout` so it is readable in the built-in logging interface. Redirect
it by changing the `CORAZA_*` environment variables in the workload configuration.

## If the workload restart-loops on `PostStartHook failed`

The startup hook configures the image's reverse proxy, and it exits non-zero rather than bring the WAF up
unconfigured. That platform message says only that the hook failed; the hook itself writes the reason to
the container's log:

```bash
cpln logs '{gvc="GVC_NAME", workload="RELEASE_NAME-coraza-waf"} |= "[FATAL]"' --limit 100 --since 30m
```

The usual causes are an `image` that is not a Caddy variant, or a moving tag that upstream repointed to a
build whose internal configuration differs. Drop the `|= "[FATAL]"` filter to see the `[INFO]` lines as
well — on a healthy start those show which handler index was resolved and what the WAF was pointed at,
which is the quickest way to confirm the proxy is configured the way you intended.

Log ingestion runs a few minutes behind live, so wait before concluding the query returned nothing.

## Important Notes

- **This only protects traffic that goes through it.** The WAF is a proxy, so the workload behind it must not remain publicly reachable on its own endpoint, or requests bypass inspection entirely.
- **Pin a digest or a datecode, never `-lts` or `caddy-alpine`** — moving tags change the image under a running deployment. Only `*-caddy-alpine-*` variants work.
- **CRS rule updates require a deliberate `image` change.** That is the right default for a security control, but new CRS releases are not picked up on their own.
- **`diskBodyInspection: false` trades coverage for memory.** With it off, request bodies above the in-memory limit are not inspected at all rather than being buffered — a silent inspection gap, not a performance tweak.
- **A request body too large to inspect inside `timeoutSeconds` returns 504 from the WAF, not from your application.** Size `resources.cpu` and `timeoutSeconds` together — see *Request size, CPU and timeout*.
- **Custom rules layer on top of CRS**, so a rule ID that collides with a CRS rule silently overrides it.
- **A failed startup hook restarts the container on purpose.** A WAF serving with no reverse-proxy configuration is worse than one that is visibly down.
- **Do not override the container's `command`/`args`.** They run the image's own entrypoint behind a `tail` that forwards the startup hook's output onto the container log — a `postStart` hook's own output reaches no log surface, so replacing them leaves a failed hook with no diagnosis at all.

## Links

- [OWASP Coraza documentation](https://coraza.io/docs/tutorials/introduction/)
- [OWASP Core Rule Set documentation](https://coreruleset.org/docs/)
- [seclang directive reference](https://coraza.io/docs/seclang/directives/)
- [coraza-crs image source and tags](https://github.com/coreruleset/coraza-crs-docker)
- [Caddy admin API](https://caddyserver.com/docs/api)
