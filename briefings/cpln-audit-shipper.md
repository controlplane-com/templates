# Audit Shipper — Maintainer Briefing

## What it is
- A small Go program, [controlplane-com/cpln-audit-shipper](https://github.com/controlplane-com/cpln-audit-shipper), that ships an org's audit logs to a destination the customer owns. Image `ghcr.io/controlplane-com/cpln-build/cpln-audit-shipper:vX.Y.Z` (distroless, nonroot uid/gid 65532, amd64 and arm64), published by a `vX.Y.Z` tag in that repo.
- **Sources:** the Control Plane audit trail (`audit.cpln.io`, per audit context) and mk8s Kubernetes audit logs (the org's Loki, `{cluster_name="<cluster>", job="audit"}`, per cluster), either or both.
- **Destinations:** S3 (JSON Lines by UTC hour), syslog over TCP or TLS (RFC 5424 in the org-logging fluent-bit layout: `cpln@0` structured data, BOM, newline framing by default), or OTLP/HTTP with JSON.
- Audit logs only. Workload logs go through org external logging.

## Common use cases
- Feed a SIEM over syslog or OTLP with who-changed-what in Control Plane, plus mk8s API server audit.
- A long-term copy of the audit trail in the customer's S3 bucket (compliance, Athena).
- Replace a customer-specific shipper; `startTime` set to the old shipper's last position avoids a gap or a resend.

## Architecture on cpln
| Resource | Purpose |
|---|---|
| `{release}-audit-shipper` standard workload | one replica per GVC location, no ports, exec liveness probe (`/cpln-audit-shipper healthcheck`) |
| identity | reveal on the key / CA / OTLP auth secrets; AWS cloud access when S3 is used with `aws.authMode: identity`; `view` on the GVC with volume set state |
| `-audit` policy | `readAudit` on each audit context, for the service account |
| `-logs` policy | `readLogs` on the org (`targetKind: org`, `target: all`; cannot be narrowed), only with the Kubernetes source |
| `-state` volume set | only with `state.backend: volumeSet`: `shared` file system, mounted at `/state` |

- **Auth:** the audit and logs APIs reject a workload's `CPLN_TOKEN`; the shipper uses a service account key from an opaque secret (raw in `Authorization` for the audit API, `Bearer` for Loki). The workload token is used only to read the GVC's locations.
- **One pipeline per audit context and per cluster**, each a loop with its own checkpoint: read *watermark − overlap* to *now − settleDelay* in windows that fit one page (the audit API orders ties differently per call, so a full window is narrowed), deliver the batch, then advance. A batch is recorded *pending* first; S3 replays it with the same bounds, so the same object names; syslog and OTLP re-collect it.
- **Checkpoint stores:** S3 (`<prefix>/state/…/checkpoint.json`, conditional writes, a lease so replicas in several locations take turns) or a volume set (single-location GVC only; `flock` on `/state/lock`; the shipper refuses to start in a multi-location GVC or on a volume without file locks).
- No `CPLN_` env var names: the platform rejects them, so the chart uses `AUDIT_*`, `K8S_AUDIT_*`, `SINK_TYPE`, etc.

**Key knobs:** `serviceAccount.name`/`.keySecret` (required) · `sources.cplnAudit.*` (on, `[cpln]`, 24h lookback, settle 1m, overlap 15m) · `sources.k8sAudit.*` (off; `clusters`, `pipeline`, settle 2m, overlap 2m) · `sink.type` (s3 / syslog / otlp) · `state.backend` (s3 / volumeSet) · `aws.authMode` (identity / secret, only with S3) · `interval` (5m; 1m works) · `stream` · `tuning.*` (batch and object limits, lease 5m, drain 60s, heartbeat 30m).

**Availability:** S3 state with several locations survives a location loss; the other replicas carry on after the dead one's lease expires (`leaseTTL`). A restart resumes from the checkpoint; a delivery under way gets `drainTimeout` to finish on SIGTERM. Memory: about 15 MB for the audit trail; about 110 MB of heap per busy cluster during a backfill.

## Troubleshooting / considerations
- `403 token invalid` from the audit API: wrong or revoked key, or no `readAudit` on the context. The workload token never works there.
- `logs API denied the request`: the service account lacks `readLogs` on the org.
- Kubernetes audit `watch` entries are stamped with their start time and logged when they end (up to ~1 h later), so a short settle delay misses ~0.15% of entries. `sources.k8sAudit.settleDelay: 1h` catches them at an hour's delay; a large overlap would re-read an hour every cycle.
- `| json` in `sources.k8sAudit.pipeline` turns every JSON field into a label, and labels ship as syslog SD or OTLP attributes (much bigger messages). Filter on existing labels instead (`| verb != "get"`).
- Syslog delivery is confirmed by the listener closing the connection; a listener that never closes gets a warning and the batch counts as sent after `sink.syslog.timeout`. Messages can reach 32 KiB; receivers must accept that.
- Hostname firewall rules open only 80/443/445: a syslog listener on another port needs a CIDR.
- `no such host` right after a DNS record for the listener appears: the replica cached the negative answer; force-redeploy.
- `another replica holds the state lock; waiting` for ~30 s during a rollout is normal: `maxSurgeReplicas: 0` still starts the new pod before the old one gets SIGTERM.
- `checkpoint state is invalid`: the shipper never resets progress itself. Restore a previous S3 object version, or delete the checkpoint to restart at `startTime`/`initialLookback`.
- Volume set state on BYOK needs the location's shared file system (JuiceFS); `ext4` volume sets cannot be mounted by a standard workload.
