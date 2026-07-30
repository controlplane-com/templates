# OpenTelemetry Collector

The OpenTelemetry Collector receives, processes, and exports telemetry over OTLP. This template deploys a stateless collector that feeds Control Plane's native tracing, and can additionally ingest OTLP metrics and push them to any Prometheus-remote-write-compatible store — with optional authenticated public ingestion (bearer token or mTLS).

## Architecture

- **Workload** `{release}` — the collector (`standard`, stateless, `replicas` copies behind one endpoint)
- **Secret** `{release}-conf` — the rendered collector configuration, mounted as a file
- **Identity + policy** — workload identity with `reveal` on the config secret and (only when auth is enabled) your auth secret
- **Optional direct load balancer** — TCP passthrough on 4317/4318, created only for public mTLS ingestion

## Prerequisites

None for a default install.

- **Bearer auth** (`auth.method: bearer`): create an opaque secret holding the token **before install** — the deployment waits on it otherwise:

  ```bash
  openssl rand -hex 32 | tr -d '\n' | cpln secret create-opaque --name my-otel-ingest-token --encoding plain -f -
  ```

- **mTLS auth** (`auth.method: mtls`): create a dictionary secret **before install** with exactly the keys `cert` (server certificate), `key` (server private key), and `ca` (CA that signed your client certificates), e.g. via `cpln apply -f`:

  ```yaml
  kind: secret
  name: my-otel-mtls-certs
  type: dictionary
  data:
    cert: |-
      -----BEGIN CERTIFICATE----- ...
    key: |-
      -----BEGIN PRIVATE KEY----- ...
    ca: |-
      -----BEGIN CERTIFICATE----- ...
  ```

## Configuration

### Collector

```yaml
otelCollector:
  image: otel/opentelemetry-collector-contrib:0.157.0
  mode: simple    # simple: config generated from the knobs below | advanced: advanced.config used verbatim
  replicas: 1     # stateless; 2+ = HA ingestion pool behind the same endpoint
  resources:
    cpu: 200m
    memory: 256Mi
  simple:
    processors:
      transform:
        traceStatements:      # span URL normalization (OTTL statements)
          - replace_pattern(span.attributes["http.url"], "^.*(PLACEHOLDER).*$", "/PLACEHOLDER")
    spanmetrics:
      histogram:
        buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000]  # span-duration buckets — tune to your SLOs
        unit: ms              # ms or s
  advanced:
    config: |                 # full collector config, used verbatim when mode: advanced
      ...
```

### Metrics ingestion

```yaml
metrics:
  enabled: true   # adds an OTLP → prometheus_remote_write pipeline (simple mode only)
  remoteWrite:
    endpoint: http://my-prometheus.my-gvc.cpln.local:9095/api/v1/write  # any Prometheus-remote-write-compatible URL
```

### Ingestion auth

```yaml
auth:
  method: bearer  # none | bearer | mtls — required (not none) for public ingestion
  bearer:
    secretName: my-otel-ingest-token  # opaque secret created BEFORE install (see Prerequisites)
  mtls:
    secretName: my-otel-mtls-certs    # dictionary secret (cert/key/ca) created BEFORE install
```

Auth applies to a dedicated `otlp/ingest` receiver on 4318 (HTTP) / 4319 (gRPC). The plain gRPC :4317 receiver stays unauthenticated for the GVC tracing integration and is never exposed publicly.

### Access

```yaml
publicAccess:
  enabled: true                     # bearer → canonical https endpoint; mtls → direct TCP 4317/4318
  allowedCidrs: ["203.0.113.0/24"]  # REQUIRED when enabled; use ["0.0.0.0/0"] to explicitly allow all
internalAccess:
  type: same-gvc                    # none | same-gvc | same-org
```

## Advanced mode with metrics or auth

`advanced.config` is fully authoritative — the `metrics.*` knobs are refused in advanced mode (the install fails rather than silently ignoring them). To ingest metrics, add the pipeline to your config yourself:

```yaml
exporters:
  prometheus_remote_write:
    endpoint: http://my-prometheus.my-gvc.cpln.local:9095/api/v1/write
service:
  pipelines:
    metrics/otlp:
      receivers: [otlp]
      processors: [resource, batch]
      exporters: [prometheus_remote_write]
```

The `auth.*` and `publicAccess.*` knobs still wire secret mounts, the reveal policy, firewall, and the load balancer in advanced mode, but your config must bind the authed receiver to `0.0.0.0:4318` (HTTP) / `0.0.0.0:4319` (gRPC) — cert/token files are mounted at `/etc/otel-collector/tls/{server.crt,server.key,ca.crt}` and `/etc/otel-collector/auth/token`. Keep `health_check` on `0.0.0.0:13133` or readiness probes are skipped.

## Connecting

| Endpoint | Address | Auth |
|---|---|---|
| In-GVC OTLP gRPC (traces + metrics) | `{release}.{gvc}.cpln.local:4317` | none (GVC tracing target) |
| In-GVC OTLP HTTP | `http://{release}.{gvc}.cpln.local:4318` | none, or bearer when auth is on (in mTLS mode use plain gRPC `:4317` instead) |
| Public OTLP HTTP (bearer) | `https://{canonical-endpoint}/v1/traces` `/v1/metrics` | `Authorization: Bearer <token>` |
| Public OTLP (mTLS) | `{direct-lb-endpoint}:4318` (HTTP), `:4317` (gRPC) | client certificate signed by your CA |
| Spanmetrics scrape | `http://{release}.{gvc}.cpln.local:8889/metrics` | none |

The canonical endpoint is in `status.canonicalEndpoint` of `cpln workload get {release}`. The bearer token is whatever you stored in your prerequisite secret.

## Important Notes

- **Default `mode` changed from `advanced` to `simple` in 1.1.0** — if you customized `advanced.config` while relying on the old default, set `mode: advanced` explicitly when upgrading.
- Enable tracing at the GVC level after install (target `{release}`, port 4317); this restarts all workloads in the GVC.
- Public ingestion requires auth: `publicAccess.enabled` with `auth.method: none` or an empty `allowedCidrs` fails at install — opening to the world requires an explicit `["0.0.0.0/0"]`.
- Create the auth secret before installing — a missing secret leaves the deployment waiting on it.
- mTLS uses the direct load balancer (raw TCP), not the canonical endpoint; in mTLS mode the canonical `https://` endpoint intentionally stops accepting traffic.
- **In mTLS mode, in-GVC senders must use the plain internal gRPC port `:4317`** — the TLS-terminating ingest ports (4318/4319) are not reachable through the internal service mesh (handshake fails); they are for external clients via the direct LB only.
- One collector pushes to one remote-write store; run multiple installs for multiple targets.

## Links

- [OpenTelemetry Collector documentation](https://opentelemetry.io/docs/collector/)
- [Collector configuration reference](https://opentelemetry.io/docs/collector/configuration/)
- [prometheusremotewrite exporter](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/exporter/prometheusremotewriteexporter)
- [bearertokenauth extension](https://github.com/open-telemetry/opentelemetry-collector-contrib/tree/main/extension/bearertokenauthextension)
- [OTLP specification](https://opentelemetry.io/docs/specs/otlp/)
