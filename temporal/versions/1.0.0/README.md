# Temporal

This app deploys [Temporal](https://temporal.io/) — an open-source (MIT) durable-execution platform for writing workflows that survive process crashes and outages — backed by a highly available PostgreSQL cluster by default. It ships a single-process Temporal server exposing the gRPC frontend to your workloads, plus the Temporal Web UI, both internal-only. Database and schema setup run automatically at boot, including schema migrations on version upgrades.

## Architecture

- **Temporal server**: single-replica workload running all four services (frontend, history, matching, worker) in one process; gRPC frontend on port 7233, internal-only. Stateless — all state lives in PostgreSQL.
- **Temporal Web UI** (optional, default on): workload serving the UI on port 8080, internal-only (the UI has no built-in authentication).
- **PostgreSQL (HA, default)** (subchart): the `postgres-highly-available` template — 3× Patroni Postgres, 3× etcd, and an HAProxy leader endpoint Temporal connects through.
- **PostgreSQL (dev/lightweight, optional)** (subchart): the single-instance `postgres` template instead, for lighter deployments.
- **Identity and policy**: a least-privilege policy granting the server identity `reveal` on exactly the database credentials secret.
- **Optional database backups** (subchart): logical dumps or WAL-G archiving to S3, GCS, or an S3-compatible endpoint.

## Prerequisites

- None for a default install.
- For optional database backups: a bucket and access setup for one of the supported providers (see [Backup storage setup](#backup-storage-setup)).

## Configuration

### Temporal server

```yaml
image: temporalio/auto-setup:1.29.7 # server + schema tools; boot runs schema setup, then the server

resources:
  cpu: 1000m
  memory: 2Gi
  minCpu: 500m
  minMemory: 1Gi

historyShards: 512        # PERMANENT after first install — can never be changed for this cluster
namespaceRetention: 72h   # how long closed workflow histories stay queryable in the default namespace
```

### Web UI

```yaml
ui:
  enabled: true           # set false to remove the UI workload
  image: temporalio/ui:2.52.1
  resources:
    cpu: 500m
    memory: 512Mi
    minCpu: 125m
    minMemory: 128Mi
```

### Access

Both workloads are internal-only by design — there is no public-access option. The gRPC frontend serves workers/clients running as workloads in your org; the UI has no built-in authentication, so users who need browser access from outside front it with their own authenticating proxy.

```yaml
internalAccess:           # internal firewall scope for the gRPC frontend (:7233) and the UI (:8080)
  type: same-gvc          # none, same-gvc, same-org, workload-list
  workloads: []           # used with workload-list, e.g. //gvc/GVC/workload/NAME
```

### PostgreSQL

Exactly one of the two databases must be enabled (the chart enforces this at render).

```yaml
postgresHA:               # default: highly available PostgreSQL
  enabled: true
  postgres:
    username: temporal
    password: change-me-temporal-db-password # change before installing
    database: temporal
  replicas: 3
  volumeset:
    capacity: 10          # GiB per replica
  backup:
    enabled: false        # optional — see Backup storage setup
```

```yaml
postgresHA:
  enabled: false
postgres:                 # dev/lightweight: single-instance PostgreSQL
  enabled: true
  config:
    username: temporal
    password: change-me-temporal-db-password # change before installing
    database: temporal
  volumeset:
    capacity: 10          # GiB
  backup:
    enabled: false        # optional — see Backup storage setup
```

## Connecting

| What | Value |
|---|---|
| gRPC frontend (workers/clients) | `{release}-temporal.{gvc}.cpln.local:7233` |
| Namespace | `default` |
| Web UI (internal) | `http://{release}-temporal-ui.{gvc}.cpln.local:8080` |
| Postgres (internal, HA mode) | `{release}-postgres-ha-proxy.{gvc}.cpln.local:5432`, credentials in the `{release}-postgres-config` secret |
| Postgres (internal, single mode) | `{release}-postgres.{gvc}.cpln.local:5432`, credentials in the `{release}-pg-config` secret |

- **Always use the full `.cpln.local` FQDN** in worker/client connection config — short workload names do not resolve.
- **Python workers must guard their entrypoint with `if __name__ == "__main__":`** — the Temporal Python SDK's workflow sandbox re-imports the worker module, and an unguarded module-level `main()` crashes the worker.

## Backup storage setup

Only needed when backups are enabled (`postgresHA.backup.enabled` or `postgres.backup.enabled`). Complete the steps for your provider before installing.

### AWS S3

1. Create your S3 bucket. Set `backup.aws.bucket` and `backup.aws.region`.
2. If you do not have one, create a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account) for your AWS account. Set `backup.aws.cloudAccountName`.
3. Create an AWS IAM policy with the JSON below (replace `YOUR_BUCKET`), then set `backup.aws.policyName` to the policy's name:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:ListBucket", "s3:GetBucketLocation", "s3:GetObject", "s3:PutObject",
               "s3:DeleteObject", "s3:AbortMultipartUpload"],
    "Resource": ["arn:aws:s3:::YOUR_BUCKET", "arn:aws:s3:::YOUR_BUCKET/*"]
  }]
}
```

### Google Cloud Storage

1. Create your GCS bucket. Set `backup.gcp.bucket`.
2. If you do not have one, create a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account) for your GCP project. Set `backup.gcp.cloudAccountName` — the backup identity is granted access to the bucket keylessly (no stored credentials).

### S3-compatible (MinIO, R2, Wasabi, …)

1. Create your bucket on the server. Set `backup.minio.bucket`.
2. Set `backup.minio.endpoint` to the S3 API address including port. For the `minio` marketplace template in the same GVC, this is `http://WORKLOAD_NAME:9000`.
3. Set `backup.minio.accessKey` and `backup.minio.secretKey` to credentials with access to the bucket.

## Important Notes

- **Change the database password (`postgresHA.postgres.password` / `postgres.config.password`) before installing.**
- **`historyShards` is permanent** — the shard count is fixed at the cluster's first boot and can never be changed; the server refuses a different value later. Size it before installing (512 suits most deployments).
- **Never expose the Web UI publicly** — it has no built-in authentication. To offer browser access from outside the internal scope, put your own authenticating proxy in front of it.
- **Temporal connects and runs schema setup as the database superuser** provisioned by the Postgres subchart — it needs `CREATE DATABASE` and DDL rights at every version upgrade.
- **Upgrades restart the single server replica and apply schema migrations automatically at boot** — expect a brief frontend outage per `helm upgrade`; in-flight workflows resume where they left off once the server is back.
- **Uninstall deletes the database volumesets** — all workflow histories and state. Enable backups if the data matters.

## Links

- [Temporal documentation](https://docs.temporal.io/)
- [Self-hosted guide](https://docs.temporal.io/self-hosted-guide)
- [SDKs](https://docs.temporal.io/develop)
- [Namespaces and retention](https://docs.temporal.io/namespaces)
- [Web UI reference](https://docs.temporal.io/web-ui)
