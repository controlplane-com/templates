# Temporal

> **Upgrading from 2.x:** the default HA database upgrades in place and keeps PostgreSQL 17; a single-instance
> database needs `postgres.image: postgres:18` in your values — see [Upgrading from 2.x](#upgrading-from-2x).
>
> **Upgrading from 2.1.0 or earlier:** the HA database moves to patroni-postgres 0.8 (pgvector 0.8.7) — see
> [Upgrading from 2.1.0 or earlier](#upgrading-from-210-or-earlier).
>
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
- **PostgreSQL (HA, default)** (subchart): the `postgres-highly-available` template (PostgreSQL 18 for new clusters): 3 Patroni Postgres replicas, 3 etcd replicas, and an HAProxy leader endpoint Temporal connects through.
- **PostgreSQL (single-instance, optional)** (subchart): the `postgres` template (PostgreSQL 19) instead, for lighter deployments. A boot guard refuses to start the server on a data directory of another PostgreSQL major and leaves it untouched.
- **Two databases** in either mode: `temporal` (workflow state, histories and task queues) and `temporal_visibility` (the index behind workflow lists and queries), both created by the `admin` sidecar.
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
  image: controlplanecorporation/patroni-postgres:0.9 # PostgreSQL 18 for new clusters (bundles 14-18); tags 0.1-0.7 are refused
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
  image: postgres:19 # a release from an earlier version of this chart keeps postgres:18 (see Upgrading from 2.x)
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

## Upgrading from 2.x

**HA mode (the default)** moves to the `postgres-highly-available` 3.0.0 template. New clusters run PostgreSQL 18; an existing cluster keeps PostgreSQL 17 in place, because the new image (`controlplanecorporation/patroni-postgres:0.9`) bundles PostgreSQL 14 to 18 and each member runs the version of its data directory. The upgrade needs no pin. What changes:

- The database members restart one after another onto the new image (and the latest 17 minor release), so the Temporal API is briefly unavailable while the leader changes; running workflows and schedules continue.
- If your values set `postgresHA.image`, use the `0.9` tag (`0.8` also keeps a 17 cluster running); tags `0.1` to `0.7` are refused at render.
- The default logical backup image moves to `postgres-backup:18.2.0`, which backs up 17 and 18 clusters.
- The backup identity no longer carries `aws::ReadOnlyAccess`. With AWS backups, **check that your IAM policy grants the action list in [AWS S3](#aws-s3) before upgrading.**
- With archival on, the server identity no longer attaches `cpln-connector`; it uses only your bucket-scoped IAM policy.

To move an existing HA cluster to PostgreSQL 18, copy both Temporal databases into a new release: see [Moving the data to a new release](#moving-the-data-to-a-new-release) below.

**Single-instance mode** (`postgres.enabled: true`) now installs PostgreSQL 19, while a 2.x release's database is PostgreSQL 18. A data directory only opens with its own major, and the chart never converts it in place: before PostgreSQL starts, a guard compares the two, and on a mismatch it does not start the server and changes nothing on the volume. `cpln workload get-deployments RELEASE_NAME-postgres --gvc GVC_NAME` then stays not ready, and the logs repeat `[pg-guard] REFUSING TO START` every 30 seconds:

```bash
cpln logs '{gvc="GVC_NAME", workload="RELEASE_NAME-postgres"} |= "pg-guard"' --since 15m
```

**Stay on PostgreSQL 18:** upgrade with the image pinned, and keep `postgres.image: postgres:18` in your values file for every later upgrade (`cpln helm upgrade` does not reuse the installed values). The Console upgrade wizard keeps the installed image for you.

```bash
cpln helm upgrade RELEASE_NAME CHART --gvc GVC_NAME -f my-values.yaml --set postgres.image=postgres:18
```

To move a single-instance database to PostgreSQL 19, use the same procedure.

### Moving the data to a new release

Temporal keeps everything in two databases, `temporal` and `temporal_visibility`, and both must be copied. The new release gets a new endpoint, so workers and clients move to `NEW_RELEASE-temporal.GVC_NAME.cpln.local:7233`. The Temporal API is down during the copy; running workflows, timers and schedules continue from where they were afterwards.

1. **Install this version as a NEW release** in the same GVC and database mode, with the same values as the old one: the same `historyShards` (the copied data keeps its shard count) and the same database credentials secret (`postgresHA.config.credentialsSecretName` or `postgres.config.credentialsSecretName`). In single-instance mode leave `postgres.image` at the default `postgres:19`; in HA mode leave `postgresHA.image` at the `0.9` default. With WAL-G backups, give the new release a different `backup.*.prefix`.
2. **Once `NEW_RELEASE-temporal` is ready, stop both servers**, so nothing writes to either database: `cpln workload stop NEW_RELEASE-temporal --gvc GVC_NAME` and `cpln workload stop OLD_RELEASE-temporal --gvc GVC_NAME`.
3. **Replace the new release's empty databases with copies of the old ones.** Single-instance mode, from inside the new PostgreSQL container:

   ```bash
   cpln workload exec NEW_RELEASE-postgres --gvc GVC_NAME --container postgresql -- bash -c \
     'export PGPASSWORD="$POSTGRES_PASSWORD"
      for db in temporal temporal_visibility; do
        psql -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 -q \
          -c "DROP DATABASE \"$db\" WITH (FORCE)" -c "CREATE DATABASE \"$db\" OWNER \"$POSTGRES_USER\"" &&
        pg_dump -h OLD_RELEASE-postgres.GVC_NAME.cpln.local -U "$POSTGRES_USER" -d "$db" |
          psql -U "$POSTGRES_USER" -d "$db" -v ON_ERROR_STOP=1 -q >/dev/null || exit 1
      done
      echo COPIED'
   ```

   HA mode, from inside a new Patroni member, through both releases' HAProxy endpoints:

   ```bash
   cpln workload exec NEW_RELEASE-postgres-ha --gvc GVC_NAME --container patroni-postgres -- bash -c \
     'N=NEW_RELEASE-postgres-ha-proxy.GVC_NAME.cpln.local; O=OLD_RELEASE-postgres-ha-proxy.GVC_NAME.cpln.local
      for db in temporal temporal_visibility; do
        psql -h "$N" -d postgres -v ON_ERROR_STOP=1 -q \
          -c "DROP DATABASE \"$db\" WITH (FORCE)" -c "CREATE DATABASE \"$db\"" &&
        pg_dump -h "$O" -d "$db" | psql -h "$N" -d "$db" -v ON_ERROR_STOP=1 -q >/dev/null || exit 1
      done
      echo COPIED'
   ```

   Both print `COPIED` once the two databases are in. On an error they stop at once; run the command again, as it starts each database over.
4. **Start the new server** (`cpln workload start NEW_RELEASE-temporal --gvc GVC_NAME`). Once it is ready, check that your workflows came across:

   ```bash
   cpln workload exec NEW_RELEASE-temporal --gvc GVC_NAME --container admin -- temporal workflow list -n default
   ```

5. **Point your workers and clients at `NEW_RELEASE-temporal.GVC_NAME.cpln.local:7233`.** Then uninstall the old release; this deletes its volumes, so take a backup of it first if you want one to fall back on.

## Upgrading from 2.1.0 or earlier

2.1.1 moves the HA database to `controlplanecorporation/patroni-postgres:0.8`, which carries pgvector 0.8.7 (CVE-2026-103484). The fix takes effect when the upgrade restarts the Patroni members; existing data needs nothing. Nothing limits that rollout, so expect a brief interruption of writes while the leader changes. Temporal itself restarts without a gap, but its API is briefly unavailable while the database leader changes; running workflows and schedules continue. Upgrade in a quiet window. If you pinned `postgresHA.image`, set it to the `0.9` tag: tags `0.1` to `0.7` are refused at render. Temporal does not use the `vector` extension; if you created it yourself in a database, run `ALTER EXTENSION vector UPDATE;` there, which only updates the version `\dx` reports. 2.1.1 left single-instance mode unchanged; for 3.0.0 see [Upgrading from 2.x](#upgrading-from-2x).

## Upgrading from 2.0.0

`postgres.credentials` was removed: the database credentials are now a prerequisite secret, the same one the database templates require on their own. Carrying the old key forward fails the render.

2.0.0 created the database secret itself, so **this upgrade deletes it**. Before upgrading, create a secret under a **new** name holding the values your database was initialized with — not new ones, or Temporal loses its database connection. `database` stays `temporal`:

```bash
cpln secret reveal OLD_SECRET_NAME -o yaml   # the CURRENT values, until the upgrade deletes this secret
cpln secret create-dictionary --name RELEASE_NAME-postgres-credentials \
  --entry username='YOUR_CURRENT_USERNAME' --entry password='YOUR_CURRENT_PASSWORD' --entry database=temporal
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
6. **Upgrade to this version** following [Upgrading from 2.0.0](#upgrading-from-200) and [Upgrading from 2.x](#upgrading-from-2x).

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

### Backup retention

The backup job only uploads; it never deletes old backups. To keep a fixed window, add a lifecycle rule on the bucket that expires objects under the backup prefix. Each backup is a complete, standalone copy, so expiring old ones never affects restoring a newer one. Set the window to at least your retention plus one backup interval, and note that an age rule keeps no minimum: if backups stop running, the last ones expire too.

In `wal-g` mode (`postgresHA.backup.mode: wal-g`), a restore needs the newest full base backup plus the WAL files written after it, all under the same prefix and never rewritten. Older base backups and the WAL before them are not needed, so the same rule is safe as long as the window is longer than two base-backup intervals (`postgresHA.backup.walg.intervalSeconds`). If base backups stop while WAL archiving continues, the rule eventually expires the last base backup, so check that new `basebackups_005/` entries keep appearing.

The rules below use the default prefix `postgres/backups/`; change it if you changed `postgres.backup.<provider>.prefix` (or `postgresHA.backup.<provider>.prefix` in HA mode).

**AWS S3.** `put-bucket-lifecycle-configuration` **replaces every existing rule on the bucket**, so check for existing rules first and add them to the file:

```bash
aws s3api get-bucket-lifecycle-configuration --bucket BUCKET_NAME
cat > lifecycle.json <<'EOF'
{"Rules":[{"ID":"expire-db-backups","Filter":{"Prefix":"postgres/backups/"},"Status":"Enabled",
  "Expiration":{"Days":30},"NoncurrentVersionExpiration":{"NoncurrentDays":1}}]}
EOF
aws s3api put-bucket-lifecycle-configuration --bucket BUCKET_NAME --lifecycle-configuration file://lifecycle.json
```

**Google Cloud Storage.** `--lifecycle-file` also **replaces the bucket's existing rules**; check with `gcloud storage buckets describe gs://BUCKET_NAME --format='json(lifecycle_config)'` first:

```bash
cat > lifecycle.json <<'EOF'
{"rule":[
  {"action":{"type":"Delete"},"condition":{"age":30,"matchesPrefix":["postgres/backups/"]}},
  {"action":{"type":"Delete"},"condition":{"daysSinceNoncurrentTime":1,"isLive":false,"matchesPrefix":["postgres/backups/"]}}]}
EOF
gcloud storage buckets update gs://BUCKET_NAME --lifecycle-file=lifecycle.json
```

**MinIO** (adds a rule alongside existing ones; the access key needs `s3:PutLifecycleConfiguration`, which the built-in `readwrite` policy grants):

```bash
mc ilm rule add --expire-days 30 --noncurrent-expire-days 1 --prefix "postgres/backups/" ALIAS/BUCKET_NAME
mc ilm rule ls ALIAS/BUCKET_NAME
```

Lifecycle rules run in the background; objects are removed within about a day of reaching the age. The `Noncurrent` parts matter only on a versioned bucket, where expiry otherwise just adds a delete marker.

## Rotating the database password

PostgreSQL keeps the password it was initialized with, and a running workload keeps the values it started with, so a rotation takes three steps in order (single-instance; in HA mode follow [Rotating the database password in HA mode](#rotating-the-database-password-in-ha-mode) instead):

1. Change it in the database: `ALTER ROLE DB_USERNAME PASSWORD 'NEW_PASSWORD';` (connected as that user, from inside the GVC).
2. Update the secret: `cpln secret edit SECRET_NAME`. Keep `database` at `temporal`.
3. Right away, redeploy Temporal: `cpln workload force-redeployment RELEASE_NAME-temporal --gvc GVC_NAME`, and wait until `get-deployments` shows a higher version number, alone and ready (right after the command the status may not show the restart yet, and `ready: true` alone can still describe the old replica). Do not redeploy the database: PostgreSQL reads the secret only when it is first initialized, so restarting it only adds downtime.

Temporal keeps serving on the database connections it already has open, so this order had no failed requests in testing. Do step 3 right away: if those connections drop before Temporal restarts, it cannot open new ones.

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

- **3.0.0 moves new databases to PostgreSQL 18 (HA, the default) and 19 (single-instance).** An existing HA cluster keeps PostgreSQL 17 with no action. A single-instance release from 2.x keeps PostgreSQL 18 only with `postgres.image: postgres:18` in its values; without it the database refuses to start and leaves the data untouched. See [Upgrading from 2.x](#upgrading-from-2x).
- **Create the database credentials secret before installing**, with `database` set to `temporal`. A missing secret leaves the workload waiting with zero log lines — see Prerequisites for how to diagnose it.
- **Rotating the database password needs `ALTER ROLE` plus a forced redeployment of Temporal** — see [Rotating the database password](#rotating-the-database-password); editing the secret alone changes nothing.
- **`historyShards` is permanent**: it is fixed at the cluster's first boot, and a later change is ignored (the server keeps the original count and only logs the mismatch). 512 suits most deployments.
- **The Web UI has no login**: anyone who can reach it can view and act on every workflow. List only addresses you trust in `ui.allowedCIDRs` (whole-internet ranges are refused), and allow up to a few minutes for a change to apply.
- **A replica that stays not ready:** read its `admin` container's logs. "another replica is migrating the schema" is normal during an upgrade with several replicas; `CPLN_TEMPORAL_SKIP_GUARD` means the image skips a minor version; `CPLN_TEMPORAL_DATABASE_GUARD` means the credentials secret's `database` key is not `temporal` (fix it, then force a redeployment; the database PostgreSQL created under the wrong name is unused and can be dropped).
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
