# Grafana Mimir

This app deploys [Grafana Mimir](https://github.com/grafana/mimir) in monolithic mode — a long-term Prometheus metrics store you own. Your collectors (Prometheus, Grafana Alloy, OpenTelemetry) push metrics in via Prometheus `remote_write`; anything that speaks PromQL (your own Grafana, scripts, dashboards) queries them back, with durable storage in your object bucket.

This is a **self-hosted metrics store for your own metrics from your own sources**. It is separate from — and not a replacement for — Control Plane's built-in observability, which continues to collect and dashboard your workloads' metrics natively.

## Architecture

- **Mimir**: Stateful workload running all Mimir components in one process (`target: all`); single replica by default — set `replicas: 3` or more for an HA cluster with 3-way-replicated ingest, where queries and pushes continue through a replica loss or rolling restart. Remote-write ingest and PromQL query on port 8080; internal gRPC on 9095; memberlist on 7946 (self-contained ring — no Consul/etcd).
- **Volumeset**: 20 GiB at `/data` for the ingester WAL/TSDB and compactor workspace; metric blocks are durably stored in your object bucket, not on the volume.
- **Config secret**: the rendered Mimir configuration, mounted as a file.
- **Identity + policy**: least privilege — `reveal` on the config secret only, plus cloud access scoped to your bucket (AWS/GCP).


## Prerequisites

An existing bucket in one of the supported backends, and access setup for it (step-by-step under [Storage setup](#storage-setup)):

- **AWS S3** — an S3 bucket, a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account) for your AWS account, and a bucket-scoped IAM policy.
- **Google Cloud Storage** — a GCS bucket and a Control Plane cloud account for your GCP project.
- **S3-compatible (MinIO, R2, Wasabi, …)** — a bucket and static access credentials (no cloud account).

## Configuration

### Mimir

```yaml
image: grafana/mimir:3.1.3

resources:            # memory governs how many active series you can ingest
  cpu: 1000m
  memory: 2Gi
  minCpu: 500m
  minMemory: 1Gi

replicas: 1           # 1 for a single instance; 3 or more forms an HA cluster with 3-way replication
```

### Storage

```yaml
storage:
  type: aws           # aws | gcp | minio

  aws:
    bucket: my-mimir-bucket        # must already exist
    region: us-east-1
    cloudAccountName: my-s3-cloud-account
    policyName: my-mimir-s3-policy # custom bucket-scoped IAM policy (bare name)

  gcp:
    bucket: my-mimir-bucket        # must already exist
    cloudAccountName: my-gcs-cloud-account

  minio:
    endpoint: my-minio:9000        # host:port, no scheme
    insecure: true                 # true for plain-HTTP endpoints
    bucket: my-mimir-bucket
    region: us-east-1
    accessKey: my-minio-username
    accessSecret: my-minio-password
```

### Tenancy

```yaml
multitenancy:
  enabled: false      # when true, EVERY request must carry X-Scope-OrgID: <tenant>
```

### Retention

```yaml
retention:
  period: "0"         # blocks retention: "0" keeps data forever; e.g. 30d, 13w, 1y
```

### Storage volume and access

```yaml
volumeset:
  capacity: 20        # GiB — WAL/TSDB and compactor workspace

internalAccess:
  type: same-gvc      # none | same-gvc | same-org | workload-list
  workloads: []       # used with workload-list
```

## Storage setup

### AWS S3

1. Create an S3 bucket (e.g. `my-mimir-bucket`).
2. In AWS IAM, create a policy (e.g. `my-mimir-s3-policy`) scoped to that bucket:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": [
        "arn:aws:s3:::my-mimir-bucket",
        "arn:aws:s3:::my-mimir-bucket/*"
      ]
    }
  ]
}
```

3. Create a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account) for your AWS account.
4. Set `storage.aws.*` to your bucket, region, cloud account name, and policy name.

### Google Cloud Storage

1. Create a GCS bucket.
2. Create a Control Plane cloud account for your GCP project.
3. Set `storage.gcp.bucket` and `storage.gcp.cloudAccountName`. The template grants the workload identity `roles/storage.objectAdmin` on exactly that bucket.

### S3-compatible (MinIO, R2, Wasabi, …)

1. Create the bucket on your server and credentials that can read/write it.
2. Set `storage.minio.*`: endpoint as `host:port` (no scheme; `insecure: true` for plain HTTP), bucket, region, and the access key pair.

## Connecting

| What | Endpoint |
|---|---|
| Remote-write ingest (from your collectors) | `http://RELEASE-mimir.GVC.cpln.local:8080/api/v1/push` |
| PromQL / Grafana datasource | `http://RELEASE-mimir.GVC.cpln.local:8080/prometheus` |
| Tenant header (when `multitenancy.enabled`) | `X-Scope-OrgID: <tenant>` on every request |

Point a Grafana Prometheus datasource at the PromQL URL. Collectors inside the GVC (or org, per `internalAccess`) push directly to the ingest endpoint.

## Important Notes

- **Mimir has no built-in authentication, so this template never exposes a public endpoint.** The `X-Scope-OrgID` header identifies a tenant; it does not authenticate anyone. To serve clients outside Control Plane, front Mimir with your own authenticating proxy behind a custom domain.
- **With `multitenancy.enabled: true`, every request needs `X-Scope-OrgID`** — pushes and queries without it are rejected; tenants are implicit (no provisioning step).
- **Transient "Access Denied" warnings in the first seconds of a fresh boot are expected** — the workload identity's cloud credentials are still being issued; Mimir retries and proceeds.
- **Data lives in your bucket** — the volumeset only holds the WAL and scratch space. Reinstalling the template against the same bucket resumes with your data; deleting data means emptying the bucket.
- **Retention is enforced by the compactor** — changing `retention.period` applies to existing blocks too.
- **After uninstall, re-check your bucket**: the terminating replica can re-write a small cluster-seed file (`blocks/__mimir_cluster/`) minutes after teardown — delete it if you are emptying the bucket.

## Links

- [Grafana Mimir (GitHub)](https://github.com/grafana/mimir)
- [Documentation](https://grafana.com/docs/mimir/latest/)
- [Prometheus remote_write](https://prometheus.io/docs/practices/remote_write/)
- [Control Plane cloud accounts](https://docs.controlplane.com/guides/create-cloud-account)
