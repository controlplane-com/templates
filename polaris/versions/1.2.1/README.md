# Apache Polaris

This app deploys [Apache Polaris](https://polaris.apache.org/) — an Apache Iceberg **REST catalog** (Apache-2.0). It is the service that tells query engines which tables exist, where their metadata lives in object storage, and who may read them. Together with an S3-compatible bucket and a query engine such as the `trino` template, it turns a bucket of Parquet files into a lakehouse.

## Architecture

- **Polaris server**: Standard workload serving the Iceberg REST API and the management API on `8181`, and Quarkus health/metrics on `8182`. Stateless — a `replicas` knob scales it horizontally.
- **Bootstrap workload**: Runs the official `polaris-admin-tool` image once to create the realm schema and the root principal, then idles. Always one replica; the operation is idempotent, so restarts and upgrades re-run it harmlessly.
- **Bootstrap script secret**: The shell script the bootstrap workload runs (opaque secret, mounted as a file).
- **Two identities and two policies**: Least privilege — only the bootstrap principal can reveal the root credentials; only the server principal can reveal the token signing key and the object-storage credentials.
- **PostgreSQL (single-instance, default)**: The `postgres` template — every catalog, namespace, table pointer, principal and grant lives here.
- **PostgreSQL (HA, optional)**: The `postgres-highly-available` template instead — 3 Patroni replicas, 3 etcd replicas, and an HAProxy leader endpoint.
- **Metastore credentials secret**: A `dictionary` secret holding the bundled single-instance metastore's `username`, `password` and `database`, built by this template from `postgres.credentials.*` and handed to the Postgres subchart by name. Nothing for you to create. (Not rendered on the HA path — `postgres-highly-available` still makes its own.)
- **No volumeset**: The Polaris server writes nothing to local disk that must survive a restart.

## Prerequisites

Two Control Plane secrets **must exist before installing** (the deployment waits on them otherwise):

```bash
# Root principal credentials — what Trino, Spark and any Iceberg REST client authenticate with.
# Neither value may contain a comma.
cpln secret create-dictionary --name my-polaris-root-credentials \
  --entry CLIENT_ID=root --entry CLIENT_SECRET="$(openssl rand -hex 24)"

# Shared token signing key — every replica signs and validates access tokens with it.
printf '%s' "$(openssl rand -hex 32)" | \
  cpln secret create-opaque --name my-polaris-signing-key --encoding plain -f -
```

Optional:

- **Object storage credentials** for the bucket that holds your Iceberg data — see **Iceberg bucket setup** below.
- **Cloud account + bucket** only if you enable the Postgres backup pass-through (see **Storage setup**). With `postgres.backup.provider: minio` (single-instance mode) the endpoint's keys are a prerequisite dictionary secret instead — see that section.

**The metastore password is not a prerequisite** — it is bundled plumbing, so this template creates that secret for you from `postgres.credentials.*` (single-instance mode) or `postgres.credentials.*` (HA mode).

## Iceberg bucket setup

Skip this if you have no object storage yet — Polaris runs without it, and catalogs can be added later.

Polaris reads and writes table metadata in the bucket with static credentials (this version does not vend STS credentials), so the same dictionary secret works for every S3-compatible backend:

```bash
cpln secret create-dictionary --name my-polaris-s3-credentials \
  --entry AWS_ACCESS_KEY_ID=... --entry AWS_SECRET_ACCESS_KEY=...
```

Then set `storage.credentialsSecretName` to that name.

**SeaweedFS / MinIO (in-GVC)** — point `storage.credentialsSecretName` at the *same* secret your `seaweedfs` (`s3.credentialsSecretName`) or MinIO deployment already uses; there is nothing else to create. Use the workload's internal endpoint (`http://{release}-seaweedfs.{gvc}.cpln.local:8333`) with `pathStyleAccess: true` when creating the catalog.

**AWS S3** — create the bucket and an access key scoped to it:

1. Create the bucket (e.g. `my-polaris-bucket`) in the region you will use, block public access, and leave default encryption on.
2. Create an IAM user (or role with static keys) for Polaris and attach this bucket-scoped policy — Polaris needs no other permission:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": ["s3:ListBucket", "s3:GetBucketLocation"], "Resource": "arn:aws:s3:::my-polaris-bucket" },
    { "Effect": "Allow", "Action": ["s3:PutObject", "s3:GetObject", "s3:DeleteObject"], "Resource": "arn:aws:s3:::my-polaris-bucket/*" }
  ]
}
```

3. Create an access key for it and put both halves in the dictionary secret above, then set `storage.region` to the bucket's region.
4. Give your query engine the same (or a similarly scoped) key — with vending off, each engine authenticates to the bucket itself.

## Configuration

### Server

```yaml
image: apache/polaris:1.7.0

replicas: 1

resources:
  minCpu: 500m
  maxCpu: 1000m
  minMemory: 1Gi
  maxMemory: 2Gi # JVM heap is a percentage OF THIS — see jvm.maxRAMPercentage

jvm:
  maxRAMPercentage: 70 # max heap as a percentage of resources.maxMemory; allowed range 40–80
```

### Realm

```yaml
realm: POLARIS # PERMANENT after first install — renaming it bootstraps an empty realm
```

The `Polaris-Realm` header is not required: a header-less request resolves to this realm, which is what Trino's Iceberg REST connector needs (it cannot send an arbitrary header).

### Credentials

```yaml
rootCredentials:
  secretName: my-polaris-root-credentials # dictionary secret with CLIENT_ID and CLIENT_SECRET

tokenSigningKey:
  secretName: my-polaris-signing-key # opaque secret (encoding: plain), payload = 32+ random chars
```

### Object storage

```yaml
storage:
  credentialsSecretName: "" # e.g. my-seaweedfs-s3-credentials
  region: us-east-1 # AWS_REGION; S3-compatible servers ignore the value but the SDK requires one
```

These are the credentials Polaris uses for its **own** metadata I/O. Query engines keep their own copy — this version does not use STS credential vending.

### Bootstrap

```yaml
bootstrap:
  image: apache/polaris-admin-tool:1.7.0 # keep this tag in lockstep with `image`
  resources:
    minCpu: 100m
    maxCpu: 400m
    minMemory: 128Mi
    maxMemory: 1Gi
```

### Access

```yaml
publicAccess:
  enabled: false # true = Iceberg REST + management API on the auto *.cpln.app HTTPS endpoint

internalAccess:
  type: same-gvc # options: none, same-gvc, same-org, workload-list
  workloads: [] # used with workload-list
```

### Metastore

Exactly one of the two stores must be enabled (the chart enforces this at render).

```yaml
postgres: # default: single-instance PostgreSQL
  enabled: true
  credentials: # this template builds the metastore credential secret from these
    username: polaris
    password: change-me-polaris-db # change before installing
    database: polaris
  config:
    # name of the dictionary secret this template CREATES and Postgres reads;
    # secret names are org-wide; a second release on this name is refused at install
    credentialsSecretName: my-polaris-db-credentials
  resources:
    minCpu: 200m
    maxCpu: 500m
    minMemory: 256Mi
    maxMemory: 512Mi
  volumeset:
    capacity: 10 # initial capacity in GiB (minimum is 10)
  backup:
    enabled: false # true = scheduled DB backups to object storage
    provider: aws # options: aws, gcp, minio
    aws:
      bucket: my-polaris-backup-bucket
      region: us-east-1
      cloudAccountName: my-s3-cloud-account
      policyName: my-polaris-backup-policy
```

```yaml
postgres:
  enabled: false
postgresHA: # set postgresHA.enabled: true for near-zero-downtime upgrades and failover
  enabled: true
  config:
    credentialsSecretName: my-polaris-db-credentials # see Prerequisites — must exist before install
  replicas: 3
  volumeset:
    capacity: 10 # initial capacity in GiB per replica (minimum is 10)
  backup:
    enabled: false
    mode: logical # logical or wal-g
    provider: aws # options: aws, gcp, minio
```

Each Polaris replica opens up to 20 JDBC connections, plus the bootstrap workload — about 21 of Postgres's default 100 at `replicas: 1`, about 61 at `replicas: 3`.

## Connecting

| What | Value |
|---|---|
| Public URL (when `publicAccess.enabled`) | `status.canonicalEndpoint` from `cpln workload get {release}-polaris -o yaml` |
| Iceberg REST API | `{base}/api/catalog` |
| Management API | `{base}/api/management/v1` |
| OAuth2 token endpoint | `{base}/api/catalog/v1/oauth/tokens` |
| In-GVC (internal) | `http://{release}-polaris.{gvc}.cpln.local:8181` |
| Health and metrics | `http://{release}-polaris.{gvc}.cpln.local:8182/q/health`, `/q/metrics` — reachable in-GVC only |
| Credentials | `CLIENT_ID` / `CLIENT_SECRET` from your `rootCredentials` secret |

Only the **first declared container port is published** on the canonical endpoint, and this template declares `8181` first. That is what keeps `8182` — the unauthenticated Quarkus health and metrics interface — off the internet even with `publicAccess.enabled`: publicly, `/q/metrics`, `/q/health` and `/q/info` all return 404, while `:8182/q/metrics` answers in-GVC. The port order in the workload template is a security boundary, not cosmetics.

Every API call needs a bearer token:

```bash
curl -X POST https://{canonical-endpoint}/api/catalog/v1/oauth/tokens \
  --user "$CLIENT_ID:$CLIENT_SECRET" \
  -d grant_type=client_credentials -d scope=PRINCIPAL_ROLE:ALL
```

## Creating a catalog

Catalogs are a day-2 API call, not an install-time value. With `$TOKEN` from above and an S3-compatible bucket (`seaweedfs`, MinIO, AWS S3):

```bash
curl -X POST https://{canonical-endpoint}/api/management/v1/catalogs \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{
  "catalog": {
    "name": "lakehouse",
    "type": "INTERNAL",
    "properties": { "default-base-location": "s3://my-bucket/warehouse" },
    "storageConfigInfo": {
      "storageType": "S3",
      "allowedLocations": ["s3://my-bucket/warehouse"],
      "endpoint": "http://my-seaweedfs.my-gvc.cpln.local:8333",
      "endpointInternal": "http://my-seaweedfs.my-gvc.cpln.local:8333",
      "pathStyleAccess": true,
      "stsUnavailable": true,
      "region": "us-east-1"
    }
  }
}'

# Let the root principal administer the new catalog
curl -X PUT https://{canonical-endpoint}/api/management/v1/principal-roles/service_admin/catalog-roles/lakehouse \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"catalogRole":{"name":"catalog_admin"}}'
```

`pathStyleAccess: true` and `stsUnavailable: true` are what an S3-compatible server needs; drop `endpoint`/`endpointInternal`/`pathStyleAccess` for AWS S3 itself.

## Connecting Trino

Add this catalog to the `trino` template's values. Trino authenticates to Polaris with the root credentials and talks to the bucket with its own S3 keys — vending is off, so both sides hold static credentials:

```yaml
catalogs:
  - name: iceberg
    properties: |
      connector.name=iceberg
      iceberg.catalog.type=rest
      iceberg.rest-catalog.uri=http://my-polaris.my-gvc.cpln.local:8181/api/catalog
      iceberg.rest-catalog.security=OAUTH2
      iceberg.rest-catalog.oauth2.credential=${ENV:POLARIS_CLIENT_ID}:${ENV:POLARIS_CLIENT_SECRET}
      iceberg.rest-catalog.oauth2.scope=PRINCIPAL_ROLE:ALL
      iceberg.rest-catalog.warehouse=lakehouse
      iceberg.rest-catalog.vended-credentials-enabled=false
      fs.native-s3.enabled=true
      s3.endpoint=http://my-seaweedfs.my-gvc.cpln.local:8333
      s3.region=us-east-1
      s3.path-style-access=true
      s3.aws-access-key=${ENV:S3_ACCESS_KEY}
      s3.aws-secret-key=${ENV:S3_SECRET_KEY}
    secrets:
      - env: POLARIS_CLIENT_ID
        secretName: my-polaris-root-credentials
        secretKey: CLIENT_ID
      - env: POLARIS_CLIENT_SECRET
        secretName: my-polaris-root-credentials
        secretKey: CLIENT_SECRET
      - env: S3_ACCESS_KEY
        secretName: my-seaweedfs-s3-credentials
        secretKey: AWS_ACCESS_KEY_ID
      - env: S3_SECRET_KEY
        secretName: my-seaweedfs-s3-credentials
        secretKey: AWS_SECRET_ACCESS_KEY
```

Then `CREATE SCHEMA iceberg.demo`, `CREATE TABLE`, `INSERT` and `SELECT` work against tables stored in the bucket.

## Storage setup (only if you enable backups)

Backups are off by default and need no cloud account. To turn them on, set `<store>.backup.enabled: true` (where `<store>` is `postgres` or `postgresHA`) and configure a provider. The backup runs inside the backing Postgres store, so this is that template's setup.

**AWS S3** — create the bucket, a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account), and an IAM policy scoped to the bucket:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": ["s3:ListBucket"], "Resource": "arn:aws:s3:::my-polaris-backup-bucket" },
    { "Effect": "Allow", "Action": ["s3:PutObject","s3:GetObject","s3:DeleteObject"], "Resource": "arn:aws:s3:::my-polaris-backup-bucket/*" }
  ]
}
```

Then set `provider: aws` and `aws.{bucket,region,cloudAccountName,policyName}`.

**GCP Cloud Storage** — create the bucket and a cloud account, grant its service account **Storage Object Admin** (`roles/storage.objectAdmin`) on the bucket, then set `provider: gcp` and `gcp.{bucket,cloudAccountName}`.

**MinIO / S3-compatible** — set `provider: minio` and `minio.{endpoint,bucket}` (no cloud account needed; the keys authenticate directly). On both paths the keys are a prerequisite dictionary secret, named by `postgresHA.backup.minio.credentialsSecretName` or `postgres.backup.minio.credentialsSecretName`. The same secret serves either:

```bash
cpln secret create-dictionary --name my-polaris-minio-credentials \
  --entry accessKey=YOUR_ACCESS_KEY \
  --entry secretKey=YOUR_SECRET_KEY
```

## Important Notes

- **Create both prerequisite secrets before installing** — without them the workloads wait on a secret that does not exist and the install looks broken.
- **Expect a warm-up while the metastore comes up, and do not interrupt it.** The server restarts a couple of times logging `Failed to initialize DatasourceOperations` (measured: 2 restarts by 32 s) and the bootstrap workload retries on the same schedule; both self-heal. A default install is ready in about **90 s**; the `postgresHA` metastore takes about **6 minutes** (measured 348 s) before Polaris answers.
- **Scaling is real, and measured.** With `replicas: 2`, a request loop through the service DNS name saw **403/403 2xx (0 non-2xx) across a rolling `helm upgrade`** (rollout converged in 95 s) and **384/384 2xx (0 non-2xx) while scaling back to one replica** — because all replicas share the signing key and the metastore.
- **Root credentials are write-once.** They are applied when the realm is first bootstrapped; changing them afterwards has no effect. Rotate by creating a new principal through the management API.
- **Rotating `tokenSigningKey` invalidates every outstanding token** — clients must obtain a new one.
- **`realm` is permanent.** Renaming it bootstraps a new, empty realm and hides the existing catalogs; changing it back makes them visible again.
- **Change `postgres.credentials.password` before installing** — the default is a placeholder.
- **Upgrading from 1.0.x**: the single-instance metastore credentials moved from `postgres.config.username/password/database` to `postgres.credentials.username/password/database`, named by the new `postgres.config.credentialsSecretName`. Carrying the old keys fails the render with `config.username was REMOVED in postgres 3.4.0` — move the three keys and you are done. **Ignore that message's advice to create a secret yourself; this template creates it**, and the metastore password stays a value. `postgres.backup.minio.accessKey`/`secretKey` were removed the same way (see Storage setup). The HA path (`postgresHA.*`) and the `rootCredentials` / `tokenSigningKey` prerequisite secrets are all unchanged.
- **Give each polaris release its own `postgres.config.credentialsSecretName`** (single-instance mode only). Secret names are org-wide, so a second release left on the default name is **refused at install** — `The resource '…' cannot be updated because it is being managed by a different release` — and creates nothing. Nothing is shared or overwritten, and the first release is unaffected; you simply cannot install the second until you give it a distinct name.
- **Database volumes survive restarts, redeploys and upgrades; uninstalling deletes them** — every catalog definition is lost with them. Use `postgresHA` and/or the backup pass-through for production.
- **No credential vending in this version.** Polaris and each engine hold their own static object-storage credentials; keep `iceberg.rest-catalog.vended-credentials-enabled=false` in Trino.
- **Polaris does not migrate its own database schema** — treat a future Polaris version bump as an explicit schema step, not something boot handles.

## Links

- [Apache Polaris 1.7.0 documentation](https://polaris.apache.org/releases/1.7.0/)
- [Configuration reference](https://polaris.apache.org/releases/1.7.0/configuration/configuration-reference/)
- [Relational JDBC metastore](https://polaris.apache.org/releases/1.7.0/metastores/relational-jdbc/)
- [Admin tool (bootstrap)](https://polaris.apache.org/releases/1.7.0/admin-tool/)
- [Creating a catalog on S3](https://polaris.apache.org/releases/1.7.0/getting-started/creating-a-catalog/s3/)
- [Trino Iceberg REST catalog](https://trino.io/docs/483/object-storage/metastores.html)
