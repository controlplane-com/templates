# pgEdge Distributed PostgreSQL

This template deploys a pgEdge active-active distributed PostgreSQL cluster using Spock multi-master replication. Every node accepts both reads and writes simultaneously, and data written to any node replicates to all others automatically. The cluster spans multiple geographic locations with configurable replicas per location, providing a globally distributed, fault-tolerant database with no single point of failure.

## Architecture

- **pgEdge**: Stateful workload running PostgreSQL 17 with the Spock extension. All nodes are active writers connected in a full-mesh replication ring. Each replica gets its own persistent volume.
- **pgcat**: Connection pooler providing a single virtual endpoint for applications. Routes writes to the designated primary and distributes reads across all nodes.
- **Spock**: Multi-master logical replication extension included in the pgEdge image. Handles cross-node replication with last-update-wins conflict resolution.

## Configuration

### pgEdge Settings

Configure your cluster in the values file:

```yaml
gvc:
  name: pgedge-gvc  # Must be unique per independent cluster deployment
  locations:
    - name: aws-us-west-2
      replicas: 3  # Use 1 for dev/testing, 3 for production
    - name: aws-us-east-2
      replicas: 3
    - name: aws-eu-central-1
      replicas: 3

resources:
  minCpu: 500m
  minMemory: 1Gi
  maxCpu: 2
  maxMemory: 4Gi

postgres:
  username: postgres  # PostgreSQL superuser username
  password: password  # PostgreSQL superuser password
  database: mydb      # Auto-created database name

multiZone: false  # Set to true to spread replicas across availability zones
```

**Replica counts:**

| Environment | Replicas per location |
|---|---|
| Dev / testing | 1 |
| Production | 3 |

**Volume** — set the initial storage capacity (minimum 10 GiB). Optionally enable autoscaling to expand as data grows:

```yaml
volumeset:
  capacity: 10
  autoscaling:
    enabled: true
    maxCapacity: 100
    minFreePercentage: 10
    scalingFactor: 1.2
```

Configure which workloads can access pgEdge and pgcat:

```yaml
internal_access:
  type: same-gvc  # Options: same-gvc, same-org, workload-list
  workloads:
    # Uncomment and specify workloads if using workload-list
    #- //gvc/GVC_NAME/workload/WORKLOAD_NAME
```

- `same-gvc`: Allow access from all workloads in the same GVC
- `same-org`: Allow access from all workloads in the org
- `workload-list`: Allow access only from specified workloads

### pgcat Settings

pgcat multiplexes application connections into a smaller pool of real database connections, reducing overhead and protecting Postgres from connection exhaustion under high concurrency.

```yaml
pgcat:
  poolMode: transaction  # Options: session, transaction, statement
  defaultPoolSize: 25    # Real Postgres connections pgcat maintains per pool
  maxClientConn: 1000    # Maximum client connections pgcat accepts
  minReplicas: 2
  maxReplicas: 4
  resources:
    cpu: 500m
    memory: 256Mi
```

**Pool modes:**
- `transaction` — connection held only for the duration of a transaction. Best for most web and API workloads. Not compatible with session-level features like `SET` variables, temporary tables, or advisory locks.
- `session` — connection held for the entire client session. Compatible with all Postgres features but provides less connection reuse.
- `statement` — connection returned after every statement. Transactions are not supported. Rarely used.

## Connecting to pgEdge

Connect through pgcat for all application traffic:

```
Host: {release-name}-pgcat.{gvc}.cpln.local
Port: 5432
Database: {postgres.database}
Username: {postgres.username}
Password: {postgres.password}
```

## Schema Changes (DDL)

Spock replicates row-level changes (`INSERT`, `UPDATE`, `DELETE`) automatically. DDL (`CREATE TABLE`, `ALTER TABLE`, etc.) must be broadcast using `spock.replicate_ddl()` so it executes on all nodes.

### Creating a table

Run `spock.replicate_ddl()` once on any single node to create the table on all nodes, then add it to the replication set on every node so DML replicates in all directions:

```sql
-- Step 1: Run on ONE node only -- creates the table on all nodes
SELECT spock.replicate_ddl('CREATE TABLE orders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  amount numeric,
  created_at timestamptz DEFAULT now()
);');

-- Step 2: Run on ONE node -- adds the table to the replication set on all nodes
SELECT spock.repset_add_table('default', 'orders'::regclass);
```

Step 2 is required because Spock suppresses event triggers during replication apply to prevent loops, so the auto-add trigger only fires on the node where `replicate_ddl` was called. The `repset_add_table` call itself replicates to all other nodes automatically.

### Other DDL

```sql
SELECT spock.replicate_ddl('ALTER TABLE orders ADD COLUMN status text DEFAULT ''pending'';');
SELECT spock.replicate_ddl('DROP TABLE orders;');
```

### Primary keys

Use `uuid` primary keys instead of `serial`/`bigserial`. Each node maintains its own sequence, so auto-increment integers will collide when the same ID is generated on multiple nodes simultaneously. UUIDs are globally unique by design:

```sql
-- Good: no conflicts
id uuid PRIMARY KEY DEFAULT gen_random_uuid()

-- Avoid: causes duplicate key conflicts under concurrent multi-node writes
id serial PRIMARY KEY
```

## Important Notes

- **Minimum replicas**: Use at least 3 replicas per location for production to survive a node loss within a location
- **GVC naming**: Each independent pgEdge deployment must use a unique GVC name
- **Conflict resolution**: Concurrent writes to the same row from different nodes are resolved by last-update-wins based on commit timestamp. For workloads requiring stronger consistency, route writes for a given entity to a single node using application-level logic
- **multiZone**: Verify your selected location supports multiple availability zones before enabling

## Supported External Services

- [pgEdge Documentation](https://docs.pgedge.com/)
- [Spock Documentation](https://docs.pgedge.com/spock-v5/)
- [pgcat Documentation](https://github.com/postgresml/pgcat)
- [PostgreSQL Documentation](https://www.postgresql.org/docs/)