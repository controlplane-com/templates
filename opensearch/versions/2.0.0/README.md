# OpenSearch

OpenSearch is an Apache-2.0 search and analytics engine for full-text search, log analytics and security monitoring. This template deploys a multi-node OpenSearch cluster with the security plugin on (a login, TLS on every connection and a security audit log), Security Analytics for Sigma-rule threat detection, an optional Dashboards UI, an optional demo log pipeline, and optional automated snapshots to AWS S3 or GCS.

## Architecture

- **Stateful OpenSearch Workload** — (`RELEASE_NAME-opensearch`): a cluster of `replicas` nodes serving HTTPS on `9200` and TLS transport on `9300`, using `replicaDirect` so nodes can discover each other. At every start each node signs its own certificate from your CA.
- **Volume Set** — (`RELEASE_NAME-opensearch-vs`): persistent storage per node, with optional autoscaling.
- **Startup Secret** — the node startup script: it issues the node certificates, writes the security configuration and installs the snapshot repository plugin when backups are enabled.
- **Identities & Policies** — the node identity may reveal the startup, credentials and CA secrets; a client identity, used by Dashboards and the setup jobs, may reveal only the credentials secret. When backups are enabled, the node identity also carries the Cloud Account binding used to reach your bucket.
- **Dashboards Workload** *(optional)* — (`RELEASE_NAME-opensearch-dashboard`): the web UI on port `5601`, created when `dashboard.enabled: true`.
- **Backup Setup Workload** *(optional)* — a one-time job that registers the snapshot repository and creates the snapshot policy, created when `backup.enabled: true`.
- **Demo Log Pipeline** *(optional)* — a log generator, a Fluent Bit sidecar, its own identity, policy and volume set, and a one-time setup job that also creates a sample Security Analytics detector, created when `demoLogs.enabled: true`.

This template does not create a GVC. Deploy it into an existing one.

## Prerequisites

Two dictionary secrets must exist **before** you install. If one is missing, the nodes never start and `cpln logs` shows nothing; read the reason with `cpln workload get-deployments RELEASE_NAME-opensearch --gvc GVC_NAME -o yaml` (`status.versions[].message`).

**1. Credentials** — the `admin` password, the password Dashboards uses to reach OpenSearch, and the Dashboards session-cookie key (32+ characters):

```bash
cpln secret create-dictionary --name my-opensearch-credentials \
  --entry password="$(openssl rand -hex 16)" \
  --entry dashboardsPassword="$(openssl rand -hex 16)" \
  --entry cookieSecret="$(openssl rand -hex 32)"
```

Set `security.credentialsSecretName` to its name. Read the admin password back with `cpln secret reveal my-opensearch-credentials -o yaml`.

**2. Certificate authority** — a CA the nodes sign their own certificates from, stored as a base64 PKCS#12 plus its passphrase:

```bash
openssl req -x509 -newkey rsa:3072 -nodes -keyout ca.key -out ca.crt -days 3650 -subj "/CN=opensearch-ca" \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign"
P="$(openssl rand -hex 16)"
openssl pkcs12 -export -inkey ca.key -in ca.crt -out ca.p12 -passout pass:"$P"
cpln secret create-dictionary --name my-opensearch-ca \
  --entry keystore="$(base64 < ca.p12 | tr -d '\n')" --entry passphrase="$P"
```

Set `security.caSecretName` to its name. Keep `ca.crt`: your applications use it to verify the cluster's certificate. Store `ca.key` safely or delete it; the secret holds the key.

Backups also need a bucket and a Control Plane Cloud Account, see [Storage setup](#storage-setup).

## Configuration

**Cluster** — `replicas` must be odd (quorum):

```yaml
image: opensearchproject/opensearch:3.8.0

replicas: 3 # Must be odd

clusterName: my-opensearch-cluster
```

**Resources** — per node; raise `maxMemory` before CPU:

```yaml
resources:
  minCpu: 500m
  minMemory: 2Gi
  maxCpu: 1
  maxMemory: 4Gi
```

**Volume** — per node:

```yaml
volumeset:
  capacity: 10 # initial capacity in GiB (minimum is 10)
  autoscaling:
    enabled: false # Set to true to enable autoscaling
    maxCapacity: 100 # Maximum capacity in GiB when autoscaling is enabled
    minFreePercentage: 10 # Minimum free percentage to trigger scaling when autoscaling is enabled
    scalingFactor: 1.2 # Scaling factor to determine how much to scale up when autoscaling is triggered
```

**Security** — the two [prerequisite](#prerequisites) secrets:

```yaml
security:
  credentialsSecretName: my-opensearch-credentials # dictionary: password (admin), dashboardsPassword (kibanaserver), cookieSecret (32+ chars)
  caSecretName: my-opensearch-ca # dictionary: keystore (base64 PKCS#12 with the CA certificate and key), passphrase
```

**Internal access** — which workloads may reach `9200` (every request still needs credentials):

```yaml
internal_access:
  type: same-gvc # options: same-gvc, same-org, workload-list
  workloads:  # Note: can only be used if type is same-gvc or workload-list
    #- //gvc/GVC_NAME/workload/WORKLOAD_NAME
    #- //gvc/GVC_NAME/workload/WORKLOAD_NAME
```

With `workload-list`, list the additional clients only: the chart always allows its own workloads (the nodes, Dashboards, the demo and backup jobs).

**Dashboards:**

```yaml
dashboard:
  enabled: true
  image: opensearchproject/opensearch-dashboards:3.8.0
  resources:
    cpu: 250m
    memory: 1Gi
  publicAccess:
    enabled: false # true publishes the login page on an HTTPS *.cpln.app endpoint
```

**Demo logs** — sample logs in a `demo-logs` index plus a sample detector:

```yaml
demoLogs:
  enabled: false
  remove_setup_workload: false # Set to true after demo logs startup is no longer needed to reduce resource usage
```

**Backups** — see [Storage setup](#storage-setup) first:

```yaml
backup:
  enabled: false      # Set to true to enable automated snapshots
  remove_setup_workload: false # Set to true after backup setup is no longer needed to reduce resource usage

  # Cloud provider: aws or gcp
  provider: aws

  # Backup schedule (cron format, UTC timezone)
  schedule: 0 2 * * *  # Daily at 2am UTC

  # Snapshot retention
  retention:
    maxAge: 30d        # Delete snapshots older than 30 days
    maxCount: 30       # Keep maximum 30 snapshots

  # AWS S3 Configuration
  aws:
    bucket: my-s3-bucket                 # S3 bucket name (required if provider=aws)
    region: us-east-1                    # S3 bucket region (required if provider=aws)
    prefix: opensearch-snapshots         # Path prefix in bucket
    cloudAccountName: my-cloud-account   # Control Plane Cloud Account name (required)
    policyName: my-backup-policy         # AWS IAM custom policy name (required)

  # GCP GCS Configuration
  gcp:
    bucket: my-gcs-bucket                # GCS bucket name (required if provider=gcp)
    prefix: opensearch-snapshots         # Path prefix in bucket
    cloudAccountName: my-cloud-account   # Control Plane Cloud Account name (required)
```

## Connecting

| What | Value |
|---|---|
| OpenSearch API (same GVC) | `https://RELEASE_NAME-opensearch.GVC_NAME.cpln.local:9200` |
| Dashboards UI (private) | `cpln port-forward RELEASE_NAME-opensearch-dashboard 5601:5601 --gvc GVC_NAME`, then `http://localhost:5601` |
| Dashboards UI (public) | the `status.canonicalEndpoint` of `RELEASE_NAME-opensearch-dashboard` (`cpln workload get RELEASE_NAME-opensearch-dashboard --gvc GVC_NAME -o yaml`) |
| Credentials | user `admin`, password = the `password` key of your credentials secret |

Verify from any workload in the same GVC, with `ca.crt` from the prerequisite step:

```bash
curl --cacert ca.crt -u "admin:ADMIN_PASSWORD" "https://RELEASE_NAME-opensearch.GVC_NAME.cpln.local:9200/_cluster/health?pretty"
```

Plain `http://` is refused. In Dashboards, log in as `admin` and pick the **Global** tenant to share saved objects with other users.

## Security Analytics

Security Analytics runs Sigma rules over your log indices and records findings and alerts. To use it with your own logs:

1. Ship logs into an index (Fluent Bit, Logstash, OpenTelemetry or the bulk API).
2. In Dashboards, open **Security Analytics → Detectors → Create detector**, choose the index and a log type (CloudTrail, VPC Flow, DNS, Windows and others ship with prepackaged rules), and map the fields it asks for.
3. Findings appear under **Findings**; add a trigger with a notification channel to be alerted.

With `demoLogs.enabled: true`, detector `demo-auth-failures` watches the `demo-logs` index for `Invalid authentication token` messages, and its findings appear within a few minutes.

## Storage setup

Required only when `backup.enabled: true`.

### AWS S3

1. Create your bucket. Set `backup.aws.bucket` to its name and `backup.aws.region` to its region.
2. If you do not have one, [create a Cloud Account](https://docs.controlplane.com/guides/create-cloud-account). Set `backup.aws.cloudAccountName` to its name.
3. Create an IAM policy with the following JSON, replacing `YOUR_BUCKET_NAME`, and set `backup.aws.policyName` to its name:

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
                "s3:GetBucketLocation",
                "s3:ListBucketMultipartUploads",
                "s3:AbortMultipartUpload",
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

Keep both ARNs: listing authorizes against the bucket, object actions against `bucket/*`.

### GCS

1. Create your bucket. Set `backup.gcp.bucket` to its name.
2. If you do not have one, [create a Cloud Account](https://docs.controlplane.com/guides/create-cloud-account). Set `backup.gcp.cloudAccountName` to its name.
3. Grant the Cloud Account's service account the **Storage Admin** role. Access is keyless — no credentials are stored.

## Snapshots

The backup setup job registers a `backup-repo` snapshot repository and a policy matching your schedule and retention. Once it has run successfully you can set `backup.remove_setup_workload: true` and upgrade to reclaim its resources; scheduled snapshots continue.

Take or inspect snapshots from any workload in the same GVC. Set `OS=https://RELEASE_NAME-opensearch.GVC_NAME.cpln.local:9200` and `AUTH="admin:ADMIN_PASSWORD"` first:

```bash
# Take a manual snapshot
curl --cacert ca.crt -u "$AUTH" -X PUT "$OS/_snapshot/backup-repo/manual-$(date +%Y%m%d-%H%M%S)"

# List all snapshots
curl --cacert ca.crt -u "$AUTH" "$OS/_snapshot/backup-repo/_all?pretty"
```

### Restoring

OpenSearch snapshots are raw index segment files, not dumps. Restore through the API. Always leave out `.opendistro_security`: it holds the live users and roles.

**Into an empty cluster** — nothing to conflict with:

```bash
curl --cacert ca.crt -u "$AUTH" -X POST "$OS/_snapshot/backup-repo/SNAPSHOT_NAME/_restore" \
  -H 'Content-Type: application/json' \
  -d '{"indices": "*,-.opendistro_security", "ignore_unavailable": true, "include_global_state": false}'
```

**Over existing indices** — an open index cannot be restored into, so close the indices you restore first (never `_all`, which would close the security index and lock everyone out):

```bash
curl --cacert ca.crt -u "$AUTH" -X POST "$OS/INDEX_NAME/_close"
curl --cacert ca.crt -u "$AUTH" -X POST "$OS/_snapshot/backup-repo/SNAPSHOT_NAME/_restore" \
  -H 'Content-Type: application/json' \
  -d '{"indices": "INDEX_NAME", "ignore_unavailable": true, "include_global_state": false}'
curl --cacert ca.crt -u "$AUTH" -X POST "$OS/INDEX_NAME/_open"
```

**Alongside existing indices** — restore under new names, leaving live data untouched:

```bash
curl --cacert ca.crt -u "$AUTH" -X POST "$OS/_snapshot/backup-repo/SNAPSHOT_NAME/_restore" \
  -H 'Content-Type: application/json' \
  -d '{"indices": "*,-.opendistro_security", "rename_pattern": "(.+)", "rename_replacement": "restored-$1",
       "ignore_unavailable": true, "include_global_state": false}'
```

Monitor with `curl --cacert ca.crt -u "$AUTH" "$OS/_cat/recovery?v&active_only=true"`.

## Upgrading from 1.0.x

2.0.0 turns the security plugin on, so every client changes:

1. Create both [prerequisite secrets](#prerequisites) and set `security.credentialsSecretName` and `security.caSecretName`.
2. Upgrade. The nodes restart one at a time, about 11 minutes on three nodes. Old and new nodes cannot talk to each other, so the API is unavailable for 2-5 minutes while the first nodes come up on TLS, and plain-HTTP clients fail from the first restart. Your indices are kept.
3. Point every client at `https://` with the `admin` user (or a user you create), and trust `ca.crt`.
4. Saved objects from 1.0.x are in the **Global** tenant of Dashboards.

If a node or Dashboards still waits about 5 minutes after the upgrade, run `cpln workload force-redeployment WORKLOAD_NAME --gvc GVC_NAME`: new identities and grants can take a few minutes to apply.

## Important Notes

- **Both prerequisite secrets must exist before install.** A missing one leaves the nodes waiting with nothing in the logs; `cpln workload get-deployments RELEASE_NAME-opensearch --gvc GVC_NAME -o yaml` names it.
- **The `admin` and `kibanaserver` passwords come from the credentials secret at every node start.** A password changed in Dashboards reverts at the next restart. To rotate, update the secret, then run `cpln workload force-redeployment` on `RELEASE_NAME-opensearch`, `RELEASE_NAME-opensearch-dashboard` and, with the demo pipeline on, `RELEASE_NAME-demo-log-generator`. Use a strong, generated password (`openssl rand -hex 16`).
- **Changing the CA restarts the whole cluster.** Old and new certificates do not trust each other, so the cluster is unavailable until every node has restarted with the new CA.
- **`replicas` must be odd.** An even count cannot form a quorum and is rejected at render.
- **Turn backups on at install time where you can.** The repository plugin is installed at node startup, so on a running cluster the setup job retries until every node has restarted with it.
- **Switching `backup.provider` on an existing release leaves the old cloud binding attached.** The identity keeps both provider blocks; uninstall and reinstall if you need the old binding gone.
- **Data survives a Helm upgrade but not an uninstall** — `cpln helm uninstall` deletes the volume sets. Enable snapshots if the data matters.

## Links

- [OpenSearch documentation](https://docs.opensearch.org/latest/)
- [Security plugin](https://docs.opensearch.org/latest/security/)
- [Security Analytics](https://docs.opensearch.org/latest/security-analytics/)
- [Snapshot and restore](https://docs.opensearch.org/latest/tuning-your-cluster/availability-and-recovery/snapshots/snapshot-restore/)
- [Create a Cloud Account](https://docs.controlplane.com/guides/create-cloud-account)
