# Keycloak

[Keycloak](https://www.keycloak.org/) open-source identity and access management: single sign-on, OIDC/SAML, user federation, and fine-grained authorization. This template deploys a clustered Keycloak 26 in production mode, backed by a highly available PostgreSQL cluster by default.

## Architecture

This template creates:

| Resource | Name | Purpose |
|---|---|---|
| workload (stateful) | `{release}-keycloak` | Keycloak server — 2 replicas by default, clustered via embedded Infinispan over JGroups JDBC_PING |
| secret (dictionary) | `{release}-keycloak-admin` | Bootstrap admin credentials |
| secret (opaque) | `{release}-keycloak-startup` | Startup script: waits for Postgres, configures clustering, starts Keycloak |
| identity | `{release}-keycloak-identity` | Workload identity |
| policy | `{release}-keycloak-policy` | `reveal` on exactly the secrets the workload uses |

Plus one backing store, selected by Helm dependency conditions:

- **`postgresHA` (default)** — the [postgres-highly-available](https://github.com/controlplane-com/templates) template: 3 Patroni PostgreSQL replicas, 3 etcd replicas, and an HAProxy leader-routing endpoint Keycloak connects through.
- **`postgres` (dev/test)** — the single-instance postgres template.

All durable state (realms, users, and — since Keycloak 26 — active user sessions) lives in PostgreSQL; the Keycloak tier itself is stateless on disk. With the default 2 replicas, a single replica restart is invisible to logged-in users.

### Clustering

`replicas: 2+` (default) forms an Infinispan cluster: node discovery goes through the shared PostgreSQL database (JGroups JDBC_PING2, the Keycloak 26 default — no multicast, no Kubernetes API), and replica-to-replica traffic runs over ports 7800/57800 using per-replica DNS (`loadBalancer.replicaDirect`). In-flight logins, cache invalidation, and brute-force counters are shared across replicas.

`replicas: 1` runs dev mode: clustering is fully inert (`--cache local`), and the JGroups ports and `replicaDirect` are omitted from the workload entirely.

## Installation

```bash
cpln helm install my-keycloak ./keycloak/versions/1.0.0 --gvc my-gvc --dependency-update \
  --set 'admin.password=a-strong-admin-password' \
  --set 'postgresHA.postgres.password=a-strong-db-password'
```

## Configuration

### Keycloak

```yaml
image: quay.io/keycloak/keycloak:26.6.3

replicas: 2          # 2+ = clustered (zero-downtime restarts); 1 = dev mode, clustering disabled

resources:           # per replica
  cpu: 1000m
  memory: 2Gi        # JVM heap is sized to 70% of this limit; do not set below 1.5Gi
  minCpu: 500m
  minMemory: 1Gi
```

### Admin bootstrap

Creates a temporary admin on first boot against an empty database. Log in, create a permanent admin, then remove the temporary one.

```yaml
admin:
  username: admin
  password: change-me-keycloak-admin
```

### Hostname

```yaml
hostname: ""                          # default: derive from request headers — canonical *.cpln.app works out of the box
# hostname: https://sso.example.com   # production: pin to your domain (strict hostname checking applies)
```

### Backing store — highly available PostgreSQL (default)

```yaml
postgresHA:
  enabled: true
  postgres:
    username: keycloak
    password: change-me-keycloak-db
    database: keycloak
  replicas: 3
  volumeset:
    capacity: 10          # GiB per replica
  backup:
    enabled: false        # see postgres-highly-available template docs — logical or wal-g, to S3/GCS/MinIO
```

The `postgresHA.backup.*` block is a pass-through to the postgres-highly-available template's native backup feature; see that template's README for details.

### Backing store — single-instance PostgreSQL (dev/test)

```yaml
postgresHA:
  enabled: false
postgres:
  enabled: true
  config:
    username: keycloak
    password: change-me-keycloak-db
    database: keycloak
  volumeset:
    capacity: 10
  backup:
    enabled: false        # pass-through to the postgres template's backup feature
```

Exactly one backing store must be enabled; the chart fails at render otherwise.

### Access

```yaml
publicAccess:
  enabled: true           # HTTPS via the canonical *.cpln.app endpoint

internalAccess:
  type: same-gvc          # none | same-gvc | same-org | workload-list
  workloads: []           # for workload-list; replicas > 1 requires type != none
```

## Connecting

| What | Value |
|---|---|
| Public URL | canonical endpoint — `cpln workload get {release}-keycloak -o yaml`, `status.canonicalEndpoint` |
| Admin console | `https://{canonical-endpoint}/admin` |
| OIDC discovery | `https://{canonical-endpoint}/realms/{realm}/.well-known/openid-configuration` |
| In-GVC (internal) | `http://{release}-keycloak.{gvc}.cpln.local:8080` |
| Admin credentials | `admin.username` / `admin.password` values |

## Important Notes

- **Change both default passwords before installing.** The bootstrap admin is temporary by design — replace it after first login.
- **Keycloak must be publicly reachable for browser SSO.** End-user browsers are redirected to Keycloak's login endpoints; disable `publicAccess` only for pure service-to-service or VPN-fronted deployments.
- **Persistent sessions:** since Keycloak 26, user sessions are stored in PostgreSQL — restarts and upgrades do not log users out, even with a single replica.
- **Do not disable the HA proxy** (`postgresHA.proxy.enabled`) — Keycloak writes through the HAProxy leader endpoint; the chart enforces this at render.
- **Scaling is operator-driven** (no autoscaling): JGroups cluster membership should change only intentionally. Change `replicas` via `helm upgrade`.
- **First install takes several minutes** — the HA postgres stack (etcd + Patroni) must come up before Keycloak's DB wait completes and augmentation/migrations run.
- **Volume data survives reinstalls** — the backing store's volumesets persist database state across `helm uninstall`/`install` of the same release name unless deleted.

## Links

- [Keycloak documentation](https://www.keycloak.org/documentation)
- [Server configuration](https://www.keycloak.org/server/all-config)
- [Caching and clustering](https://www.keycloak.org/server/caching)
- [Reverse proxy guide](https://www.keycloak.org/server/reverseproxy)
- [Sizing guide](https://www.keycloak.org/high-availability/multi-cluster/concepts-memory-and-cpu-sizing)
