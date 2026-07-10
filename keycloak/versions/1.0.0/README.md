# Keycloak

This app deploys [Keycloak](https://www.keycloak.org/) — open-source identity and access management providing single sign-on, OIDC/SAML, user federation, and fine-grained authorization. It runs clustered Keycloak 26 in production mode with a highly available PostgreSQL backing store by default, delivering zero-downtime restarts and upgrades.

## Architecture

- **Keycloak**: Stateful workload, 2 replicas by default, clustered via embedded Infinispan (JGroups JDBC_PING through the shared database — no extra infrastructure). `replicas: 1` runs a dev mode with clustering fully disabled.
- **PostgreSQL (HA, default)**: The `postgres-highly-available` template — 3 Patroni replicas, 3 etcd replicas, and an HAProxy leader-routing endpoint Keycloak connects through.
- **PostgreSQL (dev/test, optional)**: The single-instance `postgres` template instead, for lighter deployments.
- **Secrets, identity, and policy**: Bootstrap admin credentials (dictionary secret), startup script (opaque secret), and a least-privilege policy granting the workload access to exactly those secrets.

All durable state — realms, users, and active sessions — lives in PostgreSQL; the Keycloak tier is stateless on disk.

## Prerequisites

- None for a default install. Optional: a custom domain if you want a pinned production hostname, and a cloud account + bucket if you enable the Postgres backup pass-through.

## Installation

```bash
cpln helm install my-keycloak ./keycloak/versions/1.0.0 --gvc my-gvc --dependency-update \
  --set 'admin.password=a-strong-admin-password' \
  --set 'postgresHA.postgres.password=a-strong-db-password'
```

## Configuration

### Keycloak Settings

```yaml
image: quay.io/keycloak/keycloak:26.6.3

replicas: 2          # 2+ = clustered, zero-downtime restarts; 1 = dev mode

resources:           # per replica
  cpu: 1000m
  memory: 2Gi        # JVM heap = 70% of this; do not set below 1.5Gi
  minCpu: 500m
  minMemory: 1Gi

admin:
  username: admin    # temporary bootstrap admin, created on first boot
  password: change-me-keycloak-admin

hostname: ""         # empty: canonical *.cpln.app endpoint works out of the box
                     # production: pin your domain, e.g. https://sso.example.com
```

### Backing Store

Exactly one of the two stores must be enabled (the chart enforces this at render).

```yaml
postgresHA:          # default: highly available PostgreSQL
  enabled: true
  postgres:
    username: keycloak
    password: change-me-keycloak-db
    database: keycloak
  replicas: 3
  volumeset:
    capacity: 10     # GiB per replica
  backup:
    enabled: false   # see the postgres-highly-available template docs
```

```yaml
postgresHA:
  enabled: false
postgres:            # dev/test: single-instance PostgreSQL
  enabled: true
  config:
    username: keycloak
    password: change-me-keycloak-db
    database: keycloak
  volumeset:
    capacity: 10
  backup:
    enabled: false   # see the postgres template docs
```

### Access

```yaml
publicAccess:
  enabled: true      # HTTPS via the canonical *.cpln.app endpoint

internalAccess:
  type: same-gvc     # options: none, same-gvc, same-org, workload-list
  workloads: []      # for workload-list; replicas > 1 requires type != none
```

## Connecting

| What | Value |
|---|---|
| Public URL | `status.canonicalEndpoint` from `cpln workload get {release}-keycloak -o yaml` |
| Admin console | `https://{canonical-endpoint}/admin` |
| OIDC discovery | `https://{canonical-endpoint}/realms/{realm}/.well-known/openid-configuration` |
| In-GVC (internal) | `http://{release}-keycloak.{gvc}.cpln.local:8080` |
| Admin credentials | `admin.username` / `admin.password` values |

## Important Notes

- **Change both default passwords before installing.** The bootstrap admin is temporary by design — log in, create a permanent admin, then remove it.
- **Keep `publicAccess` enabled for browser SSO** — end-user browsers must reach Keycloak's login endpoints; disable it only for pure service-to-service deployments.
- **Do not disable the HA proxy** (`postgresHA.proxy.enabled`) — Keycloak writes through the HAProxy leader endpoint; the chart enforces this at render.
- **Scaling is operator-driven** — change `replicas` via `helm upgrade`; there is deliberately no autoscaling, so cluster membership only changes intentionally.
- **Database volumes survive reinstalls** — uninstalling and reinstalling under the same release name reuses the persisted data unless the volumesets are deleted.

## Links

- [Keycloak documentation](https://www.keycloak.org/documentation)
- [Server configuration reference](https://www.keycloak.org/server/all-config)
- [Caching and clustering](https://www.keycloak.org/server/caching)
