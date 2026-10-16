# Temporal

> **Upgrading from 2.0.0:** the database credentials are now a secret you create before upgrading,
> under a **new** name — see [Upgrading from 2.0.0](#upgrading-from-200).

> **Upgrading from 1.x:** Temporal upgrades one minor version at a time, so a 1.x release (server 1.29)
> steps through 1.30 and 1.31 before reaching this version's default 1.32. Follow
> [Upgrading from 1.x](#upgrading-from-1x). A direct upgrade with the defaults is refused before the
> database is touched.

This app deploys [Temporal](https://temporal.io/), an open-source (MIT) durable-execution platform for writing workflows that survive process crashes and outages. It runs the Temporal server (one replica by default, or a cluster of up to five) with its gRPC frontend and HTTP API, plus the Temporal Web UI, all internal-only by default (the UI can be opened to IP ranges you list), on a highly available PostgreSQL cluster by default. Database creation, schema migrations and the `default` namespace are handled automatically.

## Architecture

- **Temporal server**: `replicas` replicas (default 1), each running all four services (frontend, history, matching, worker) in one process; gRPC on 7233, HTTP API on 7243, internal-only. With more than one replica they form a single Temporal cluster. Stateless: all state lives in PostgreSQL.
- **`admin` sidecar** (in every server replica): creates the databases, migrates the schema (one replica at a time), refuses an upgrade that skips a minor version, creates the `default` namespace, then serves as an in-cluster `temporal` CLI.
- **Temporal Web UI** (optional, default on): serves the UI on port 8080, internal-only unless you list IP ranges in `ui.allowedCIDRs` (the UI has no built-in authentication).
- **PostgreSQL (HA, default)** (subchart): the `postgres-highly-available` template: 3 Patroni Postgres replicas, 3 etcd replicas, and an HAProxy leader endpoint Temporal connects through.
- **PostgreSQL (single-instance, optional)** (subchart): the `postgres` template instead, for lighter deployments.
- **Database credentials secret** (dictionary) — *not created by this template*; you create it before install. The bundled PostgreSQL initializes from it and Temporal connects with it, in either database mode.
- **Identity and policy**: the server identity may `reveal` exactly the database credentials secret; with archival on it is also bound to your AWS cloud account and the bucket-scoped IAM policy (no keys).
- **Server metrics**: each replica's Prometheus metrics (port 8000) are collected into the platform's built-in metrics.
- **Optional database backups** (subchart): logical dumps or WAL-G archiving to S3, GCS, or an S3-compatible endpoint.
- **Optional workflow archival** (`archival.enabled`): closed workflow histories and visibility records copied to an S3 bucket, reached keylessly through the server identity.

## Prerequisites

**A database credentials secret must exist BEFORE you install.** It holds credentials, so it is a prerequisite secret rather than values — a value would sit in plaintext in the Helm release for the life of the install. The bundled PostgreSQL initializes with these values and Temporal connects with them:

```bash
cpln secret create-dictionary --name my-temporal-db-credentials \
  --entry username=temporal \
  --entry password="$(openssl rand -hex 24)" \
  --entry database=temporal
```

- **`database` must be `temporal`.** The server reads its main store from the database named `temporal`, while PostgreSQL creates the one the secret names. With any other value both Temporal containers stop at boot and log `CPLN_TEMPORAL_DATABASE_GUARD`.
- Set its name in the key of the database mode you use: `postgresHA.config.credentialsSecretName` (HA, the default) or `postgres.config.credentialsSecretName` (single-instance). Secret names are org-wide, so give each Temporal release its own secret.
- PostgreSQL reads the secret only when its data is first initialized — see [Rotating the database password](#rotating-the-database-password).

**If the secret does not exist at install time the deployment wedges silently.** `cpln logs` returns zero lines — the containers never start, so there is nothing to log. The only diagnostic is `status.versions[].message` in `cpln workload get-deployments RELEASE_NAME-temporal --gvc GVC_NAME -o yaml` (note **`get-deployments`** — plain `cpln workload get` has no `versions` key). Create the missing secret and it recovers on its own, but it can take up to about 12 minutes to serve again — poll rather than giving up.

- For optional database backups: a bucket and access setup for one of the supported providers (see [Backup storage setup](#backup-storage-setup)).
- For optional archival: an S3 bucket, an AWS cloud account and a bucket-scoped IAM policy (see [Archival storage setup](#archival-storage-setup)).

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

historyShards: 512 # fixed at first install; a later change is ignored (the cluster keeps its original count)
namespaceRetention: 72h # retention of the `default` namespace, applied when it is first created
```

### Web UI

```yaml
ui:
  enabled: true # set false to remove the UI workload
  image: temporalio/ui:2.55.0
  allowedCIDRs: [] # IP ranges that may open the UI in a browser, e.g. [203.0.113.10/32]; empty = internal-only
  resources:
    maxCpu: 500m
    maxMemory: 512Mi
    minCpu: 125m
    minMemory: 128Mi
```

### Access

The server is never reachable from outside Control Plane: workers and clients run as workloads in your org. The Web UI is internal-only too, unless you list IP ranges in `ui.allowedCIDRs` (see [Connecting](#connecting)).

```yaml
internalAccess: # firewall scope for the server (gRPC :7233, HTTP API :7243, cluster ports) and the UI (:8080)
  type: same-gvc # none, same-gvc, same-org, workload-list
  workloads: [] # used with workload-list, e.g. //gvc/GVC_NAME/workload/WORKLOAD_NAME;
                # the server's own replicas and the Web UI are always allowed
```

### Archival

Archival keeps closed workflows readable after the namespace's retention deletes them. It is S3-only in this version (the local-file archiver is not offered: it would write to the replica's own short-lived disk), and needs Temporal server 1.31 or later: on a 1.x upgrade, turn it on after the hop to 1.31.

```yaml
archival:
  enabled: false # declares the S3 archiver and binds the identity to AWS; set true after the Archival storage setup steps
  defaultNamespace: true # archive the `default` namespace; set false to stop archiving it
  s3:
    bucket: my-temporal-archival-bucket # bare bucket name, no s3://
    region: us-east-1
    prefix: temporal # history goes under temporal/history, visibility under temporal/visibility
    cloudAccountName: my-s3-cloud-account # AWS cloud account; access is keyless
    policyName: my-temporal-archival-policy # AWS IAM policy scoped to the bucket
```

**To stop archiving, set `archival.defaultNamespace: false` and keep `archival.enabled: true`.** Never set `archival.enabled: false` once archival has been used: namespaces keep their `s3://` targets, every later update of `default` then fails with `unable to find archiver config`, the server retries archiving each closed workflow indefinitely, and archived workflows become unreadable. The identity keeps its AWS binding until the release is uninstalled.

With archival on, the `default` namespace archives to `s3://BUCKET/PREFIX/history` and `s3://BUCKET/PREFIX/visibility`, also when you turn it on for an existing install. A workflow appears in the archive a few minutes after it closes. Read it back from the `admin` container:

```bash
cpln workload exec RELEASE_NAME-temporal --gvc GVC_NAME --container admin -- temporal workflow list -n default --archived
cpln workload exec RELEASE_NAME-temporal --gvc GVC_NAME --container admin -- temporal workflow show -n default -w WORKFLOW_ID -r RUN_ID
```

Temporal never changes an archival target once it is enabled on a namespace: a later change to `bucket` or `prefix` applies only to namespaces that do not archive yet. Other namespaces you create can archive to the same bucket with `temporal operator namespace create … --history-archival-state enabled --history-uri s3://BUCKET/PREFIX/history --visibility-archival-state enabled --visibility-uri s3://BUCKET/PREFIX/visibility`.

### PostgreSQL

Exactly one of the two databases must be enabled (the chart enforces this at render).

```yaml
postgresHA: # default: highly available PostgreSQL
  enabled: true
  config:
    credentialsSecretName: my-temporal-db-credentials # PREREQUISITE dictionary secret (username, password, database=temporal) — must exist BEFORE install
  replicas: 3
  volumeset:
    capacity: 10 # GiB per replica
  backup:
    enabled: false # optional; see Backup storage setup
    mode: logical # logical or wal-g
    resources:
      cpu: 100m
      memory: 512Mi # 128Mi OOMKills wal-g mid-backup
```

```yaml
postgresHA:
  enabled: false
postgres: # dev/lightweight: single-instance PostgreSQL
  enabled: true
  config:
    credentialsSecretName: my-temporal-db-credentials # PREREQUISITE dictionary secret (username, password, database=temporal) — must exist BEFORE install
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

- **Losing a replica:** the other members notice within about 20 seconds and take over its share of workflows; the lost replica leaves service within about a minute and is replaced in about 4 to 5 minutes. Timers fire on time and nothing is lost; clients may see a few timed-out calls in the first minute.
- **Rolling upgrades and restarts with more than one replica take a while.** Replicas are replaced one at a time, about 8 to 10 minutes per roll at 3 replicas. A newly started replica's worker service may exit and restart a few times in its first minutes (upstream Temporal treats a slow internal start-up as fatal); in testing clients saw no errors and no workflow failed.
- **Changing the count** is a plain `helm upgrade` with the new `replicas`. It is a rolling restart of every server replica, not just an added or removed one: the per-replica connection pools are sized from `replicas`, so every replica is replaced with the new sizes. Members join or drain and the shards rebalance.
- **Changing `internalAccess` also restarts every server replica**, and the new firewall is fully in force only once the last replica has restarted.
- **Change `replicas` under light load.** While replicas with the old and the new pool sizes run side by side, the total can briefly exceed the database's 100 connections (going from 2 to 4 replicas reaches about 120).

## Connecting

| What | Value |
|---|---|
| gRPC frontend (workers and clients) | `RELEASE_NAME-temporal.GVC_NAME.cpln.local:7233` |
| HTTP API | `http://RELEASE_NAME-temporal.GVC_NAME.cpln.local:7243` (for example `/api/v1/namespaces/default`) |
| Namespace | `default` |
| Web UI in a browser (recommended) | List your address in `ui.allowedCIDRs`, then open the UI's canonical endpoint: `status.canonicalEndpoint` in `cpln workload get RELEASE_NAME-temporal-ui --gvc GVC_NAME -o yaml` |
| Web UI, quick checks | `cpln port-forward RELEASE_NAME-temporal-ui 8080:8080 --gvc GVC_NAME`, then `curl http://localhost:8080/healthz` |
| `temporal` CLI | `cpln workload exec RELEASE_NAME-temporal --gvc GVC_NAME --container admin -- temporal workflow list` |
| Postgres (HA mode) | `RELEASE_NAME-postgres-ha-proxy.GVC_NAME.cpln.local:5432`, credentials in your `postgresHA.config.credentialsSecretName` secret (`cpln secret reveal SECRET_NAME -o yaml`) |
| Postgres (single mode) | `RELEASE_NAME-postgres.GVC_NAME.cpln.local:5432`, credentials in your `postgres.config.credentialsSecretName` secret |

- **Always use the full `.cpln.local` name** in worker and client configuration; short workload names do not resolve.
- **Python workers must guard their entrypoint with `if __name__ == "__main__":`**: the Temporal Python SDK's workflow sandbox re-imports the worker module, and an unguarded module-level `main()` crashes the worker.
- `cpln port-forward` suits curl-level checks; a browser through it can stop loading pages after some navigation. For browser use, list your address in `ui.allowedCIDRs`.

## Upgrading from 2.0.0

`postgres.credentials` was removed: the database credentials are now a prerequisite secret, the same one the database templates require on their own. Carrying the old key forward fails the render.

2.0.0 created the database secret itself, so **this upgrade deletes it**. Before upgrading, create a secret under a **new** name holding the values your database was initialized with — not new ones, or Temporal loses its database connection. `database` stays `temporal`:

```bash
cpln secret reveal OLD_SECRET_NAME -o yaml   # the CURRENT values, until the upgrade deletes this secret
cpln secret create-dictionary --name RELEASE_NAME-postgres-credentials \
  --entry username=YOUR_CURRENT_USERNAME --entry password=YOUR_CURRENT_PASSWORD --entry database=temporal
```

`OLD_SECRET_NAME` is the `credentialsSecretName` of the mode you use in the 2.0.0 release (default `my-temporal-db-credentials`). Then upgrade with `postgresHA.config.credentialsSecretName` (HA mode) or `postgres.config.credentialsSecretName` (single-instance mode) set to the new name, and `postgres.credentials` removed. Your current values are also in `postgres.credentials` of the 2.0.0 release.

The upgrade restarts the bundled PostgreSQL too (it now reads the new secret), so Temporal can briefly lose its database; it reconnects by itself. The new version of a workload can also wait about 10 minutes with `is not allowed to reveal the secret` in `get-deployments`, while access to the new secret propagates; the previous version keeps serving meanwhile, and it clears by itself.

## Upgrading from 1.x

Temporal supports upgrading **one minor version at a time**, with about 10 minutes on each. A 1.x release runs Temporal 1.29.7, so it takes three upgrades. Do them at `replicas: 1`, and raise `replicas` only after the last one, so each step replaces a single replica.

1. **Back up first.** A migrated schema cannot be rolled back. If backups are not on yet, turn on `postgresHA.backup` (HA) or `postgres.backup` (single-instance) for your current release (see [Backup storage setup](#backup-storage-setup)). With logical backups, take one now and check that it reports success:

   ```bash
   cpln workload cron start RELEASE_NAME-postgres-ha-backup --gvc GVC_NAME   # HA mode
   cpln workload cron start RELEASE_NAME-postgres-backup --gvc GVC_NAME      # single mode
   cpln workload cron get RELEASE_NAME-postgres-ha-backup --gvc GVC_NAME     # the run must show Successful
   ```

   With WAL-G backups, wait for a base backup (`Backup complete` in the leader's `wal-g-backup` container logs). Restoring follows the bundled database template's procedure: [postgres-highly-available](https://docs.controlplane.com/template-catalog/templates/postgres-highly-available#restoring-a-backup) or [postgres](https://docs.controlplane.com/template-catalog/templates/postgres#restoring-a-backup); it has not been tested as part of this template. Volume set snapshots are **not** a supported recovery path for the HA database: restoring them onto a running Patroni cluster does not bring the database back.

2. **Upgrade to 2.0.0 on Temporal 1.30** (with your existing values file):

   ```bash
   cpln helm upgrade RELEASE_NAME oci://ghcr.io/controlplane-com/templates/temporal --version 2.0.0 --gvc GVC_NAME \
     -f values.yaml --set image=temporalio/server:1.30.8 --set adminTools.image=temporalio/admin-tools:1.30.8
   ```

   If your values file sets `image: temporalio/auto-setup:…`, delete that line now: the last step uses the chart default, and the chart refuses an auto-setup image.

   On the HA database, this first upgrade also updates the bundled PostgreSQL cluster, which restarts every member and fails the leader over: expect about 2.5 minutes in which Temporal cannot reach its database, after the schema step has finished. Workflows resume afterwards; plan this step in a maintenance window. The later steps, and the single-instance database, have no such outage.
3. **Wait** until the server is ready, then about 10 more minutes.
4. **Upgrade to 1.31:** the same command with `1.31.4` in both `--set`s.
5. **Upgrade to 1.32:** the same command without the two `--set`s (the chart defaults are 1.32.1).
6. **Upgrade to this version** following [Upgrading from 2.0.0](#upgrading-from-200).

Each step migrates the schema before the new server starts. A step that skips a minor version is refused before the database is touched: the new replica never becomes ready, and its `admin` container logs `CPLN_TEMPORAL_SKIP_GUARD` with the tag to use next. Set the right tag and upgrade again.

Also in this version:

- **AWS backups:** the HA backup no longer attaches AWS's `ReadOnlyAccess` policy. Update your bucket-scoped IAM policy to the full action list under [AWS S3](#aws-s3) before upgrading.
- **Temporal 1.32 visibility queries are stricter:** a list filter that compares a search attribute with the wrong type, or an empty `Text` filter, now returns an error instead of results.
- **Older releases:** 1.0.x moved `postgres.config.{username,password,database}` to `postgres.credentials.*` (1.1.0); 1.1.x moved `postgresHA.postgres.*` to `postgres.credentials.*` (1.2.0) and MinIO keys to `postgresHA.backup.minio.credentialsSecretName` / `postgres.backup.minio.credentialsSecretName` (1.2.1, a dictionary secret with `accessKey` and `secretKey`); 1.2.x renamed `resources.cpu`/`memory` to `maxCpu`/`maxMemory` (1.3.0, also under `ui.resources`). Keep your existing password values unchanged when you move them: the database keeps the password it was initialised with.

## Archival storage setup

Only needed when `archival.enabled` is true. Complete these steps before turning it on.

1. Create an S3 bucket. Set `archival.s3.bucket` and `archival.s3.region`.
2. If you do not have one, create a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account) for your AWS account. Set `archival.s3.cloudAccountName`.
3. Create an AWS IAM policy with the JSON below (replace `YOUR_BUCKET` and `YOUR_PREFIX`, the value of `archival.s3.prefix`), then set `archival.s3.policyName` to the policy's name. The server lists the bucket and writes and reads archives under the prefix; it never deletes from it.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": ["s3:ListBucket"], "Resource": ["arn:aws:s3:::YOUR_BUCKET"] },
    { "Effect": "Allow", "Action": ["s3:PutObject", "s3:GetObject"], "Resource": ["arn:aws:s3:::YOUR_BUCKET/YOUR_PREFIX/*"] }
  ]
}
```

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
3. Grant the cloud account's GCP service account the **Storage Admin** role on the bucket.

### S3-compatible (MinIO, R2, Wasabi, …)

1. Create your bucket on the server. Set `backup.minio.bucket`.
2. Set `backup.minio.endpoint` to the S3 API address including port. For the `minio` marketplace template in the same GVC, this is `http://WORKLOAD_NAME.GVC_NAME.cpln.local:9000`.
3. Create a dictionary secret with the access keys and name it in `postgresHA.backup.minio.credentialsSecretName` (HA) or `postgres.backup.minio.credentialsSecretName` (single-instance):

   ```bash
   cpln secret create-dictionary --name my-temporal-minio-credentials \
     --entry accessKey=ACCESS_KEY \
     --entry secretKey=SECRET_KEY
   ```

## Rotating the database password

PostgreSQL keeps the password it was initialized with, and a running workload keeps the values it started with, so a rotation takes four steps in order (single-instance; in HA mode follow [Rotating the database password in HA mode](#rotating-the-database-password-in-ha-mode) instead):

1. Change it in the database: `ALTER ROLE DB_USERNAME PASSWORD 'NEW_PASSWORD';` (connected as that user, from inside the GVC).
2. Update the secret: `cpln secret edit SECRET_NAME`. Keep `database` at `temporal`.
3. Redeploy the database and wait for it to be ready: `cpln workload force-redeployment RELEASE_NAME-postgres --gvc GVC_NAME`. Wait until `get-deployments` no longer shows `will be restarted shortly`; `ready: true` alone can still describe the old replica.
4. Redeploy Temporal: `cpln workload force-redeployment RELEASE_NAME-temporal --gvc GVC_NAME`.

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

Then force-redeploy `RELEASE_NAME-temporal`, which keeps the old password until it restarts. The database itself drops connections for roughly 10–60 s at each switchover, but the app cannot open new connections from the `ALTER ROLE` until its own redeploy finishes (several minutes in all), so rotate in a quiet window. If a member stays `starting`, or `running` without `streaming` for several minutes, re-copy it from the leader. This copies the whole database, so it costs network traffic in proportion to its size:

```bash
pgx N curl -s -XPOST -d '{"force": true}' localhost:8008/reinitialize
```

## Important Notes

- **Create the database credentials secret before installing**, with `database` set to `temporal`. A missing secret leaves the workload waiting with zero log lines — see Prerequisites for how to diagnose it.
- **Rotating the database password needs `ALTER ROLE` plus forced redeployments** — see [Rotating the database password](#rotating-the-database-password); editing the secret alone changes nothing.
- **`historyShards` is permanent**: it is fixed at the cluster's first boot, and a later change is ignored (the server keeps the original count and only logs the mismatch). 512 suits most deployments.
- **The Web UI has no login**: anyone who can reach it can view and act on every workflow. List only addresses you trust in `ui.allowedCIDRs` (whole-internet ranges are refused), and allow up to a few minutes for a change to apply.
- **A replica that stays not ready:** read its `admin` container's logs. "another replica is migrating the schema" is normal during an upgrade with several replicas; `CPLN_TEMPORAL_SKIP_GUARD` means the image skips a minor version; `CPLN_TEMPORAL_DATABASE_GUARD` means the credentials secret's `database` key is not `temporal` (fix it, then force a redeployment).
- **Features that need no configuration:** Nexus endpoints that target a namespace and task queue in this Temporal cluster (create them with `temporal operator nexus endpoint create` or the UI's Nexus page); endpoints that target an external URL are not supported. Worker Deployments (versioning) work; the UI's worker list relies on worker heartbeats, which need a recent SDK.
- **Keep the GVC to one location.** Each location would run its own servers against its own database.
- **Uninstall deletes the database volumesets**, with all workflow histories. Enable backups if the data matters.
- **Rotating the database password in HA mode needs a leader switchover first** — follow [Rotating the database password in HA mode](#rotating-the-database-password-in-ha-mode). A plain redeploy can promote a member still holding the old password and split the cluster.

## Links

- [Temporal documentation](https://docs.temporal.io/)
- [Upgrading a self-hosted Temporal Service](https://docs.temporal.io/self-hosted-guide/upgrade-server)
- [SDKs](https://docs.temporal.io/develop)
- [Namespaces and retention](https://docs.temporal.io/namespaces)
- [Web UI](https://docs.temporal.io/web-ui)
