# Coraza WAF

A web application firewall — [Coraza](https://coraza.io/) with the OWASP Core Rule Set — deployed as a
reverse proxy in front of a workload you already run. Traffic enters the WAF, is inspected against CRS
and any rules you add, and is forwarded to the workload behind it.

## Architecture

- **WAF workload** — Coraza + CRS on Caddy, listening on `WAFPort` and proxying to `targetWorkload:targetPort`.
- **Startup secret** — a `postStart` hook that points the image's reverse-proxy handler at your target workload.
- **Custom-rules secret** — your own rules, layered on top of the Core Rule Set.
- **Identity and policy** — `reveal` on those two secrets.

The chart fixes several settings that have no values knob: the rule engine runs in blocking mode
(`CORAZA_RULE_ENGINE: On`) with the image's default CRS paranoia level, autoscaling is 1-3 replicas on CPU,
the public endpoint is always open to `0.0.0.0/0`, and internal access is `same-gvc`.

This template does not create a GVC and does not deploy the workload it protects.

## Prerequisites

**The workload you intend to protect must already exist.** `targetWorkload` must be its fully-qualified
internal address (`WORKLOAD.GVC.cpln.local`) and `targetPort` the port it serves. That workload's
internal access must be `same-gvc`, `same-org`, or explicitly allow this WAF workload, or the WAF
cannot reach it.

## Configuration

### Image

```yaml
# Pinned by digest = tag 4.28-caddy-alpine-202608260808 (OWASP CRS 4.28.0, Caddy v2.11.3).
# Only the *-caddy-alpine-* variants work with this template, and only a datecode or a
# digest is safe to pin — moving tags such as -lts get repointed upstream.
image: ghcr.io/coreruleset/coraza-crs@sha256:ed1e4a656e83f1ba17d629f30de0910d491b1cc13e5e8e7e9b9f2ac9a35bac1b
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

## Choosing an image tag

**Only the Caddy variants work.** The `-nginx-` and `-apache-` builds of `coraza-crs` ship no Caddy binary,
so this template cannot configure them. Upstream publishes a `*-caddy-alpine-*` build alongside them for
each CRS release — take the newest of those.

**Pin a digest or a datecode, never a moving tag.** `4.25-caddy-alpine-lts` and `caddy-alpine` are
repointed by upstream, so the image can change under a deployment you have not touched. A digest
(`coraza-crs@sha256:…`) or a datecode (`4.28-caddy-alpine-202608260808`) names one specific build.

The shipped default is a pinned digest of the newest Caddy build at release time.

## Request size, CPU and timeout

Bodies larger than Coraza's in-memory limit are buffered to disk under `/tmp/coraza` and inspected in
full — there is nothing to enable. The startup hook creates that directory unconditionally, which
matters if you point `image` at an older `coraza-crs` build: those do not create it themselves, and
without it every large request fails with a 500 and `failed to append request body: ... no such file
or directory`, which reads as a WAF fault rather than a missing directory.

Inspecting a request body costs CPU in proportion to its size, and `timeoutSeconds` cuts the request off
part-way through. Together they set the largest body this WAF accepts; anything larger is a **504 from the
WAF**, which reads as an application fault. GET traffic is unaffected, so smoke tests never reveal it.
The pre-1.2.0 defaults (`cpu: 50m`, a 5 s timeout) returned 504 for POST bodies of a few tens of KB.

As a rule, `largest body ≈ 120 KB × cpu-cores × timeoutSeconds`, so the shipped `500m` / `30 s` handles
bodies up to roughly 1.8 MB, enough for ordinary form posts and JSON APIs. Throughput drops off more than
proportionally below about `250m`, where CPU throttling bites.

For more, raise `resources.cpu` first (faster, rather than merely more patient), then `timeoutSeconds`, and
raise `resources.memory` with them — memory use grows with body size, which is why the default is no
longer 128Mi. Two ceilings you cannot raise here: Coraza stops inspecting above **12.5 MiB**
(`SecRequestBodyLimit`, fixed in the image), and `timeoutSeconds` also caps how long your own upstream has
to answer, so set it above your application's slowest response.

## Connecting

| What | Value |
|---|---|
| Public | `status.canonicalEndpoint` from `cpln workload get RELEASE_NAME-coraza-waf --gvc GVC_NAME -o yaml` — always open to the internet; this is the address clients should use |
| Internal (same GVC) | `RELEASE_NAME-coraza-waf.GVC_NAME.cpln.local:WAFPort` |
| Upstream | whatever you set as `targetWorkload` and `targetPort` |

Send traffic to the WAF, not to the workload behind it.

## Custom rules

Edit the `RELEASE_NAME-coraza-custom-rules` secret (there is no values knob for it). It ships with an
example rule that blocks any request whose URI contains `attack`:

```
SecRule REQUEST_URI "@rx attack" "id:1001,phase:1,deny,msg:'Blocked attack attempt'"
```

Rules use [seclang directives](https://coraza.io/docs/seclang/directives/). Rules are read at startup, so
after changing the secret run `cpln workload force-redeployment RELEASE_NAME-coraza-waf --gvc GVC_NAME`.
The chart renders this secret with the example rule, and whether a later `helm upgrade` keeps your edits is
unverified, so keep your rules under version control and re-check the secret after every upgrade.

The secret is loaded **after** the Core Rule Set, so it can also switch a CRS rule off:

```
SecRuleRemoveById 920450
```

Rule 920450 blocks any request carrying an `Expect: 100-continue` header, which HTTP clients add for large
uploads: an otherwise identical request returns 200 without the header and 403 with it. An
app behind this WAF that receives large uploads will see 403s unrelated to the payload. Removing that one
rule leaves the rest of CRS untouched.

## Logging

All Coraza logging (access, audit and debug) goes to `/dev/stdout`, so it is readable with `cpln logs`.
The `CORAZA_*` and `ACCESSLOG` environment variables are set by the chart and have no values knob.

## Important Notes

- **This only protects traffic that goes through it.** The WAF is a proxy, so the workload behind it must not remain publicly reachable on its own endpoint, or requests bypass inspection entirely.
- **Pin a digest or a datecode, never `-lts` or `caddy-alpine`** — moving tags change the image under a running deployment. Only `*-caddy-alpine-*` variants work.
- **CRS rule updates require a deliberate `image` change.** That is the right default for a security control, but new CRS releases are not picked up on their own.
- **CRS blocks any request carrying an `Expect: 100-continue` header** (rule 920450), which some HTTP clients add for large uploads. Switch that one rule off in the custom-rules secret if your clients send it.
- **A request body too large to inspect inside `timeoutSeconds` returns 504 from the WAF, not from your application.** Size `resources.cpu` and `timeoutSeconds` together — see *Request size, CPU and timeout*.
- **Custom rules layer on top of CRS**, so a rule ID that collides with a CRS rule silently overrides it.
- **A failed startup hook restarts the container on purpose.** A WAF serving with no reverse-proxy configuration is worse than one that is visibly down. If the workload will not start, check `cpln logs` for a `[FATAL]` line naming the reason; an incompatible (non-Caddy) image instead exits immediately with `exitCode: 127`.
- **Do not override the container's `command`/`args`.** They run the image's own entrypoint behind a `tail` that forwards the startup hook's output onto the container log — a `postStart` hook's own output reaches no log surface, so replacing them leaves a failed hook with no diagnosis at all.

## Links

- [OWASP Coraza documentation](https://coraza.io/docs/tutorials/introduction/)
- [OWASP Core Rule Set documentation](https://coreruleset.org/docs/)
- [seclang directive reference](https://coraza.io/docs/seclang/directives/)
- [coraza-crs image source and tags](https://github.com/coreruleset/coraza-crs-docker)
- [Caddy admin API](https://caddyserver.com/docs/api)
