# Prometheus

> **MinIO credentials are a prerequisite secret (1.2.0+).** Create a `dictionary` secret holding
> `accessKey` and `secretKey`, and set `credentialsSecretName` to its name:
>
> ```bash
> cpln secret create-dictionary --name my-prometheus-minio-credentials \
>   --entry accessKey=MINIO_ACCESS_KEY \
>   --entry secretKey=MINIO_SECRET_KEY
> ```
>
> They reach the container as `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` rather than being written
> into the object-storage config file, because a `cpln://` reference inside a mounted file is never
> resolved. The S3 client picks them up from the environment. AWS and GCP are unaffected — they were
> already keyless via cloud identity. An upgrade still carrying `accessKey`/`accessSecret` is refused
> at render.


This app deploys [Prometheus](https://prometheus.io/) — the standard open-source metrics database — with the remote-write receiver enabled and a durable TSDB volume. An optional co-located [Thanos](https://thanos.io/) sidecar (on by default) exposes the Store API for a Thanos Query tier and can upload TSDB blocks to your object bucket for long-term durability.

This is a **self-hosted metrics store for your own metrics from your own sources**. It is separate from — and not a replacement for — Control Plane's built-in observability, which continues to collect and dashboard your workloads' metrics natively.

## Architecture

- **Prometheus**: Stateful workload, single replica; scrape + remote-write ingest and PromQL query on port 9095 (9090 is platform-reserved). HA is achieved by installing the template twice (see [High availability](#high-availability)).
- **Thanos sidecar** (optional, default on): second container in the same workload; Store API (gRPC) on 10901, HTTP health/metrics on 10902; uploads TSDB blocks to object storage when enabled.
- **Volumeset**: 20 GiB at `/prometheus` for the TSDB, shared read-only by the sidecar.
- **Config secret**: the rendered `prometheus.yml`, mounted as a file; a second secret holds the Thanos bucket config when object storage is enabled.
- **Identity + policy**: least privilege — `reveal` on exactly the template's secrets (plus any remote-write password secrets you name), and cloud access scoped to your bucket (AWS/GCP) when object storage is on.

## Prerequisites

None for a default install. Depending on the features you enable:

- **Object storage** (`thanos.objectStorage`) — an existing bucket and access setup for it (step-by-step under [Storage setup](#storage-setup)): **AWS S3** (bucket + Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account) + bucket-scoped IAM policy), **Google Cloud Storage** (bucket + cloud account), or any **S3-compatible** server (bucket + static credentials).
- **Remote write with basic auth** — an **opaque secret** per endpoint holding the password (e.g. `my-remote-write-password`), created **before** install; the template references it by name only.

## Configuration

### Prometheus

```yaml
image: prom/prometheus:v3.13.1

resources:            # memory scales with active series
  minCpu: 500m
  maxCpu: 1000m
  minMemory: 1Gi
  maxMemory: 2Gi
```

### TSDB

```yaml
retention:
  time: 15d           # how long samples are kept on the local volume
  size: ""            # optional local size cap, e.g. 15GB — empty means no cap

volumeset:
  capacity: 20        # GiB — TSDB volume at /prometheus
```

### Metrics

```yaml
scrapeInterval: 30s   # global scrape interval
externalLabels: {}    # identity labels on all uploaded/forwarded series, e.g. region: us-east-1
extraScrapeConfigs: "" # raw YAML list of additional scrape_configs entries
```

To scrape your own workloads, set `extraScrapeConfigs` to a raw YAML list:

```yaml
extraScrapeConfigs: |
  - job_name: my-app
    static_configs:
      - targets: ["my-app.my-gvc.cpln.local:8080"]
```

### Remote write

Push metrics to Mimir or any Prometheus-remote-write-compatible store — the recommended shape when the Thanos sidecar is disabled.

```yaml
remoteWrite:
  - url: http://my-mimir.my-gvc.cpln.local:8080/api/v1/push
    basicAuth:                                    # optional
      username: my-user
      passwordSecretName: my-remote-write-password # opaque secret, must exist BEFORE install
```

### Thanos sidecar and object storage

```yaml
thanos:
  sidecar:
    enabled: true     # Store API (gRPC :10901) for a Thanos Query tier
    image: quay.io/thanos/thanos:v0.42.2
    resources:
      minCpu: 100m
      maxCpu: 250m
      minMemory: 128Mi
      maxMemory: 512Mi
  objectStorage:
    enabled: false    # sidecar uploads TSDB blocks to your bucket; requires sidecar.enabled
    type: aws         # aws | gcp | minio
    blockDuration: 2h # advanced: TSDB block interval (min=max disables local compaction)

    aws:
      bucket: my-prometheus-bucket        # must already exist
      region: us-east-1
      cloudAccountName: my-s3-cloud-account
      policyName: my-prometheus-s3-policy # custom bucket-scoped IAM policy (bare name)

    gcp:
      bucket: my-prometheus-bucket        # must already exist
      cloudAccountName: my-gcs-cloud-account

    minio:
      endpoint: my-minio:9000             # host:port, no scheme
      insecure: true                      # true for plain-HTTP endpoints
      bucket: my-prometheus-bucket
      region: us-east-1
      # REQUIRED PREREQUISITE SECRET when type is `minio` — a `dictionary` secret
      # holding exactly `accessKey` and `secretKey`.
      credentialsSecretName: my-prometheus-minio-credentials
```

### Access

```yaml
internalAccess:
  type: same-gvc      # none | same-gvc | same-org | workload-list
  workloads: []       # used with workload-list, e.g. //gvc/GVC/workload/NAME — cross-GVC callers allowed
```

## Storage setup

### AWS S3

1. Create an S3 bucket (e.g. `my-prometheus-bucket`).
2. In AWS IAM, create a policy (e.g. `my-prometheus-s3-policy`) scoped to that bucket:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": [
        "arn:aws:s3:::my-prometheus-bucket",
        "arn:aws:s3:::my-prometheus-bucket/*"
      ]
    }
  ]
}
```

3. Create a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account) for your AWS account.
4. Set `thanos.objectStorage.aws.*` to your bucket, region, cloud account name, and policy name.

### Google Cloud Storage

1. Create a GCS bucket.
2. Create a Control Plane cloud account for your GCP project.
3. Set `thanos.objectStorage.gcp.bucket` and `.cloudAccountName`. The template grants the workload identity `roles/storage.objectAdmin` on exactly that bucket.

### S3-compatible (MinIO, R2, Wasabi, …)

1. Create the bucket on your server and credentials that can read/write it.
2. Set `thanos.objectStorage.minio.*`: endpoint as `host:port` (no scheme; `insecure: true` for plain HTTP), bucket, region, and the access key pair.

## Connecting

| What | Endpoint |
|---|---|
| Remote-write ingest (from your senders) | `http://RELEASE-prometheus.GVC.cpln.local:9095/api/v1/write` |
| PromQL / Grafana datasource | `http://RELEASE-prometheus.GVC.cpln.local:9095` |
| Built-in web UI (see [Web UI](#web-ui)) | `http://RELEASE-prometheus.GVC.cpln.local:9095/query` |
| Thanos Store API, same GVC | `RELEASE-prometheus:10901` |
| Thanos Store API, cross-GVC | `RELEASE-prometheus.GVC.cpln.local:10901` |

For cross-GVC callers (e.g. a Thanos Query tier in another GVC), set `internalAccess.type` to `same-org`, or `workload-list` naming the caller. Cross-location internal traffic incurs egress charges — co-locate the query tier with its stores where practical.

Use the service-level DNS name above — this workload is single-replica by design, so it addresses the one replica directly and is the most reliable path. (The per-replica form `replica-0.RELEASE-prometheus.LOCATION.GVC.cpln.local:10901` also exists but adds no value for a single-replica workload.)

## Web UI

Prometheus serves its own web interface on the same port as the API (`:9095`), with no extra configuration. The pages that matter most when something is wrong:

| Page | Path | What it answers |
|---|---|---|
| Targets | `/targets` | Every scrape target, its last scrape time, and the exact error when a scrape fails — **the first place to look when an expected metric never appears.** |
| Service discovery | `/service-discovery` | Discovered targets before and after relabeling — shows targets your relabel rules dropped. |
| Expression browser | `/query` | Ad-hoc PromQL with table and graph views (`/` and `/graph` both redirect here). |
| Configuration | `/config` | The running `prometheus.yml` exactly as Prometheus parsed it — confirms your `extraScrapeConfigs` landed. |
| TSDB status | `/tsdb-status` | Head-block cardinality by metric and label — the answer to "why is memory growing?". |

Access is internal-only, so reach it from inside the GVC. Each page also has a JSON API equivalent, which is the practical form from a shell:

```bash
# from any workload in the same GVC (substitute your own workload and GVC)
cpln workload exec MY-WORKLOAD --gvc MY-GVC -- curl -s http://RELEASE-prometheus.GVC.cpln.local:9095/api/v1/targets
```

`/api/v1/targets`, `/api/v1/status/config`, and `/api/v1/status/tsdb` back the Targets, Configuration, and TSDB status pages respectively.

**Prometheus has no authentication of its own** — anyone who can reach port 9095 gets full read access and can run arbitrary PromQL — which is why this template offers `internalAccess` only and no public exposure. For a browser-facing, authenticated query UI, install the **grafana** template in the same GVC and add a Prometheus datasource pointing at `http://RELEASE-prometheus.GVC.cpln.local:9095`.

## High availability

Prometheus has no cluster mode; the upstream HA pattern is two independent, identically-configured instances deduplicated at query time. Install the template twice (e.g. releases `prom-a` and `prom-b`) with identical values except:

```yaml
# prom-a                              # prom-b
externalLabels:                       externalLabels:
  prometheus: my-prom                   prometheus: my-prom
  replica: a                            replica: b
```

Senders dual-write to both endpoints; a Thanos Query tier dedups via `--query.replica-label=replica`. Overriding `prometheus` to a shared value is required so the two label sets differ only in `replica`.

## Important Notes

- **Prometheus has no built-in authentication, so this template never exposes a public endpoint.** To serve clients outside Control Plane, front it with your own authenticating proxy behind a custom domain.
- **Remote-write password secrets must exist before install** — a missing `passwordSecretName` secret wedges the deployment waiting on it.
- **Config changes ship via `helm upgrade`** (workload redeploy) — there is no hot reload.
- **With object storage enabled, keep `retention.time` at least 3× `blockDuration`** (the default `15d`/`2h` satisfies this) — the sidecar needs blocks on the local volume long enough to upload them; history beyond local retention lives in your bucket.
- **The TSDB survives reinstall** (`recoveryPolicy: retain` + final snapshot) — local data resumes when a new install binds the volume.
- **After a restart, readiness can take minutes on a large TSDB** — WAL replay holds `/-/ready` at 503; this is normal recovery, not a failure.

## Links

- [Prometheus documentation](https://prometheus.io/docs/introduction/overview/)
- [Prometheus configuration reference](https://prometheus.io/docs/prometheus/latest/configuration/configuration/)
- [Thanos sidecar](https://thanos.io/tip/components/sidecar.md/)
- [Prometheus remote_write](https://prometheus.io/docs/practices/remote_write/)
- [Control Plane cloud accounts](https://docs.controlplane.com/guides/create-cloud-account)
