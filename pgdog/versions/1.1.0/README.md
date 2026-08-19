# PgDog

PgDog is a high-performance PostgreSQL connection pooler, load balancer, and sharding proxy written in Rust. It sits transparently in front of one or more PostgreSQL instances and appears to clients as a standard PostgreSQL server on port 6432 — only the connection string changes, no application code does.

## Architecture

- **PgDog workload** — stateless proxy that multiplexes client connections into a smaller pool of real backend connections, routes writes to the primary, and distributes reads across replicas.
- **Config secret** — the static half of `pgdog.toml` (general settings and the `[[databases]]` backends), rendered by the chart and mounted read-only.
- **Startup script secret** — PgDog reads credentials only from files on disk and has no environment-variable interpolation, so this script assembles the final `pgdog.toml` and `users.toml` at container start from your prerequisite secrets, then execs PgDog. That is what keeps the credentials out of the Helm release.
- **Identity + policy** — grants the workload `reveal` on exactly the secrets it needs: the two chart-created ones, the admin password, and each pooled user's credentials.

This template does not deploy PostgreSQL. Point it at an existing **postgres** or **postgres-highly-available** deployment, or at any external PostgreSQL endpoint.

## Prerequisites

**Create these secrets BEFORE you install.** If a referenced secret does not exist, the deployment wedges silently — see the note on diagnosing it under Important Notes.

**1. One credentials secret per pooled user.** Each entry in `users` names its own `dictionary` secret holding `username` and `password`. PgDog authenticates clients with this pair *and* opens backend connections with it, so it must be a real Postgres role on the backend. If you deployed the backend with the **postgres** template, point this at the same secret that template already uses.

```sh
cpln secret create-dictionary \
  --name my-pgdog-user-credentials \
  --entry username=appuser \
  --entry password='CHOOSE-A-STRONG-PASSWORD'
```

**2. The admin password**, as an `opaque` secret. This guards PgDog's admin database, so it is deliberately a *separate* secret from the pooled-user credentials — revealing an application's password must not also hand it PgDog's introspection database.

```sh
printf '%s' "$(openssl rand -hex 32)" | \
  cpln secret create-opaque --name my-pgdog-admin-password --encoding plain -f -
```

Use `printf`, not `echo`: `echo` appends a newline, which PgDog cannot carry in a TOML value. The startup script detects it and fails with that message rather than starting a proxy that rejects every admin login.

Read a secret back in plaintext with `-o yaml` (without it, the value is redacted):

```sh
cpln secret reveal my-pgdog-admin-password -o yaml
```

## Configuration

### Image, resources, and replicas

```yaml
image: ghcr.io/pgdogdev/pgdog:v0.1.45

resources:
  minCpu: 100m       # reservation
  minMemory: 128Mi
  maxCpu: 500m       # limit
  maxMemory: 256Mi

replicas: 1          # PgDog is stateless; see Important Notes before scaling up
```

### Backend databases

Each entry maps to a `[[databases]]` block in `pgdog.toml`. Multiple entries sharing a `name` form one cluster — PgDog routes writes to `primary` backends and reads to `replica` backends.

```yaml
databases:
  - name: my-pgdog-database   # logical name clients connect to; must be a real database on the backend
    host: my-postgres-workload  # e.g. WORKLOAD_NAME for an in-GVC Postgres, or an external hostname
    port: 5432
    role: primary             # options: primary, replica, auto
```

With the **postgres** template, `host` is `{release-name}-postgres` — the short name resolves inside the GVC. With **postgres-highly-available**, point the `primary` entry at `{release-name}-postgres-ha-proxy` and add `replica` entries using the replicaDirect hostnames (`replica-{n}.{release-name}-postgres-ha.{location}.{gvc}.cpln.local`).

### Pooled users

Each entry maps to a `[[users]]` block in `users.toml`. The username and password come from the secret; only the routing target is a value.

```yaml
users:
  - credentialsSecretName: my-pgdog-user-credentials
    database: my-pgdog-database   # must match a `name` from the databases list above
```

**To pool a second user**, create a second dictionary secret and add a second entry — one secret per entry, always:

```sh
cpln secret create-dictionary \
  --name my-pgdog-reporting-credentials \
  --entry username=reporting \
  --entry password='ANOTHER-STRONG-PASSWORD'
```

```yaml
users:
  - credentialsSecretName: my-pgdog-user-credentials
    database: my-pgdog-database
  - credentialsSecretName: my-pgdog-reporting-credentials
    database: my-pgdog-database
```

The chart adds a policy target for each secret automatically, so nothing else needs changing. Two entries may name the same secret; there is deliberately no way to put two users in one secret.

### Connection pooling

```yaml
pooling:
  mode: transaction      # options: transaction, session, statement
  defaultPoolSize: 10    # max real Postgres connections per pool
  minPoolSize: 1         # minimum idle connections kept open
  workers: 2             # async threads; recommend 2× vCPU count
```

`transaction` holds a backend connection only for the length of a transaction — best for most web and API workloads, but incompatible with session-level features (`SET` variables, temporary tables, advisory locks). `session` holds one for the whole client session: compatible with everything, reuses less, so raise `defaultPoolSize` to match expected concurrency.

### Timeouts

```yaml
timeouts:
  connect: 5000      # milliseconds to establish a backend connection
  checkout: 5000     # max time a client waits for a free pool connection
  idle: 60000        # idle backend connections closed after this
  query: 0           # per-query timeout; 0 = disabled
```

### Load balancing

```yaml
loadBalancing:
  strategy: least_active_connections  # options: random, round_robin, least_active_connections
  readWriteSplit: include_primary     # include_primary lets the primary serve reads too
```

PgDog parses queries to detect writes (`INSERT`, `UPDATE`, `DELETE`, DDL) and sends them to a `primary`; `SELECT`s go to `replica` backends by the chosen strategy.

### Admin database

PgDog exposes an internal admin database for stats and introspection. The password is a prerequisite secret; the names are ordinary values.

```yaml
admin:
  database: admin
  user: admin
  passwordSecretName: my-pgdog-admin-password
```

From a workload inside the GVC:

```sh
PGPASSWORD="$(cpln secret reveal my-pgdog-admin-password -o yaml | awk '/^  payload:/ {print $2}')" \
  psql -h {release-name}-pgdog -p 6432 -U admin -d admin
```

### Authentication and logging

```yaml
auth:
  type: scram        # SCRAM-SHA-256; supported by every standard Postgres client

logging:
  format: text       # options: text, json, json_flattened
  level: info        # RUST_LOG syntax; e.g. info, debug, pgdog=debug
```

### Access

```yaml
publicAccess:
  enabled: false
  # address: my-pgdog-domain.example.com  # name of an existing cpln domain resource

internalAccess:
  type: same-gvc     # options: none, same-gvc, same-org, workload-list
  workloads: []      # used when type is workload-list
```

With `publicAccess.enabled: true` Control Plane assigns a canonical `*.cpln.app` hostname automatically — read it from `status.canonicalEndpoint` in `cpln workload get {release-name}-pgdog -o yaml`; `address` is only needed for a custom domain. A change to either access knob takes up to a couple of minutes to propagate.

## Connecting

Applications connect exactly as they would to PostgreSQL — PgDog speaks the full wire protocol.

| Setting | Value |
|---|---|
| Host (in-GVC) | `{release-name}-pgdog` (or `{release-name}-pgdog.{gvc}.cpln.local`) |
| Host (public) | the workload's `status.canonicalEndpoint`, when `publicAccess.enabled` is true |
| Port | `6432` |
| Database | a `name` from your `databases` list |
| Username | the `username` key of that user's credentials secret |
| Password | the `password` key of that user's credentials secret |
| Admin database | `admin.database` on the same host/port, as `admin.user`, with the payload of `admin.passwordSecretName` |

## Important Notes

- **A missing prerequisite secret wedges the deployment silently** — `cpln logs` returns zero lines because the container never starts. The only diagnostic is `cpln workload get-deployments {release-name}-pgdog --gvc {gvc} -o yaml` and reading `status.versions[].message` (plain `cpln workload get` has no `versions` key). It recovers on its own within about 6–8 minutes of the secret appearing, or immediately with `cpln workload force-redeployment`.
- **PgDog does not manage PostgreSQL** — it is a proxy only. Deploy a backend before pointing PgDog at it.
- **Port 6432, not 5432** — update application connection strings accordingly.
- **Transaction mode drops session state** — if your application relies on `SET` variables, temporary tables, or advisory locks, use `pooling.mode: session`.
- **Each replica keeps its own pool** — when raising `replicas`, lower `pooling.defaultPoolSize` proportionally or the backend sees `replicas × defaultPoolSize` connections.
- **Rotating a credential needs a restart** — the config files are assembled once at container start, so run `cpln workload force-redeployment` after changing a secret's contents.

## Links

- [PgDog documentation](https://docs.pgdog.dev/)
- [PgDog configuration reference](https://docs.pgdog.dev/configuration/)
- [users.toml reference](https://docs.pgdog.dev/configuration/users.toml/users/)
- [PgDog on GitHub](https://github.com/pgdogdev/pgdog)
- [Create a Control Plane secret](https://docs.controlplane.com/reference/secret)
