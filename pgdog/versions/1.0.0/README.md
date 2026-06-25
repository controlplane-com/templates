# PgDog

PgDog is a high-performance PostgreSQL connection pooler, load balancer, and sharding proxy written in Rust. It sits transparently in front of one or more PostgreSQL instances and appears to clients as a standard PostgreSQL server on port 6432. No application code changes are required — only the connection string changes.

## Architecture

- **PgDog**: Stateless proxy workload that multiplexes client connections into a smaller pool of real backend connections, routes writes to the primary, and distributes reads across replicas.
- **pgdog.toml**: Main configuration rendered as a secret and mounted at startup — defines backend databases, pool settings, timeouts, and load balancing strategy.
- **users.toml**: Credentials configuration rendered as a separate secret — defines which users can connect to PgDog and which backend databases they map to.

PgDog does not include or manage any PostgreSQL instance. It is intended to be deployed alongside the **postgres** or **postgres-highly-available** templates, or pointed at any external PostgreSQL endpoint.

## Configuration

### Backend Databases

The `databases` list defines the PostgreSQL backends PgDog will proxy. Each entry maps to a `[[databases]]` block in `pgdog.toml`. Multiple entries with the same `name` form a cluster — PgDog routes writes to `primary` backends and distributes reads across `replica` backends.

```yaml
databases:
  - name: mydb
    host: my-postgres.my-gvc.cpln.local
    port: 5432
    role: primary       # options: primary, replica, auto

  # Add replicas for read/write splitting:
  - name: mydb
    host: replica-1.my-patroni-postgres.aws-us-east-1.my-gvc.cpln.local
    port: 5432
    role: replica
  - name: mydb
    host: replica-2.my-patroni-postgres.aws-us-east-1.my-gvc.cpln.local
    port: 5432
    role: replica
```

**Using with the postgres template:**
Set `host` to `{release-name}-postgres.{gvc}.cpln.local`.

**Using with the postgres-highly-available template:**
Point the `primary` entry at the HA proxy (`{release-name}-postgres-ha-proxy.{gvc}.cpln.local`) and add `replica` entries using the replicaDirect hostnames (`replica-{n}.{release-name}-postgres-ha.{location}.{gvc}.cpln.local`).

### Users

The `users` list defines who can connect to PgDog. Each entry maps to a `[[users]]` block in `users.toml`. The `database` field must match a `name` from the `databases` list.

```yaml
users:
  - name: myuser
    password: mypassword
    database: mydb
    # serverUser: postgres       # backend Postgres username if different from name
    # serverPassword: secret     # backend Postgres password if different from password
    # poolMode: session          # per-user pool mode override
    # poolSize: 20               # per-user connection limit override
```

If `serverUser` and `serverPassword` are omitted, PgDog uses `name` and `password` to authenticate to the backend as well.

### Connection Pooling

```yaml
pooling:
  mode: transaction      # options: transaction, session, statement
  defaultPoolSize: 10    # max real Postgres connections per pool
  minPoolSize: 1         # minimum idle connections kept open
  workers: 2             # async threads; recommend 2× vCPU count
```

**Pool modes:**

- `transaction` — a backend connection is held only for the duration of a transaction, then returned to the pool. Best for most web and API workloads. Not compatible with session-level features like `SET` variables, temporary tables, or advisory locks.
- `session` — a backend connection is held for the entire client session. Compatible with all Postgres features but provides less connection reuse. Increase `defaultPoolSize` to match your expected concurrent client count.
- `statement` — connection is returned after every statement. Transactions are not supported. Rarely used.

### Timeouts

All timeouts are in milliseconds.

```yaml
timeouts:
  connect: 5000      # time to establish a backend connection
  checkout: 5000     # max time a client waits for a free pool connection
  idle: 60000        # idle backend connections closed after this
  query: 0           # per-query timeout; 0 = disabled
```

### Load Balancing

```yaml
loadBalancing:
  strategy: least_active_connections  # options: random, round_robin, least_active_connections
  readWriteSplit: include_primary     # options: include_primary, exclude_primary, include_primary_if_replica_banned
```

PgDog parses queries to detect writes (`INSERT`, `UPDATE`, `DELETE`, DDL) and routes them to a `primary` backend. `SELECT` queries are routed to `replica` backends according to the load balancing strategy. With `readWriteSplit: include_primary`, the primary can also serve reads if no replicas are available.

### Admin Database

PgDog exposes an internal admin database for stats and introspection.

```yaml
admin:
  database: admin
  user: admin
  password: changeme
```

Connect to the admin database with any PostgreSQL client:

```sh
PGPASSWORD=<admin.password> psql \
  -h {release-name}-pgdog.{gvc}.cpln.local \
  -p 6432 \
  -U admin \
  -d admin
```

### Authentication

```yaml
auth:
  type: scram    # options: scram, md5, trust
```

`scram` (SCRAM-SHA-256) is recommended for production. Use `md5` only if your client does not support SCRAM.

### Access

```yaml
internalAccess:
  type: same-gvc    # options: none, same-gvc, same-org, workload-list
  workloads: []     # used when type is workload-list

publicAccess:
  enabled: false
  # address: pgdog.example.com
```

## Connecting

Applications connect to PgDog exactly as they would connect to PostgreSQL directly — PgDog implements the full PostgreSQL wire protocol.

| Setting | Value |
|---|---|
| Host | `{release-name}-pgdog.{gvc}.cpln.local` |
| Port | `6432` |
| Database | Matches a `name` from your `databases` list |
| Username | Matches a `name` from your `users` list |
| Password | Matches the `password` from your `users` list |

## Advanced: Sharding

PgDog supports horizontal sharding across multiple PostgreSQL instances. Add multiple database entries with the same `name` and assign each a `shard` number:

```yaml
databases:
  - name: mydb
    host: shard-0-primary.example.com
    port: 5432
    role: primary
    shard: 0
  - name: mydb
    host: shard-1-primary.example.com
    port: 5432
    role: primary
    shard: 1
```

Enable two-phase commit for safe cross-shard writes:

```yaml
sharding:
  twoPhaseCommit: true
```

Refer to the [PgDog sharding documentation](https://docs.pgdog.dev/features/sharding/) for sharded table configuration and shard key routing.

## Important Notes

- **PgDog does not manage PostgreSQL** — it is a proxy only. Deploy a PostgreSQL backend separately before pointing PgDog at it.
- **Port 6432** — PgDog listens on 6432, not 5432. Update your application connection strings accordingly.
- **Transaction mode and session features** — if your application uses `SET` variables, prepared statements, temporary tables, or advisory locks, use `pooling.mode: session` instead of `transaction`.
- **Admin password** — if `admin.password` is not set, PgDog generates a random password at each startup and the admin database becomes inaccessible across restarts. Always set it explicitly.
- **Scaling** — PgDog is stateless and can be scaled by increasing `replicas`. Each replica maintains its own connection pool, so scale `pooling.defaultPoolSize` down proportionally or use per-user `poolSize` limits to avoid overloading the backend with too many open connections.

## Supported External Services

- [PgDog Documentation](https://docs.pgdog.dev/)
- [PgDog GitHub](https://github.com/pgdogdev/pgdog)
- [PostgreSQL Documentation](https://www.postgresql.org/docs/)
