# Temporal

> **Upgrading from 1.x:** Temporal upgrades one minor version at a time, so a 1.x release (server 1.29)
> steps through 1.30 and 1.31 before reaching this version's default 1.32. Follow
> [Upgrading from 1.x](#upgrading-from-1x). A direct upgrade with the defaults is refused before the
> database is touched.

This app deploys [Temporal](https://temporal.io/), an open-source (MIT) durable-execution platform for writing workflows that survive process crashes and outages. It runs the Temporal server (one replica by default, or a cluster of up to five) with its gRPC frontend and HTTP API, plus the Temporal Web UI, all internal-only, on a highly available PostgreSQL cluster by default. Database creation, schema migrations and the `default` namespace are handled automatically.

## Architecture

- **Temporal server**: `replicas` replicas (default 1), each running all four services (frontend, history, matching, worker) in one process; gRPC on 7233, HTTP API on 7243, internal-only. With more than one replica they form a single Temporal cluster. Stateless: all state lives in PostgreSQL.
- **`admin` sidecar** (in every server replica): creates the databases, migrates the schema (one replica at a time), refuses an upgrade that skips a minor version, creates the `default` namespace, then serves as an in-cluster `temporal` CLI.
- **Temporal Web UI** (optional, default on): serves the UI on port 8080, internal-only (the UI has no built-in authentication).
- **PostgreSQL (HA, default)** (subchart): the `postgres-highly-available` template: 3 Patroni Postgres replicas, 3 etcd replicas, and an HAProxy leader endpoint Temporal connects through.
- **PostgreSQL (single-instance, optional)** (subchart): the `postgres` template instead, for lighter deployments.
- **Database credentials secret** (dictionary): created by this template from `postgres.credentials.*` in both database modes. Nothing for you to create.
- **Identity and policy**: the server identity may `reveal` exactly the database credentials secret.
- **Server metrics**: each replica's Prometheus metrics (port 8000) are collected into the platform's built-in metrics.
- **Optional database backups** (subchart): logical dumps or WAL-G archiving to S3, GCS, or an S3-compatible endpoint.

## Prerequisites

- None for a default install.
- For optional database backups: a bucket and access setup for one of the supported providers (see [Backup storage setup](#backup-storage-setup)).

## Configuration

### Temporal server

```yaml
image: temporalio/server:1.32.1 # 1.30.x, 1.31.x or 1.32.x; step one minor per upgrade
replicas: 1 # 1-5; 3 survives a replica loss. >1 rolling restarts are noisy (see Scaling the server)

resources: # per replica
  maxCpu: 1000m
  maxMemory: 2Gi
  minCpu: 500m
  minMemory: 1Gi

adminTools:
  image: temporalio/admin-tools:1.32.1 # schema migrations + `temporal` CLI sidecar; same tag as image

historyShards: 512 # PERMANENT after first install; can never be changed for this cluster
namespaceRetention: 72h # retention of the `default` namespace, applied when it is first created
```

### Web UI

```yaml
ui:
  enabled: true # set false to remove the UI workload
  image: temporalio/ui:2.55.0
  resources:
    maxCpu: 500m
    maxMemory: 512Mi
    minCpu: 125m
    minMemory: 128Mi
```

### Access

There is no public-access option. Workers and clients run as workloads in your org; reach the UI with `cpln port-forward` (see [Connecting](#connecting)).

```yaml
internalAccess: # firewall scope for the server (gRPC :7233, HTTP API :7243, cluster ports) and the UI (:8080)
  type: same-gvc # none, same-gvc, same-org, workload-list
  workloads: [] # used with workload-list, e.g. //gvc/GVC_NAME/workload/WORKLOAD_NAME
```

### PostgreSQL

Exactly one of the two databases must be enabled (the chart enforces this at render).

```yaml
postgresHA: # default: highly available PostgreSQL
  enabled: true
  config:
    credentialsSecretName: my-temporal-db-credentials # secret this template CREATES from postgres.credentials.*; org-wide, unique per release
  replicas: 3
  volumeset:
    capacity: 10 # GiB per replica
  backup:
    enabled: false # optional; see Backup storage setup
    mode: logical # logical or wal-g
    resources:
      cpu: 100m
      memory: 512Mi # 128Mi OOMKills wal-g mid-backup
postgres:
  credentials: # HA mode also reads these: this template builds the credentials secret from them
    username: temporal
    password: change-me-temporal-db-password # change before installing
    database: temporal # must stay `temporal` (render-enforced in both modes)
```

```yaml
postgresHA:
  enabled: false
postgres: # dev/lightweight: single-instance PostgreSQL
  enabled: true
  credentials:
    username: temporal
    password: change-me-temporal-db-password # change before installing
    database: temporal # must stay `temporal`
  config:
    credentialsSecretName: my-temporal-db-credentials # secret this template CREATES; org-wide, unique per release
  volumeset:
    capacity: 10 # GiB
  backup:
    enabled: false # optional; see Backup storage setup
```

## Scaling the server

- **Sizing:** `replicas: 3` is the highly available shape: it survives the loss of one replica with capacity to spare. `1` is fine when a short gap per upgrade or restart is acceptable. Up to 5 are allowed.
- **Add replicas for availability, not throughput.** Each replica's database connection pools shrink as replicas are added, so that every replica plus the extra one a rolling update starts fits under the bundled database's 100 connections:

  | `replicas` | Connections per replica (up to) | With the rolling-update replica |
  |---|---|---|
  | 1 | 40 | 80 |
  | 2 | 28 | 84 |
  | 3 | 20 | 80 |
  | 4 | 16 | 80 |
  | 5 | 12 | 72 |

- **Losing a replica:** the remaining replicas take over its share of workflows within about a minute. Workflows on the moved shards pause briefly and timers fire late by that gap; nothing is lost. The lost replica restarts on its own.
- **Rolling upgrades and restarts with more than one replica are noisy.** For a period after each roll, the worker service on new replicas exits and restarts while workflows rebalance (upstream Temporal treats a slow internal start-up as fatal), and clients see a small share of retried calls. In earlier measurements at 3 replicas this lasted 60 to 90 minutes with about 5% of calls retried. Workflows are unaffected. Plan upgrades outside peak hours.
- **Changing the count** is a plain `helm upgrade` with the new `replicas`; members join or drain and the shards rebalance. Nothing else restarts.

## Connecting

| What | Value |
|---|---|
| gRPC frontend (workers and clients) | `RELEASE_NAME-temporal.GVC_NAME.cpln.local:7233` |
| HTTP API | `http://RELEASE_NAME-temporal.GVC_NAME.cpln.local:7243` (for example `/api/v1/namespaces/default`) |
| Namespace | `default` |
| Web UI | `cpln port-forward RELEASE_NAME-temporal-ui 8080:8080 --gvc GVC_NAME`, then open `http://localhost:8080` |
| `temporal` CLI | `cpln workload exec RELEASE_NAME-temporal --gvc GVC_NAME --container admin -- temporal workflow list` |
| Postgres (HA mode) | `RELEASE_NAME-postgres-ha-proxy.GVC_NAME.cpln.local:5432`, credentials in the secret named by `postgresHA.config.credentialsSecretName` |
| Postgres (single mode) | `RELEASE_NAME-postgres.GVC_NAME.cpln.local:5432`, credentials in the secret named by `postgres.config.credentialsSecretName` |

- **Always use the full `.cpln.local` name** in worker and client configuration; short workload names do not resolve.
- **Python workers must guard their entrypoint with `if __name__ == "__main__":`**: the Temporal Python SDK's workflow sandbox re-imports the worker module, and an unguarded module-level `main()` crashes the worker.
- If the UI stops loading pages through `cpln port-forward` after some navigation, restart the port-forward and reload.

## Upgrading from 1.x

Temporal supports upgrading **one minor version at a time**, with about 10 minutes on each. A 1.x release runs Temporal 1.29.7, so it takes three upgrades. Do them at `replicas: 1`, and raise `replicas` only after the last one, so each step replaces a single replica.

1. **Back up first.** A migrated schema cannot be rolled back. Enable `postgresHA.backup` (or `postgres.backup`) and confirm a backup reached the bucket, or snapshot the database volumes:

   ```bash
   cpln volumeset snapshot create RELEASE_NAME-postgres-ha-vs --snapshot-name pre-temporal-2 --gvc GVC_NAME   # HA mode
   cpln volumeset snapshot create RELEASE_NAME-pg-vs --snapshot-name pre-temporal-2 --gvc GVC_NAME          # single mode
   ```

2. **Upgrade to 2.0.0 on Temporal 1.30** (with your existing values file):

   ```bash
   cpln helm upgrade RELEASE_NAME oci://ghcr.io/controlplane-com/templates/temporal --version 2.0.0 --gvc GVC_NAME \
     -f values.yaml --set image=temporalio/server:1.30.8 --set adminTools.image=temporalio/admin-tools:1.30.8
   ```

   If your values file sets `image: temporalio/auto-setup:…`, delete that line now: the last step uses the chart default, and the chart refuses an auto-setup image.
3. **Wait** until the server is ready, then about 10 more minutes.
4. **Upgrade to 1.31:** the same command with `1.31.4` in both `--set`s.
5. **Upgrade to 1.32:** the same command without the two `--set`s (the chart defaults are 1.32.1).

Each step migrates the schema before the new server starts. A step that skips a minor version is refused before the database is touched: the new replica never becomes ready, and its `admin` container logs `CPLN_TEMPORAL_SKIP_GUARD` with the tag to use next. Set the right tag and upgrade again.

Also in this version:

- **AWS backups:** the HA backup no longer attaches AWS's `ReadOnlyAccess` policy. Update your bucket-scoped IAM policy to the full action list under [AWS S3](#aws-s3) before upgrading.
- **Temporal 1.32 visibility queries are stricter:** a list filter that compares a search attribute with the wrong type, or an empty `Text` filter, now returns an error instead of results.
- **Older releases:** 1.0.x moved `postgres.config.{username,password,database}` to `postgres.credentials.*` (1.1.0); 1.1.x moved `postgresHA.postgres.*` to `postgres.credentials.*` (1.2.0) and MinIO keys to `postgresHA.backup.minio.credentialsSecretName` / `postgres.backup.minio.credentialsSecretName` (1.2.1, a dictionary secret with `accessKey` and `secretKey`); 1.2.x renamed `resources.cpu`/`memory` to `maxCpu`/`maxMemory` (1.3.0, also under `ui.resources`). Keep your existing password values unchanged when you move them: the database keeps the password it was initialised with.

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
    "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket",
               "s3:GetObjectVersion", "s3:DeleteObjectVersion", "s3:GetBucketLocation",
               "s3:AbortMultipartUpload", "s3:ListBucketMultipartUploads", "s3:ListMultipartUploadParts"],
    "Resource": ["arn:aws:s3:::YOUR_BUCKET", "arn:aws:s3:::YOUR_BUCKET/*"]
  }]
}
```

### Google Cloud Storage

1. Create your GCS bucket. Set `backup.gcp.bucket`.
2. If you do not have one, create a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account) for your GCP project. Set `backup.gcp.cloudAccountName`. The backup identity reaches the bucket keylessly (no stored credentials).
3. Grant the cloud account's GCP service account the **Storage Admin** role.

### S3-compatible (MinIO, R2, Wasabi, …)

1. Create your bucket on the server. Set `backup.minio.bucket`.
2. Set `backup.minio.endpoint` to the S3 API address including port. For the `minio` marketplace template in the same GVC, this is `http://WORKLOAD_NAME.GVC_NAME.cpln.local:9000`.
3. Create a dictionary secret with the access keys and name it in `postgresHA.backup.minio.credentialsSecretName` (HA) or `postgres.backup.minio.credentialsSecretName` (single-instance):

   ```bash
   cpln secret create-dictionary --name my-temporal-minio-credentials \
     --entry accessKey=ACCESS_KEY \
     --entry secretKey=SECRET_KEY
   ```

## Important Notes

- **Change the database password (`postgres.credentials.password`) before installing.** It is set once, when the database volume is first initialised; changing it later only rewrites the secret, and the server can no longer connect.
- **Give each Temporal release its own credentials secret name** (`postgresHA.config.credentialsSecretName` or `postgres.config.credentialsSecretName`). Secret names are org-wide, so a second release on the default name is refused at install.
- **`historyShards` is permanent**: it is fixed at the cluster's first boot and the server refuses a different value later. 512 suits most deployments.
- **Never expose the Web UI publicly**: it has no built-in authentication.
- **A replica that stays not ready:** read its `admin` container's logs. "another replica is migrating the schema" is normal during an upgrade with several replicas; `CPLN_TEMPORAL_SKIP_GUARD` means the image skips a minor version.
- **Keep the GVC to one location.** Each location would run its own servers against its own database.
- **Uninstall deletes the database volumesets**, with all workflow histories. Enable backups if the data matters.

## Links

- [Temporal documentation](https://docs.temporal.io/)
- [Upgrading a self-hosted Temporal Service](https://docs.temporal.io/self-hosted-guide/upgrade-server)
- [SDKs](https://docs.temporal.io/develop)
- [Namespaces and retention](https://docs.temporal.io/namespaces)
- [Web UI](https://docs.temporal.io/web-ui)
