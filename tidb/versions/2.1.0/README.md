# TiDB

TiDB is a distributed, MySQL-compatible SQL database that scales horizontally and keeps serving
through node loss. This template deploys the three tiers — PD (metadata and placement), TiKV
(storage) and tidb-server (the MySQL front door) — with optional scheduled backups to S3 or GCS.
From 2.0.0 the chart deploys into the GVC you install into and creates none of its own.

## Architecture

- **Stateful PD workload** (`RELEASE_NAME-pd`) — the placement driver quorum, `pdReplicas` members spread across `locations`, each individually addressable via `replicaDirect`.
- **Stateful TiKV workload** (`RELEASE_NAME-tikv`) — the storage nodes; `locations[].replicas` per location, each with its own persistent volume.
- **TiDB server workload** (`RELEASE_NAME-server`) — the MySQL-compatible SQL layer on port 4000.
- **DB init workload** *(optional, on by default)* — a one-time job that sets the root password and creates the application database and user. Turn it off after the first deploy.
- **Volume sets** — PD and TiKV storage, each with 7-day snapshot retention.
- **Secrets** — the PD, TiKV and tidb-server startup scripts, plus the init job's script.
- **Identity and two policies** — `reveal` on this release's secrets and the credentials secret you create, `view` on the one GVC you install into so PD can confirm at boot that the GVC really has every location you listed, and cloud storage access when backups are on.
- **Backup cron workload** *(optional)* — TiDB's `br` writing a full cluster snapshot to S3 or GCS, unsuspended in exactly one location.

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
organization-wide, so give each release its own.

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
    replicas: 3
pdReplicas: 3
```

Every location listed must already exist in the GVC you install into. `replicas` is the number of
TiKV nodes **and** tidb-server nodes in that location, and must be at least 1. `pdReplicas` is the
total number of PD members, spread evenly across the locations with any remainder going to the
first ones; PD is Raft based, so it must be 1, 3, 5 or 7.

The default — one location, three TiKV nodes, three PD members — survives the loss of a node. It
does **not** survive the loss of a location.

#### Example: surviving the loss of a location

```yaml
locations:
  - name: aws-us-east-1
    replicas: 1
  - name: aws-us-west-2
    replicas: 1
  - name: aws-eu-central-1
    replicas: 1
pdReplicas: 3
```

Three locations with one PD member each: PD keeps quorum when one location goes away, and TiKV
spreads each region's three copies one per location. Every location must be in the GVC.

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

### Volume Storage

```yaml
volumeset:
  tikv:
    capacity: 10 # initial capacity in GiB (minimum is 10)
    autoscaling:
      enabled: false
      maxCapacity: 100       # maximum capacity in GiB
      minFreePercentage: 10  # scale when free space drops below this percentage
      scalingFactor: 1.2     # multiply current capacity by this factor when scaling
  pd:
    capacity: 10 # initial capacity in GiB
```

PD only holds cluster metadata, so it has no autoscaling knob.

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

| What | Where | Credentials |
|---|---|---|
| MySQL protocol (applications) | `RELEASE_NAME-server.GVC_NAME.cpln.local:4000` | `user` / `password` from the credentials secret; database `db` |
| MySQL protocol (root) | same | `root` / `rootPassword` from the credentials secret |
| PD HTTP API (cluster state) | `RELEASE_NAME-pd.GVC_NAME.cpln.local:2379` | none — internal only |

```bash
mysql -h RELEASE_NAME-server.GVC_NAME.cpln.local -P 4000 -u myuser -p
```

The `pingcap/tidb` image ships **no** mysql client, so run the command from another workload in the
same GVC — a throwaway `mysql:8` workload works, and the `RELEASE_NAME-tidb-db-init` workload
already is one.

Depending on how many replicas and locations you configured, the cluster can take up to 5 minutes
to accept connections.

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
  --pd="RELEASE_NAME-pd.GVC_NAME.cpln.local:2379" \
  --storage="s3://BUCKET_NAME/PREFIX/tidb-TIMESTAMP" \
  --s3.region="BUCKET_REGION"
```

**GCS**
```sh
br restore full \
  --pd="RELEASE_NAME-pd.GVC_NAME.cpln.local:2379" \
  --storage="gcs://BUCKET_NAME/PREFIX/tidb-TIMESTAMP"
```

`br` must be the same version as the cluster. **This restore path is the upstream procedure and has
not been exercised end to end against a backup produced by this template** — in particular the SST
object layout differs between the S3 (`1/<name>`) and GCS (`1_<name>`) backends. Rehearse a restore
into a scratch release before you need one.

## Important Notes

- **Never `helm upgrade` a 1.x release onto 2.0.0** — it deletes the GVC the 1.x release created and everything inside it. Install a new release instead; see [Migrating from 1.x](#migrating-from-1x).
- **Every location in `locations` must already exist in the GVC.** A location the GVC lacks is accepted silently by the platform; PD refuses to bootstrap and says so in its logs. A GVC location you did *not* list simply runs nothing.
- **PD's replication factor is fixed when the cluster first bootstraps.** It is the number of TiKV nodes you configure, capped at 3, and PD persists it — scaling TiKV up later does not raise it. Start with at least 3 TiKV nodes if you ever want 3-way replication.
- **There is no public access to the MySQL port.** Reach the server over internal GVC DNS, or with `cpln port-forward RELEASE_NAME-server 4000:4000 --gvc GVC_NAME`. (`exposeServer` was removed in 2.0.0: it opened public inbound without publishing port 4000, leaving TiDB's unauthenticated status port as the only thing served.)
- **The database-init job is a cron that runs on a schedule, and that is intentional.** It fast-exits once the database exists (measured: ~200-300 ms), so every run after the first is a no-op; `autoCreateDatabase.schedule` only controls how soon after install the database appears. Set `autoCreateDatabase.deployInitWorkload: false` and upgrade if you would rather remove it entirely once initialised.
- **Credentials apply on first initialization only.** Changing the secret afterwards does not change the cluster; rotate with `ALTER USER` inside TiDB first, then update the secret and force a redeployment — a `cpln://` reference is resolved when a replica starts and is never re-resolved while it runs.
- **Access changes take up to about 10 minutes to propagate.** After flipping an `internal_access` value, keep re-polling rather than concluding the knob is broken.

## Links

- [TiDB documentation](https://docs.pingcap.com/tidb/stable/)
- [TiDB architecture](https://docs.pingcap.com/tidb/stable/tidb-architecture/)
- [PD configuration reference](https://docs.pingcap.com/tidb/stable/pd-configuration-file/)
- [TiKV configuration reference](https://docs.pingcap.com/tidb/stable/tikv-configuration-file/)
- [BR backup and restore](https://docs.pingcap.com/tidb/stable/backup-and-restore-overview/)
