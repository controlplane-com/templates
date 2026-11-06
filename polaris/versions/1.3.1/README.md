# Apache Polaris

> **Upgrading from 1.2.1:** the metastore credentials are now a secret you create before upgrading,
> under a **new** name — see [Upgrading from 1.2.1](#upgrading-from-121).

This app deploys [Apache Polaris](https://polaris.apache.org/) — an Apache Iceberg **REST catalog** (Apache-2.0). It is the service that tells query engines which tables exist, where their metadata lives in object storage, and who may read them. Together with an S3-compatible bucket and a query engine such as the `trino` template, it turns a bucket of Parquet files into a lakehouse.

## Architecture

- **Polaris server**: Standard workload serving the Iceberg REST API and the management API on `8181`, and Quarkus health/metrics on `8182`. Stateless — a `replicas` knob scales it horizontally.
- **Bootstrap workload**: Runs the official `polaris-admin-tool` image once to create the realm schema and the root principal, then idles. Always one replica; the operation is idempotent, so restarts and upgrades re-run it harmlessly.
- **Bootstrap script secret**: The shell script the bootstrap workload runs (opaque secret, mounted as a file).
- **Two identities and two policies**: Least privilege — only the bootstrap principal can reveal the root credentials; only the server principal can reveal the token signing key and the object-storage credentials. Both can reveal your metastore credentials secret.
- **PostgreSQL (single-instance, default)**: The `postgres` template — every catalog, namespace, table pointer, principal and grant lives here.
- **PostgreSQL (HA, optional)**: The `postgres-highly-available` template instead — 3 Patroni replicas, 3 etcd replicas, and an HAProxy leader endpoint.
- **Metastore credentials secret** (dictionary) — *not created by this template*; you create it before install. The database initializes from it, and the Polaris server and bootstrap workload connect with it, in either metastore mode.
- **No volumeset**: The Polaris server writes nothing to local disk that must survive a restart.

## Prerequisites

Three Control Plane secrets **must exist before installing**. They hold credentials, so they are prerequisite secrets rather than values — a value would sit in plaintext in the Helm release for the life of the install.

```bash
# Metastore credentials — the bundled PostgreSQL initializes with these and Polaris connects with them.
cpln secret create-dictionary --name my-polaris-db-credentials \
  --entry username=polaris \
  --entry password="$(openssl rand -hex 24)" \
  --entry database=polaris

# Root principal credentials — what Trino, Spark and any Iceberg REST client authenticate with.
# Neither value may contain a comma.
cpln secret create-dictionary --name my-polaris-root-credentials \
  --entry CLIENT_ID=root --entry CLIENT_SECRET="$(openssl rand -hex 24)"

# Shared token signing key — every replica signs and validates access tokens with it.
printf '%s' "$(openssl rand -hex 32)" | \
  cpln secret create-opaque --name my-polaris-signing-key --encoding plain -f -
```

Set the metastore secret's name in the key of the store you use: `postgres.config.credentialsSecretName` (single-instance, the default) or `postgresHA.config.credentialsSecretName` (HA). Secret names are org-wide, so give each polaris release its own secret.

- **`database` must be URL-safe** (letters, digits, `_`): the JDBC URL is assembled from it at container start. The snippet's hex password needs no escaping either.
- **PostgreSQL reads the metastore secret only when its data is first initialized.** To change the password later, run `ALTER ROLE` first, then edit the secret (`cpln secret edit my-polaris-db-credentials`), then right away `cpln workload force-redeployment RELEASE_NAME-polaris --gvc GVC_NAME`, and wait until `get-deployments` shows a higher version number, alone and ready (right after the command the status may not show the restart yet, and `ready: true` alone can still describe the old replica). Do not redeploy the database: PostgreSQL reads the secret only when it is first initialized, so restarting it only adds downtime. Connections the app already has open keep working after `ALTER ROLE`; new ones fail until its redeploy finishes, so redeploy right away and rotate in a quiet window. In HA mode follow [Rotating the database password in HA mode](#rotating-the-database-password-in-ha-mode) instead. A running workload keeps the values it started with.

**If any of these secrets does not exist at install time the deployment wedges silently.** `cpln logs` returns zero lines — the container never starts, so there is nothing to log. The only diagnostic is `status.versions[].message` in `cpln workload get-deployments RELEASE_NAME-polaris --gvc GVC_NAME -o yaml` (note **`get-deployments`** — plain `cpln workload get` has no `versions` key); check `RELEASE_NAME-polaris-bootstrap` and `RELEASE_NAME-postgres` the same way. Create the missing secret and it can take up to about 12 minutes to serve again — poll rather than giving up — or clear it immediately with `cpln workload force-redeployment` on the waiting workload.

Optional:

- **Object storage credentials** for the bucket that holds your Iceberg data — see **Iceberg bucket setup** below.
- **Cloud account + bucket** only if you enable the Postgres backup pass-through (see **Storage setup**). With `postgres.backup.provider: minio` (single-instance mode) the endpoint's keys are a prerequisite dictionary secret instead — see that section.

## Iceberg bucket setup

Skip this if you have no object storage yet — Polaris runs without it, and catalogs can be added later.

Polaris reads and writes table metadata in the bucket with static credentials (this version does not vend STS credentials), so the same dictionary secret works for every S3-compatible backend:

```bash
cpln secret create-dictionary --name my-polaris-s3-credentials \
  --entry AWS_ACCESS_KEY_ID=... --entry AWS_SECRET_ACCESS_KEY=...
```

Then set `storage.credentialsSecretName` to that name.

**SeaweedFS (in-GVC)** — point `storage.credentialsSecretName` at the *same* secret your `seaweedfs` deployment uses (`s3.credentialsSecretName`, which already holds `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`); there is nothing else to create. Use its internal endpoint (`http://SEAWEEDFS_WORKLOAD_NAME.GVC_NAME.cpln.local:8333`) with `pathStyleAccess: true` when creating the catalog.

**MinIO (in-GVC)** — the `minio` template's credentials secret holds `username` / `password`, not the `AWS_*` keys Polaris reads, so create the dictionary above with those values (`AWS_ACCESS_KEY_ID=` the MinIO username, `AWS_SECRET_ACCESS_KEY=` its password). Its endpoint is `http://MINIO_WORKLOAD_NAME.GVC_NAME.cpln.local:9000`.

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
  config:
    credentialsSecretName: my-polaris-db-credentials # PREREQUISITE dictionary secret (username, password, database) — must exist BEFORE install
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
  image: controlplanecorporation/patroni-postgres:0.8 # pgvector 0.8.7; tags 0.1-0.7 are refused
  config:
    credentialsSecretName: my-polaris-db-credentials # PREREQUISITE dictionary secret (username, password, database) — must exist BEFORE install
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
| Public URL (when `publicAccess.enabled`) | `status.canonicalEndpoint` from `cpln workload get RELEASE_NAME-polaris --gvc GVC_NAME -o yaml` |
| Iceberg REST API | `{base}/api/catalog` |
| Management API | `{base}/api/management/v1` |
| OAuth2 token endpoint | `{base}/api/catalog/v1/oauth/tokens` |
| In-GVC (internal) | `http://RELEASE_NAME-polaris.GVC_NAME.cpln.local:8181` |
| Health and metrics | `http://RELEASE_NAME-polaris.GVC_NAME.cpln.local:8182/q/health`, `/q/metrics` — reachable in-GVC only |
| Credentials | `CLIENT_ID` / `CLIENT_SECRET` from your `rootCredentials` secret |
| Metastore credentials | the `username` / `password` / `database` keys of your secret named by `postgres.config.credentialsSecretName` (or `postgresHA.config.credentialsSecretName` in HA mode) — `cpln secret reveal SECRET_NAME -o yaml` |

With `publicAccess.enabled`, only port `8181` is served on the canonical endpoint; the unauthenticated Quarkus health and metrics interface on `8182` stays reachable in-GVC only.

Every API call needs a bearer token. `POLARIS_URL` below is the public base URL (`status.canonicalEndpoint`) or, from inside the GVC, the internal one:

```bash
curl -X POST "$POLARIS_URL/api/catalog/v1/oauth/tokens" \
  --user "$CLIENT_ID:$CLIENT_SECRET" \
  -d grant_type=client_credentials -d scope=PRINCIPAL_ROLE:ALL
```

## Creating a catalog

Catalogs are a day-2 API call, not an install-time value. With `$TOKEN` from above and an S3-compatible bucket (`seaweedfs`, MinIO, AWS S3):

```bash
curl -X POST "$POLARIS_URL/api/management/v1/catalogs" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{
  "catalog": {
    "name": "lakehouse",
    "type": "INTERNAL",
    "properties": { "default-base-location": "s3://my-bucket/warehouse" },
    "storageConfigInfo": {
      "storageType": "S3",
      "allowedLocations": ["s3://my-bucket/warehouse"],
      "endpoint": "http://SEAWEEDFS_WORKLOAD_NAME.GVC_NAME.cpln.local:8333",
      "endpointInternal": "http://SEAWEEDFS_WORKLOAD_NAME.GVC_NAME.cpln.local:8333",
      "pathStyleAccess": true,
      "stsUnavailable": true,
      "region": "us-east-1"
    }
  }
}'

# Let the root principal administer the new catalog
curl -X PUT "$POLARIS_URL/api/management/v1/principal-roles/service_admin/catalog-roles/lakehouse" \
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
      iceberg.rest-catalog.uri=http://RELEASE_NAME-polaris.GVC_NAME.cpln.local:8181/api/catalog
      iceberg.rest-catalog.security=OAUTH2
      iceberg.rest-catalog.oauth2.credential=${ENV:POLARIS_CLIENT_ID}:${ENV:POLARIS_CLIENT_SECRET}
      iceberg.rest-catalog.oauth2.scope=PRINCIPAL_ROLE:ALL
      iceberg.rest-catalog.warehouse=lakehouse
      iceberg.rest-catalog.vended-credentials-enabled=false
      fs.native-s3.enabled=true
      s3.endpoint=http://SEAWEEDFS_WORKLOAD_NAME.GVC_NAME.cpln.local:8333
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

**MinIO / S3-compatible** — set `provider: minio` and `minio.{endpoint,bucket}` (no cloud account needed; the keys authenticate directly). Replace the default endpoint with the full address, e.g. `http://MINIO_WORKLOAD_NAME.GVC_NAME.cpln.local:9000` for an in-GVC MinIO. On both paths the keys are a prerequisite dictionary secret, named by `postgresHA.backup.minio.credentialsSecretName` or `postgres.backup.minio.credentialsSecretName`. The same secret serves either:

```bash
cpln secret create-dictionary --name my-polaris-minio-credentials \
  --entry accessKey=YOUR_ACCESS_KEY \
  --entry secretKey=YOUR_SECRET_KEY
```

## Upgrading from 1.3.0 or earlier (HA mode)

1.3.1 runs the highly available database (`postgresHA`) on `controlplanecorporation/patroni-postgres:0.8`, which carries pgvector 0.8.7 (CVE-2026-103484); earlier versions ran `0.7`. The fix takes effect when the upgrade restarts the Patroni members, and existing data needs nothing. Nothing limits that rollout, so expect a brief interruption of writes while the leader changes. Polaris itself restarts without a gap (the new replica serves before the old one stops); while the leader changes, Polaris's token endpoint can briefly refuse requests. Upgrade in a quiet window. Polaris does not use the `vector` extension; if you created it yourself in a database, `\dx` keeps reporting the old version until you run `ALTER EXTENSION vector UPDATE;` there. If you set `postgresHA.image` in your values, set it to the `0.8` tag: tags `0.1` to `0.7` are refused at render. Single-instance installs (`postgres`) are unaffected.

## Upgrading from 1.2.1

`postgres.credentials` was removed: the metastore credentials are now a prerequisite secret, the same one the database templates require on their own. Carrying the old key forward fails the render.

1.2.1 created the metastore secret itself, so **this upgrade deletes it**. Before upgrading, create a secret under a **new** name holding the values your database was initialized with — not new ones, or Polaris loses its metastore connection:

```bash
cpln secret create-dictionary --name RELEASE_NAME-postgres-credentials \
  --entry username=polaris --entry password='YOUR_CURRENT_PASSWORD' --entry database=polaris
```

Your current values are in `postgres.credentials` of the 1.2.1 release, and also in the old secret (`cpln secret reveal my-polaris-db-credentials -o yaml`, or whatever name your release set) until the upgrade deletes it. Then upgrade with `postgres.config.credentialsSecretName` (single-instance mode) or `postgresHA.config.credentialsSecretName` (HA mode) set to the new name, and `postgres.credentials` removed.

The upgrade restarts the bundled PostgreSQL too (it now reads the new secret), so Polaris loses its database for about a minute and a half; it reconnects by itself. The new version of a workload can also wait about 10 minutes with `is not allowed to reveal the secret` in `get-deployments`, while access to the new secret propagates; the previous version keeps serving meanwhile, and it clears by itself. When that wait happens, the PostgreSQL restart (and its outage) comes only after it clears, about 10 minutes after the upgrade command returns.

## Upgrading from 1.2.0

With `postgresHA.backup.provider: minio`, `postgresHA.backup.minio.accessKey`/`secretKey` were replaced by `postgresHA.backup.minio.credentialsSecretName`; create that secret (see Storage setup). Then follow [Upgrading from 1.2.1](#upgrading-from-121).

## Upgrading from 1.1.x

The HA metastore moved to `postgres-highly-available` 2.5.0, which removed `postgresHA.postgres.*`. Put the username, password and database your HA cluster was **initialized with** into the metastore credentials secret under [Prerequisites](#prerequisites) — new values there do not change the database password, and Polaris can no longer log in — set `postgresHA.config.credentialsSecretName` to its name, and delete the `postgresHA.postgres` block. Single-instance installs follow [Upgrading from 1.2.1](#upgrading-from-121).

## Upgrading from 1.0.x

`postgres.config.username/password/database` were removed. Put the values your single-instance database was initialized with into the metastore credentials secret under [Prerequisites](#prerequisites), set `postgres.config.credentialsSecretName` to its name, and remove the three keys. With `postgres.backup.provider: minio`, `postgres.backup.minio.accessKey`/`secretKey` moved to a dictionary secret named by `postgres.backup.minio.credentialsSecretName` (see Storage setup). HA installs also follow [Upgrading from 1.1.x](#upgrading-from-11x).

## Rotating the database password in HA mode

The HA database (`postgresHA`) needs its own order. The replication role `repl` shares the password, and a member that restarts with the old password can be promoted to leader, which splits the cluster. Move the leader to member `-0` first, so it restarts last, after every other member already has the new password. `pgx` runs a command in one member (`LOCATION` is your GVC's location, `DB_USERNAME` the secret's `username`):

```bash
pgx() { cpln workload exec RELEASE_NAME-postgres-ha --gvc GVC_NAME --location LOCATION \
  --container patroni-postgres --replica "RELEASE_NAME-postgres-ha-$1" -- "${@:2}"; }
# 1. Find the leader ("role": "leader"); the other two must be "streaming" on the same "timeline"
pgx 0 curl -s localhost:8008/cluster
# 2. If the leader is not RELEASE_NAME-postgres-ha-0, move it there (N = current leader), then repeat step 1
pgx 0 curl -s -XPOST -d '{"leader":"RELEASE_NAME-postgres-ha-N","candidate":"RELEASE_NAME-postgres-ha-0"}' localhost:8008/switchover
# 3-5. Back to back: change BOTH roles on -0, put the same password in the secret, restart the members
pgx 0 psql -h 127.0.0.1 -d postgres -c "ALTER ROLE DB_USERNAME PASSWORD 'NEW_PASSWORD'; ALTER ROLE repl PASSWORD 'NEW_PASSWORD';"
cpln secret edit SECRET_NAME
cpln workload force-redeployment RELEASE_NAME-postgres-ha --gvc GVC_NAME
# 6. After ~5-7 minutes, confirm one leader and two "streaming" replicas on one timeline (repeat step 1)
# 7. Optional: remove the install-time password Patroni keeps in its cluster config
pgx 0 curl -s -XPATCH -d '{"postgresql":{"authentication":null}}' localhost:8008/config
```

Then force-redeploy `RELEASE_NAME-polaris`, which keeps the old password until it restarts. The database itself drops connections for roughly 10–60 s at each switchover, but the app cannot open new connections from the `ALTER ROLE` until its own redeploy finishes (several minutes in all), so rotate in a quiet window. If a member stays `starting`, or `running` without `streaming` for several minutes, re-copy it from the leader. This copies the whole database, so it costs network traffic in proportion to its size:

```bash
pgx N curl -s -XPOST -d '{"force": true}' localhost:8008/reinitialize
```

## Important Notes

- **Create all three prerequisite secrets before installing** — without them the workloads wait on a secret that does not exist, with zero log lines; see Prerequisites for how to diagnose it.
- **Expect a warm-up while the metastore comes up, and do not interrupt it.** The server may restart a few times and the bootstrap workload retries until PostgreSQL answers; both self-heal. The `postgresHA` metastore takes noticeably longer than the single instance.
- **Use `replicas: 2` or more for rolling upgrades without downtime** — all replicas share the signing key and the metastore, so a token or catalog from one is valid on every other.
- **Root credentials are write-once.** They are applied when the realm is first bootstrapped; changing them afterwards has no effect. Rotate by creating a new principal through the management API.
- **Rotating `tokenSigningKey` invalidates every outstanding token** — clients must obtain a new one.
- **`realm` is permanent.** Renaming it bootstraps a new, empty realm and hides the existing catalogs; changing it back makes them visible again.
- **Rotating the metastore password needs `ALTER ROLE` plus a forced redeployment** — PostgreSQL keeps the password it was initialized with, and a running workload keeps the values it started with (see Prerequisites).
- **Rotating the database password in HA mode needs a leader switchover first** — follow [Rotating the database password in HA mode](#rotating-the-database-password-in-ha-mode). A plain redeploy can promote a member still holding the old password and split the cluster.
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
