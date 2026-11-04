# Constructive

This app deploys [Constructive](https://constructive.io/): pgpm, a package manager for versioned Postgres modules (schemas, row-level security policies, functions), and a GraphQL API generated from the database. The template deploys your pgpm modules from a git tag or your own image at boot, and serves them over an internal GraphQL API whose every request runs as a non-superuser role, so Postgres row-level security (RLS) decides which rows each user sees.

## Architecture

- **GraphQL server** (`RELEASE_NAME-constructive`): standard workload, 1 replica by default (up to 4, interchangeable), serving GraphQL on port 3000 to workloads inside Control Plane only. Each boot creates the database roles and the server's login, deploys Constructive's base modules and your modules when they changed, then starts the server.
- **PostgreSQL** (`RELEASE_NAME-postgres`): the `postgres` template with Constructive's `postgres-plus` image (Postgres 18 with PostGIS and pgvector), one replica on a 10 GiB volume.
- **Database backups (optional)**: the `postgres` template's scheduled backups to object storage.
- **Identity + policy**: `reveal` on exactly your two prerequisite secrets.

## Prerequisites

**Two dictionary secrets must exist BEFORE you install.**

**1. Database credentials**: PostgreSQL initializes its superuser and database with them, and the boot deploys modules with them:

```bash
cpln secret create-dictionary --name my-constructive-db \
  --entry username=constructive \
  --entry password="$(openssl rand -hex 32)" \
  --entry database=constructive
```

**2. Server login**: the boot creates this login as `NOSUPERUSER NOBYPASSRLS`, and the GraphQL server connects as it. Its username must differ from the database username:

```bash
cpln secret create-dictionary --name my-constructive-login \
  --entry username=constructive_app \
  --entry password="$(openssl rand -hex 32)"
```

Secret names are org-wide, so give each release its own secrets.

**If either secret does not exist at install time, the deployment waits silently**: `cpln logs` returns nothing. The only signal is `status.versions[].message` in `cpln workload get-deployments RELEASE_NAME-constructive --gvc GVC_NAME -o yaml`, which names the missing secret. Create the secret and the deployment recovers within about 10 minutes, or right away with `cpln workload force-redeployment RELEASE_NAME-constructive --gvc GVC_NAME`.

**Module source (optional)**: a public git repository holding a pgpm workspace, or your own image built `FROM constructiveio/constructive:08e422d` with the workspace copied in. See [Deploying modules](#deploying-modules).

**Backups (optional)**: a cloud account and bucket, as described in the [postgres](https://docs.controlplane.com/template-catalog/templates/postgres) template.

## Configuration

### Server

```yaml
image: constructiveio/constructive:08e422d # upstream release build of commit 08e422d (upstream publishes no semver tags)

# GraphQL server replicas. All state lives in PostgreSQL, so replicas are interchangeable;
# 2 keeps the API up through restarts and upgrades. Allowed: 1-4.
replicas: 1

resources: # per GraphQL server replica
  minCpu: 250m
  minMemory: 512Mi
  maxCpu: 1000m
  maxMemory: 1Gi
```

### Server login

```yaml
# ─── Server Login ─────────────────────────────────────────────────────────────
server:
  # REQUIRED PREREQUISITE SECRET — CREATE IT BEFORE YOU INSTALL. A `dictionary` secret with
  # `username` and `password`. The chart creates this NOSUPERUSER, NOBYPASSRLS Postgres login on
  # every start and the GraphQL server connects as it, so row-level security always applies.
  # The username must differ from the database superuser. If it is missing the deployment WEDGES silently.
  loginSecretName: my-constructive-login
```

### pgpm modules

```yaml
# ─── pgpm Modules ─────────────────────────────────────────────────────────────
modules:
  source: none # none | git (public repo) | image (workspace baked into your own `image`)
  git:
    url: ""  # https URL of a public repo holding a pgpm workspace, e.g. https://git.example.com/acme/db.git
    ref: ""  # tag or full commit SHA to deploy; change it and `helm upgrade` to deploy a new version
  path: "."  # workspace directory: relative to the repo root (git) or absolute inside the image (image)
  packages: [] # pgpm packages to deploy, in order, e.g. [my-app]
```

### Access

```yaml
# ─── Access ───────────────────────────────────────────────────────────────────
internalAccess: # which workloads can call the GraphQL API (there is no public access: callers assert X-Actor-Id)
  type: same-gvc # options: none, same-gvc, same-org, workload-list
  workloads: [] # used with workload-list
  # workloads:
  #   - //gvc/GVC_NAME/workload/WORKLOAD_NAME
```

### Database

```yaml
# ─── Database: PostgreSQL with PostGIS and pgvector ───────────────────────────
# Deploys the postgres template with Constructive's postgres-plus image (Postgres 18 +
# PostGIS + pgvector), which Constructive's modules require.
postgres:
  image: constructiveio/postgres-plus@sha256:3708b89b001fbc7ca0f5fb5c7818135a6f1c1d4aae0d63cb7ca38aa0fe85a28e # tag 57d7be6: Postgres 18, PostGIS 3.6.4, pgvector 0.8.2
  config:
    # REQUIRED PREREQUISITE SECRET — CREATE IT BEFORE YOU INSTALL. A `dictionary` secret with
    # `username`, `password` and `database`. PostgreSQL initializes its superuser and database from
    # it once; Constructive deploys modules with it. If it is missing the deployment WEDGES silently.
    credentialsSecretName: my-constructive-db
  resources:
    minCpu: 250m
    minMemory: 256Mi
    maxCpu: 1000m
    maxMemory: 1Gi
  volumeset:
    capacity: 10 # initial capacity in GiB (minimum is 10)

  backup: # pass-through to the postgres template's backup feature
    enabled: false
    image: ghcr.io/controlplane-com/backup-images/postgres-backup:18.1.0
    schedule: "0 2 * * *" # daily at 2am UTC
    resources:
      cpu: 100m
      memory: 128Mi
    provider: aws # Options: aws, gcp, or minio
    aws:
      bucket: my-constructive-backup-bucket
      region: us-east-1
      cloudAccountName: my-constructive-backup-cloudaccount
      policyName: my-constructive-backup-policy
      prefix: postgres/backups
    gcp:
      bucket: my-constructive-backup-bucket
      cloudAccountName: my-constructive-backup-cloudaccount
      prefix: postgres/backups
    minio:
      endpoint: http://my-minio-workload:9000
      bucket: my-constructive-backup-bucket
      # REQUIRED prerequisite dictionary secret holding `accessKey` and `secretKey`,
      # only when backup is enabled with provider: minio.
      credentialsSecretName: my-constructive-minio-credentials
      prefix: postgres/backups
```

## Deploying modules

- **Workspace layout**: a pgpm workspace (`pgpm.json` at `modules.path`, packages under it). `modules.packages` takes the pgpm package names (the `%project` in each `pgpm.plan`), deployed in the order listed.
- **Dependencies**: `pgpm deploy` installs nothing. Commit everything your packages require to the workspace (the `pgpm install` output) or bake it into your image. Native extensions such as `pgcrypto` and `postgis` need nothing extra.
- **Grants**: your modules grant `anonymous` and `authenticated` what they may use. A table with no grant answers `permission denied`.
- **New versions**: set a new `modules.git.ref` (or a new `image` tag) and `helm upgrade`. A restart with the same settings skips the deploy, so a branch name never picks up new commits.
- **Failed deploy**: the new replica stops with the pgpm error in its logs and never becomes ready, while the old replicas keep serving. Fix the module or revert the upgrade.
- **Image source**: build `FROM constructiveio/constructive:08e422d`, `COPY` your workspace to an absolute path, set `image` to your image, `modules.source: image` and `modules.path` to that path.

## Connecting

| Who | Endpoint | Notes |
|---|---|---|
| Workloads allowed by `internalAccess` | `http://RELEASE_NAME-constructive.GVC_NAME.cpln.local:3000/graphql` | POST GraphQL with the headers below. |
| You, in a browser | `cpln port-forward RELEASE_NAME-constructive 3000:3000 --gvc GVC_NAME`, then `http://localhost:3000/graphiql` | GraphiQL; add the same headers in its headers pane. |
| PostgreSQL (superuser) | `RELEASE_NAME-postgres.GVC_NAME.cpln.local:5432` | The database credentials secret. |

Every request sends these headers:

| Header | Value |
|---|---|
| `X-Schemata` | the schemas to expose, comma-separated, e.g. `app_public` |
| `X-Database-Id` | `00000000-0000-4000-8000-000000000c01` (fixed for every install) |
| `X-Actor-Id` | the acting user's UUID; requests run as `authenticated` with `jwt.claims.user_id` set to it. Without it they run as `anonymous` |

```bash
curl -s http://RELEASE_NAME-constructive.GVC_NAME.cpln.local:3000/graphql \
  -H 'content-type: application/json' \
  -H 'X-Schemata: app_public' \
  -H 'X-Database-Id: 00000000-0000-4000-8000-000000000c01' \
  -H 'X-Actor-Id: 7d3b8c1e-0000-4000-8000-000000000001' \
  --data '{"query":"query { __typename }"}'
```

## Important Notes

- `X-Actor-Id` is trusted as sent, and `X-Schemata` can name any schema the server login can read. Allow only workloads you trust in `internalAccess`; there is no public endpoint for this reason.
- The server login is re-created on every start. To rotate its password, edit the login secret, then run `cpln workload force-redeployment RELEASE_NAME-constructive --gvc GVC_NAME`.
- Do not edit the database credentials secret after install: PostgreSQL keeps the original credentials, and the server's boot authenticates with the secret, so a changed value stops the server from starting.
- Keep `postgres.image` on an image with PostGIS: Constructive's base modules require it, and a backup restores only into such a server.
- Jobs that modules enqueue are not processed: this template runs no job worker.
- A PostgreSQL restart interrupts the API at any replica count, and the first `helm upgrade` after an install can restart it.
- Use a single-location GVC: the bundled database runs in one location. Uninstalling deletes the database volume.

## Links

- [Constructive on GitHub](https://github.com/constructive-io/constructive)
- [Constructive quickstart](https://github.com/constructive-io/constructive/blob/main/QUICKSTART.md)
- [GraphQL server reference](https://github.com/constructive-io/constructive/tree/main/graphql/server)
- [pgpm modules](https://github.com/constructive-io/pgpm-modules)
