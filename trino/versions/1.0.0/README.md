# Trino

Trino is a distributed SQL query engine that queries data where it lives. This template deploys a Trino cluster — one coordinator plus a scalable worker tier — that federates SQL across PostgreSQL, MySQL, ClickHouse, MongoDB and 40+ other connectors, joining across them in a single query without copying any data.

## Architecture

- **Coordinator workload** — parses and plans queries, serves the Web UI and the JDBC/REST endpoint on port 8080, and tracks the workers. Always one replica.
- **Worker workload** — stateless execution tier, `workers.replicas` replicas (optional: `0` collapses to single-node mode where the coordinator executes queries itself).
- **Config secrets** — `config.properties`, `jvm.config` and `node.properties` rendered by the template and mounted into `/etc/trino`.
- **Catalog secrets** — one per `catalogs[]` entry, mounted as `/etc/trino/catalog/<name>.properties` on every node (optional).
- **Password-authenticator secret** — `password-authenticator.properties`, coordinator only (optional, created when `auth.enabled`).
- **Identity + policy** — shared by both workloads; grants `reveal` on exactly the config, catalog and authentication secrets in use.

No persistent volumes: Trino owns no data, so a restart costs only the queries in flight.

## Prerequisites

- None for a default install — the image ships the `tpch`, `tpcds`, `memory` and `jmx` catalogs, so the cluster is queryable immediately.
- To query your own data sources: a Control Plane secret per credential, created **before** install (see [Connecting data sources](#connecting-data-sources)).
- To enable authentication (required for public access): two opaque secrets created before install — a bcrypt password file and a shared secret (see [Authentication](#authentication)).

## Configuration

### Image

```yaml
image: trinodb/trino:483
```

### Coordinator

```yaml
coordinator:
  resources:
    minCpu: 500m
    maxCpu: 1000m
    minMemory: 2Gi
    maxMemory: 4Gi # JVM heap is a percentage OF THIS — see jvm.maxRAMPercentage
```

### Workers

```yaml
workers:
  replicas: 1 # 0 = single-node mode (the coordinator executes queries itself)
  resources:
    minCpu: 500m
    maxCpu: 2000m
    minMemory: 2Gi
    maxMemory: 4Gi # JVM heap is a percentage OF THIS — see jvm.maxRAMPercentage
```

Raise `replicas` for more query throughput and to keep capacity available through a rolling restart. `maxMemory` must be whole GiB and at least `2Gi`, and `maxCpu:minCpu` may not exceed 4:1 — the template refuses to render otherwise.

### JVM

```yaml
jvm:
  maxRAMPercentage: 70
```

Heap is this percentage of each tier's `maxMemory`; the allowed range is 40–80.

Trino derives its per-node query memory (30% of heap) and headroom (30% of heap) from the heap, so `maxMemory` is normally the only number to change. Capacity AI is disabled on both workloads because the JVM sizes its heap from the container limit at startup.

### Catalogs

```yaml
catalogs: []
```

Each entry renders one secret and one file at `/etc/trino/catalog/<name>.properties` on every node:

```yaml
catalogs:
  - name: pg # queried as pg.<schema>.<table>
    properties: | # copied from the connector's documentation page
      connector.name=postgresql
      connection-url=jdbc:postgresql://WORKLOAD_NAME.GVC_NAME.cpln.local:5432/postgres
      connection-user=postgres
      connection-password=${ENV:PG_PASSWORD}
    secrets:
      - env: PG_PASSWORD # injected as an env var, referenced as ${ENV:PG_PASSWORD}
        secretName: my-postgres-credentials # must exist BEFORE install
        secretKey: password # omit for an opaque secret (uses its payload)
```

`name` must be lowercase letters, digits and underscores; `env` names must be unique across all catalogs.

### Authentication

```yaml
auth:
  enabled: false
  passwordFileSecretName: "" # opaque secret, payload = bcrypt password file (e.g. my-trino-passwords)
  sharedSecretName: "" # opaque secret, payload = random string shared by all nodes (e.g. my-trino-shared-secret)
```

Create both secrets first — Trino requires an internal shared secret as soon as authentication is on:

```bash
htpasswd -B -C 10 -n alice | cpln secret create-opaque \
  --name my-trino-passwords --encoding plain -f -    # bcrypt, cost >= 8; one user per line
printf '%s' "$(openssl rand -hex 32)" | cpln secret create-opaque \
  --name my-trino-shared-secret --encoding plain -f -
```

### Access

```yaml
publicAccess:
  enabled: false # true = Web UI + JDBC on the automatic *.cpln.app HTTPS endpoint; requires auth.enabled

internalAccess: # who may reach the coordinator from inside Control Plane
  type: same-gvc # options: same-gvc, same-org, workload-list ('none' breaks Trino — the coordinator calls itself over this path)
  workloads: [] # used with workload-list, e.g. //gvc/GVC_NAME/workload/WORKLOAD_NAME
```

`internalAccess` controls who may reach the coordinator — including its own workers, which announce themselves over that same internal path. `workload-list` is safe because the coordinator automatically allows its worker workload in addition to whatever you list. **`none` is rejected outright**: the coordinator addresses itself by service DNS, so even a single-node install routes its own task and status calls through this firewall and every query fails with *403 RBAC: access denied*. The worker tier keeps its own least-privilege firewall (coordinator and sibling workers only).

## Connecting data sources

Point a catalog at any reachable database. Sibling templates in the same GVC are reachable at their fully qualified internal name, `WORKLOAD_NAME.GVC_NAME.cpln.local`:

| Template | Workload name | Port |
|---|---|---|
| postgres | its release name + `-postgres` | `5432` |
| mysql | its release name + `-mysql` | `3306` |
| mariadb | its release name + `-maria` | `3306` |
| clickhouse | its release name + `-clickhouse-server` | `8123` (HTTP interface) |
| mongodb | its release name + `-mongo` | `27017` |

Credentials always come from a pre-created secret and are referenced with Trino's `${ENV:NAME}` substitution, so no password is ever written into values or into a rendered file.

Create the credential secret first:

```bash
# one credential -> opaque secret (referenced without secretKey)
printf '%s' 'the-password' | cpln secret create-opaque --name my-postgres-credentials --encoding plain -f -

# several values -> dictionary secret (referenced with secretKey)
cpln secret create-dictionary --name my-mysql-credentials --entry password=the-password
```

Then wire it up:

```yaml
catalogs:
  # postgres / postgres-highly-available / timescaledb / postgis
  - name: pg
    properties: |
      connector.name=postgresql
      connection-url=jdbc:postgresql://WORKLOAD_NAME.GVC_NAME.cpln.local:5432/postgres
      connection-user=postgres
      connection-password=${ENV:PG_PASSWORD}
    secrets:
      - env: PG_PASSWORD
        secretName: my-postgres-credentials

  # mysql / mariadb / tidb — no database name in the URL
  - name: mysql
    properties: |
      connector.name=mysql
      connection-url=jdbc:mysql://WORKLOAD_NAME.GVC_NAME.cpln.local:3306
      connection-user=root
      connection-password=${ENV:MYSQL_PASSWORD}
    secrets:
      - env: MYSQL_PASSWORD
        secretName: my-mysql-credentials
        secretKey: password

  # clickhouse — HTTP interface on 8123
  - name: clickhouse
    properties: |
      connector.name=clickhouse
      connection-url=jdbc:clickhouse://WORKLOAD_NAME.GVC_NAME.cpln.local:8123/
      connection-user=default
      connection-password=${ENV:CLICKHOUSE_PASSWORD}
    secrets:
      - env: CLICKHOUSE_PASSWORD
        secretName: my-clickhouse-credentials

  # mongodb — credentials live inside the URL, so the whole URL is the secret
  - name: mongo
    properties: |
      connector.name=mongodb
      mongodb.connection-url=${ENV:MONGO_URL}
    secrets:
      - env: MONGO_URL
        secretName: my-mongo-url
```

Use the user name your database template was installed with in `connection-user`. With those in place a single query spans all of them:

```sql
SELECT c.name, count(*)
FROM pg.public.orders o
JOIN mysql.shop.customers c ON c.id = o.customer_id
GROUP BY c.name;
```

Iceberg tables in object storage need a REST catalog, which this template does not bundle: deploy the `polaris` template against your bucket and add the `iceberg` catalog entry its README gives. Hive and Delta Lake catalogs are not offered.

## Connecting

| Target | Address | Credentials |
|---|---|---|
| Web UI / JDBC (public) | `status.canonicalEndpoint` from `cpln workload get RELEASE_NAME-trino --gvc GVC_NAME -o yaml` | password-file user, when `auth.enabled` |
| JDBC / clients (internal) | `jdbc:trino://RELEASE_NAME-trino.GVC_NAME.cpln.local:8080/<catalog>/<schema>` | none; plain HTTP, so usable only while `auth.enabled` is false |
| CLI inside the cluster | `cpln workload exec RELEASE_NAME-trino --gvc GVC_NAME --container trino -- trino --execute "SELECT 1"` | none |
| Built-in catalogs | `tpch`, `tpcds`, `memory`, `jmx`, `system` | none |

## Important Notes

- **Authentication and public access must be enabled together; the chart refuses either alone.** The Trino server refuses password logins over plain HTTP (`401 Password not allowed for insecure authentication`), so with auth on, clients sign in over the public HTTPS endpoint; without auth, the internal firewall is the boundary.
- The default install has no authentication and is reachable only inside the GVC.
- Both authentication secrets and every catalog credential secret must exist **before** install — a missing secret leaves the deployment waiting.
- There is one coordinator per cluster and OSS Trino has no coordinator failover: restarting the coordinator interrupts querying. Worker replicas are interchangeable, so scale `workers.replicas` for capacity and restart tolerance.
- Queries in flight on a worker that is replaced or restarted fail and must be retried — Trino retries nothing without fault-tolerant execution.
- Nothing is persisted: uninstalling removes the cluster but never touches the databases it queries, and your own credential secrets are left in place.
- Keep the GVC single-location: coordinator/worker traffic is per-query and latency-sensitive.

## Links

- [Trino documentation](https://trino.io/docs/current/)
- [Connectors](https://trino.io/docs/current/connector.html)
- [Deployment and configuration properties](https://trino.io/docs/current/installation/deployment.html)
- [Password file authentication](https://trino.io/docs/current/security/password-file.html)
- [Secrets in properties files](https://trino.io/docs/current/security/secrets.html)
