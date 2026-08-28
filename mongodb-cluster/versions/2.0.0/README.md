# MongoDB Cluster

A MongoDB replica set built on Percona Server for MongoDB, with automatic primary election and failover. This template deploys the members into an existing GVC — one location, or several — and optionally puts HAProxy in front so clients always reach the current primary.

## Architecture

- **Stateful MongoDB workload** — the replica set members, one per replica in each configured location, with keyfile authentication and automatic replica-set registration at boot.
- **Volume set** — per-member `/data/db` storage, with optional capacity autoscaling and daily snapshots.
- **HAProxy workload** *(optional, on by default)* — one stable address that TCP-health-checks every member and routes to whichever one is primary.
- **Backup workload** *(optional)* — a cron job running either a logical `mongodump` or a Percona Backup for MongoDB (PBM) physical backup to object storage.
- **PBM agent sidecar** *(optional)* — added to each member when `backup.mode: physical`.
- **Secrets** — the MongoDB startup script, the HAProxy startup script, and the PBM agent script.
- **Identity** — the workloads' identity, bound to your cloud account when backups are enabled.
- **Policy** — `reveal` on this release's secrets and on your two prerequisite secrets.
- **Policy** — `view` on the install GVC alone, so each member can check at boot that the GVC really has the locations it was configured for.

This chart does **not** create a GVC. It deploys into the one you install into.

## Prerequisites

A GVC containing the location(s) you list in `locations`, and **two secrets that must exist BEFORE you install**. A missing one wedges the deployment waiting on a secret that is not there — `cpln logs` returns nothing at all, and the only place it is named is `status.versions[].message` from `cpln workload get-deployments RELEASE-mongo --gvc GVC -o yaml`. Neither value passes through Helm values, so neither lands in the release.

**1. Database credentials** (`mongodb.credentialsSecretName`) — a `dictionary` secret holding exactly three entries:

```bash
cpln secret create-dictionary --name my-mongodb-credentials \
  --entry username=admin \
  --entry password='YOUR-STRONG-PASSWORD' \
  --entry database=mydatabase
```

**2. Replica-set keyfile** (`mongodb.keyfileSecretName`) — an `opaque` secret holding the key that authenticates replica-set members to each other:

```bash
openssl rand -base64 756 | cpln secret create-opaque --name my-mongodb-keyfile --encoding plain -f -
```

> **The keyfile must be valid base64.** MongoDB accepts 6–1024 characters from the base64 alphabet only (`A-Z a-z 0-9 + / =`). A passphrase containing hyphens or other punctuation **will not start the cluster** — use `openssl rand -base64 756` rather than inventing a string. The container checks this at boot and fails with an explicit message naming your secret, instead of mongod's unhelpful error.

They are deliberately **two** secrets: granting an application `reveal` on the database credentials must not also hand it the key that lets a member join your replica set.

For backups you also need a bucket and a Control Plane cloud account — see [Storage setup](#storage-setup).

## Configuration

### Locations

```yaml
# Every location listed MUST already exist in the GVC you install into.
# One entry per location; `replicas` = mongod members in that location.
locations:
  - name: aws-us-east-1
    replicas: 3
```

The default is one location with three members — the smallest shape that both installs on any single-location GVC and survives losing a member. Set it to your GVC's locations before installing.

Every member this chart creates is a **voting** member, so the total across all locations decides what the set survives:

| Total members | Majority | Survives | Notes |
|---|---|---|---|
| 1 | 1 | nothing | Valid and writable — a single member is always its own primary |
| 2 | 2 | nothing | **Refused by this chart** — losing either member leaves no primary, so it is strictly worse than 1 |
| 3 | 2 | 1 member | The usual choice |
| 5 | 3 | 2 members | |
| 7 | 4 | 3 members | **The maximum.** MongoDB allows at most 7 voting members |

Totals above 7 are refused at render time: MongoDB rejects the 8th voting member, and every member past it would run a mongod that is not in the replica set while still reporting `ready: true`.

Spreading members across **locations** buys survival of a whole location, at the cost of cross-region replication traffic, which is billed. Size it against the same table — 3 locations × 1 member survives losing one location; 2 locations × 2 members does not survive losing either, because 2 of 4 is not a majority.

```yaml
# Spread each location's members across availability zones. Confirm your
# locations support multi-zone before enabling.
multiZone: false
```

### Image and resources

```yaml
image: percona/percona-server-mongodb:8.0

resources:
  cpu: 1
  memory: 2Gi
```

### Credentials

```yaml
mongodb:
  # Dictionary secret holding username, password and database. Must EXIST BEFORE INSTALL.
  credentialsSecretName: my-mongodb-credentials
  # Opaque secret holding the replica-set keyfile. Must EXIST BEFORE INSTALL.
  keyfileSecretName: my-mongodb-keyfile
```

### Storage

```yaml
volumeset:
  capacity: 10 # initial capacity in GiB per member (minimum is 10)
  autoscaling:
    enabled: false
    maxCapacity: 100
    minFreePercentage: 10
    scalingFactor: 1.2
```

### Access

```yaml
# There is no public endpoint: MongoDB is reachable on the internal network only.
firewall:
  internalAllowType: same-gvc # options: same-gvc, same-org, workload-list
  workloads: [] # only used with workload-list; this release's own workloads are added automatically
  # - //gvc/GVC_NAME/workload/WORKLOAD_NAME
```

This list governs replication between the members themselves, HAProxy's health checks and the backup job — not just client traffic — so the chart always adds its own workloads to it. List only your client workloads.

### HAProxy

Only the primary accepts writes. The proxy gives clients one stable address and routes to whichever member is primary right now, so applications do not have to track elections themselves.

```yaml
proxy:
  enabled: true
  image: haproxy:2.9
  resources:
    cpu: 100m
    memory: 128Mi
  minReplicas: 2 # per configured location
  maxReplicas: 2
```

Backups do **not** use the proxy — both jobs connect directly to `replica-0` in `backup.location` — so it can be disabled without affecting them.

### Backups

```yaml
backup:
  enabled: false
  mode: logical # options: logical, physical

  schedule: "0 2 * * *" # daily at 2am UTC

  # The ONE location the backup job runs in. Must be one of `locations`.
  location: aws-us-east-1

  provider: aws # options: aws or gcp

  # Logical backup (mongodump)
  logical:
    image: ghcr.io/controlplane-com/backup-images/mongo-backup:8.0
    resources:
      cpu: 100m
      memory: 128Mi

  # Physical backup (Percona Backup for MongoDB)
  physical:
    image: percona/percona-backup-mongodb:2.14.0
    resources:
      cpu: 100m
      memory: 128Mi
    cron:
      resources:
        cpu: 50m
        memory: 64Mi

  aws:
    bucket: my-backup-bucket
    region: us-east-1
    cloudAccountName: my-backup-cloudaccount
    policyName: my-backup-policy
    prefix: mongodb-cluster/backups

  gcp:
    bucket: my-backup-bucket
    cloudAccountName: my-backup-cloudaccount
    prefix: mongodb-cluster/backups
```

- **Logical** (`mongodump`) — portable BSON archives, good for smaller databases, cross-version moves and selective restores.
- **Physical** (PBM) — a filesystem-level copy of the WiredTiger data files, faster for large databases. It adds a `pbm-agent` sidecar to every member. Read the restore caveat below before choosing it.

## Storage setup

### AWS S3

1. Create your bucket. Set `backup.aws.bucket` to the bucket name and `backup.aws.region` to its region.

2. If you do not have a Cloud Account set up, refer to the docs to [Create a Cloud Account](https://docs.controlplane.com/guides/create-cloud-account). Set `backup.aws.cloudAccountName` to the account name.

3. Create a new AWS IAM policy with the following JSON (replace `YOUR_BUCKET_NAME`):

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

4. Set `backup.aws.policyName` to the name of the policy created in step 3.

### GCS

1. Create your bucket. Set `backup.gcp.bucket` to the bucket name.

2. If you do not have a Cloud Account set up, refer to the docs to [Create a Cloud Account](https://docs.controlplane.com/guides/create-cloud-account). Set `backup.gcp.cloudAccountName` to the account name.

3. Grant the service account behind that cloud account the **Storage Admin** role on the bucket. This chart's identity additionally requests `roles/storage.objectAdmin` on `backup.gcp.bucket`.

## Connecting

| From | Address | Credentials |
|---|---|---|
| Another workload in the same GVC, via the proxy | `RELEASE-mongo-proxy.GVC.cpln.local:27017` | the `username` / `password` entries of your credentials secret |
| Another workload in the same GVC, a specific member | `replica-N.RELEASE-mongo.LOCATION.GVC.cpln.local:27017` | same |
| Your own machine | `cpln port-forward RELEASE-mongo-proxy 27017:27017 --gvc GVC`, then `localhost:27017` | same |

There is no public endpoint — the members and the proxy are reachable on the internal network only.

Example connection string through the proxy:

```
mongodb://USERNAME:PASSWORD@RELEASE-mongo-proxy.GVC.cpln.local:27017/DATABASE?authSource=admin
```

Read the credentials back with `cpln secret reveal my-mongodb-credentials -o yaml`. To read from secondaries instead of the primary, connect to the members directly and set `readPreference=secondaryPreferred`.

## Restoring a backup

### Logical (mongodump / mongorestore)

The cluster has no public endpoint, so the restore runs through a port-forward tunnel. You need the [MongoDB Database Tools](https://www.mongodb.com/docs/database-tools/) and your cloud CLI on the machine you run it from.

1. Find the archive in your bucket — `aws s3 ls s3://BUCKET/PREFIX/` (or `gcloud storage ls gs://BUCKET/PREFIX/`) — and download it:

```bash
aws s3 cp s3://BUCKET/PREFIX/BACKUP_FILE.gz ./backup.gz
```

2. Open a tunnel to the proxy, which routes to the current primary (or to `RELEASE-mongo` if the proxy is disabled):

```bash
cpln port-forward RELEASE-mongo-proxy 27017:27017 --gvc GVC
```

3. In another terminal, restore through the tunnel:

```bash
mongorestore --uri="mongodb://USERNAME:PASSWORD@localhost:27017/?authSource=admin" \
  --gzip --archive=./backup.gz
```

### Physical (PBM)

**A PBM physical restore has not been verified on Control Plane, and there is a known conflict with how this template runs mongod.** PBM's documented physical restore has `pbm-agent` stop mongod on every node, replace the data directory, and leave the database down until an operator restarts it — and it requires that nothing restarts mongod on its own in the meantime. In this template mongod is PID 1 of the container, so the platform restarts the container as soon as PBM stops it. Whether a physical restore can complete under that behaviour is untested.

Until it is proven, choose `backup.mode: logical` if you need a restore path you can rely on. To list the physical backups that exist:

```bash
cpln workload exec RELEASE-mongo --gvc GVC --container pbm-agent -- /bin/sh -c 'pbm list --mongodb-uri="mongodb://$MONGO_INITDB_ROOT_USERNAME:$MONGO_INITDB_ROOT_PASSWORD@localhost:27017/admin?replicaSet=rs0&authSource=admin"'
```

## Migrating from 1.x

**Never `helm upgrade` a 1.x release onto 2.0.0.** 1.x created its own GVC; 2.0.0 does not. An in-place upgrade drops `kind: gvc` from the manifest, and Helm deletes what a chart no longer declares — which destroys that GVC and **every workload, volume set and identity inside it**, including your data. On a sibling template this was measured taking 6 seconds while Helm printed `upgraded successfully`.

The chart refuses to render if your values still carry the 1.x `gvc` key, so the usual path fails safely. Migrate like this instead:

1. Install 2.0.0 as a **new release** against an existing GVC, with `locations` set to that GVC's locations.
2. Copy the data across with `mongodump` from the old cluster and `mongorestore` into the new one, tunnelling to each with `cpln port-forward`.
3. Point your applications at the new release, then `cpln helm uninstall` the old one.

Values that moved or were removed in 2.0.0 — the chart names each one at render time rather than ignoring it:

| 1.x | 2.0.0 |
|---|---|
| `gvc.name` | gone; the chart deploys into the GVC you install into |
| `gvc.locations` | `locations` (top level) |
| backup location derived from `backup.aws.region` | `backup.location`, explicit and checked against `locations` |
| `locations[].replicas: 0` | not allowed; remove the location instead |
| a total above 7 members, or exactly 2 | not allowed; see the sizing table above |

## Important Notes

- **Both prerequisite secrets must exist BEFORE you install.** A missing one wedges the deployment silently — `cpln logs` returns nothing, and the secret is named only in `status.versions[].message` from `cpln workload get-deployments`. It self-heals within roughly 6–10 minutes once the secret exists, or immediately after `cpln workload force-redeployment`.
- **The keyfile must be valid base64, or mongod will not start.** 6–1024 characters from `A-Z a-z 0-9 + / =` only — generate it with `openssl rand -base64 756`. The container checks this at boot and says so explicitly.
- **The keyfile cannot be changed after the cluster is initialized.** It authenticates members to each other; rotating it means a full cluster rebuild.
- **Rotating either secret does not restart anything.** A `cpln://` reference resolves when a replica starts and is never re-resolved while it lives, so the old value keeps working with no error until you run `cpln workload force-redeployment`.
- **Every location in `locations` must already exist in the GVC.** The platform accepts a location a GVC does not have without any error — the members there simply never start, so your replica set is smaller than the quorum you sized. Each member checks this against the live GVC at boot: a member with an empty data directory refuses to start, and one that already holds data warns and keeps serving rather than taking a live cluster down.
- **Locations in the GVC that are not in `locations` run nothing.** Their deployment reads `This workload location is deactivated because maxScale is set to 0`, and no volume is provisioned there. That is intended, not a failure.
- **Scaling down needs manual preparation.** Before reducing a location's `replicas`, remove those members from the replica set config — connect to the primary and run `rs.remove("replica-N.RELEASE-mongo.LOCATION.GVC.cpln.local:27017")`. Otherwise the config keeps referencing hosts that no longer exist, which distorts elections and quorum.
- **A firewall change takes up to ~10 minutes to propagate.** After changing `firewall.internalAllowType`, keep re-testing rather than concluding the knob is broken.
- **Data lives on the volume set and survives redeployment, but `cpln helm uninstall` deletes it.**

## Links

- [Percona Server for MongoDB documentation](https://docs.percona.com/percona-server-for-mongodb/)
- [Percona Backup for MongoDB documentation](https://docs.percona.com/percona-backup-mongodb/)
- [MongoDB replication](https://www.mongodb.com/docs/manual/replication/)
- [Replica set members and the 7-voting-member limit](https://www.mongodb.com/docs/manual/core/replica-set-members/)
- [MongoDB Database Tools](https://www.mongodb.com/docs/database-tools/)
