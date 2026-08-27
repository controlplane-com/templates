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

### Resources and placement

```yaml
resources:
  cpu: 50m
  memory: 128Mi

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

The startup hook configures the image's reverse proxy, and it exits non-zero rather than bring the WAF
up unconfigured. Its output names the reason:

```bash
cpln logs '{gvc="GVC_NAME", workload="RELEASE_NAME-coraza-waf"}' --limit 100 --since 30m
```

Look for a `[FATAL]` line. The usual causes are an `image` that is not a Caddy variant, or a moving tag
that upstream repointed to a build whose internal configuration differs.

## Important Notes

- **This only protects traffic that goes through it.** The WAF is a proxy, so the workload behind it must not remain publicly reachable on its own endpoint, or requests bypass inspection entirely.
- **Pin a digest or a datecode, never `-lts` or `caddy-alpine`** — moving tags change the image under a running deployment. Only `*-caddy-alpine-*` variants work.
- **CRS rule updates require a deliberate `image` change.** That is the right default for a security control, but new CRS releases are not picked up on their own.
- **`diskBodyInspection: false` trades coverage for memory.** With it off, request bodies above the in-memory limit are not inspected at all rather than being buffered — a silent inspection gap, not a performance tweak.
- **Custom rules layer on top of CRS**, so a rule ID that collides with a CRS rule silently overrides it.
- **A failed startup hook restarts the container on purpose.** A WAF serving with no reverse-proxy configuration is worse than one that is visibly down.

## Links

- [OWASP Coraza documentation](https://coraza.io/docs/tutorials/introduction/)
- [OWASP Core Rule Set documentation](https://coreruleset.org/docs/)
- [seclang directive reference](https://coraza.io/docs/seclang/directives/)
- [coraza-crs image source and tags](https://github.com/coreruleset/coraza-crs-docker)
- [Caddy admin API](https://caddyserver.com/docs/api)
