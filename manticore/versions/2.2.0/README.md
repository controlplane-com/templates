# Manticore Search Cluster

> **Upgrading from 2.1.0:** resource blocks that expose both a floor and a ceiling now name the
> ceiling `maxCpu`/`maxMemory` instead of `cpu`/`memory`, so it is no longer ambiguous which number
> is the limit. Rename those two keys in your values; an upgrade that still carries the old names is
> refused at render. Blocks that expose only a limit keep the bare `cpu`/`memory` names.


Manticore Search is an open-source full-text search engine. This template deploys a replicated Manticore cluster with Galera replication, an orchestrator that performs coordinated zero-downtime CSV imports from S3, optional S3 backups, and a web dashboard.

## Architecture

- **Manticore workload** (stateful) — searchd replicas, each with an agent sidecar that performs local table operations
- **Orchestrator API** (standard) — REST API coordinating cluster-wide init, import, repair and backup
- **Orchestrator job** (cron) — runs the actual init/import/health/repair actions; ships suspended, triggered on demand
- **Web UI** (standard) — dashboard for cluster health, imports, backups and repairs; internal-only by default
- **Volumesets** — one per-replica volume for data and cluster state, plus one shared volume used to hand off import artifacts
- **Backup job** (cron, optional) — logical delta/main backups to S3
- **Load-test workloads** (optional) — k6 runner plus a cron controller that scales it up and back to zero
- **Domain** (optional) — routes `/api/*` to the orchestrator API and everything else to the UI

## Prerequisites

1. **Agent token secret** — a bearer token shared by the orchestrator, agents and UI. **It must exist before you install**; a missing secret leaves the deployment waiting on it and looks like a platform fault. Create it with:

   ```bash
   printf '%s' "$(openssl rand -base64 32)" | cpln secret create-opaque --name my-manticore-agent-token --encoding plain -f -
   ```

   Then set `orchestrator.agent.tokenSecretName` to that name. Rotating the token means updating the secret and redeploying every component.

2. **S3 bucket** holding the CSV files you want to import, plus a Control Plane cloud account with access to it — see [Storage setup](#storage-setup).
3. **Second S3 bucket and policy** only if you enable `orchestrator.backup` — this one does need write access, see [Backup bucket](#backup-bucket-only-with-orchestratorbackupenabled).

## Storage setup

Only AWS S3 is supported. The source bucket is mounted **read-only** — imports read the CSVs and write every scratch artifact (TSV, indexer config, built index) to the shared volume, never to the bucket. Backups go to a **separate** bucket, which does need write access.

1. **Create the bucket** in the AWS console (S3 → Create bucket) and upload your CSVs, e.g. to `imports/addresses.csv`.
2. **Create an IAM policy** (IAM → Policies → Create policy → JSON) for the source bucket, replacing `my-manticore-bucket`:

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Effect": "Allow",
         "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
         "Resource": "arn:aws:s3:::my-manticore-bucket"
       },
       {
         "Effect": "Allow",
         "Action": ["s3:GetObject"],
         "Resource": "arn:aws:s3:::my-manticore-bucket/*"
       }
     ]
   }
   ```

3. **Create a Control Plane cloud account** for your AWS account following the [Create a Cloud Account](https://docs.controlplane.com/guides/create-cloud-account) guide, and attach the policy above to the role it uses.
4. **Reference both** in `buckets.cloudAccountName` and `buckets.awsPolicyRefs`. Custom policies are named without a prefix; only AWS-managed policies take the `aws::` prefix.

### Backup bucket (only with `orchestrator.backup.enabled`)

Backups are written by a separate workload under its own identity, so give them their own bucket and their own policy — do not widen the source policy. Replacing `my-manticore-backup-bucket`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket", "s3:GetBucketLocation"],
      "Resource": "arn:aws:s3:::my-manticore-backup-bucket"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::my-manticore-backup-bucket/*"
    }
  ]
}
```

Set `orchestrator.backup.cloudAccountName`, `s3Bucket`, `s3Region` and `s3Policy` to match. `GetObject` and `DeleteObject` are there so restores can read an archive back and lifecycle cleanup can remove one; a backup-only install can drop them.

## Configuration

### Buckets

```yaml
buckets:
  cloudAccountName: my-manticore-cloudaccount    # Name of your configured Cloud Account
  awsPolicyRefs:                        # IAM policies for S3 access
    - my-manticore-policy       # Note: if using a custom policy, omit the aws:: prefix as this is only for AWS managed policies
  awsRegion: us-east-1                  # Region of your S3 bucket
  sourceBucket: my-manticore-bucket               # S3 bucket containing files to import
```

### Tables

One entry per searchable table. `csvPath` is a path within `buckets.sourceBucket`, or a list of paths for a multi-segment table.

```yaml
tables:
  - name: addresses
    csvPath:
      - imports/addresses.csv
    config:
      haStrategy: noerrors        # Distributed-query HA strategy; noerrors skips agents returning errors
      agentRetryCount: 3          # Retries for a failed agent connection
      clusterMain: false          # true replicates the main table across all nodes
      segmentCount: 1             # Must equal the number of csvPath entries
      charsetTable: non_cont      # Manticore charset_table preset; omit for the engine default
      memLimit: 2G                # Indexer memory limit during import
      hasHeader: true             # true if the CSV has a header row
      secondaryIndexes: false     # Build secondary indexes on attributes
    schema:
      columns:                    # See "Column types" below
        - name: address_id
          type: attr_uint
        - name: street_number
          type: attr_uint
        - name: street_name
          type: field
        - name: city
          type: field
        - name: county
          type: field
        - name: state
          type: field
        - name: postal_code
          type: field
        - name: country
          type: field
        - name: latitude
          type: attr_float
        - name: longitude
          type: attr_float
```

### Manticore

```yaml
manticore:
  image: manticoresearch/manticore:25.0.0
  clusterName: manticore          # Galera cluster name
  resources:
    cpu: 4
    memory: 8Gi
  volumeset:
    capacity: 200                 # GB per replica
  sharedVolumeset:
    capacity: 100                 # GB shared across replicas and orchestrator
  autoscaling:
    minScale: 3                   # Replica count the orchestrator coordinates across
    maxScale: 4
    metric: rps
    target: 100
    scaleToZeroDelay: 300
  rolloutOptions:
    maxSurgeReplicas: 25%
    minReadySeconds: 10
    scalingPolicy: OrderedReady
    terminationGracePeriodSeconds: 60
  firewall:
    internalAccess:
      type: same-gvc              # Required for Galera replication — do not narrow
      workloads: []
```

### Orchestrator

```yaml
orchestrator:
  version: v6.0.5
  image: ghcr.io/controlplane-com/manticore-orchestrator/manticore-cpln-api
  logLevel: debug                 # debug, info, warn, error
  resources:
    cpu: 1
    memory: 2Gi
  schedule: "0 * * * *"           # Cron schedule (default = every hour)
  action: import                  # init, import, health, repair
  tableName: addresses            # Must match a name in tables[]
  suspend: true                   # Start suspended (trigger via UI/API)
  timeoutSeconds: 900             # Container timeout (seconds, default 15 minutes)
  importMemLimit: 2G              # Memory limit for import jobs
  activeDeadlineSeconds: 14400    # Max job runtime (seconds, default 4 hours)

  api:
    version: v6.0.5
    image: ghcr.io/controlplane-com/manticore-orchestrator/manticore-cpln-api
    logLevel: debug
    importPollInterval: 30s
    importPollTimeout: 2h
    resources:
      cpu: 0.25
      memory: 256Mi
    autoscaling:
      maxScale: 3
      minScale: 2
      metric: cpu
      target: 80

  agent:
    version: v6.0.5
    image: ghcr.io/controlplane-com/manticore-orchestrator/manticore-cpln-agent
    tokenSecretName: my-manticore-agent-token   # Opaque secret — MUST EXIST BEFORE INSTALL
    resources:
      maxCpu: 250m
      minCpu: 100m
      memory: 512Mi
      minMemory: 128Mi
    import:
      batchSize: 20000            # Rows per INSERT statement
    recovery:
      maxRetries: 5               # Retry attempts for cluster recovery
      initialBackoffSec: 5        # Initial delay between retries
      maxBackoffSec: 60           # Max backoff delay (exponential)

  ui:
    version: v6.0.5
    image: ghcr.io/controlplane-com/manticore-orchestrator/manticore-cpln-ui
    resources:
      cpu: 0.25
      memory: 0.25Gi
    publicAccess:
      enabled: false              # true publishes an UNAUTHENTICATED admin UI — see Important Notes
    internalAccess:
      type: same-gvc              # same-gvc, same-org, workload-list, none
      workloads: []               # //gvc/{gvc}/workload/{name} links, used when type is workload-list
    autoscaling:
      maxScale: 2
      minScale: 1
      metric: cpu
      target: 80

  backup:
    enabled: false
    version: v6.0.5
    image: ghcr.io/controlplane-com/manticore-orchestrator/manticore-cpln-backup
    cloudAccountName: my-manticore-backup-cloudaccount
    s3Bucket: my-manticore-backup-bucket    # S3 bucket for backups
    s3Policy:                               # IAM policies for S3 access
      - my-manticore-backup-policy          # Custom policy created in S3 setup instructions
    s3Region: us-east-1
    dataSet: addresses            # Data set to back up
    prefix: manticore-backups     # S3 prefix/folder for backups
    schedules: [
      {"table":"addresses","type":"delta","schedule":"0 2 * * *"},     # Daily at 2am UTC
      {"table":"addresses","type":"main","schedule":"0 2 1 * *"}       # Monthly full backup on 1st at 2am UTC
      ]
    activeDeadlineSeconds: 14400  # Max job runtime (seconds, default 4 hours)
    resources:
      cpu: 1
      memory: 1Gi
```

### Domain (optional)

```yaml
domain:
  enabled: false
  name: ""                        # FQDN, e.g., manticore.example.com
  dnsMode: cname                  # cname (subdomains) or ns (zone delegation)
```

### Load testing (optional)

```yaml
loadTest:
  enabled: false
  image: grafana/k6:0.47.0
  resources:
    cpu: 0.5
    memory: 512Mi
  vus: 10                         # Virtual users
  duration: "5m"                  # Test duration (e.g., 30s, 5m, 1h)
  rps: null                       # Target RPS (null = unlimited)
  replicas: 1                     # Number of k6 pods to spawn
  controller:
    image: alpine/curl            # Alpine image with curl pre-installed
    schedule: ""                  # Cron expression (empty = manual only)
    testDurationBuffer: 60        # Seconds added to duration before scale-down
  target:
    port: 9308                    # Manticore HTTP API port
    endpoint: search              # "search" or "sql"
  query:                          # Full JSON body for the /search endpoint
    index: addresses
    query:
      match:
        "*": "test"
    limit: 10
  thresholds:
    p95ResponseTime: 500          # ms
    errorRate: 0.01               # 1%
```

Trigger a run with `cpln workload cron start {release}-load-test-controller --gvc {gvc}`; the controller scales the k6 workload up, waits `duration + testDurationBuffer`, then scales it back to zero. Read the results — including whether each threshold passed — from the runner's own log:

```bash
cpln logs '{gvc="{gvc}", workload="{release}-load-test", container="k6"}' --since 15m
```

The last lines are k6's end-of-test summary (`http_req_duration`, `http_req_failed`, a `✓`/`✗` per threshold) followed by `k6 exited with status N` — non-zero means a threshold was breached. The runner idles after the test rather than exiting, so the summary survives; it stops costing anything once the controller scales it to zero.

## Connecting

| Target | Address | Notes |
|---|---|---|
| Manticore SQL | `{release}-manticore.{gvc}.cpln.local:9306` | MySQL protocol, no auth — GVC-internal only |
| Manticore HTTP | `{release}-manticore.{gvc}.cpln.local:9308` | JSON search API, no auth |
| Orchestrator API | `{release}-orchestrator-api.{gvc}.cpln.local:8080` | Requires `Authorization: Bearer {token}` |
| Web UI | `{release}-ui.{gvc}.cpln.local:3000` | Public `*.cpln.app` endpoint only when `orchestrator.ui.publicAccess.enabled` is true |
| Custom domain | `https://{domain.name}` | `/api/*` → orchestrator API, `/*` → UI |

The bearer token is whatever you stored in the secret named by `orchestrator.agent.tokenSecretName`. Read it back with `cpln secret reveal my-manticore-agent-token`.

## Authentication

The token authenticates **machine-to-machine** calls: orchestrator ↔ agents, and the API's own endpoints. It is not a user login.

The UI has **no authentication of its own**. It holds the token server-side and attaches it to every request it makes on a visitor's behalf, so reaching the UI is equivalent to holding the admin token — a visitor can trigger imports, restores and repairs. Manticore's own SQL and HTTP ports are likewise unauthenticated and rely entirely on the GVC firewall.

Keep `orchestrator.ui.publicAccess.enabled: false` and reach the UI from inside the GVC, or place an authenticating proxy in front of it. Firewall changes take up to a couple of minutes to take effect.

## Column types

| Type | Description |
|------|-------------|
| `field` | Full-text searchable field |
| `field_string` | Full-text field (string variant) |
| `attr_uint` | Unsigned integer attribute |
| `attr_bigint` | Big integer attribute |
| `attr_float` | Float attribute |
| `attr_bool` | Boolean attribute |
| `attr_string` | String attribute (not full-text indexed) |
| `attr_timestamp` | Timestamp attribute |
| `attr_multi` | Multi-value integer attribute |
| `attr_multi_64` | Multi-value 64-bit integer attribute |
| `attr_json` | JSON attribute |

If the first CSV column is numeric it becomes the document ID and must not be declared; otherwise an ID is generated.

## Multi-segment tables

Split a large dataset across several CSV files and query them as one distributed table. Set `csvPath` to a list and `segmentCount` to its length — the chart fails at render time if they disagree.

```yaml
tables:
  - name: addresses
    csvPath:
      - large-file/part1.csv
      - large-file/part2.csv
    config:
      segmentCount: 2
      memLimit: 2G
      hasHeader: true
    schema:
      columns:
        - name: street_name
          type: field
```

A backup of a multi-segment table covers all segments as one archive, and a restore replaces all of them.

## Operations

The orchestrator job ships suspended. Set `orchestrator.action` to the action you want, then trigger a run from the UI or the CLI:

```bash
cpln workload cron start {release}-orchestrator-job --gvc {gvc}
```

`init` bootstraps the Galera cluster, `import` loads CSVs into a fresh slot and swaps it in, `health` reports cluster state, and `repair` recovers from split brain. The UI exposes the same actions plus backup and restore.

## Backup and restore

With `orchestrator.backup.enabled: true`, `schedules` drives automated delta and main backups to S3. Run them on demand from the UI, or against the orchestrator API:

```bash
# Back up ("type": "delta" or "main")
curl -X POST "http://{release}-orchestrator-api.{gvc}.cpln.local:8080/api/backup" \
  -H "Authorization: Bearer {token}" -H "Content-Type: application/json" \
  -d '{"tableName": "addresses", "type": "delta"}'

# List available backups — "type" defaults to delta, so pass type=main to see full backups
curl "http://{release}-orchestrator-api.{gvc}.cpln.local:8080/api/backups/files?tableName=addresses&type=main" \
  -H "Authorization: Bearer {token}"

# Restore
curl -X POST "http://{release}-orchestrator-api.{gvc}.cpln.local:8080/api/restore" \
  -H "Authorization: Bearer {token}" -H "Content-Type: application/json" \
  -d '{"tableName": "addresses", "type": "delta", "filename": "addresses_delta-2026-01-28T22-50-49Z.tar.gz"}'
```

The backup cron workload only runs **delta** backups on its own schedule; main backups come from `schedules`, the UI, or the API call above. Restore is available only through the UI or the API — there is no `orchestrator.action: restore`. A restore scales the cluster up by one replica while it runs and puts it back afterwards.

After restoring a main table, use the UI's **Rotate Main** control to swap the active slot.

## Important Notes

- Create the agent-token secret **before** installing; without it the deployment hangs waiting on a secret that does not exist.
- Enabling `orchestrator.ui.publicAccess` puts an unauthenticated admin console on the public internet. Only do it behind your own authenticating proxy.
- Manticore's 9306/9308 ports have no authentication — keep `manticore.firewall.internalAccess.type` at `same-gvc`, which Galera replication also requires.
- Tables are empty until you run an `init` followed by an `import`; the install alone does not load data.
- The source bucket only ever needs read access; scratch files go to the shared volume. Only the optional backup bucket needs write.
- `manticore.autoscaling.minScale` is the replica count the orchestrator coordinates across; changing it after the cluster is initialized requires a `repair`.
- Any `helm upgrade` — including one that changes nothing — restarts every Manticore replica one at a time (`scalingPolicy: OrderedReady`); budget ~6-7 minutes at the default 3 replicas. Indexed data survives, and searches keep serving from the replicas that are still up.
- Uninstalling deletes the volumesets and all indexed data. Take a backup first if you need it.

## Links

- [Manticore Search manual](https://manual.manticoresearch.com/)
- [Real-time tables](https://manual.manticoresearch.com/Creating_a_table/Local_tables/Real-time_table)
- [Replication setup](https://manual.manticoresearch.com/Creating_a_cluster/Setting_up_replication/Setting_up_replication)
- [Orchestrator, agent, UI and backup source](https://github.com/controlplane-com/manticore-orchestrator)
- [Create a Control Plane cloud account](https://docs.controlplane.com/guides/create-cloud-account)
