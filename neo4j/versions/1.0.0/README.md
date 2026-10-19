# Neo4j

A single Neo4j Community Edition graph database server on a persistent, snapshotted volume. It
serves Bolt to applications in the GVC and the bundled Neo4j Browser and HTTP Query API on the same
private endpoint, with the APOC procedures loaded.

## Architecture

- **Neo4j workload** (`{release}-neo4j`, stateful): one server, Bolt on 7687, Browser and HTTP API on 7474.
- **Volume set** (`{release}-neo4j-data`): `/data` (the stores and their transaction logs) on `ext4`, daily snapshots, and a final snapshot when it is deleted.
- **Identity and policy**: `reveal` on exactly your credentials secret.

Single instance: Neo4j clustering and online backup are Enterprise-only, so there is no failover.
Nothing is exposed to the internet.

## Prerequisites

1. **A credentials secret, created BEFORE installing.** A `dictionary` secret with the key
   `password`: at least 8 characters and no `/`. The user is always `neo4j`.

   ```bash
   cpln secret create-dictionary --name my-neo4j-credentials \
     --entry password="$(openssl rand -hex 24)"
   ```

   Then set `auth.credentialsSecretName` to that name. Read the password back with
   `cpln secret reveal my-neo4j-credentials -o yaml`.

   **If the secret does not exist at install time, the deployment waits silently** and
   `cpln logs` returns nothing. The reason is in `status.versions[].message` of
   `cpln workload get-deployments RELEASE_NAME-neo4j --gvc GVC_NAME -o yaml`. Once the secret
   exists it recovers on its own within about 10 minutes, or at once with
   `cpln workload force-redeployment RELEASE_NAME-neo4j --gvc GVC_NAME`.

2. **A GVC with exactly one location.** Each extra location would run a separate, empty Neo4j.

## Configuration

### Image

```yaml
# Neo4j Community Edition (GPLv3). Enterprise images are refused: they need a paid license.
image: neo4j:2026.09.0-community
```

### Credentials

```yaml
auth:
  # REQUIRED PREREQUISITE SECRET — CREATE IT BEFORE YOU INSTALL.
  # A dictionary secret with the key `password` (8+ characters, no `/`); the user is always `neo4j`.
  # If it does not exist at install time the deployment waits silently and `cpln logs` shows nothing.
  # Used only on the FIRST start; to change the password later, see the README.
  credentialsSecretName: my-neo4j-credentials
```

### Resources

```yaml
resources:
  minCpu: 250m
  maxCpu: 1000m   # at most 4× minCpu
  minMemory: 2Gi
  maxMemory: 2Gi  # keep heapSize + pageCacheSize to about 3/4 of this
```

### Neo4j Memory and Plugins

```yaml
neo4j:
  heapSize: 512m      # JVM heap (initial = max), Neo4j size syntax: 512m, 2g
  pageCacheSize: 512m # graph store cache outside the heap
  apoc: true          # load the bundled APOC Core procedures
```

For a production-sized graph, for example: `maxMemory: 8Gi`, `heapSize: 3g`, `pageCacheSize: 3g`,
and a larger volume with autoscaling on. Size the page cache toward the size of your store.

### Storage

```yaml
volumeset:
  capacity: 10 # initial capacity in GiB (minimum 10)
  autoscaling:
    enabled: false # grow the volume automatically as it fills
    maxCapacity: 100 # GiB ceiling when autoscaling
    minFreePercentage: 10
    scalingFactor: 1.2
  snapshots:
    schedule: "0 3 * * *" # daily at 03:00 UTC; at most hourly; "" turns scheduled snapshots off
    retentionDuration: 7d # how long each snapshot is kept
```

### Internal Access

```yaml
internalAccess:
  type: same-gvc # none, same-gvc, same-org or workload-list
  workloads: [] # extra allowed clients, used with same-gvc or workload-list
  # workloads:
  #   - //gvc/GVC_NAME/workload/WORKLOAD_NAME
```

## Connecting

| What | Where |
|---|---|
| Bolt, from a workload in the GVC | `bolt://RELEASE_NAME-neo4j.GVC_NAME.cpln.local:7687` (`neo4j://` also works) |
| HTTP Query API, from a workload in the GVC | `http://RELEASE_NAME-neo4j.GVC_NAME.cpln.local:7474/db/neo4j/query/v2` |
| Neo4j Browser, from your computer | `cpln port-forward RELEASE_NAME-neo4j 7474:7474 7687:7687 --gvc GVC_NAME`, then open `http://localhost:7474/browser/` and connect to `bolt://localhost:7687` |
| Credentials | user `neo4j`, and the `password` key of your credentials secret |

Through port-forward, connect with `bolt://localhost:7687`, not `neo4j://`: a `neo4j://` connection
asks the server for its address and gets the internal name, which your computer cannot resolve.

## Backup and restore

Backups are volume snapshots: daily by default, kept for `retentionDuration`, plus a final snapshot
when the volume set is deleted. They stay with the volume set in Control Plane and are not copied
off-site. Neo4j Community cannot back up a running database, so there is no backup job.

To restore, list the snapshots and restore one onto the volume. Neo4j restarts on the restored data:

```bash
cpln volumeset snapshot get RELEASE_NAME-neo4j-data --gvc GVC_NAME
cpln volumeset snapshot restore RELEASE_NAME-neo4j-data --gvc GVC_NAME \
  --snapshot-name SNAPSHOT_NAME --location LOCATION --volume-index 0
```

Everything written after the snapshot is lost, and the `neo4j` password is the one that was in use
when the snapshot was taken.

## Important Notes

- The secret's password is used only on the first start. To change it, run `ALTER CURRENT USER SET PASSWORD FROM 'old' TO 'new'`, then update the secret so it matches.
- Every upgrade or configuration change restarts the only server, so Neo4j is briefly unavailable.
- Keep `heapSize` + `pageCacheSize` to about three quarters of `maxMemory`; the JVM needs the rest, and an over-committed container is OOM-killed.
- `volumeset.capacity` only sizes a new volume; grow a live one with `volumeset.autoscaling` or `cpln volumeset expand`.
- If Neo4j Browser hangs through port-forward, restart the tunnel and fully quit the browser.

## Links

- [Neo4j Operations Manual: Docker](https://neo4j.com/docs/operations-manual/current/docker/)
- [Cypher Manual](https://neo4j.com/docs/cypher-manual/current/)
- [Neo4j Browser](https://neo4j.com/docs/browser/)
- [APOC Core](https://neo4j.com/docs/apoc/current/)
- [Neo4j drivers](https://neo4j.com/docs/create-applications/)
