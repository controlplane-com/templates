# otel-collector 1.1.0 — Maintainer Briefing

## What it is
- OpenTelemetry Collector (Apache-2.0, fully open source): a relay that receives telemetry over OTLP (the OpenTelemetry wire protocol for traces/metrics), processes it, and forwards it to backends.
- 1.1.0 adds a metrics path — OTLP in, pushed out via Prometheus remote-write (Prometheus's standard HTTP push protocol) — plus public authenticated ingestion. Trace path from 1.0.x is preserved.

## Common use cases
- Feed the platform's native tracing from app workloads (existing 1.0.x behavior).
- Ingest metrics from external systems and push them into a Prometheus / Mimir / Thanos-compatible store.
- One collector per store: run several installs, each pinned to its own remote-write URL, to build a fan-in topology.
- Public ingestion endpoint for senders outside the org, locked by token or client certificates.

## Architecture on cpln
| Resource | Purpose |
|---|---|
| workload `{release}` | The collector, stateless, `replicas` copies (default 1) |
| secret `{release}-conf` | Rendered collector config file (opaque, plain) |
| identity + policy | Workload identity; `reveal` on the config secret and any user auth secrets |

- No storage, no clustering: replicas are independent; HA = `replicas: 2+` behind one endpoint.
- Auth secrets are prerequisites the user creates; the template only references them by name.

## Key knobs
| Knob | Default | Meaning |
|---|---|---|
| `otelCollector.mode` | `simple` (was `advanced`) | simple = structured knobs; advanced = raw config verbatim |
| `otelCollector.replicas` | 1 | HA ingestion pool size |
| `metrics.enabled` + `metrics.remoteWrite.endpoint` | off | OTLP metrics → remote-write push URL |
| `auth.method` | `none` | `bearer` (token in `Authorization` header) or `mtls` (mutual TLS — client must present a certificate we trust) |
| `auth.bearer.secretName` / `auth.mtls.secretName` | `""` | Names of user-created prerequisite secrets |
| `publicAccess.enabled` + `allowedCidrs` | off / `[]` | Public ingestion; CIDR list is mandatory when on |

## Availability posture
- Multi-replica is OSS-supported and shipped (`replicas` knob); default 1 keeps the proven single-replica shape. Rolling-restart and replica-down continuity are test-gated.

## Troubleshooting / considerations
- **Public without auth is refused at install** — render fails; same for public with an empty CIDR list. Users must explicitly write `0.0.0.0/0` to open wide.
- **Never put the token in values** — bearer token and mTLS certs live in prerequisite secrets (opaque token; dictionary with `cert`/`key`/`ca`); if the secret doesn't exist before install, the deployment wedges waiting on it.
- **Bearer vs mTLS endpoints differ:** bearer = the `https://…cpln.app` canonical endpoint (platform terminates TLS); mTLS = the direct load-balancer TCP ports 4317 (gRPC — Google's binary RPC protocol) / 4318 (HTTP). In mTLS mode the canonical endpoint intentionally stops working (fails closed).
- **Internal trace path is never authenticated:** GVC-level tracing pushes to gRPC :4317 with no token, so the design keeps that receiver plain and puts auth on a separate receiver (:4318/:4319). If traces stop after enabling auth, check the GVC tracing target still points at :4317.
- **Default mode flipped to `simple` in 1.1.0.** Anyone who customized `advanced.config` while relying on the old default must now set `mode: advanced` explicitly.
- **`metrics.*` knobs only generate config in simple mode** — in advanced mode the install fails with instructions to add the pipeline to `advanced.config` (nothing is silently ignored).
- **Histogram buckets must be duration strings** ("250ms", "1s") — bare numbers are parsed as NANOSECONDS and silently break the histogram (defaults ship as strings).
- **In mTLS mode, in-GVC senders use the plain gRPC `:4317`** — the TLS ingest ports (4318/4319) are external-only via the direct LB (mesh handshake fails internally).
- **Advanced-mode public ingestion is a fixed port contract:** authed receiver on `0.0.0.0:4318`/`0.0.0.0:4319`, health check on `0.0.0.0:13133` — the collector's upstream defaults bind localhost, which breaks probes/ingress if users omit explicit endpoints.
- **Metrics not arriving?** Check order: sender → collector logs (401 = token; TLS error = certs) → remote-write queue warnings in logs → the store's own ingest endpoint reachable (cross-GVC targets need the store's public endpoint, not `.cpln.local`).
