# TiDB

TiDB is a distributed, MySQL-compatible SQL database that scales horizontally and keeps serving
through node loss. This template deploys the three tiers — PD (metadata and placement), TiKV
(storage) and tidb-server (the MySQL front door) — with optional scheduled backups to S3 or GCS.
From 2.0.0 the chart deploys into the GVC you install into and creates none of its own.

## Architecture

- **Stateful PD workload** (`RELEASE_NAME-pd`) — the placement driver quorum, `pdReplicas` members spread across `locations`, each individually addressable via `replicaDirect`.
- **Stateful TiKV workload** (`RELEASE_NAME-tikv`) — the storage nodes; `locations[].tikvReplicas` per location, each with its own persistent volume.
- **TiDB server workload** (`RELEASE_NAME-server`) — the MySQL-compatible SQL layer on port 4000; `locations[].serverReplicas` per location.
- **DB init workload** *(optional, on by default)* — a backstop job that sets the root password and creates the application database and user if they are missing. On a fresh 2.2.0 install the first TiDB server already does this while the cluster bootstraps, before it accepts any connection, so root is never reachable without a password. Turn the job off after the first deploy.
- **Volume sets** — PD and TiKV storage, snapshotted daily (03:00 UTC) and kept for 7 days by default.
- **Secrets** — the PD, TiKV and tidb-server startup scripts, plus the init job's script.
- **Identity and two policies** — `reveal` on this release's secrets and the credentials secret you create, `view` on the one GVC you install into so PD can confirm at boot that the GVC really has every location you listed, and cloud storage access when backups are on.
- **Backup cron workload** *(optional)* — TiDB's `br` writing a full cluster snapshot to S3 or GCS, unsuspended in exactly one location.
- **ProxySQL workload** *(optional, off by default)* — a connection pooler in every location, in front of the TiDB servers.

This template does **not** create a GVC. Every resource lands in the GVC you pass to `--gvc`, so
`cpln workload exec`, `cpln logs` and `cpln helm uninstall` all work against that GVC, and
uninstalling can never delete it.

## Prerequisites

**A GVC must already exist, and it must contain every location you list in `locations`.**
The requirement is one-directional: the GVC may have *more* locations than you list — nothing
TiDB-related runs in those. Check what a GVC has before you install:

```bash
cpln gvc get GVC_NAME -o json
```

The locations are under `spec.staticPlacement.locationLinks`. If you list a location the GVC does
not have, `helm install` still succeeds — the platform does not validate it — and PD then refuses to
bootstrap with a named error in `cpln logs`:

```
[tidb-pd] FATAL: locations declared in values are not in GVC 'my-gvc': aws-us-west-2
```

That refusal applies only to a PD member with an empty data directory. A member that already has
data logs a WARNING and keeps serving instead, so the check can never take a live cluster down.

**One `dictionary` secret must exist BEFORE you install** (whenever `autoCreateDatabase.enabled`).
These are the credentials you put in every application's connection string, so they are not values —
putting them in values would leave them in the Helm release.

```bash
cpln secret create-dictionary --name my-tidb-credentials \
  --entry rootPassword='YOUR-ROOT-PASSWORD' \
  --entry user=myuser \
  --entry password='YOUR-STRONG-PASSWORD' \
  --entry db=mydb
```

Set `autoCreateDatabase.credentialsSecretName` to the name you used. Secret names are
organization-wide, so give each release its own. `user` must be 1–32 characters and `db` 1–64
characters (not ending in a space); the TiDB servers refuse to start otherwise, naming the key.

**If the secret does not exist at install time, the deployment wedges silently.** `cpln logs`
returns **zero lines** — the container never starts, so it has nothing to log. Read
`status.versions[].message` instead:

```bash
cpln workload get-deployments RELEASE_NAME-server --gvc GVC_NAME -o yaml
```

Note this is `get-deployments` — plain `cpln workload get` has no `versions` field. Creating the
secret repairs the deployment on its own in roughly 5.5 to 10.5 minutes, or force a redeployment to
skip the wait.

Backups additionally need a bucket and a Control Plane
[cloud account](https://docs.controlplane.com/guides/create-cloud-account) — see [Backing Up](#backing-up).

## Upgrading from 2.1.0

An in-place `helm upgrade` with your existing values; nothing about how clients connect changes.
**Every workload restarts once** — any chart version upgrade does, because the platform restarts a
workload when its template-version tag changes. Stateful tiers restart one replica at a time within
a location but every location at once, so with one PD member and one TiKV node per location, writes
pause for about 75 s (measured): run the upgrade in a quiet period, with clients that retry. Also:

- **Volume snapshots start.** Every PD and TiKV volume is snapshotted daily at 03:00 UTC and kept for
  7 days (2.1.0 declared the retention but never scheduled a snapshot). Set
  `volumeset.tikv.snapshots.schedule` and `volumeset.pd.snapshots.schedule` to `""` to keep them off.
- **ProxySQL accepts credentials containing `'`.** 2.1.0 silently loaded no users from them.
- **The db-init job runs in one location only** (2.1.0 ran it in every GVC location).

Root's password is now set by the first TiDB server at bootstrap; that only affects new clusters —
an existing cluster keeps the password it has. Before upgrading, check that root refuses an empty
password (`mysql -u root` with no password must fail). If it connects, keep
`autoCreateDatabase.deployInitWorkload: true` for the upgrade: each new TiDB server waits about
2 minutes before serving, logs a warning, and the init job then sets the password.

## Upgrading from 2.0.0

In each `locations` entry, replace `replicas: N` with `tikvReplicas: N` and `serverReplicas: N` to
keep your current shape exactly. The chart refuses to render while a location still sets `replicas`,
so an upgrade with your old values file fails before touching anything.

The upgrade restarts PD, TiKV and the TiDB servers. Replicas in the same location restart one at a
time; separate locations restart at the same time, so on a one-PD-per-location install writes pause
for up to about a minute while PD re-forms (measured: ~45 s, no failed queries with a 60 s client
timeout; connections and `SELECT 1` uninterrupted). Data is never at risk.

**First, check your 2.0.0 cluster is actually healthy.** A 2.0.0 bootstrap can leave a TiKV store
that never comes up, so the cluster runs without fault tolerance — or never serves SQL at all.
Upgrading does not repair that. Check from any PD replica:

```bash
cpln workload exec RELEASE_NAME-pd --gvc GVC_NAME --location LOCATION --replica RELEASE_NAME-pd-0 \
  --container tidb-pd -- sh -c 'curl -s 127.0.0.1:2379/pd/api/v1/stores | grep state_name'
```

Every store must say `"Up"`. If one is `"Down"` and the cluster has never served queries, it holds
no data: uninstall it and install the current version fresh. If it has been serving with a store
down, back it up and restore into a fresh install of the current version (see
[Backing Up](#backing-up)).

## Migrating from 1.x

**Never `helm upgrade` a 1.x release onto 2.0.0.** Versions through 1.8.1 created their own GVC, so
that GVC is part of the 1.x release's manifest. 2.0.0 does not declare it — and Helm deletes what a
chart stops declaring. The upgrade would therefore **delete the GVC and every workload, volume set
and identity inside it**, including your data.

The chart refuses to render if your values still carry a `gvc:` key, so an upgrade that passes your
old values file fails before touching anything. A 1.x install made on pure defaults has no such key
and is **not** protected — nothing at render time can see it. Migrate instead:

1. Back up the old cluster — enable `backup` on the 1.x release, or run `br backup full` by hand.
2. Create (or pick) the GVC you want 2.0.0 to live in, with the locations you intend to use.
3. Install 2.0.0 as a **new release** into that GVC. Use a different release name — secret names are organization-wide and would otherwise collide with the 1.x release's.
4. Restore into the new cluster (see [Restoring a Backup](#restoring-a-backup)) and cut your applications over to the new `RELEASE_NAME-server` endpoint.
5. Uninstall the old release **against the GVC you originally installed it into**, not the `tidb-gvc` it created. That is where Helm tracks the release, and it takes the created GVC with it.

Values keys that moved or changed in 2.0.0:

- `gvc.locations` is now the top-level `locations`, `gvc.pdReplicas` is now the top-level `pdReplicas`, and `gvc.name` is gone entirely.
- `devMode` is gone. It only waived the three-location requirement, and there is no longer such a requirement: `locations` may hold a single location, and PD's replication factor is derived from the number of TiKV nodes you configure.
- `replicas: 0` on a location is refused. 1.x turned it into a suspended location, and suspending a location permanently withdraws that workload's endpoints from other locations' service discovery. Remove the location from `locations` instead.

2.0.0 also removes the hazard that made 1.x's GVC handling dangerous in the first place: a
`createsGvc` chart pointed at a GVC that already exists **adopts** it, and `helm uninstall` then
deletes that GVC and everything else in it. There is nothing left to point at the wrong GVC.

## Configuration

### Locations

```yaml
locations:
  - name: aws-us-east-1
    tikvReplicas: 3    # TiKV storage nodes in this location
    serverReplicas: 3  # TiDB SQL servers in this location
pdReplicas: 3
```

Every location listed must already exist in the GVC you install into. `tikvReplicas` and
`serverReplicas` set the TiKV storage nodes and TiDB SQL servers in that location independently;
each must be at least 1. `pdReplicas` is the total number of PD members, spread evenly across the
locations with any remainder going to the first ones; PD is Raft based, so it must be 1, 3, 5 or 7.

The default — one location, three TiKV nodes, three PD members — survives the loss of a node. It
does **not** survive the loss of a location.

#### Example: surviving the loss of a location, with zero downtime

```yaml
locations:
  - name: aws-us-east-1
    tikvReplicas: 1
    serverReplicas: 2
  - name: aws-us-west-2
    tikvReplicas: 1
    serverReplicas: 2
  - name: aws-eu-central-1
    tikvReplicas: 1
    serverReplicas: 2
pdReplicas: 3
proxysql:
  enabled: true
```

Three locations with one PD member and one TiKV node each: PD keeps quorum when one location goes
away, and TiKV spreads each region's three copies one per location. Every location must be in the GVC.

Measured with one location fully dark (servers, ProxySQL, PD leader and TiKV all gone): clients in
the other locations kept connecting with no interruption, and writes paused about 15 seconds while
new leaders were elected, then ran normally — no failed queries with a 60 s client timeout. A
rolling restart of PD or TiKV pauses writes for about 45 s. Use a client timeout of 60 s (or retry)
so those pauses are a delay, not an error.

Two SQL servers per location behind [ProxySQL](#connection-pooling-proxysql) keep a location serving
through a server crash with zero failed queries; with `serverReplicas: 1` that location's clients
lose about 10 seconds. Run clients in a listed location — the server's service name only reaches
servers in the caller's own location.

### Images and Resources

```yaml
images:
  server: pingcap/tidb:v8.5.7
  tikv: pingcap/tikv:v8.5.7
  pd: pingcap/pd:v8.5.7

resources:
  pd:
    cpu: 2
    memory: 4Gi
  server:
    cpu: 2
    memory: 2Gi
  tikv:
    cpu: 2
    memory: 4Gi
```

These defaults are sized for testing. For production, PD wants 4–8 CPU / 8–16Gi, tidb-server 8–16
CPU / 16–32Gi (it scales with concurrent connections), and TiKV 8–16 CPU / 32–64Gi (memory-hungry
for caching).

### Database Initialization

```yaml
autoCreateDatabase:
  enabled: true
  deployInitWorkload: true
  credentialsSecretName: my-tidb-credentials
  schedule: "*/5 * * * *"  # how soon after install the DB appears; later runs are no-ops
```

`credentialsSecretName` names the prerequisite `dictionary` secret above. After the first deploy has
finished, upgrade with `deployInitWorkload: false` to remove the one-time job and its secret while
keeping the credentials available to tidb-server. The job is idempotent — it exits immediately if
the database already exists.

### Connection Pooling (ProxySQL)

```yaml
proxysql:
  enabled: false                   # set true for a ProxySQL pooler tier in every location
  image: proxysql/proxysql:3.0.11
  replicas: 2                      # pooler replicas per location
  resources:
    cpu: 500m
    memory: 512Mi
```

Requires `autoCreateDatabase.enabled` — ProxySQL authenticates clients with the `user`, `password`
and `rootPassword` from the credentials secret. It is reachable by whoever `internal_access.server`
allows. Clients must connect with a **utf8mb4** charset (every modern driver's default; the `mysql`
CLI needs `--default-character-set=utf8mb4`) — see Important Notes.

### Volume Storage

```yaml
volumeset:
  tikv:
    capacity: 10 # initial capacity in GiB (minimum is 10)
    snapshots:
      schedule: "0 3 * * *"    # volume snapshots of every TiKV node, daily at 3am UTC; at most hourly; "" turns them off
      retentionDuration: 7d    # how long each snapshot is kept
    autoscaling:
      enabled: false
      maxCapacity: 100       # maximum capacity in GiB
      minFreePercentage: 10  # scale when free space drops below this percentage
      scalingFactor: 1.2     # multiply current capacity by this factor when scaling
  pd:
    capacity: 10 # initial capacity in GiB
    snapshots:
      schedule: "0 3 * * *"    # volume snapshots of every PD member, daily at 3am UTC; at most hourly; "" turns them off
      retentionDuration: 7d    # how long each snapshot is kept
```

PD only holds cluster metadata, so it has no autoscaling knob. Volume snapshots are per volume and
crash-consistent — they protect against losing a single volume; restore a whole cluster from a `br`
backup (see Backing Up).

### Access

```yaml

external_access:
  server_outboundAllowCIDR: []
  tikv_outboundAllowCIDR: []
  pd_outboundAllowCIDR: []

internal_access:
  server:
    type: same-gvc # options: same-gvc, same-org, workload-list
    workloads:     # only used when type is workload-list
      #- //gvc/GVC_NAME/workload/WORKLOAD_NAME
  tikv:
    type: same-gvc
  pd:
    type: same-gvc
```

`internal_access` controls who may reach each tier from inside the org. **Every workload this
release creates is always allowed, whatever you set** — the tiers have to reach each other, and each
tier's own replicas have to reach each other, so a `workload-list` naming only your clients would
otherwise cut the cluster off from itself.

`external_access.*_outboundAllowCIDR` opens outbound internet access per tier. When
`backup.enabled` is true the template gives TiKV `0.0.0.0/0` outbound regardless, because TiKV
uploads to the bucket directly.

The tidb-server workload takes no public inbound traffic. Reach it over internal GVC DNS or `cpln port-forward`.

## Connecting

> **Your application must retry — build it in from the start.** Restarts, upgrades and failovers are routine, and each one fails a few connections or statements for a few seconds even though the database stays up. Retry a failed connection with a short backoff (about 0.5–1 s) for 10–15 s, and retry a failed statement, making retried writes idempotent. Connection pools usually replace a broken connection but do not re-run the failed query for you. Details: [Resiliency](#resiliency).

| What | Where | Credentials |
|---|---|---|
| MySQL protocol (applications) | `RELEASE_NAME-server.GVC_NAME.cpln.local:4000` | `user` / `password` from the credentials secret; database `db` |
| MySQL protocol (root) | same | `root` / `rootPassword` from the credentials secret |
| Pooled MySQL protocol *(when `proxysql.enabled`)* | `RELEASE_NAME-proxysql.GVC_NAME.cpln.local:4000` | same users and passwords as above |
| PD HTTP API (cluster state) | `RELEASE_NAME-pd.GVC_NAME.cpln.local:2379` | none — internal only |

```bash
mysql -h RELEASE_NAME-server.GVC_NAME.cpln.local -P 4000 -u myuser -p --default-character-set=utf8mb4
```

The `pingcap/tidb` image ships **no** mysql client, so run the command from another workload in the
same GVC — a throwaway `mysql:8` workload works, and the `RELEASE_NAME-tidb-db-init` workload
already is one.

A fresh install takes about 5 minutes to accept connections in one location, and 10 to 15 minutes
when its locations span regions or clouds. The TiDB servers wait for TiKV and then create the system
tables, and each step crosses the network between locations.

## Resiliency

Your application never has to pick another server for anything inside a location: the template and
TiDB handle that, and the application needs only the ordinary retry described below. The one thing
they cannot handle is the loss of a whole location, because a client reaches only the database in
its own location.

| Failure | Handled by | What it needs |
|---|---|---|
| A TiDB server | The template | `serverReplicas: 2` or more per location. With [ProxySQL](#connection-pooling-proxysql) no queries fail; without it, new connections fail for about 5 seconds |
| A ProxySQL replica | The template | `proxysql.replicas: 2` (the default) |
| A TiKV or PD node | TiDB (Raft elects a new leader) | At least 3 TiKV nodes and `pdReplicas: 3` (the default) |
| A whole location | The template for the database; **your application** for its clients | The [three-location layout](#example-surviving-the-loss-of-a-location-with-zero-downtime), and **your application running in at least 2 of the listed locations** behind a public endpoint that spans them. A workload's [canonical endpoint](https://docs.controlplane.com/reference/workload/general#canonical-endpoint-global) already sends each request to the nearest healthy location |

**Retry logic your application needs, with or without ProxySQL.** Every row above can still fail a
connection or a statement for a moment:

- **Retry failed connections** with a short backoff (about 0.5–1 s) for 10–15 s. Without ProxySQL,
  this is what covers a TiDB server crash: for several seconds new connections can still reach the
  server that died. ProxySQL retries those for you, but a ProxySQL replica that dies still drops the
  connections going through it.
- **Retry a failed statement**, and make retried writes idempotent: a statement running on a process
  that fails returns an error, and may already have committed.
- **Set a client timeout of 60 s**, so a write pause during a leader election or a PD/TiKV restart
  (15–75 s measured) is a delay rather than an error.

## Backing Up

Set a schedule and point `backup` at your bucket. `backup.location` must be one of `locations` —
the cron is suspended everywhere else, and the chart refuses to render if it names a location you
did not configure. Put it near your bucket to keep transfer costs down.

```yaml
backup:
  enabled: false
  image: ghcr.io/controlplane-com/backup-images/tidb-backup:8.5.7
  schedule: "0 2 * * *"          # daily at 2am UTC
  activeDeadlineSeconds: 14400   # hard kill after 4 hours
  location: aws-us-east-1        # MUST be one of `locations`
  resources:
    cpu: 1
    memory: 1Gi
  provider: aws                  # options: aws, gcp
  aws:
    bucket: my-backup-bucket
    region: us-east-1
    cloudAccountName: my-backup-cloudaccount
    policyName: my-backup-policy
    prefix: tidb/backups
  gcp:
    bucket: my-backup-bucket
    cloudAccountName: my-backup-cloudaccount
    prefix: tidb/backups
```

The backup image version must match the cluster version. From v8.5.7 `br` enforces the check even
with `--check-requirements=false`, so bump `backup.image` and `images.*` together.

### AWS S3

1. Create your bucket. Set `aws.bucket` to its name and `aws.region` to its region.
2. Create a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account) if you do not have one, and set `aws.cloudAccountName`.
3. Create an AWS IAM policy with the JSON below (replace `YOUR_BUCKET_NAME`), and set `aws.policyName` to its name.

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject",
                "s3:ListBucket",
                "s3:GetObjectVersion",
                "s3:DeleteObjectVersion",
                "s3:GetBucketLocation",
                "s3:AbortMultipartUpload",
                "s3:ListBucketMultipartUploads",
                "s3:ListMultipartUploadParts"
            ],
            "Resource": [
                "arn:aws:s3:::YOUR_BUCKET_NAME",
                "arn:aws:s3:::YOUR_BUCKET_NAME/*"
            ]
        }
    ]
}
```

### GCS

1. Create your bucket. Set `gcp.bucket` to its name.
2. Create a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account) if you do not have one, and set `gcp.cloudAccountName`.
3. Grant the cloud account's service account the **Storage Admin** (`roles/storage.admin`) role on that bucket. The chart also binds `roles/storage.objectAdmin` to the workload identity.

### Restoring a Backup

Backups land at `BUCKET/PREFIX/tidb-TIMESTAMP/`. Restore with `br restore full`, run from a workload
**inside the GVC** — `*.cpln.local` names do not resolve from anywhere else, and the
`ghcr.io/controlplane-com/backup-images/tidb-backup` image is the one that carries a matching `br`.

**AWS S3**
```sh
br restore full \
  --pd="replica-0.RELEASE_NAME-pd.LOCATION_1.GVC_NAME.cpln.local:2379,replica-0.RELEASE_NAME-pd.LOCATION_2.GVC_NAME.cpln.local:2379,replica-0.RELEASE_NAME-pd.LOCATION_3.GVC_NAME.cpln.local:2379" \
  --storage="s3://BUCKET_NAME/PREFIX/tidb-TIMESTAMP" \
  --s3.region="BUCKET_REGION"
```

**GCS**
```sh
br restore full \
  --pd="replica-0.RELEASE_NAME-pd.LOCATION_1.GVC_NAME.cpln.local:2379,replica-0.RELEASE_NAME-pd.LOCATION_2.GVC_NAME.cpln.local:2379,replica-0.RELEASE_NAME-pd.LOCATION_3.GVC_NAME.cpln.local:2379" \
  --storage="gcs://BUCKET_NAME/PREFIX/tidb-TIMESTAMP" \
  --send-credentials-to-tikv=false
```

List one PD member per location, `replica-0.RELEASE_NAME-pd.LOCATION.GVC_NAME.cpln.local:2379` —
`br` needs one that answers and finds the rest. The plain `RELEASE_NAME-pd.GVC_NAME.cpln.local` name
only reaches PD in the caller's own location, which may have no PD member.

`br` must be the same version as the cluster, and the target must be empty. TiKV reads the backup
with the target release's own cloud identity, so set the target's `backup` section to the same
provider, bucket and cloud account. Restoring into a fresh release was verified end to end on S3 and
GCS (identical `ADMIN CHECKSUM`). **A full restore also restores the source cluster's
users** — root's password and the application user become the ones the backup was taken with, not
the target release's credentials secret. Rehearse a restore into a scratch release before you need
one.

## Important Notes

- **Root has a password from the first moment** when `autoCreateDatabase.enabled` (the default): the first TiDB server sets it while the cluster bootstraps. With `autoCreateDatabase.enabled: false`, root starts with **no password** — set one with `ALTER USER` before exposing the cluster.
- **Each TiDB server start makes one root login attempt with an empty password** (to confirm root is protected before serving). If you set `FAILED_LOGIN_ATTEMPTS` on root, set it above your total number of TiDB servers, since restarting them all counts one failure each.
- **Your application must retry failed connections and statements** — without it, every upgrade and replica restart shows up as errors in your app. Retry with a short backoff for 10–15 s and make retried writes idempotent; see [Resiliency](#resiliency).
- **Never `helm upgrade` a 1.x release onto 2.0.0** — it deletes the GVC the 1.x release created and everything inside it. Install a new release instead; see [Migrating from 1.x](#migrating-from-1x).
- **Every location in `locations` must already exist in the GVC.** A location the GVC lacks is accepted silently by the platform; PD refuses to bootstrap and says so in its logs. A GVC location you did *not* list simply runs nothing.
- **Surviving a location loss needs your application in at least 2 locations** — clients reach only their own location's TiDB servers. See [Resiliency](#resiliency).
- **PD's replication factor is fixed when the cluster first bootstraps.** It is the number of TiKV nodes you configure, capped at 3, and PD persists it — scaling TiKV up later does not raise it. Start with at least 3 TiKV nodes if you ever want 3-way replication.
- **There is no public access to the MySQL port.** Reach the server over internal GVC DNS, or with `cpln port-forward RELEASE_NAME-server 4000:4000 --gvc GVC_NAME`. (`exposeServer` was removed in 2.0.0: it opened public inbound without publishing port 4000, leaving TiDB's unauthenticated status port as the only thing served.)
- **The database-init job is a cron that runs on a schedule, and that is intentional.** It fast-exits once the database exists (measured: ~200-300 ms), so every run after the first is a no-op; `autoCreateDatabase.schedule` only controls how soon after install the database appears. Set `autoCreateDatabase.deployInitWorkload: false` and upgrade if you would rather remove it entirely once initialised.
- **Credentials apply on first initialization only.** Changing the secret afterwards does not change the cluster; rotate with `ALTER USER` inside TiDB first, then update the secret and force a redeployment (of `RELEASE_NAME-proxysql` too, when enabled) — a `cpln://` reference is resolved when a replica starts and is never re-resolved while it runs.
- **Through ProxySQL, connect with a utf8mb4 charset.** A client requesting latin1 works direct to TiDB but fails intermittently through ProxySQL with `ERROR 1273 ... latin1_swedish_ci`. Modern drivers default to utf8mb4; the `mysql` CLI picks its charset from the OS locale, so pass `--default-character-set=utf8mb4`.
- **Access changes take up to about 10 minutes to propagate.** After flipping an `internal_access` value, keep re-polling rather than concluding the knob is broken.

## Links

- [TiDB documentation](https://docs.pingcap.com/tidb/stable/)
- [TiDB architecture](https://docs.pingcap.com/tidb/stable/tidb-architecture/)
- [PD configuration reference](https://docs.pingcap.com/tidb/stable/pd-configuration-file/)
- [TiKV configuration reference](https://docs.pingcap.com/tidb/stable/tikv-configuration-file/)
- [BR backup and restore](https://docs.pingcap.com/tidb/stable/backup-and-restore-overview/)
