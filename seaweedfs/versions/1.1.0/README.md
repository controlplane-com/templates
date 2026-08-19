# SeaweedFS

SeaweedFS is a distributed object store with an S3-compatible API. This template deploys a single all-in-one node — master, volume server, filer, S3 gateway and admin UI in one process — with persistent storage, startup bucket creation, and SigV4-authenticated S3 on port 8333. It is the drop-in S3 target for any workload or template in your org that expects an S3-compatible endpoint.

## Architecture

- **SeaweedFS workload** — stateful, single replica; runs `weed mini`, serving the S3 API on port 8333 and the admin UI on 23646.
- **Volumeset** (`/data`, 20 GiB) — object data, filer metadata (leveldb) and master metadata on one disk.
- **S3 credentials secret** (dictionary) — *not created by this template*; you create it before install and reference it by name.
- **Admin credentials secret** (dictionary) — *not created by this template* either; required only when `adminUI.enabled` is true.
- **Identity + policy** — grant the workload `reveal` on exactly the secrets it mounts, nothing else.

## Prerequisites

Both secrets below are credentials, so they are **prerequisite secrets rather than values** — a value would sit in plaintext in the Helm release for the life of the install. Create them BEFORE you install.

1. **S3 credentials** — a `dictionary` secret with exactly the keys `AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`. SeaweedFS serves S3 with *no authentication at all* when they are absent, so this is a hard requirement.

   ```bash
   cpln secret create-dictionary --name my-seaweedfs-s3-credentials \
     --entry AWS_ACCESS_KEY_ID="$(openssl rand -hex 10)" \
     --entry AWS_SECRET_ACCESS_KEY="$(openssl rand -hex 24)"
   ```

   Then set `s3.credentialsSecretName` to that name.

2. **Admin UI credentials** — a `dictionary` secret with exactly the keys `username` and `password`, guarding the admin login form. Required whenever `adminUI.enabled` is true (the default).

   ```bash
   cpln secret create-dictionary --name my-seaweedfs-admin-credentials \
     --entry username=admin \
     --entry password="$(openssl rand -hex 24)"
   ```

   Then set `adminUI.credentialsSecretName` to that name. Read either secret back later with
   `cpln secret reveal my-seaweedfs-admin-credentials -o yaml`.

**If a secret does not exist at install time the deployment wedges silently.** `cpln logs` returns zero lines — the container never starts, so there is nothing to log. The only diagnostic is `status.versions[].message` in `cpln workload get-deployments <release>-seaweedfs --gvc <gvc> -o yaml` (note **`get-deployments`** — plain `cpln workload get` has no `versions` key). Create the missing secret and it recovers on its own in about 6 minutes, or clear it immediately with a `cpln workload force-redeployment` on the workload (~90 s).

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
  credentialsSecretName: my-seaweedfs-s3-credentials # PREREQUISITE dictionary secret — must exist BEFORE install
  buckets: [] # buckets created at startup if missing, e.g. [backups, uploads]
```

### Admin UI

```yaml
adminUI:
  enabled: true # cluster status, bucket browser, user and maintenance management
  credentialsSecretName: my-seaweedfs-admin-credentials # PREREQUISITE dictionary secret (username, password) — must exist BEFORE install
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
| Admin UI | `http://<release>-seaweedfs.<gvc>.cpln.local:23646` | In-GVC only, never public. From a laptop, tunnel to it with `cpln port-forward <release>-seaweedfs 23646:23646 --gvc <gvc>`. With `adminUI.enabled: false` the port and credentials are removed so nothing is reachable — the upstream binary still starts the component in-process, it simply has no route and no declared port. |
| S3 credentials | your `s3.credentialsSecretName` secret | `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`. |
| Admin UI credentials | your `adminUI.credentialsSecretName` secret | `username` / `password`. |

## Using SeaweedFS as the S3 backend for other templates

Any client that speaks S3 works, subject to three rules:

- **Path-style addressing is required** (`http://host:8333/bucket/key`). Virtual-host style (`bucket.host`) is not served.
- **Any region value works.** The region is read from the client's signature scope and never compared against a server-side value, so leaving a consumer at `us-east-1` is fine.
- **The bucket must already exist** for most backup tools. Create it with `s3.buckets`, through the admin UI, or with `aws s3 mb`.

Endpoint and credentials for the common catalog consumers:

| Consumer template | Values to set |
|---|---|
| `postgres-highly-available`, `timescaledb-highly-available` | `backup.provider: minio`, `backup.minio.endpoint: http://<release>-seaweedfs:8333`, `backup.minio.bucket`, `backup.minio.accessKey` / `backup.minio.secretKey` = the two values in the prerequisite secret |
| `thanos`, `mimir` | `storage.type: minio`, `storage.minio.endpoint: <release>-seaweedfs.<gvc>.cpln.local:8333` (no scheme), `storage.minio.insecure: true`, `storage.minio.region: us-east-1`, `accessKey` / `accessSecret` |
| `prometheus` | same fields but under the Thanos sidecar: `thanos.objectStorage.enabled: true`, `thanos.objectStorage.type: minio`, `thanos.objectStorage.minio.*` — there is no top-level `storage:` key |
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

- **Create both prerequisite secrets before installing** — a missing one wedges the deployment with no log output at all; Prerequisites gives the one command that diagnoses it.
- **Upgrading from 1.0.0 needs the new admin secret** — `adminUI.username` and `adminUI.password` are gone, and passing either now fails the render with a message naming `adminUI.credentialsSecretName`. Put the same username and password in the secret to keep existing logins working.
- **Rotating the S3 credentials secret and redeploying actually rotates the keys** — the S3 identity is rebuilt from the environment on every boot, not stored on disk.
- **Single replica by design** — `weed mini` runs one master, one filer and one volume server in a single process, so raising the replica count would create separate, divergent object stores. A redeploy or upgrade is therefore a full S3 outage: measured at **337 failed requests over an 80.8 s gap** (≈5 req/s polling), with the store reachable again about 128 s after the trigger. Schedule upgrades accordingly, and expect the same window when the platform reschedules the replica. Multi-node clustering is a planned follow-up.
- **Data lives on the volumeset** and survives redeploys and upgrades under the same release name. `helm uninstall` deletes the volumeset and every stored object.
- **Volume file size is derived from disk capacity at startup**, so growing the volumeset takes effect on the next restart. This is harmless — SeaweedFS simply creates more volume files.
- **Only the S3 API is publicly routable.** The admin UI is the workload's second port, so `publicAccess` exposes port 8333 only; reach the admin UI from inside the GVC or through `cpln port-forward`.

## Links

- [SeaweedFS on GitHub](https://github.com/seaweedfs/seaweedfs)
- [Quick start with `weed mini`](https://github.com/seaweedfs/seaweedfs/wiki/Quick-Start-with-weed-mini)
- [Amazon S3 API support](https://github.com/seaweedfs/seaweedfs/wiki/Amazon-S3-API)
- [S3 credentials](https://github.com/seaweedfs/seaweedfs/wiki/S3-Credentials)
- [Admin UI](https://github.com/seaweedfs/seaweedfs/wiki/Admin-UI)
