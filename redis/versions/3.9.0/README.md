## Redis Sentinel

Creates a Redis Sentinel cluster on Control Plane with automatic leader election, failover, and an optional backup configuration. With `mode: dev` it runs a single Redis node with no Sentinel instead, for development and testing.

### Architecture

- **Stateful Redis workload** — one primary plus replicas, each on its own volume set; a single node in dev mode.
- **Stateful Sentinel workload** *(production mode only)* — monitors the primary and promotes a replica on failure; clients discover the current primary through it.
- **Secrets** — Redis and Sentinel configuration, plus password secrets created only when auth is enabled.
- **Identities and policies** — one identity for Redis, shared by the backup job (it also carries the backup cloud binding), and one for Sentinel in production mode; each policy grants `reveal` on only the secrets its tier needs.
- **Domains** *(optional)* — created when public access is enabled, for external TCP reach.
- **Volume sets** *(optional)* — persistence for Redis, and for Sentinel in production mode.
- **Backup cron workload** *(optional)* — a scheduled backup to S3 or GCS.
- **Grafana dashboard** — shipped with the template.

This template does not create a GVC.

### Important Notes

- **`mode: dev` has no failover and is not for production;** with persistence off its data is lost on every restart and upgrade.
- **Do not change the Redis password on a running release.** A restarted replica can no longer authenticate to the master, so the rollout stops advancing; setting the previous password back recovers it. To change the password, uninstall and reinstall.
- **Turn persistence on at install when you can.** Adding it to a running release takes effect only once every node stops, so set `suspend: true` in the same upgrade, then `suspend: false` in the next one. Data held only in memory is lost.
- **The engine is fixed at install.** Valkey cannot read the data files Redis 8 writes, so switching `engine` on a running release crash-loops the nodes (persistence on) or starts them empty (persistence off). Move data between engines with dump/restore or replication.
- **Switching `backup.provider` between `aws` and `gcp` keeps the previous provider's cloud access on the Redis identity.** Remove it by editing the identity or reinstalling the release.

### Mode: production or dev

- **`production`** (default): `redis.replicas` Redis nodes and a Sentinel quorum that fails over automatically.
- **`dev`**: one Redis node that boots as a plain master. **No failover: a restart or reschedule means the database is down until it returns. Not for production.** `redis.replicas` and every `sentinel.*` setting are ignored; Sentinel public access, persistence and auth are refused at render, on install and on upgrade.
- Turn on `redis.persistence.enabled` if dev data must survive restarts and upgrades; see Important Notes for adding it to a running release.
- In dev mode clients connect directly to `RELEASE_NAME-redis.GVC_NAME.cpln.local:6379`; there is no Sentinel to query.

### Moving from dev to production

Set `mode: production` with a `helm upgrade` on the same release. The new replicas copy node 0 first, with or without persistence, while the dev node keeps serving. Node 0 then restarts and Sentinel fails over to one of the new nodes, so the master ends up on node 1 or 2. This failover is expected and keeps the data; Sentinel-aware clients see a write gap of a few seconds. Point clients at Sentinel afterwards (see Connecting).

### Engine: Redis or Valkey

This template runs either server. `engine: redis` is the default and changes nothing.

- **Valkey** is the BSD-3-Clause fork of Redis 7.2, stewarded by the Linux Foundation. There is no paid edition, so nothing — replication, Sentinel, failover — is feature-gated.
- **Both tiers move together.** `engine: valkey` puts the Redis *and* Sentinel workloads on `valkeyImage`; `redis.image` and `sentinel.image` are then ignored. Running different engines on the two tiers is not supported.
- **Nothing else in the chart changes.** The Valkey image ships `redis-server`, `redis-cli` and `redis-sentinel` compatibility symlinks, so every command, config directive and health probe here is identical on both engines. `redis.serverCommand` stays `redis-server` on both.
- **Only the Debian-based Valkey tags are supported.** The `-alpine` tags have no bash, and this chart's readiness and liveness probes are bash scripts.
- **`INFO` reports `redis_version:7.2.4` on Valkey** for client compatibility. To see what is actually running, read `server_name` and `valkey_version`. The marketplace card still shows the Redis `appVersion` — a chart's appVersion is a constant and cannot follow a values knob.
- **Do not set `dual-channel-replication-enabled yes` via `extraArgs` on Valkey** — a [known upstream defect](https://github.com/valkey-io/valkey/issues/2338) makes Sentinel see duplicate replicas.

### Configuration

**Mode** — set at the top of the values:
```yaml
mode: production                  # production | dev. dev = ONE Redis node, NO Sentinel, no failover: development and testing only
```

**Engine** — which server both tiers run:
```yaml
engine: redis                     # redis | valkey
# Used for BOTH tiers when engine is valkey; redis.image / sentinel.image are
# then ignored. Only the Debian-based tags are supported.
valkeyImage: valkey/valkey:8.1.9
```

**Suspend** — stops every workload in the release (Redis, Sentinel and the backup job) without deleting anything:
```yaml
suspend: false                    # true = stop all nodes; volume sets and secrets are kept
```
With persistence on, the data on the volume sets is reloaded when you set it back to `false`; without persistence, the data is lost.

**Redis and Sentinel** — set replicas, resources, and timeouts for each. Sentinel replicas must be an odd number for quorum. In dev mode `redis.replicas` and the `sentinel` block are ignored:
```yaml
redis:
  replicas: 3                     # ignored in dev mode (always 1)
  resources:
    minCpu: 80m
    minMemory: 128Mi
    maxCpu: 200m
    maxMemory: 256Mi

sentinel:
  replicas: 3
  quorumAutoCalculation: true  # calculates as (replicas/2)+1
```

**Authentication** — enable one method. In production mode apply the same config under both `redis.auth` and `sentinel.auth`; dev mode uses `redis.auth` only and refuses `sentinel.auth`:
```yaml
redis:
  auth:
    password:
      enabled: true
      value: change-me-redis-password
    # fromSecret:
    #   enabled: true
    #   name: my-redis-secret
    #   passwordKey: password
```

**Persistence** — disabled by default. Enable to attach a persistent volume to Redis:
```yaml
redis:
  persistence:
    enabled: true
    volumes:
      data:
        initialCapacity: 10
        performanceClass: general-purpose-ssd  # or high-throughput-ssd (min 200 GB)
        fileSystemType: ext4
```

With persistence enabled, each node removes leftover temporary RDB and AOF-rewrite files from the volume before Redis starts, so files from an interrupted sync never accumulate.

**Probe tuning for large datasets** — the startup probe window is derived from the readiness probe:
```
startup window = initialDelaySeconds + (30 × periodSeconds)
```
The default (`10 + 30×5 = 160s`) is sufficient for small datasets. With persistence enabled and a large dataset, replicas must load their local AOF before syncing — which can take 60–120s or more — leaving little time for the actual RDB transfer. Increase `periodSeconds` to extend the window:
```yaml
redis:
  probes:
    readiness:
      initialDelaySeconds: 35  # clears the AOF load window
      periodSeconds: 20         # startup window = 35 + (30×20) = 635s (~10 min)
```

**Metrics exporter** — disabled by default. When enabled, a `redis_exporter` sidecar is added to each Redis pod. Control Plane scrapes `:9121/metrics` automatically every 30 seconds and makes the metrics available in the console:
```yaml
redis:
  exporter:
    enabled: true
```
Use `dropMetrics` to filter high-cardinality series before they are stored (regex patterns matched against metric names):
```yaml
redis:
  exporter:
    dropMetrics:
      - "redis_commands_latencies_usec_bucket"
      - "redis_latency_percentiles_usec"
```

**Grafana Dashboard** — opt-in, k8s clusters only. When enabled, a `GrafanaDashboard` CRD is provisioned via the [Grafana Operator](https://grafana.github.io/grafana-operator/) and automatically appears in your Grafana instance:

```yaml
grafana:
  dashboard:
    enabled: true
  folder: Redis                 # Grafana folder the dashboard is placed in
  datasource: metrics           # name of the Prometheus datasource in your Grafana instance
  instanceSelector:
    matchLabels:
      dashboards: grafana       # must match the label on your Grafana CR
```

On Control Plane's managed platform where no Grafana Operator is present, leave this disabled — the `GrafanaDashboard` CRD will have nothing to reconcile it.

**Prerequisites:**

1. **Grafana Operator installed** in your Kubernetes cluster. The operator must be configured with your Grafana instance URL and a Grafana service account API token (not a Control Plane token):

```bash
kubectl create secret generic grafana-admin-credentials \
  --from-literal=GF_SECURITY_ADMIN_USER=admin \
  --from-literal=GF_SECURITY_ADMIN_PASSWORD=<grafana-api-token> \
  -n grafana-operator
```

2. **A Grafana CR** with a label matching `grafana.instanceSelector.matchLabels`. For example:
```yaml
apiVersion: grafana.integreatly.org/v1beta1
kind: Grafana
metadata:
  name: grafana
  labels:
    dashboards: grafana
spec:
  external:
    url: https://your-org.grafana.cpln.io
    adminPassword:
      name: grafana-admin-credentials
      key: GF_SECURITY_ADMIN_PASSWORD
```

**Included panels:**
- CPU Usage (`cpu_used`) — always included
- Memory Usage (`mem_used`) — always included
- Connected Clients, Redis Memory, Commands/sec, Cache Hit Rate — included when `redis.exporter.enabled: true`

The dashboard includes template variables for datasource, GVC, workload, and replica so you can filter by deployment without editing the dashboard.

**Firewall** — set the internal access scope for each tier:
```yaml
redis:
  firewall:
    internal_inboundAllowType: same-gvc  # same-gvc, same-org, or workload-list

sentinel:
  firewall:
    internal_inboundAllowType: same-gvc
```

### Public Access (External TCP)

Redis and Sentinel can be exposed over the internet via TCP using Control Plane's domain resource with per-replica port routing. Sentinel public access is production mode only; dev mode refuses it.

#### Prerequisites

1. **A domain you control** with DNS managed by your registrar (e.g. Cloudflare)
2. **Dedicated Load Balancer** enabled on your GVC — required for arbitrary TCP port routing. Enable this under your GVC settings in the Control Plane console.
3. **DNS records added before deploying** — Control Plane will reject the domain resource on first deploy if ownership has not been proven. Add the following records in your DNS provider for each address before running the deployment. **Disable proxying** (e.g. Cloudflare's orange cloud) — TCP traffic must pass through directly:

| Type | Name | Value |
|------|------|-------|
| TXT | `_cpln-<subdomain>` | your Control Plane org name or org ID (either is accepted) |
| CNAME | `<subdomain>` | `<gvc-alias>.cpln.app` |

Your GVC alias is visible in the Control Plane console under GVC settings. The TXT record proves domain ownership — without it, the first deploy will fail with an `Unable to apply domain` error.

#### Configuration

Enable `publicAccess` for Redis and/or Sentinel (production mode only) and set a subdomain you own:

```yaml
redis:
  publicAccess:
    enabled: true
    address: redis.your-domain.com
  firewall:
    internal_inboundAllowType: same-gvc
    external_inboundAllowCIDR: "0.0.0.0/0"  # or restrict to specific CIDRs

sentinel:
  publicAccess:
    enabled: true
    address: redis-sentinel.your-domain.com
  firewall:
    internal_inboundAllowType: same-gvc
    external_inboundAllowCIDR: "0.0.0.0/0"
```

When enabled, a Control Plane `domain` resource is created for each address. Port mapping is one port per replica:
- **Redis**: ports `6380`, `6381`, ... (replica 0, 1, ...)
- **Sentinel**: ports `26380`, `26381`, `26382`, ... (replica 0, 1, 2, ...)

After DNS propagates, the domain status in Control Plane will show **Ready**. You can verify the full DNS chain resolves correctly with:

```bash
dig <subdomain>.your-domain.com CNAME   # should return <gvc-alias>.cpln.app
dig <gvc-alias>.cpln.app               # should return an IP address
```

#### Connecting Externally (Public Access Enabled)

```bash
# add -a <password> if auth is enabled

# Redis replica 0
redis-cli -h redis.your-domain.com -p 6380 ping

# Redis replica 1
redis-cli -h redis.your-domain.com -p 6381 ping

# Sentinel replica 0
redis-cli -h redis-sentinel.your-domain.com -p 26380 ping
```

### Connecting

Redis is accessible internally on port 6379:
```
RELEASE_NAME-redis.GVC_NAME.cpln.local:6379
```

Sentinel (production mode) is accessible on port 26379:
```
RELEASE_NAME-sentinel.GVC_NAME.cpln.local:26379
```

To route writes to the current master:
```bash
MASTER_INFO=$(redis-cli -h RELEASE_NAME-sentinel.GVC_NAME.cpln.local -p 26379 SENTINEL get-master-addr-by-name mymaster)
MASTER_HOST=$(echo $MASTER_INFO | cut -d' ' -f1)
MASTER_PORT=$(echo $MASTER_INFO | cut -d' ' -f2)
redis-cli -h $MASTER_HOST -p $MASTER_PORT SET my-key "value"
```

### Backing Up

Set `backup.enabled` to `true`, configure your provider, and set your desired schedule. The backup image is compatible with all Redis versions.

```yaml
backup:
  enabled: true
  schedule: "0 2 * * *"  # daily at 2am UTC
  provider: aws           # Options: aws or gcp
```

#### AWS S3

For the backup cron job to access an S3 bucket, complete the following in your AWS account first:

1. Create your bucket. Set `backup.aws.bucket` to its name and `backup.aws.region` to its region.

2. If you do not have a Cloud Account set up, refer to the docs to [Create a Cloud Account](https://docs.controlplane.com/guides/create-cloud-account). Set `backup.aws.cloudAccountName` to its name.

3. Create a new IAM policy with the following JSON (replace `YOUR_BUCKET_NAME`) and set `backup.aws.policyName` to match:

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

#### GCS

For the backup cron job to access a GCS bucket, complete the following in your GCP account first:

1. Create your bucket. Set `backup.gcp.bucket` to its name.

2. If you do not have a Cloud Account set up, refer to the docs to [Create a Cloud Account](https://docs.controlplane.com/guides/create-cloud-account). Set `backup.gcp.cloudAccountName` to its name.

**Important**: You must add the `Storage Admin` role when creating your GCP service account.

### Restoring a Backup

Each backup is a standard gzipped RDB file (`redis-TIMESTAMP.rdb.gz`). This template does not provide an in-place restore into a running release.

To use a backup, decompress it and start a standalone Redis or Valkey server with AOF disabled and the file in place as its `dump.rdb` (for example locally with Docker). From there, inspect the data or replay it into your cluster with your own tooling.

- Placing a `dump.rdb` in the cluster's data directory has no effect: the cluster runs with AOF enabled, and Redis loads the AOF at startup.
- `redis-cli --rdb FILE` downloads a dump from a server; it does not load one, and pointing it at your backup file overwrites it.

### Upgrading

- **From 3.4.x:** the default image is `redis:8`, which reads 7.4 data directly. The upgrade is one-way: once a node writes under Redis 8, a 7.4 image cannot load its data. Snapshot the volume set first if you want a rollback path, or pin `redis.image` and `sentinel.image` to `redis:7.4`.
- **From 3.5.0:** the backup identity carries only the bucket-scoped policy you supply. Make sure your IAM policy has the full action list under [AWS S3](#aws-s3) before upgrading.
- **From 3.5.1:** resource blocks that expose both a reservation and a limit name the limit `maxCpu`/`maxMemory`. Rename `cpu`/`memory` in those blocks; an upgrade that still uses the old names is refused at render. Blocks that expose only a limit keep `cpu`/`memory`.

### Supported External Services
- [Redis Documentation](https://redis.io/docs/)
- [Redis Sentinel Documentation](https://redis.io/docs/latest/operate/oss_and_stack/management/sentinel/)
- [Valkey Documentation](https://valkey.io/topics/)
- [Valkey Sentinel](https://valkey.io/topics/sentinel/)
- [Migrating between Redis and Valkey](https://valkey.io/topics/migration/)

### Release Notes
See [RELEASES.md](https://github.com/controlplane-com/templates/blob/main/redis/RELEASES.md)
