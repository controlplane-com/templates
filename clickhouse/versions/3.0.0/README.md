# ClickHouse

ClickHouse is a column-oriented analytical database for real-time querying and data warehousing at scale.
This template deploys it in **single-node** or **cluster** mode — the mode is derived from the `locations`
list — with object storage (AWS S3, GCS, Azure Blob Storage, or Hetzner Object Storage) as the primary data
store. **From 3.0.0 the chart deploys into the GVC you install into and creates none of its own.**

## Architecture

- **ClickHouse Server** — stateful workload, the database itself, with configurable replicas per location.
- **ClickHouse Keeper** *(cluster modes only)* — stateful workload providing Raft coordination, one replica in each of the first three locations.
- **Volume sets** — server metadata and state, plus Keeper state in cluster modes. Table data lives in object storage; the volume is metadata and read cache.
- **Scratch volumes** — local filesystem cache and temporary spill.
- **Secrets** — startup scripts for Server and Keeper, plus one storage-configuration secret for the selected provider.
- **Identity + two policies** — `reveal` on this release's secrets and your credentials secret, plus `view` on the one GVC you install into so each container can confirm at boot that the GVC really has every location you listed.

This template does **not** create a GVC. Every resource lands in the GVC you pass to `--gvc`, so
`cpln workload exec`, `cpln logs` and `cpln helm uninstall` all work against that GVC, and uninstalling
can never delete it.

## Deployment Modes

The `locations` list is the topology, not just placement — its length selects the mode, and a location's
position in it is that shard's number.

| `locations` | Mode | Keeper |
|---|---|---|
| 1 location, `replicas: 1` | **Single-node** — development, staging, lower-traffic workloads | none |
| 1 location, `replicas: N > 1` | **Single-shard cluster** — one shard, N replicas, survives a replica loss | 1 member (no fault tolerance) |
| 3 or more locations | **Multi-shard cluster** — one shard per location | 3 members across the first three locations, quorum 2 |
| 2 locations | **Not supported** — refused at render | — |

To minimize network egress costs, keep all locations in the same cloud provider and the bucket in the same
region family. One server replica per location is enough for most cluster deployments.

## Prerequisites

**A GVC must already exist, and it must contain every location you list in `locations`.**
The requirement is one-directional: the GVC may have *more* locations than you list — nothing
ClickHouse-related runs in those. Check what a GVC has before you install:

```bash
cpln gvc get GVC_NAME -o json
```

The locations are under `spec.staticPlacement.locationLinks`. If you list a location the GVC does not
have, `helm install` still succeeds — the platform does not validate it — and the containers then refuse
to initialise with a named error in `cpln logs`:

```
[clickhouse] FATAL: locations declared in values are not in GVC 'my-gvc': aws-eu-central-1
```

If **every** location you list is absent from the GVC, nothing starts at all and there is no container to
log anything: `cpln workload get-deployments` shows zero replicas and `desiredScale: 0` in every
location. That is why the pre-flight check above matters.

**One `dictionary` secret must exist BEFORE you install.** This is the password you put in every client
connection, so it is not a value — putting it in values would leave it in the Helm release.

```bash
cpln secret create-dictionary --name my-clickhouse-credentials \
  --entry password='YOUR-STRONG-PASSWORD' \
  --entry database=mydatabase
```

Set `database.credentialsSecretName` to the name you used. Secret names are organization-wide, so give each
release its own. There is no `username` key: ClickHouse authenticates as its built-in `default` user, so the
secret holds only `password` and `database`.

**If the secret does not exist at install time, the deployment wedges silently.** `cpln logs` returns
**zero lines** — the container never starts, so it has nothing to log. Read `status.versions[].message`:

```bash
cpln workload get-deployments RELEASE_NAME-clickhouse-server --gvc GVC_NAME -o yaml
```

Note this is `get-deployments` — plain `cpln workload get` has no `versions` field. Creating the secret
repairs the deployment on its own in roughly 5.5 to 10.5 minutes, or force a redeployment to skip the wait.

**Object storage is required in every mode**, including single-node. See [Storage setup](#storage-setup) for
the per-provider steps; the `gcp`, `azure` and `hetzner` providers each need their own prerequisite secret.

## Migrating from 2.x

**Never `helm upgrade` a 2.x release onto 3.0.0.** Versions through 2.8.0 created their own GVC, so that
GVC is part of the 2.x release's manifest. 3.0.0 does not declare it — and Helm deletes what a chart stops
declaring. The upgrade would therefore **delete the GVC and every workload, volume set and identity inside
it**, including your ClickHouse metadata and Keeper state, in seconds, while printing `upgraded
successfully`.

The chart refuses to render if your values still carry a `gvc:` key, so an upgrade that passes your old
values file fails before touching anything. A 2.x install made on pure defaults has no such key and is
**not** protected — nothing at render time can see it. Migrate instead:

1. Create (or pick) the GVC you want 3.0.0 to live in, with the locations you intend to use.
2. Install 3.0.0 as a **new release** with a **new release name** into that GVC. Point it at the **same
   bucket with a different prefix**, or at a new bucket. Secret names are organization-wide and would
   otherwise collide with the 2.x release's.
3. Re-ingest your data into the new cluster. Do **not** try to adopt the old release's volume set: it holds
   metadata whose `<macros><shard>` identity and Keeper paths belong to the old topology, and it cannot be
   moved between releases.
4. Cut your applications over to the new endpoint.
5. Uninstall the old release **against the GVC you originally installed it into**, not the GVC it created.
   That is where Helm tracks the release, and it takes the created GVC with it.

Renamed in 3.0.0: `gvc.locations` is now the top-level `locations`, and `server.internal_access` /
`keeper.internal_access` are now `server.internalAccess` / `keeper.internalAccess`. The `workloads` list
under those keys is now actually applied — in 2.x it was ignored, so `type: workload-list` silently blocked
all internal traffic.

## Configuration

### Locations

```yaml
# Every location listed here MUST already exist in the GVC you install into.
# Extra locations in the GVC are fine: nothing ClickHouse-related runs in them.
# The list length selects the mode — see Deployment Modes above.
locations:
  - name: aws-us-east-1
    replicas: 1
```

### Cluster

```yaml
# Used in cluster modes only. Must be a bare identifier: letters, digits and
# underscores, not starting with a digit — it becomes an XML element name and is
# used unquoted in `ON CLUSTER` DDL.
clusterName: my_cluster

database:
  # REQUIRED PREREQUISITE SECRET — create it before you install (see Prerequisites).
  # A `dictionary` secret holding exactly `password` and `database`. No `username`.
  credentialsSecretName: my-clickhouse-credentials
```

### Object storage

```yaml
provider: aws # Options: aws, gcp, azure, or hetzner

aws: # If enabled, all fields below are required - See README for guidance
  bucket: my-clickhouse-bucket # Name of your S3 bucket
  region: us-east-1 # Region of your S3 bucket
  cloudAccountName: my-clickhouse-cloudaccount # Name of your Cloud Account
  policyName: my-clickhouse-s3-policy # Name of your pre-created policy to allow access to the S3 bucket

gcp: # If enabled, all fields below are required - See README for guidance
  bucket: my-clickhouse-gcs-bucket # Name of your GCS bucket
  # REQUIRED PREREQUISITE SECRET — a `dictionary` secret holding `accessKeyId`
  # and `secretAccessKey` (the GCS interoperability HMAC pair).
  credentialsSecretName: my-clickhouse-gcs-credentials

azure: # If enabled, all fields below are required - See README for guidance
  storageAccount: myclickhousestorage # Name of your Azure Storage Account
  container: clickhouse-data # Name of your Blob Storage container
  # REQUIRED PREREQUISITE SECRET — a `dictionary` secret holding `accountKey`.
  credentialsSecretName: my-clickhouse-azure-credentials

hetzner: # If enabled, all fields below are required - See README for guidance
  bucket: my-clickhouse-hetzner-bucket # Name of your Hetzner Object Storage bucket
  region: nbg1 # Region of your bucket. Options: nbg1, hel1, fsn1
  # REQUIRED PREREQUISITE SECRET — a `dictionary` secret holding `accessKeyId`
  # and `secretAccessKey`.
  credentialsSecretName: my-clickhouse-hetzner-credentials
```

### Storage volumes

```yaml
volumeset:
  server:
    capacity: 10 # initial capacity in GiB (minimum is 10)
  keeper:
    capacity: 10 # initial capacity in GiB (minimum is 10) - cluster modes only
```

### Server and Keeper

```yaml
server:
  image: clickhouse/clickhouse-server:25.10
  resources:
    cpu: 2
    memory: 2Gi
  internalAccess:
    type: same-gvc # options: same-gvc, same-org, workload-list, none
    workloads: [] # required when type is workload-list; list only your clients -- this release's
    # own server and keeper workloads are added automatically, e.g. //gvc/GVC_NAME/workload/WORKLOAD_NAME

keeper: # cluster modes only
  image: clickhouse/clickhouse-keeper:25.10
  resources:
    cpu: 2
    memory: 2Gi
  internalAccess:
    type: same-gvc # options: same-gvc, same-org, workload-list, none
    workloads: [] # required when type is workload-list; list only your clients -- this release's
    # own server and keeper workloads are added automatically, e.g. //gvc/GVC_NAME/workload/WORKLOAD_NAME
```

An access-knob change takes up to about five minutes to propagate — re-test before concluding it did not
apply.

## Storage setup

Object storage is required in every deployment mode. Choose one of the providers below.

### AWS S3

1. Create your bucket. Set `aws.bucket` to its name and `aws.region` to its region.

2. If you do not have a Cloud Account set up, refer to the docs to [Create a Cloud Account](https://docs.controlplane.com/guides/create-cloud-account). Set `aws.cloudAccountName`.

3. Create a new IAM policy with the following JSON (replace `YOUR_BUCKET_NAME`), and set `aws.policyName` to its name:

```JSON
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

AWS is the only keyless provider here — access comes from the Cloud Account through the workload identity,
so there is no key to store.

### GCS

ClickHouse reaches GCS over its S3-compatible interface, which requires an interoperability HMAC key. A
Cloud Account is not required.

1. Create your bucket. Set `gcp.bucket` to its name.

2. Navigate to Settings > Interoperability and click `Create a key for a service account`.

3. Click `Create new account` and name your service account.

4. Under `Permissions`, assign the role `Storage Object Admin` and click `Done`.

5. Store the HMAC key in a `dictionary` secret and set `gcp.credentialsSecretName` to that secret's name:

```bash
cpln secret create-dictionary --name my-clickhouse-gcs-credentials \
  --entry accessKeyId=YOUR_HMAC_ACCESS_KEY \
  --entry secretAccessKey=YOUR_HMAC_SECRET
```

To configure using the CLI:

```BASH
gcloud config set project YOUR_PROJECT_ID

# To specify another dual region, replace NAM4
gcloud storage buckets create gs://YOUR_BUCKET_NAME \
  --location=NAM4

gcloud iam service-accounts create clickhouse-storage

gcloud projects add-iam-policy-binding $(gcloud config get-value project) \
  --member="serviceAccount:clickhouse-storage@$(gcloud config get-value project).iam.gserviceaccount.com" \
  --role="roles/storage.objectAdmin"

gsutil hmac create clickhouse-storage@$(gcloud config get-value project).iam.gserviceaccount.com
```

### Azure Blob Storage

ClickHouse uses Azure's native Blob Storage SDK. A Cloud Account is not required — authentication uses a
storage account access key.

1. In the [Azure Portal](https://portal.azure.com), go to **Storage accounts → Create**.
   - Performance: Standard
   - Redundancy: LRS
   - Leave hierarchical namespace off

2. Inside the storage account, go to **Containers → + Container** and create a container (e.g. `clickhouse-data`). Set access level to **Private**. Set `azure.storageAccount` and `azure.container`.

3. Go to **Security + networking → Access keys** and copy either `key1` or `key2`.

4. Store the key in a `dictionary` secret and set `azure.credentialsSecretName` to that secret's name:

```bash
cpln secret create-dictionary --name my-clickhouse-azure-credentials \
  --entry accountKey=YOUR_ACCOUNT_KEY
```

To configure using the CLI:

```BASH
az storage account create \
  --name YOUR_STORAGE_ACCOUNT \
  --resource-group YOUR_RESOURCE_GROUP \
  --sku Standard_LRS

az storage container create \
  --name clickhouse-data \
  --account-name YOUR_STORAGE_ACCOUNT

az storage account keys list \
  --account-name YOUR_STORAGE_ACCOUNT \
  --resource-group YOUR_RESOURCE_GROUP \
  --query "[0].value" -o tsv
```

### Hetzner Object Storage

Hetzner Object Storage is S3-compatible. A Cloud Account is not required — authentication uses an access
key pair. Available regions: `nbg1` (Nuremberg), `hel1` (Helsinki), `fsn1` (Falkenstein).

1. In the Hetzner Cloud console, go to **Object Storage** and create a bucket. Set `hetzner.bucket` and `hetzner.region`.

2. Go to **Security → S3 Credentials** and click **Generate credentials**. Save the **Access Key** and **Secret Key** immediately — the secret will not be shown again.

3. Store the pair in a `dictionary` secret and set `hetzner.credentialsSecretName` to that secret's name:

```bash
cpln secret create-dictionary --name my-clickhouse-hetzner-credentials \
  --entry accessKeyId=YOUR_ACCESS_KEY \
  --entry secretAccessKey=YOUR_SECRET_KEY
```

## Connecting

| What | Where |
|---|---|
| Public endpoint | **None.** This template exposes no public access — `inboundAllowCIDR` is empty and there is no direct load balancer |
| Native protocol (clients, `clickhouse-client`) | `RELEASE_NAME-clickhouse-server.GVC_NAME.cpln.local:9000` |
| HTTP interface | `RELEASE_NAME-clickhouse-server.GVC_NAME.cpln.local:8123` |
| A specific replica | `replica-INDEX.RELEASE_NAME-clickhouse-server.LOCATION.GVC_NAME.cpln.local:9000` |
| Keeper (cluster modes) | `replica-0.RELEASE_NAME-clickhouse-keeper.LOCATION.GVC_NAME.cpln.local:9181` |
| Username | `default` — there is no other user |
| Password / database name | the `password` and `database` entries of your credentials secret |

From another workload in the same GVC:

```bash
clickhouse-client --host RELEASE_NAME-clickhouse-server.GVC_NAME.cpln.local \
  --port 9000 --user default --password 'YOUR-PASSWORD'
```

Always use the fully qualified `.GVC_NAME.cpln.local` form. The bare workload name is not reliable on this
platform — whether it resolves depends on the workload type.

### Tables in cluster modes

Use `ReplicatedMergeTree` plus a `Distributed` table. A plain `MergeTree` in a multi-shard cluster is
single-copy and is not covered by the cluster's availability story.

```sql
CREATE TABLE events_local ON CLUSTER my_cluster (id UInt64, ts DateTime)
ENGINE = ReplicatedMergeTree('/clickhouse/tables/{shard}/events', '{replica}')
ORDER BY id;

CREATE TABLE events ON CLUSTER my_cluster AS events_local
ENGINE = Distributed(my_cluster, currentDatabase(), events_local, rand());
```

`{shard}` and `{replica}` come from each node's `<macros>`, which the chart derives from the location's
position in `locations`.

## Important Notes

- **Never `helm upgrade` a 2.x release onto 3.0.0** — it deletes the GVC the 2.x chart created and everything in it. See [Migrating from 2.x](#migrating-from-2x)
- **The GVC must contain every location you list**, and may contain more. A missing one is not caught at install: the container exits with `FATAL: locations declared in values are not in GVC …`. An already-initialised node logs a `WARNING` instead and keeps serving, so this can never stop a running cluster
- **2 locations is not supported.** Use 1 (single-node or single-shard) or 3 or more
- **Object storage is required in every mode**, including single-node. There is no local-only shape
- **The credentials secret has no `username` key**, and credentials apply on first initialization only — rotate inside ClickHouse first, then update the secret, then force a redeployment. Updating a `cpln://` secret does not restart the workload by itself
- **Switch object-storage providers with a fresh install, not an upgrade.** An identity's cloud binding is never removed once set, so an existing release keeps the old provider's binding attached
- **Keeper is the availability floor.** Three members tolerate one loss; the single-shard shape has one member and tolerates none. If a majority of Keeper locations are missing from the GVC, the containers exit with a named error rather than waiting for an election that can never complete
- **`helm upgrade` restarts every replica in every location at once** — nothing serialises a rolling restart on a stateful workload, so treat an upgrade as a planned query interruption
- **Keep locations and the bucket in the same provider and region family.** Cross-region traffic to object storage is billed on every query that misses the local cache
- **With `workload-list`, list only your clients.** The server and Keeper reach each other over the same internal firewall, so the chart adds this release's own workloads to the list for you
- **A rolling upgrade of a 3-shard cluster is about 83 seconds of total unavailability** (measured), and changing a Keeper setting costs roughly 60 seconds of coordination outage. Plan both as query interruptions
- **Renaming `clusterName` orphans existing `Distributed` tables** — they keep pointing at the old cluster and fail with `Code: 701`. Recreate them after a rename
- **With one replica per shard, losing a shard fails every distributed query** (~60 s to surface), not just the rows on that shard. Add replicas if partial results are not acceptable

## Links

- [ClickHouse Documentation](https://clickhouse.com/docs/)
- [ClickHouse Keeper](https://clickhouse.com/docs/guides/sre/keeper/clickhouse-keeper)
- [Data Replication (ReplicatedMergeTree)](https://clickhouse.com/docs/engines/table-engines/mergetree-family/replication)
- [Distributed Table Engine](https://clickhouse.com/docs/engines/table-engines/special/distributed)
- [Create a Cloud Account](https://docs.controlplane.com/guides/create-cloud-account)
