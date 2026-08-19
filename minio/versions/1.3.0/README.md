# MinIO

MinIO is a high-performance, S3-compatible object storage server. This template deploys it in
distributed mode with erasure coding, spreading every object across all replicas so the cluster
keeps serving reads and writes while nodes are down.

## Architecture

- **MinIO workload** (`{release}-minio`, stateful) — `replicas` nodes forming one erasure-coded
  pool. S3 API on port 9000, web console on port 9001.
- **Volume set** (`{release}-minio-vs`) — one `ext4` general-purpose SSD volume per replica mounted
  at `/data`, with a final snapshot and 7-day retention.
- **Startup secret** (`{release}-minio-startup`) — the boot script each node runs; it derives the
  peer list from the replica index and `CPLN_LOCATION`.
- **Identity and policy** — `reveal` on exactly two secrets: the startup script and your
  credentials secret.

Per-replica addressing (`replicaDirect`) is enabled so each node reaches its peers at a stable
`replica-{index}` address. This chart creates no credential of its own: the MinIO root user and
password are a secret you create yourself.

## Prerequisites

1. **A root credentials secret — create it BEFORE installing.** A `dictionary` secret with exactly
   the keys `username` and `password`. These become `MINIO_ROOT_USER` and `MINIO_ROOT_PASSWORD` —
   the S3 access key and secret key every client will use.

   ```bash
   cpln secret create-dictionary --name my-minio-credentials \
     --entry username=minioadmin \
     --entry password="$(openssl rand -hex 24)"
   ```

   Then set `admin.credentialsSecretName` to that name. Read it back later with
   `cpln secret reveal my-minio-credentials -o yaml` — the `-o yaml` is required, as the plain
   command prints only a summary table. MinIO requires a username of at least 3 characters and a
   password of at least 8.

   **If the secret does not exist at install time the deployment wedges silently.** `cpln logs`
   returns zero lines — the container never starts, so there is nothing to log. The only diagnostic
   is `status.versions[].message` in
   `cpln workload get-deployments {release}-minio --gvc {gvc} -o yaml` (note **`get-deployments`** —
   plain `cpln workload get` has no `versions` key). Create the secret and it recovers on its own in
   6–8.5 minutes, or clear it immediately with
   `cpln workload force-redeployment {release}-minio --gvc {gvc}` (~90 s).

2. **Replica quota** — the default per-workload replica quota is below the recommended 6. Request a
   quota increase before installing with `replicas: 6` or more.

## Configuration

### Server and sizing

```yaml
image: minio/minio:RELEASE.2025-09-07T16-13-09Z

replicas: 6 # Must be at least 4 and an even number

resources: # Defaults are set for minimal production usage
  minCpu: 1
  minMemory: 2Gi
  maxCpu: 2
  maxMemory: 4Gi
```

### Root credentials

```yaml
admin:
  # REQUIRED PREREQUISITE SECRET — CREATE IT BEFORE YOU INSTALL.
  # A `dictionary` secret holding exactly two keys: `username` and `password`.
  # These are the MinIO root credentials, i.e. the S3 access key and secret key
  # every client and every other template will use. If the secret does not exist
  # at install time the deployment WEDGES silently — `cpln logs` returns nothing
  # at all. See Prerequisites in the README for the exact
  # `cpln secret create-dictionary` command.
  credentialsSecretName: my-minio-credentials
```

### Storage

```yaml
volumeset:
  capacity: 10 # initial capacity in GiB (minimum is 10)
  autoscaling:
    enabled: false # Set to true to enable autoscaling
    maxCapacity: 100 # Maximum capacity in GiB when autoscaling is enabled
    minFreePercentage: 10 # Minimum free percentage to trigger scaling when autoscaling is enabled
    scalingFactor: 1.2 # Scaling factor to determine how much to scale up when autoscaling is triggered
```

`capacity` is per replica, so usable space is roughly `replicas × capacity ÷ 2` after erasure-coding
parity.

### Network access

```yaml
internalAccess: # Sets the internal firewall scope - if set to none, replicas will not be able to reach each other
  type: same-gvc # options: none, same-gvc, same-org, workload-list
  workloads:  # Note: can only be used if type is same-gvc or workload-list
    #- //gvc/GVC_NAME/workload/WORKLOAD_NAME
    #- //gvc/GVC_NAME/workload/WORKLOAD_NAME
```

## Replica count

`replicas` must be **an even number, minimum 4**, and 6 or more is recommended for production.
MinIO stripes each object with data and parity blocks across all nodes in the pool, so the replica
count sets both the usable capacity ratio and how many nodes may be lost while writes continue.
Choose it before installing — see Important Notes on why it is not an online knob.

## Connecting

| What | Where |
|---|---|
| S3 API | `{release}-minio.{gvc}.cpln.local:9000` (the short name `{release}-minio` also resolves in-GVC) |
| Web console | port 9001 on the same host — `cpln port-forward {release}-minio 9001:9001 --gvc {gvc}`, then open `http://localhost:9001` |
| Individual node | `replica-{index}.{release}-minio.{location}.{gvc}.cpln.local` |
| Credentials | the `dictionary` secret named by `admin.credentialsSecretName` — `cpln secret reveal <name> -o yaml` |

Internal only — this template exposes no public endpoint. From another workload in the GVC, using
the MinIO client:

```sh
mc alias set minio http://{release}-minio:9000 USERNAME PASSWORD
```

Other templates in this catalog that back up to MinIO take the same two values as their access key
and secret key.

## Important Notes

- **The credentials secret must exist before you install.** Without it the workload wedges with no
  log output at all; see Prerequisites for the one diagnostic that shows it.
- **Rotating the secret needs a restart, and it is a fleet-wide change.** MinIO reads the root
  credentials on every start, so restarting after updating the secret is what applies them — update
  every client and every other template configured with these keys at the same time.
- **Treat `replicas` as fixed at install time.** MinIO grows by adding server pools, which this
  template does not model; changing the value rewrites every node's peer list for the existing pool.
- **Do not set `internalAccess.type: none`.** Replicas discover and reach each other over internal
  GVC traffic, so cutting it off breaks the cluster rather than just isolating it.
- **`helm uninstall` deletes the volume sets**, so stored objects do not survive a reinstall. The
  credentials secret is yours and is left alone.
- **The first `helm upgrade` after an install re-applies resources even with identical values**,
  restarting replicas. Nothing limits the rollout on a stateful workload, so treat it as a planned
  restart of the pool.
- **Firewall changes take 30–150 seconds to take effect.** After changing `internalAccess`, re-test
  rather than trusting the first response.

## Links

- [MinIO documentation](https://min.io/docs/minio/linux/index.html)
- [Erasure coding](https://min.io/docs/minio/linux/operations/concepts/erasure-coding.html)
- [Availability and resiliency](https://min.io/docs/minio/linux/operations/concepts/availability-and-resiliency.html)
- [MinIO Client (`mc`)](https://min.io/docs/minio/linux/reference/minio-mc.html)
- [Identity and access management](https://min.io/docs/minio/linux/administration/identity-access-management.html)
