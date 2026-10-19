# NocoDB

> **Upgrading from 1.3.x:** the database credentials and the Redis password are now secrets you create
> before upgrading, under **new** names — see [Upgrading from 1.3.x](#upgrading-from-13x).

NocoDB is a no-code database and spreadsheet-style app builder — the self-hosted Airtable alternative with grid, kanban, gallery and calendar views, forms, automations and a REST API. This template deploys NocoDB Community Edition backed by Postgres (all metadata), Redis (realtime, cache, rate limiting) and local or S3 attachment storage.

## Architecture

- **NocoDB server** — a `stateful` HTTP workload (`{release}-nocodb`, port 8080) serving the UI, REST/GraphQL API and live updates; scale with `nocodb.replicas` (requires S3 storage). Runs meta-database migrations automatically on boot.
- **PostgreSQL** — the metadata store holding every base, table, view, user and automation. Either the `postgres` subchart (single instance, default) or the `postgres-highly-available` subchart (3 Patroni replicas + 3 etcd + HAProxy, opt-in).
- **Redis** — bundled single-node workload with AOF persistence; job/event pub-sub, metadata cache and rate limiter. Required — it is what makes more than one replica coherent. Live updates reach the browser over HTTP long-poll (`POST /jobs/listen`) backed by this pub-sub, not over websockets.
- **Attachment volumeset** — local attachment storage at `/usr/app/data`; created only when `storage.type: local`.
- **Database credentials secret** (dictionary) — *not created by this template*; you create it before install. The bundled PostgreSQL initializes from it and NocoDB connects with it, in either database mode.
- **Redis credentials secret** (dictionary) — *not created by this template*; you create it before install. Redis requires its password and NocoDB connects with it.
- **Identity + policy** — grants the workloads `reveal` on exactly the secrets they mount; carries the AWS cloud-account link in keyless S3 mode.

## Prerequisites

**Three dictionary secrets must exist BEFORE you install.** They hold credentials, so they are prerequisite secrets rather than values — a value would sit in plaintext in the Helm release for the life of the install.

- **Database credentials** — the bundled PostgreSQL initializes with these and NocoDB connects with them:

  ```bash
  cpln secret create-dictionary --name my-nocodb-db-credentials \
    --entry username=nocodb \
    --entry password="$(openssl rand -hex 24)" \
    --entry database=nocodb
  ```

  Set its name in the key of the database mode you use: `postgres.config.credentialsSecretName` (single-instance, the default) or `postgresHA.config.credentialsSecretName` (HA). Use only letters, digits, `-` and `_` in all three values: NocoDB receives them inside its `NC_DB` connection URL, unencoded, so other characters break the connection. Secret names are org-wide, so give each nocodb release its own secret. PostgreSQL reads the secret only when its data is first initialized — see [Rotating the database password](#rotating-the-database-password).

- **Redis password** — the bundled Redis requires it and NocoDB connects with it:

  ```bash
  cpln secret create-dictionary --name my-nocodb-redis \
    --entry password="$(openssl rand -hex 24)"
  ```

  Set its name in `redis.credentialsSecretName`. Use only letters, digits, `-` and `_`: NocoDB receives the password inside its `NC_REDIS_URL`, unencoded. Give each nocodb release its own secret. To change it later, see [Rotating the Redis password](#rotating-the-redis-password).

- **Root-of-trust keys — create it BEFORE installing.** The server references it by name (`secrets.name`, default `my-nocodb-secrets`) and the deployment wedges on a missing secret. It holds NocoDB's two root-of-trust keys, both **write-once**: rotating `NC_AUTH_JWT_SECRET` logs out every user, and changing `NC_CONNECTION_ENCRYPT_KEY` makes the stored credentials of external data sources undecryptable (upstream has no re-encryption path).

  ```bash
  cpln secret create-dictionary --name my-nocodb-secrets \
    --entry NC_AUTH_JWT_SECRET="$(openssl rand -hex 64)" \
    --entry NC_CONNECTION_ENCRYPT_KEY="$(openssl rand -hex 32)"
  ```

- **(Optional, to bootstrap the super admin)** a dictionary secret with `NC_ADMIN_EMAIL` + `NC_ADMIN_PASSWORD`, referenced via `admin.secretName`. The password needs 8+ characters with an uppercase letter, a digit and a special character.

  ```bash
  cpln secret create-dictionary --name my-nocodb-admin \
    --entry NC_ADMIN_EMAIL=admin@example.com --entry NC_ADMIN_PASSWORD='Password1!'
  ```

- **(Only for S3 attachment storage)** a bucket on AWS S3 (keyless via a Control Plane cloud account + a bucket-scoped IAM policy) or a MinIO/S3-compatible server plus a static-key dictionary secret — see Storage setup.
- **(Only for database backups)** a bucket on AWS S3, Google Cloud Storage or a MinIO/S3-compatible server, plus a Control Plane cloud account for the first two — see Storage setup. With `provider: minio` (either database mode) the endpoint's keys are a prerequisite dictionary secret — see that section.
- **(Optional, only for authenticated SMTP)** a dictionary secret with `NC_SMTP_USERNAME` + `NC_SMTP_PASSWORD`, referenced via `smtp.auth.secretName`.

  ```bash
  cpln secret create-dictionary --name my-nocodb-smtp \
    --entry NC_SMTP_USERNAME=apikey --entry NC_SMTP_PASSWORD=changeme
  ```

**If any of these secrets does not exist at install time the deployment wedges silently.** `cpln logs` returns zero lines — the containers never start, so there is nothing to log. The only diagnostic is `status.versions[].message` in `cpln workload get-deployments RELEASE_NAME-nocodb --gvc GVC_NAME -o yaml` — for the Redis secret, also `RELEASE_NAME-nocodb-redis` (note **`get-deployments`** — plain `cpln workload get` has no `versions` key). Create the missing secret and it recovers on its own, which can take around 10 minutes — poll rather than giving up — or skip the wait with `cpln workload force-redeployment`.

## Configuration

### NocoDB server

```yaml
nocodb:
  image: nocodb/nocodb:2026.07.0
  replicas: 1                 # >1 requires storage.type: s3; replicas coordinate through Redis. 2 absorbs the first-upgrade Redis restart — see Important Notes
  siteUrl: ""                 # empty = derive from the canonical *.cpln.app endpoint; set (with https://) for a custom domain
  allowLocalWebhooks: false   # allow webhooks to same-GVC/private targets (*.cpln.local); off = NocoDB's SSRF guard blocks them
  resources:
    minCpu: 250m
    maxCpu: 1000m
    minMemory: 512Mi
    maxMemory: 2Gi            # upstream recommends 4 vCPU / 8 GB for a busy multi-team instance
```

### Prerequisite secret

```yaml
secrets:
  name: my-nocodb-secrets     # dictionary secret with NC_AUTH_JWT_SECRET + NC_CONNECTION_ENCRYPT_KEY — MUST exist before install
```

### Super-admin bootstrap (optional)

```yaml
admin:
  secretName: ""              # empty = the first browser signup becomes super admin; set to a dictionary secret to bootstrap instead
```

### Attachment storage

```yaml
storage:
  type: local                 # local | s3 (s3 required for nocodb.replicas > 1)
  local:
    volumeset:
      capacity: 10            # GiB (minimum 10); mounted at /usr/app/data
  s3:
    bucket: my-nocodb-bucket
    region: us-east-1
    endpoint: ""              # set for S3-compatible servers (e.g. http://my-minio-workload:9000)
    forcePathStyle: false     # true for most S3-compatible servers (MinIO, SeaweedFS)
    cloudAccountName: my-s3-cloud-account   # keyless auth (AWS) — used only when auth.secretName is empty
    policyName: my-nocodb-s3-policy         # your pre-created IAM policy (JSON below)
    auth:
      secretName: ""          # optional dictionary secret with NC_S3_ACCESS_KEY + NC_S3_ACCESS_SECRET; required for MinIO
  fileUploadSizeLimit: 20971520   # max single attachment size in BYTES (upstream default 20971520 = 20 MiB); applies to both storage modes
```

### SMTP / email (optional)

```yaml
smtp:
  enabled: false              # off = invitations and password-reset emails cannot be delivered
  host: smtp.example.com
  port: 587
  secure: false               # false = STARTTLS/plain (587); true = implicit TLS (465)
  from: no-reply@example.com  # From address
  ignoreTls: false            # true for a plaintext mail catcher
  rejectUnauthorized: false   # true to require a valid server certificate
  auth:
    secretName: ""            # optional dictionary secret with NC_SMTP_USERNAME + NC_SMTP_PASSWORD; empty = unauthenticated relay
```

### Access

```yaml
publicAccess:
  enabled: true               # HTTPS UI, API and shared views/forms on the auto *.cpln.app endpoint
internalAccess:
  type: same-gvc              # none | same-gvc | same-org | workload-list
  workloads: []               # used only with workload-list
```

### Redis

```yaml
redis:
  image: redis:8.10.0
  credentialsSecretName: my-nocodb-redis   # PREREQUISITE dictionary secret (key: password; letters/digits/-/_ only) — must exist BEFORE install
  resources:
    minCpu: 100m
    maxCpu: 400m
    minMemory: 256Mi
    maxMemory: 512Mi
  volumeset:
    capacity: 10              # GiB (minimum 10); AOF at /data
```

### Database

Enable exactly one of `postgres` (single instance, the default) and `postgresHA`.
Set `postgresHA.enabled: true` (and `postgres.enabled: false`) for near-zero-downtime upgrades and automatic failover.

```yaml
postgres:
  enabled: true
  image: postgres:18
  config:
    credentialsSecretName: my-nocodb-db-credentials # PREREQUISITE dictionary secret (username, password, database) — must exist BEFORE install
  volumeset:
    capacity: 10              # GiB (minimum 10)
  backup:
    enabled: false            # see Storage setup; provider: aws | gcp | minio

postgresHA:
  enabled: false              # 3 Patroni replicas + 3 etcd + an HAProxy leader endpoint
  config:
    credentialsSecretName: my-nocodb-db-credentials # PREREQUISITE dictionary secret (username, password, database) — must exist BEFORE install
  replicas: 3
  volumeset:
    capacity: 10              # GiB per replica (minimum 10)
  backup:
    enabled: false            # see Storage setup; mode: logical | wal-g, provider: aws | gcp | minio
```

## Storage setup

Needed for `storage.type: s3` (required when `nocodb.replicas > 1`) and for database backups. The default install — local attachments, backups off — needs none of it.

### AWS S3 (keyless, preferred)

1. Create your bucket. Set `storage.s3.bucket` and `storage.s3.region`.
2. If you do not have a Cloud Account, follow [Create a Cloud Account](https://docs.controlplane.com/guides/create-cloud-account). Set `storage.s3.cloudAccountName`.
3. Create an AWS IAM policy with the following JSON (replace `YOUR_BUCKET_NAME` with the `storage.s3.bucket` value) and set `storage.s3.policyName` to its name:

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject",
                "s3:ListBucket"
            ],
            "Resource": [
                "arn:aws:s3:::YOUR_BUCKET_NAME",
                "arn:aws:s3:::YOUR_BUCKET_NAME/*"
            ]
        }
    ]
}
```

4. Leave `storage.s3.auth.secretName` empty — the workload identity authenticates through the cloud account with no static keys. (The chart rejects static keys unless an S3-compatible `endpoint` is set.)

### MinIO / S3-compatible (static keys)

1. Create the bucket on your server (for the in-catalog `minio` template in the same GVC: `http://WORKLOAD_NAME.GVC_NAME.cpln.local:9000`).
2. Set `storage.s3.endpoint` to the S3 API address (with scheme and port) and `storage.s3.forcePathStyle: true`.
3. Create a static-key dictionary secret with the server's access/secret keys and set `storage.s3.auth.secretName` to its name:

```bash
cpln secret create-dictionary --name my-nocodb-s3-keys \
  --entry NC_S3_ACCESS_KEY=minioadmin --entry NC_S3_ACCESS_SECRET=minioadmin
```

### Database backups (AWS S3 and MinIO)

Scheduled backups are configured on whichever database path you enabled — `postgres.backup.*` (single instance) or `postgresHA.backup.*` (highly available). They are off by default.

**AWS S3** — create the bucket, a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account), and an IAM policy scoped to that bucket, then set `…backup.enabled: true`, `…backup.provider: aws`, and `…backup.aws.{bucket,region,cloudAccountName,policyName}`. The policy JSON is the same bucket-scoped document shown above for attachment storage.

**MinIO / S3-compatible** — set `…backup.provider: minio` and `…backup.minio.{endpoint,bucket}`; no cloud account is involved because the keys authenticate directly. On both paths the keys are a prerequisite dictionary secret, named by `postgresHA.backup.minio.credentialsSecretName` or `postgres.backup.minio.credentialsSecretName`. The same secret serves either:

```bash
cpln secret create-dictionary --name my-nocodb-minio-credentials \
  --entry accessKey=YOUR_ACCESS_KEY \
  --entry secretKey=YOUR_SECRET_KEY
```

The HA path additionally chooses `postgresHA.backup.mode`: `logical` (scheduled `pg_dump`) or `wal-g` (continuous WAL archiving).

### Google Cloud Storage (database backups only)

1. Create the bucket and set `postgres.backup.gcp.bucket` (or `postgresHA.backup.gcp.bucket`).
2. Create a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account) for GCP and set `…backup.gcp.cloudAccountName`.
3. Grant that account's service account the **Storage Object Admin** role (`roles/storage.objectAdmin`) on the bucket — not on the whole project. GCP has no equivalent of the AWS `policyName` field, so the grant is the whole configuration.

## Connecting

| Target | Address | Credentials |
|---|---|---|
| Public UI + API | the canonical endpoint — read `status.canonicalEndpoint` (below) | first browser signup becomes super admin, or the `admin.secretName` credentials |
| Internal (same GVC) | `http://{release}-nocodb.{gvc}.cpln.local:8080` | account login |
| Health | `GET /api/v1/health` | none |
| Version | `GET /api/v1/version` | none |
| Database | `{release}-postgres.{gvc}.cpln.local:5432` or, in HA mode, `{release}-postgres-ha-proxy.{gvc}.cpln.local:5432` | your database credentials secret — `cpln secret reveal SECRET_NAME -o yaml` |

The canonical `*.cpln.app` hostname appears under `status.canonicalEndpoint` (`cpln workload get {release}-nocodb --gvc {gvc} -o yaml`).

## Rotating the database password

PostgreSQL keeps the password it was initialized with, and a running workload keeps the values it started with, so a rotation takes three steps in order (single-instance; in HA mode follow [Rotating the database password in HA mode](#rotating-the-database-password-in-ha-mode) instead):

1. Change it in the database: `ALTER ROLE DB_USERNAME PASSWORD 'NEW_PASSWORD';` (connected as that user, from inside the GVC; letters, digits, `-` and `_` only).
2. Update the secret: `cpln secret edit SECRET_NAME`.
3. Right away, redeploy NocoDB: `cpln workload force-redeployment RELEASE_NAME-nocodb --gvc GVC_NAME`, and wait until `get-deployments` shows a higher version number, alone and ready (right after the command the status may not show the restart yet, and `ready: true` alone can still describe the old replica). Do not redeploy the database: PostgreSQL reads the secret only when it is first initialized, so restarting it only adds downtime.

Connections the app already has open keep working after `ALTER ROLE`; new ones fail until its redeploy finishes, so redeploy right away and rotate in a quiet window.

## Rotating the database password in HA mode

The HA database (`postgresHA`) needs its own order. The replication role `repl` shares the password, and a member that restarts with the old password can be promoted to leader, which splits the cluster. Move the leader to member `-0` first, so it restarts last, after every other member already has the new password. `pgx` runs a command in one member (`LOCATION` is your GVC's location, `DB_USERNAME` the secret's `username`):

```bash
pgx() { cpln workload exec RELEASE_NAME-postgres-ha --gvc GVC_NAME --location LOCATION \
  --container patroni-postgres --replica "RELEASE_NAME-postgres-ha-$1" -- "${@:2}"; }
# 1. Find the leader ("role": "leader"); the other two must be "streaming" on the same "timeline"
pgx 0 curl -s localhost:8008/cluster
# 2. If the leader is not RELEASE_NAME-postgres-ha-0, move it there (N = current leader), then repeat step 1
pgx 0 curl -s -XPOST -d '{"leader":"RELEASE_NAME-postgres-ha-N","candidate":"RELEASE_NAME-postgres-ha-0"}' localhost:8008/switchover
# 3-5. Back to back: change BOTH roles on -0, put the same password in the secret, restart the members
pgx 0 psql -h 127.0.0.1 -d postgres -c "ALTER ROLE DB_USERNAME PASSWORD 'NEW_PASSWORD'; ALTER ROLE repl PASSWORD 'NEW_PASSWORD';"
cpln secret edit SECRET_NAME
cpln workload force-redeployment RELEASE_NAME-postgres-ha --gvc GVC_NAME
# 6. After ~5-7 minutes, confirm one leader and two "streaming" replicas on one timeline (repeat step 1)
# 7. Optional: remove the install-time password Patroni keeps in its cluster config
pgx 0 curl -s -XPATCH -d '{"postgresql":{"authentication":null}}' localhost:8008/config
```

Then force-redeploy `RELEASE_NAME-nocodb`, which keeps the old password until it restarts. The database itself drops connections for roughly 10–60 s at each switchover, but the app cannot open new connections from the `ALTER ROLE` until its own redeploy finishes (about 9 minutes measured with one replica), so rotate in a quiet window. If a member stays `starting`, or `running` without `streaming` for several minutes, re-copy it from the leader. This copies the whole database, so it costs network traffic in proportion to its size:

```bash
pgx N curl -s -XPOST -d '{"force": true}' localhost:8008/reinitialize
```

## Rotating the Redis password

Redis keeps no password on disk: it takes the password from the secret each time it starts, and NocoDB does the same. So rotation is the secret and then both restarts:

1. Update the secret: `cpln secret edit SECRET_NAME` (letters, digits, `-` and `_` only), and check the new value with `cpln secret reveal SECRET_NAME -o yaml`.
2. Redeploy Redis and NocoDB together: `cpln workload force-redeployment RELEASE_NAME-nocodb-redis --gvc GVC_NAME` and `cpln workload force-redeployment RELEASE_NAME-nocodb --gvc GVC_NAME`. Neither picks up the change without its redeploy.

Expect a short interruption: until both have restarted, one side holds the old password and NocoDB cannot reach Redis.

## Upgrading from 1.3.x

`postgres.credentials` was removed: the database credentials are now a prerequisite secret, the same one the database templates require on their own. `redis.auth.password` was removed the same way: the Redis password is now a prerequisite secret named by `redis.credentialsSecretName`. Carrying either old key forward fails the render.

1.3.x created the database secret itself, so **this upgrade deletes it**. Before upgrading, create a secret under a **new** name holding the values your database was initialized with — not new ones, or NocoDB loses its database connection:

```bash
cpln secret reveal my-nocodb-db-credentials -o yaml   # the CURRENT values, until the upgrade deletes this secret
cpln secret create-dictionary --name RELEASE_NAME-nocodb-db \
  --entry username='YOUR_CURRENT_USERNAME' --entry password='YOUR_CURRENT_PASSWORD' --entry database='YOUR_CURRENT_DATABASE'
```

1.3.x also kept the Redis password in a secret it created, `RELEASE_NAME-nocodb-creds` (key `redisPassword`), which this upgrade deletes too. Create the Redis secret under a different name, holding the **current** Redis password:

```bash
cpln secret reveal RELEASE_NAME-nocodb-creds -o yaml   # redisPassword is the CURRENT Redis password
cpln secret create-dictionary --name RELEASE_NAME-nocodb-redis \
  --entry password='YOUR_CURRENT_REDIS_PASSWORD'
```

Then upgrade with `postgres.config.credentialsSecretName` (single-instance mode) or `postgresHA.config.credentialsSecretName` (HA mode) set to the database secret's name, `redis.credentialsSecretName` set to the Redis secret's name, and `postgres.credentials` and `redis.auth` removed. Your current values are also in `postgres.credentials` and `redis.auth.password` of the 1.3.x release.

The upgrade restarts the bundled PostgreSQL and Redis too (they now read the new secrets), so NocoDB can briefly lose its database and Redis; it recovers by itself. The new version of a workload can also wait about 10 minutes with `is not allowed to reveal the secret` in `get-deployments`, while access to the new secret propagates; the previous version keeps serving meanwhile, and it clears by itself.

## Upgrading from 1.1.x (HA mode)

`postgresHA.postgres.username/password/database` were removed in 1.2.0 (postgres-highly-available 2.5.0). Put those three values **unchanged** into the database credentials secret under [Prerequisites](#prerequisites), set `postgresHA.config.credentialsSecretName` to its name, and delete the `postgresHA.postgres` block. `postgresHA.backup.minio.accessKey`/`secretKey` moved to a prerequisite secret named by `postgresHA.backup.minio.credentialsSecretName` (see Storage setup).

## Upgrading from 1.0.x

`postgres.config.username/password/database` were removed. Put the values your single-instance database was initialized with into the database credentials secret under [Prerequisites](#prerequisites) (keys `username`, `password`, `database`), set `postgres.config.credentialsSecretName` to its name, and remove the three keys. `postgres.backup.minio.accessKey`/`secretKey` were removed the same way (see Storage setup).

## Important Notes

- **All three prerequisite secrets must exist before install** — a missing `secrets.name`, database credentials or Redis secret wedges the deployment with zero log lines; see Prerequisites for the diagnostic. The `secrets.name` keys are write-once: rotating `NC_AUTH_JWT_SECRET` logs out every user, and changing `NC_CONNECTION_ENCRYPT_KEY` makes stored external-data-source credentials undecryptable.
- **Signup is open by default** — with public access on, anyone who reaches the URL can create an account. Invite-only is an in-app setting (Team & Settings), not an environment variable, so turn it on in the UI right after install.
- **`admin.secretName` re-applies on every boot** — if set, the password in that secret is re-imposed at each restart, silently reverting a password changed in the UI. Either leave it empty or treat the secret as the source of truth.
- **`nocodb.replicas > 1` requires `storage.type: s3`** — local attachments live on per-replica volumes and would 404 across replicas; the chart refuses to render otherwise.
- **The first `helm upgrade` after an install briefly restarts the bundled Redis**, even when nothing about Redis changed; NocoDB exits rather than reconnecting and is restarted. At `replicas: 1` that is a short outage on a routine config change (the endpoint returns `503 no healthy upstream` for roughly a minute); at `replicas: 2` it was not user-visible. Later upgrades of the same release do not restart Redis.
- **Rolling upgrades are seamless; an abruptly killed replica is not** — measured at `replicas: 2`: a full rolling upgrade served **434 of 434 requests with HTTP 200**, while a hard `kill -9` of one replica produced **6 × HTTP 503 out of 289 requests within an ~11 s window** before traffic settled. Running two replicas is what absorbs both cases.
- **Live updates arrive over HTTP long-poll, not websockets** — `POST /jobs/listen` backed by Redis pub-sub is the real path (socket.io at this version carries telemetry only), so debug a stalled live update at Redis and that endpoint.
- **Background jobs run inside the web process** — Community Edition ships only an in-process queue, so a long import, export or base duplication dies with the replica running it and must be re-run. Multi-replica buys request availability and rolling upgrades, not job durability.
- **`nocodb.siteUrl` must match the URL browsers use** — it drives invite/reset links and the auth cookie secure flag; leave it empty unless a custom domain is in play.
- **With SMTP off, invitations and password resets cannot be delivered** — configure `smtp.*` before inviting collaborators.
- **Webhooks to same-GVC targets are blocked by default** — NocoDB's SSRF guard refuses private-network addresses, so a webhook aimed at another workload in your GVC (e.g. an internal n8n at `<workload>.<gvc>.cpln.local`) is rejected with a message to set `NC_ALLOW_LOCAL_HOOKS=true`. Set `nocodb.allowLocalWebhooks: true` to allow it. Leave it off if webhooks only ever call the public internet.
- **Rotating the Redis password needs a forced redeployment of both Redis and NocoDB** — see [Rotating the Redis password](#rotating-the-redis-password).
- **Rotating the database password needs `ALTER ROLE` plus a forced redeployment of NocoDB** (not the database) — see [Rotating the database password](#rotating-the-database-password).
- **Rotating the database password in HA mode needs a leader switchover first** — follow [Rotating the database password in HA mode](#rotating-the-database-password-in-ha-mode). A plain redeploy can promote a member still holding the old password and split the cluster.
- **Uninstalling deletes all data** — `helm uninstall` removes the database and storage volumesets with the release, so bases and local attachments are gone. Back up first if you need them.
- **SSO/SAML/OIDC, audit logs and row-level security are Enterprise features** — they are in the same image but need a purchased licence key that this template never sets.

## Model Context Protocol (MCP)

NocoDB exposes an **MCP server** (an endpoint AI agents connect to), created **per base in the UI** — there is no instance-level env flag, so it cannot be pre-enabled by this template. To connect a client:

1. In NocoDB, open a base → **Settings → Model Context Protocol → New MCP Endpoint**, which gives you an endpoint URL and an `xc-mcp-token`.
2. Register it with your MCP client, e.g. Claude Code:

   ```bash
   claude mcp add --transport http nocodb <endpoint-url> --header "xc-mcp-token: <token>"
   ```

The token authenticates every call (requests without it get `401`). Account-level MCP and OAuth are Enterprise-gated and not available on this edition.

## Links

- [NocoDB documentation](https://nocodb.com/docs/product-docs)
- [Self-hosting guide](https://nocodb.com/docs/self-hosting)
- [Environment variables](https://nocodb.com/docs/self-hosting/environment-variables)
- [NocoDB on GitHub](https://github.com/nocodb/nocodb)
- [Create a Cloud Account](https://docs.controlplane.com/guides/create-cloud-account)
