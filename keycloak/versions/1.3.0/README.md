# Keycloak

This app deploys [Keycloak](https://www.keycloak.org/) — open-source identity and access management providing single sign-on, OIDC/SAML, user federation, and fine-grained authorization. It runs clustered Keycloak 26 in production mode with a highly available PostgreSQL backing store by default, delivering zero-downtime restarts and upgrades.

## Architecture

- **Keycloak**: Stateful workload, 2 replicas by default, clustered via embedded Infinispan (JGroups JDBC_PING through the shared database — no extra infrastructure). `replicas: 1` runs a dev mode with clustering fully disabled.
- **PostgreSQL (HA, default)**: The `postgres-highly-available` template — 3 Patroni replicas, 3 etcd replicas, and an HAProxy leader-routing endpoint Keycloak connects through.
- **PostgreSQL (dev/test, optional)**: The single-instance `postgres` template instead, for lighter deployments.
- **Admin secret** (dictionary) — *not created by this template*; you create it before install and reference it by name. Holds the bootstrap admin login.
- **Database credentials secret** (dictionary) — on the single-instance path, built by *this* template from `postgres.credentials.*` and handed to the Postgres store by name. Nothing for you to create. (Not rendered on the HA path — `postgres-highly-available` still makes its own.)
- **Startup script** (opaque secret) — waits for the database and configures clustering; mounted into the container.
- **Identity + policy**: a least-privilege policy granting the workload `reveal` on exactly three secrets — your admin secret, the startup script, and the database credentials.

All durable state — realms, users, and active sessions — lives in PostgreSQL; the Keycloak tier is stateless on disk.

## Prerequisites

**One dictionary secret must exist BEFORE you install.** The bootstrap admin guards a login form on the public endpoint, so it is a prerequisite secret rather than a value — a value would sit in plaintext in the Helm release for the life of the install.

```bash
cpln secret create-dictionary --name my-keycloak-admin \
  --entry username=admin \
  --entry password="$(openssl rand -hex 24)"
```

Then set `admin.secretName` to that name. Read the password back with `cpln secret reveal my-keycloak-admin -o yaml` (the `-o yaml` is required — the default output does not show the values).

| Key | What it is |
|---|---|
| `username` | The temporary bootstrap admin's login name. |
| `password` | Its password. The login form is on the public endpoint. |

**If the secret does not exist at install time the deployment wedges silently.** `cpln logs` returns zero lines — the container never starts, so there is nothing to log. The only diagnostic is `status.versions[].message` in `cpln workload get-deployments {release}-keycloak --gvc {gvc} -o yaml` (note **`get-deployments`** — plain `cpln workload get` has no `versions` key). Create the missing secret and it recovers on its own within roughly 5.5–10.5 minutes — poll rather than giving up — or clear it immediately with `cpln workload force-redeployment {release}-keycloak --gvc {gvc}` (~90 s).

**The database password is not a prerequisite** — it is bundled plumbing no human types elsewhere, so this template creates that secret for you from `postgres.credentials.*` (single-instance path) or hands it to `postgres-highly-available` (HA path).

Optional: a cloud account + bucket if you enable the Postgres backup pass-through.

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
  secretName: my-keycloak-admin # PREREQUISITE dictionary secret — must exist BEFORE install
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
  credentials:       # this template builds the DB credential secret from these
    username: keycloak
    password: change-me-keycloak-db
    database: keycloak
  config:
    # name of the dictionary secret this template CREATES and Postgres reads;
    # secret names are org-wide, so a second release on this name is refused at install
    credentialsSecretName: my-keycloak-db-credentials
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

Public access is **on** by default: browsers must reach Keycloak's login and OIDC endpoints for SSO to work at all, and the admin login is now a credential you created rather than a published default. A firewall change takes 30 s to a few minutes to propagate, so re-test rather than trusting the first response.

## Connecting

| What | Value |
|---|---|
| Public URL | `status.canonicalEndpoint` from `cpln workload get {release}-keycloak -o yaml` |
| Admin console | `https://{canonical-endpoint}/admin` |
| OIDC discovery | `https://{canonical-endpoint}/realms/{realm}/.well-known/openid-configuration` |
| In-GVC (internal) | `http://{release}-keycloak.{gvc}.cpln.local:8080` |
| Admin credentials | `username` / `password` from your `admin.secretName` secret — `cpln secret reveal my-keycloak-admin -o yaml` |
| Database credentials | the `username` / `password` / `database` keys of the secret named by `postgres.config.credentialsSecretName` (HA path: `{release}-postgres-config`) |

## Upgrading from 1.1.0

The bundled single-instance Postgres moved to the `postgres` 3.4.1 template, which no longer
takes database credentials as values. Keycloak absorbed that change rather than passing it on,
so **there is no new prerequisite** — only a rename on the single-instance path:

| Removed key | Replacement |
|---|---|
| `postgres.config.username` | `postgres.credentials.username` |
| `postgres.config.password` | `postgres.credentials.password` |
| `postgres.config.database` | `postgres.credentials.database` |
| `postgres.backup.minio.accessKey` / `.secretKey` | `postgres.backup.minio.credentialsSecretName` (a dictionary secret you create; MinIO backups only) |

Carrying an old key fails the render with the **Postgres template's** message, which tells you
to create a dictionary secret yourself. Ignore that advice here — this template creates it.
Move the three keys and you are done. The `postgresHA` path is unchanged.

## Upgrading from 1.0.x

The bootstrap admin credentials moved out of `values.yaml` into the prerequisite dictionary secret above. Carrying either old key forward fails the render with a message naming its replacement; there are no compatibility fallbacks.

| Removed key | Now a key in the admin secret |
|---|---|
| `admin.username` | `username` |
| `admin.password` | `password` |

**An existing install's admin password does not change on upgrade.** The account already lives in the database, and `KC_BOOTSTRAP_ADMIN_*` is only consulted when no admin exists yet. Put your current credentials into the secret so the install still renders, and change the password in the Keycloak admin console. If the install is still carrying the published 1.0.x default (`change-me-keycloak-admin`), treat that password as compromised and change it in the console now.

## Important Notes

- **Create the admin secret before installing.** A missing prerequisite secret leaves the workload waiting on something that does not exist, with zero log lines — see Prerequisites for how to diagnose it.
- **Change the database password (`postgres.credentials.password`) before installing** — it is bundled plumbing, used exactly as given, and it feeds whichever store is enabled.
- **Give each keycloak release its own `postgres.config.credentialsSecretName`.** Secret names are org-wide, so a second release left on the default name is **refused at install** — `The resource '…' cannot be updated because it is being managed by a different release` — and creates nothing. Nothing is shared or overwritten, and the first release is unaffected; you simply cannot install the second until you give it a distinct name.
- **The bootstrap admin is temporary by design** — log in, create a permanent admin, then remove the bootstrap one (Keycloak warns until you do).
- **Keep `publicAccess` enabled for browser SSO** — end-user browsers must reach Keycloak's login endpoints; disable it only for pure service-to-service deployments.
- **Do not disable the HA proxy** (`postgresHA.proxy.enabled`) — Keycloak writes through the HAProxy leader endpoint; the chart enforces this at render.
- **Scaling is operator-driven** — change `replicas` via `helm upgrade`; there is deliberately no autoscaling, so cluster membership only changes intentionally.
- **Database volumes survive reinstalls** — uninstalling and reinstalling under the same release name reuses the persisted data unless the volumesets are deleted.

## Links

- [Keycloak documentation](https://www.keycloak.org/documentation)
- [Server configuration reference](https://www.keycloak.org/server/all-config)
- [Caching and clustering](https://www.keycloak.org/server/caching)
