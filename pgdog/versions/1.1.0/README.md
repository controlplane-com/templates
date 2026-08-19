# PgDog

PgDog is a high-performance PostgreSQL connection pooler, load balancer, and sharding proxy written in Rust. It sits transparently in front of one or more PostgreSQL instances and appears to clients as a standard PostgreSQL server on port 6432. No application code changes are required — only the connection string changes.

## Architecture

- **PgDog**: Stateless proxy workload that multiplexes client connections into a smaller pool of real backend connections, routes writes to the primary, and distributes reads across replicas.
- **pgdog.toml**: Main configuration rendered as a secret and mounted at startup — defines backend databases, pool settings, timeouts, and load balancing strategy.
- **users.toml**: Credentials configuration rendered as a separate secret — defines which users can connect to PgDog and which backend databases they map to.

This template does not include a PostgreSQL deployment. Users connect PgDog to their existing **postgres** or **postgres-highly-available** template deployments, or to any external PostgreSQL endpoint.

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
```

PgDog uses the `name` and `password` values to both authenticate clients and connect to the backend PostgreSQL server.

### Connection Pooling

```yaml
pooling:
  mode: transaction      # options: transaction, session
  defaultPoolSize: 10    # max real Postgres connections per pool
  minPoolSize: 1         # minimum idle connections kept open
  workers: 2             # async threads; recommend 2× vCPU count
```

**Pool modes:**

- `transaction` — a backend connection is held only for the duration of a transaction, then returned to the pool. Best for most web and API workloads. Not compatible with session-level features like `SET` variables, temporary tables, or advisory locks.
- `session` — a backend connection is held for the entire client session. Compatible with all Postgres features but provides less connection reuse. Increase `defaultPoolSize` to match your expected concurrent client count.

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
  readWriteSplit: include_primary
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

PgDog uses SCRAM-SHA-256 (`scram`) for client authentication. All standard PostgreSQL clients support SCRAM.

### Access

```yaml
internalAccess:
  type: same-gvc    # options: none, same-gvc, same-org, workload-list
  workloads: []     # used when type is workload-list

publicAccess:
  enabled: false
  # address: pgdog.example.com
```

When `publicAccess.enabled` is `true`, Control Plane provisions a public TCP load balancer and assigns a canonical hostname automatically (e.g. `pgdog-name-hash.cpln.app:6432`). You can find it under the workload's endpoint in the Control Plane console or via `cpln workload get <name> -o yaml`. The `address` field is optional and only needed if you want to attach a custom domain.

## Connecting

Applications connect to PgDog exactly as they would connect to PostgreSQL directly — PgDog implements the full PostgreSQL wire protocol.

| Setting | Value |
|---|---|
| Host | `{release-name}-pgdog.{gvc}.cpln.local` |
| Port | `6432` |
| Database | Matches a `name` from your `databases` list |
| Username | Matches a `name` from your `users` list |
| Password | Matches the `password` from your `users` list |

## Important Notes

- **PgDog does not manage PostgreSQL** — it is a proxy only. Deploy a PostgreSQL backend separately before pointing PgDog at it.
- **Port 6432** — PgDog listens on 6432, not 5432. Update your application connection strings accordingly.
- **Transaction mode and session features** — if your application uses `SET` variables, prepared statements, temporary tables, or advisory locks, use `pooling.mode: session` instead of `transaction`.
- **Admin password** — if `admin.password` is not set, PgDog generates a random password at each startup and the admin database becomes inaccessible across restarts. Always set it explicitly.
- **Scaling** — PgDog is stateless and can be scaled by increasing `replicas`. Each replica maintains its own connection pool, so scale `pooling.defaultPoolSize` down proportionally to avoid overloading the backend with too many open connections.

## Supported External Services

- [PgDog Documentation](https://docs.pgdog.dev/)
- [PgDog GitHub](https://github.com/pgdogdev/pgdog)
- [PostgreSQL Documentation](https://www.postgresql.org/docs/)
