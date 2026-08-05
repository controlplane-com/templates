# SeaweedFS

SeaweedFS is a distributed object store with an S3-compatible API. This template deploys a single all-in-one node — master, volume server, filer, S3 gateway and admin UI in one process — with persistent storage, startup bucket creation, and SigV4-authenticated S3 on port 8333. It is the drop-in S3 target for any workload or template in your org that expects an S3-compatible endpoint.

## Architecture

- **SeaweedFS workload** — stateful, single replica; runs `weed mini`, serving the S3 API on port 8333 and the admin UI on 23646.
- **Volumeset** (`/data`, 20 GiB) — object data, filer metadata (leveldb) and master metadata on one disk.
- **Admin secret** (dictionary, optional) — admin UI username and password; created only when `adminUI.enabled` is true.
- **S3 credentials secret** (dictionary) — *not created by this template*; you create it before install and reference it by name.
- **Identity + policy** — grant the workload `reveal` on exactly the secrets it mounts, nothing else.

## Prerequisites

**A dictionary secret holding the S3 credentials must exist before you install.** SeaweedFS serves S3 with *no authentication at all* when credentials are absent, so this template treats them as a hard prerequisite rather than a value. Create it first:

```bash
cpln secret create-dictionary --name my-seaweedfs-s3-credentials \
  --entry AWS_ACCESS_KEY_ID=<your-access-key> \
  --entry AWS_SECRET_ACCESS_KEY=<your-secret-key>
```

The secret must contain exactly these two keys. Installing before the secret exists leaves the deployment waiting on a missing secret — it never starts.

## Configuration

### Image and resources

```yaml
image: chrislusf/seaweedfs:4.40 # official upstream image; runs `weed mini`
resources:
  minCpu: 250m
  maxCpu: 1000m
  minMemory: 512Mi
  maxMemory: 2Gi # raise for stores holding tens of millions of objects (in-memory volume index)
```

### Storage

```yaml
volumeset:
  capacity: 20 # initial capacity in GiB (minimum is 10)
  autoscaling:
    enabled: false # set to true to grow the volume automatically as it fills
    maxCapacity: 200 # maximum capacity in GiB when autoscaling is enabled
    minFreePercentage: 10 # minimum free percentage that triggers scaling
    scalingFactor: 1.2 # how much to grow the volume when scaling is triggered
```

### S3 API

```yaml
s3:
  credentialsSecretName: my-seaweedfs-s3-credentials # PREREQUISITE secret (see above) — must exist BEFORE install
  buckets: [] # buckets created at startup if missing, e.g. [backups, uploads]
```

### Admin UI

```yaml
adminUI:
  enabled: true # cluster status, bucket browser, user and maintenance management
  username: admin
  password: change-me-seaweedfs-admin # CHANGE THIS before install
```

### Access

```yaml
publicAccess:
  enabled: false # true = S3 API on the auto *.cpln.app HTTPS endpoint (path-style addressing)
internalAccess:
  type: same-gvc # options: none, same-gvc, same-org, workload-list
  workloads: [] # only used when type is workload-list
  # workloads:
  #   - //gvc/GVC_NAME/workload/WORKLOAD_NAME
```

## Connecting

| Access | Endpoint | Notes |
|---|---|---|
| S3 API, in-GVC (short name) | `http://<release>-seaweedfs:8333` | Resolves from any workload in the same GVC. |
| S3 API, in-GVC (FQDN) | `http://<release>-seaweedfs.<gvc>.cpln.local:8333` | Same host, fully qualified. |
| S3 API, host:port form | `<release>-seaweedfs.<gvc>.cpln.local:8333` | For clients that take a bare host:port (Thanos, Mimir); pair with `insecure: true`. |
| S3 API, public | `https://<canonical>.cpln.app` | Only when `publicAccess.enabled`; port 443, no port suffix. Find it under `status.canonicalEndpoint` (`cpln workload get <release>-seaweedfs -o yaml`). |
| Admin UI | `http://<release>-seaweedfs.<gvc>.cpln.local:23646` | In-GVC only; log in with `adminUI.username` / `adminUI.password`. With `adminUI.enabled: false` the port, credentials and secret are all removed so nothing is reachable — the upstream binary still starts the component in-process, it simply has no route and no declared port. |
| S3 credentials | your prerequisite secret | `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`. |

## Using SeaweedFS as the S3 backend for other templates

Any client that speaks S3 works, subject to three rules:

- **Path-style addressing is required** (`http://host:8333/bucket/key`). Virtual-host style (`bucket.host`) is not served.
- **Any region value works.** The region is read from the client's signature scope and never compared against a server-side value, so leaving a consumer at `us-east-1` is fine.
- **The bucket must already exist** for most backup tools. Create it with `s3.buckets`, through the admin UI, or with `aws s3 mb`.

Endpoint and credentials for the common catalog consumers:

| Consumer template | Values to set |
|---|---|
| `postgres-highly-available`, `timescaledb-highly-available` | `backup.provider: minio`, `backup.minio.endpoint: http://<release>-seaweedfs:8333`, `backup.minio.bucket`, `backup.minio.accessKey` / `backup.minio.secretKey` = the two values in the prerequisite secret |
| `thanos`, `mimir`, `prometheus` | `storage.type: minio`, `storage.minio.endpoint: <release>-seaweedfs.<gvc>.cpln.local:8333` (no scheme), `storage.minio.insecure: true`, `storage.minio.region: us-east-1`, `accessKey` / `accessSecret` |
| `docmost` | `storage.type: s3`, `storage.s3.endpoint: http://<release>-seaweedfs:8333`, `storage.s3.forcePathStyle: true`, `storage.s3.bucket`, `storage.s3.region: us-east-1`, and `storage.s3.auth.secretName` = a **separate** dictionary secret whose keys are `AWS_S3_ACCESS_KEY_ID` / `AWS_S3_SECRET_ACCESS_KEY` (docmost uses different key names than this template's secret — the values are the same, the keys are not) |
| `sftpgo`, `n8n`, `metabase`, `keycloak`, `unleash` | their S3-compatible endpoint knob + the same static access/secret key pair |

Templates whose object-storage support is limited to specific providers (`ghost`, `clickhouse`, and anything else offering only `aws`/`gcp`) cannot point at an arbitrary S3 endpoint today, so they cannot use this template as their backup target.

Verifying from any workload in the GVC:

```bash
aws configure set default.s3.addressing_style path
aws --endpoint-url http://<release>-seaweedfs:8333 s3 ls
aws --endpoint-url http://<release>-seaweedfs:8333 s3 cp ./file s3://<bucket>/file
```

## Important Notes

- **Create the S3 credentials secret before installing** — the deployment waits indefinitely on a missing secret, and SeaweedFS would serve S3 unauthenticated if the credentials were simply omitted.
- **Change `adminUI.password` before installing** — the shipped default is an illustrative placeholder.
- **Rotating the S3 credentials secret and redeploying actually rotates the keys** — the S3 identity is rebuilt from the environment on every boot, not stored on disk.
- **Single replica by design** — `weed mini` runs one master, one filer and one volume server in a single process, so raising the replica count would create separate, divergent object stores. A redeploy or upgrade is therefore a full S3 outage: measured at **337 failed requests over an 80.8 s gap** (≈5 req/s polling), with the store reachable again about 128 s after the trigger. Schedule upgrades accordingly, and expect the same window when the platform reschedules the replica. Multi-node clustering is a planned follow-up.
- **Data lives on the volumeset** and survives redeploys and upgrades under the same release name. `helm uninstall` deletes the volumeset and every stored object.
- **Volume file size is derived from disk capacity at startup**, so growing the volumeset takes effect on the next restart. This is harmless — SeaweedFS simply creates more volume files.
- **Only the S3 API is publicly routable.** The admin UI is the workload's second port, so `publicAccess` exposes port 8333 only; reach the admin UI from inside the GVC.

## Links

- [SeaweedFS on GitHub](https://github.com/seaweedfs/seaweedfs)
- [Quick start with `weed mini`](https://github.com/seaweedfs/seaweedfs/wiki/Quick-Start-with-weed-mini)
- [Amazon S3 API support](https://github.com/seaweedfs/seaweedfs/wiki/Amazon-S3-API)
- [S3 credentials](https://github.com/seaweedfs/seaweedfs/wiki/S3-Credentials)
- [Admin UI](https://github.com/seaweedfs/seaweedfs/wiki/Admin-UI)
