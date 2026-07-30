# Thanos

This app deploys [Thanos](https://thanos.io) Query — a global PromQL layer that fans one query out over many Prometheus servers (via their Thanos sidecar Store API endpoints) and deduplicates HA pairs — plus an optional object-storage tier (Store Gateway + Compactor) for long-term metrics retention.

## Architecture

- **Thanos Query**: stateless standard workload; UI and PromQL API on port 10902, gRPC Store API on 10901; single replica by default — set `replicas: 2` or more for an HA query tier.
- **Identity**: shared workload identity; receives bucket access only when the storage tier is enabled.
- **Store Gateway** (optional, off by default): stateful workload serving historical bucket blocks to Query, with a 10 GiB cache volumeset (safe to lose — it rebuilds).
- **Compactor** (optional, off by default): stateful **singleton** that compacts, downsamples, and applies retention to bucket blocks, with a 20 GiB workspace volumeset.
- **Objstore secret + policy** (optional): the rendered `objstore.yml` bucket config and a `reveal` grant scoped to it — created only when the storage tier is on.

## Prerequisites

None for a default install (Query only — point it at your store endpoints).

For the optional storage tier, an existing bucket in one of the supported backends (step-by-step under [Storage setup](#storage-setup)):

- **AWS S3** — an S3 bucket, a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account) for your AWS account, and a bucket-scoped IAM policy.
- **Google Cloud Storage** — a GCS bucket and a Control Plane cloud account for your GCP project.
- **S3-compatible (MinIO, R2, Wasabi, …)** — a bucket and static access credentials (no cloud account).

## Configuration

### Query

```yaml
image: quay.io/thanos/thanos:v0.42.2

resources:
  cpu: 500m
  memory: 1Gi
  minCpu: 250m
  minMemory: 512Mi

replicas: 1             # Query is stateless — set 2+ for an HA query tier
```

### Store endpoints

```yaml
stores: []              # gRPC Store API endpoints, host:port with NO scheme
# stores:                # service-level DNS — see Wiring Prometheus sources
#   - my-prometheus-prometheus.metrics-east.cpln.local:10901
#   - my-prometheus-b-prometheus.metrics-west.cpln.local:10901

queryReplicaLabels:     # external label(s) marking HA duplicates to deduplicate
  - replica
```

### Access

```yaml
publicAccess:
  enabled: false        # true = Query UI/API at a *.cpln.app URL — it has NO built-in auth

internalAccess:
  type: same-gvc        # none | same-gvc | same-org | workload-list
  workloads: []         # used with workload-list
```

### Long-term storage tier (optional)

```yaml
storeGateway:
  enabled: false        # serves historical bucket blocks to Query
  volumeset:
    capacity: 10        # GiB — local cache; safe to lose (rebuilds on start)

compactor:
  enabled: false        # MUST be the ONLY compactor on the bucket, across all installs
  volumeset:
    capacity: 20        # GiB — workspace; size ~2x two weeks of raw blocks
  retention:            # per-resolution bucket retention; "0d" keeps forever
    raw: "0d"
    fiveMinutes: "0d"
    oneHour: "0d"
```

### Object storage (used only when the storage tier is enabled)

```yaml
storage:
  type: aws             # aws | gcp | minio

  aws:
    bucket: my-thanos-bucket         # must already exist
    region: us-east-1
    cloudAccountName: my-s3-cloud-account
    policyName: my-thanos-s3-policy  # custom bucket-scoped IAM policy (bare name)

  gcp:
    bucket: my-thanos-bucket         # must already exist
    cloudAccountName: my-gcs-cloud-account

  minio:
    endpoint: my-minio:9000          # host:port, no scheme
    insecure: true                   # true for plain-HTTP endpoints
    bucket: my-thanos-bucket
    region: us-east-1
    accessKey: my-minio-username
    accessSecret: my-minio-password
```

## Wiring Prometheus sources

Each `stores:` entry is a gRPC Store API endpoint — typically a Prometheus Thanos sidecar — as `host:port` with **no scheme**:

- **Same GVC**: `WORKLOAD.GVC.cpln.local:10901` (the short form `WORKLOAD:10901` also works)
- **Cross-GVC / cross-region**: the same service-level internal DNS — `WORKLOAD.GVC.cpln.local:10901` (e.g. `my-prometheus-prometheus.metrics-east.cpln.local:10901`)

Use the service-level name in both cases: the prometheus template is single-replica by design, so it addresses the one replica directly and is the most reliable form. (Per-replica DNS — `replica-N.WORKLOAD.LOCATION.GVC.cpln.local` — is only needed for genuinely multi-replica Store API targets.)

Two requirements for cross-GVC endpoints, both **on the Prometheus side**:

1. The target workload's internal firewall must allow inbound from this Query workload — set its `internalAccess.type` to `same-org`, or `workload-list` including `//gvc/GVC/workload/RELEASE-thanos`. A store showing as "down" in the Query UI is almost always this firewall.
2. Cross-location internal traffic (Query in one region querying sidecars in another) incurs egress charges.

## Storage setup

### AWS S3

1. Create an S3 bucket (e.g. `my-thanos-bucket`).
2. In AWS IAM, create a policy (e.g. `my-thanos-s3-policy`) scoped to that bucket:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": [
        "arn:aws:s3:::my-thanos-bucket",
        "arn:aws:s3:::my-thanos-bucket/*"
      ]
    }
  ]
}
```

3. Create a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account) for your AWS account.
4. Set `storage.aws.*` to your bucket, region, cloud account name, and policy name. Access is keyless — no static credentials.

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
| Query UI / PromQL API (in-GVC) | `http://RELEASE-thanos.GVC.cpln.local:10902` |
| Grafana Prometheus datasource | the same URL — Query speaks the Prometheus HTTP API |
| Query UI / API (public, when `publicAccess.enabled`) | the `*.cpln.app` canonical endpoint (`cpln workload get RELEASE-thanos -o yaml` → `status.canonicalEndpoint`) |
| Query's own Store API (for a higher Thanos tier) | `RELEASE-thanos.GVC.cpln.local:10901` (gRPC) |

## Important Notes

- **Query has no built-in authentication** — with `publicAccess.enabled: true`, anyone with the URL can run queries. Keep it off, or front Query with an authenticating proxy.
- **Run exactly one Compactor per bucket, across all installs and regions** — a second one corrupts the block layout and requires manual repair. Multi-region users enable `compactor` in one install only.
- **Cross-GVC stores need a firewall change on the Prometheus side** — the sidecar workload must allow inbound `same-org` or list this Query workload (see [Wiring Prometheus sources](#wiring-prometheus-sources)).
- **Changing `stores:` takes effect via `helm upgrade`** — endpoints are workload args, so an upgrade safely redeploys Query with the new list.
- **No deduplication happening?** `queryReplicaLabels` must exactly match the external label name your HA Prometheus pair sets (`replica` by default).
- **Long-term reads need both halves on the same bucket**: a sidecar uploading blocks to it, and `storeGateway.enabled: true` here to serve them.
- **Disabling the storage tier does not remove existing cloud grants from the identity** — the platform deep-merges updates, so a previously-applied AWS/GCP binding stays until you remove it (edit the identity, or uninstall/reinstall the release).

## Links

- [Thanos](https://thanos.io)
- [Query component](https://thanos.io/tip/components/query.md/)
- [Store Gateway component](https://thanos.io/tip/components/store.md/)
- [Compactor component](https://thanos.io/tip/components/compact.md/)
- [Control Plane cloud accounts](https://docs.controlplane.com/guides/create-cloud-account)
