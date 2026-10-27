# Twenty

> **Upgrading from 1.3.x:** the database credentials and the Redis password are now secrets you create
> before upgrading, under **new** names — see [Upgrading from 1.3.x](#upgrading-from-13x).

[Twenty](https://twenty.com) is an open-source CRM — customizable objects, pipelines, views and workflows, with a REST and GraphQL API. This template deploys the Twenty server, its background worker, a bundled Redis job queue, and a PostgreSQL database (single-instance by default, or highly available), reachable over HTTPS on the platform's automatic endpoint.

## Architecture

- **Twenty server** — one image serving the React front end and the NestJS API on HTTP `:3000`; scales horizontally via `twenty.replicas`.
- **Background worker** — the same image running `yarn worker:prod`; always exactly one replica (it registers cron jobs, and owns boot migrations when `twenty.replicas > 1`).
- **Redis** — bundled single node with AOF persistence and `maxmemory-policy noeviction`, for BullMQ job queues and cache.
- **PostgreSQL** — the `postgres` template (single instance, PostgreSQL 18) by default, or the `postgres-highly-available` template (3 Patroni replicas, 3 etcd replicas, HAProxy leader endpoint, PostgreSQL 17) as an opt-in.
- **Volume sets** — Redis AOF at `/data`; local attachment storage at `/app/packages/twenty-server/.local-storage` (*only* in `storage.type: local`).
- **Identity + policy** — one identity shared by the three workloads, granted `reveal` on exactly the secrets they mount.
- **Secrets** — template-created secrets for the server and worker start scripts; the app key, the database credentials, the Redis password and any S3 static keys come from secrets you create.
- **Database credentials secret** (dictionary) — *not created by this template*; you create it before install. The bundled PostgreSQL initializes from it and Twenty connects with it, in either database mode.
- **Redis credentials secret** (dictionary) — *not created by this template*; you create it before install. Redis requires its password and the server and worker connect with it.

## Prerequisites

**Three secrets must exist BEFORE you install.** They hold credentials, so they are prerequisite secrets rather than values — a value would sit in plaintext in the Helm release for the life of the install.

- **Database credentials** — a dictionary secret; the bundled PostgreSQL initializes with these and Twenty connects with them:

  ```bash
  cpln secret create-dictionary --name my-twenty-db-credentials \
    --entry username=twenty \
    --entry password="$(openssl rand -hex 24)" \
    --entry database=twenty
  ```

  Set its name in the key of the database mode you use: `postgres.config.credentialsSecretName` (single-instance, the default) or `postgresHA.config.credentialsSecretName` (HA). Use only letters, digits, `-` and `_` in all three values — Twenty puts them in its database connection URL, and other characters break it (the `openssl rand -hex` password above is safe). Secret names are org-wide, so give each twenty release its own secret. PostgreSQL reads the secret only when its data is first initialized — see [Rotating the database password](#rotating-the-database-password).

- **Redis password** — a dictionary secret; the bundled Redis requires it and the server and worker connect with it:

  ```bash
  cpln secret create-dictionary --name my-twenty-redis \
    --entry password="$(openssl rand -hex 24)"
  ```

  Set its name in `redis.credentialsSecretName`. Use only letters, digits, `-` and `_`: Twenty receives the password inside its `REDIS_URL`, unencoded. Give each twenty release its own secret. To change it later, see [Rotating the Redis password](#rotating-the-redis-password).

- **An opaque secret holding the app key.** Twenty uses it as both `APP_SECRET` and `ENCRYPTION_KEY` (at-rest encryption of OAuth tokens, TOTP secrets and app variables). Reference it with `secrets.name`.

  ```bash
  printf '%s' "$(openssl rand -base64 32)" | \
    cpln secret create-opaque --name my-twenty-app-secret --encoding plain --file -
  ```

- **(Only for S3 attachment storage)** a bucket on AWS S3 (keyless via a cloud account + IAM policy — static keys are not accepted for AWS) or a MinIO/S3-compatible server with a static-key dictionary secret — see Storage setup.
- **(Only during a key rotation)** a second opaque secret holding the *previous* app key, referenced via `secrets.fallbackName`.
- **(Only for database backups)** a bucket on AWS S3, Google Cloud Storage or a MinIO/S3-compatible server, plus a Control Plane cloud account — see Storage setup.

**If any of these secrets does not exist at install time the deployment wedges silently.** `cpln logs` returns zero lines — the containers never start, so there is nothing to log. The only diagnostic is `status.versions[].message` in `cpln workload get-deployments RELEASE_NAME-twenty --gvc GVC_NAME -o yaml` — for the Redis secret, also `RELEASE_NAME-twenty-redis` (note **`get-deployments`** — plain `cpln workload get` has no `versions` key). Create the missing secret and it recovers on its own, but Twenty can take up to about 12 minutes to serve again — poll rather than giving up — or skip the wait with `cpln workload force-redeployment`.

## Configuration

### Twenty server

```yaml
twenty:
  # One image serves the React front end and the NestJS API on :3000.
  # Docker tag keeps the leading "v"; Chart appVersion drops it.
  image: twentycrm/twenty:v2.26.1
  # Stateless web tier. >1 REQUIRES storage.type: s3 and moves boot migrations
  # to the worker (they must run in exactly one container).
  replicas: 1
  # Public base URL. MUST match the URL browsers use or auth/CORS fail with
  # opaque errors. Empty = the platform canonical endpoint. Set WITH https://
  # only for a custom domain.
  serverUrl: ""
  # Postgres connections per pool, per process. Raise replicas and this together
  # with care — the database has a finite connection limit.
  dbPoolMaxConnections: 10
  resources:
    minCpu: 250m
    maxCpu: 1000m
    minMemory: 512Mi
    maxMemory: 2Gi   # headroom for first-boot migrations and upgrade backfills
```

### Background worker

```yaml
# Same image, `yarn worker:prod`. Always exactly one replica: it owns cron
# registration, and boot migrations when twenty.replicas > 1.
worker:
  resources:
    minCpu: 250m
    maxCpu: 1000m
    minMemory: 512Mi
    maxMemory: 2Gi
```

### App key secret

```yaml
secrets:
  name: my-twenty-app-secret
  # Optional: opaque secret holding the PREVIOUS key, only during a rotation
  # (e.g. my-twenty-app-secret-old). Empty = no fallback.
  fallbackName: ""
```

### Attachment storage

```yaml
storage:
  type: local                 # local | s3  (s3 required for twenty.replicas > 1)
  local:
    volumeset:
      capacity: 10            # GiB (minimum 10); mounted at /app/packages/twenty-server/.local-storage
  s3:
    bucket: my-twenty-bucket
    region: us-east-1
    endpoint: ""              # set for S3-compatible servers (e.g. http://my-minio:9000)
    cloudAccountName: my-s3-cloud-account
    policyName: my-twenty-s3-policy
    auth:
      secretName: ""          # static-key dictionary secret; S3-compatible endpoints only
```

### Access

```yaml
publicAccess:
  enabled: true               # HTTPS UI + API on the auto *.cpln.app endpoint; false = internal-only
internalAccess:
  type: same-gvc              # none | same-gvc | same-org | workload-list
  workloads: []               # used only with workload-list
```

### Redis

```yaml
redis:
  image: redis:8.10.0
  credentialsSecretName: my-twenty-redis   # PREREQUISITE dictionary secret (key: password; letters/digits/-/_ only) — must exist BEFORE install
  resources:
    minCpu: 100m
    maxCpu: 400m
    minMemory: 256Mi
    maxMemory: 512Mi
  volumeset:
    capacity: 10              # GiB (minimum 10); AOF at /data
```

### Database — single instance (default)

```yaml
postgres:
  enabled: true
  image: postgres:18          # PostgreSQL 18 (the HA path below runs 17 — the majors differ)
  config:
    credentialsSecretName: my-twenty-db-credentials # PREREQUISITE dictionary secret (username, password, database) — must exist BEFORE install
  resources:
    minCpu: 250m
    maxCpu: 1000m
    minMemory: 512Mi
    maxMemory: 1Gi
  volumeset:
    capacity: 10              # GiB (minimum 10)
  backup:
    enabled: false            # see Storage setup; provider: aws | gcp | minio
```

### Database — highly available (opt-in)

Set `postgres.enabled: false` and `postgresHA.enabled: true`. Exactly one database must be enabled.

```yaml
postgresHA:
  enabled: false
  image: controlplanecorporation/patroni-postgres:0.8 # pgvector 0.8.7; tags 0.1-0.7 are refused
  config:
    credentialsSecretName: my-twenty-db-credentials # PREREQUISITE dictionary secret (username, password, database) — must exist BEFORE install
  replicas: 3
  resources:
    minCpu: 500m
    maxCpu: 1000m
    minMemory: 1Gi
    maxMemory: 2Gi
  volumeset:
    capacity: 10              # GiB per replica (minimum 10)
  backup:
    enabled: false            # see Storage setup; mode: logical | wal-g, provider: aws | gcp | minio
```

## Storage setup

Needed for `storage.type: s3` (required when `twenty.replicas > 1`) and for database backups. The default install — local attachments, backups off — needs none of it.

### AWS S3 (keyless, preferred)

1. Create your bucket. Set `storage.s3.bucket` and `storage.s3.region`.
2. If you do not have a Cloud Account, follow [Create a Cloud Account](https://docs.controlplane.com/guides/create-cloud-account). Set `storage.s3.cloudAccountName`.
3. Create an AWS IAM policy with the JSON below (replace `YOUR_BUCKET_NAME` with your `storage.s3.bucket` value) and set `storage.s3.policyName` to its name:

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

4. Leave `storage.s3.auth.secretName` empty — the workload identity authenticates through the cloud account with no static keys. (AWS S3 is keyless-only here: the chart rejects static keys unless an S3-compatible `endpoint` is set.)

### MinIO / S3-compatible (static keys)

1. Create the bucket on your server (for the in-catalog `minio` template in the same GVC: `http://WORKLOAD_NAME.GVC_NAME.cpln.local:9000`).
2. Set `storage.s3.endpoint` to the S3 API address, with scheme and port.
3. Create a static-key dictionary secret with the server's access/secret keys (for the MinIO template: its `admin.username` / `admin.password`) and set `storage.s3.auth.secretName` to its name:

```bash
cpln secret create-dictionary --name my-twenty-s3-keys \
  --entry STORAGE_S3_ACCESS_KEY_ID=... --entry STORAGE_S3_SECRET_ACCESS_KEY=...
```

### Database backups (AWS S3 and MinIO)

Scheduled database backups are configured on whichever database path you enabled — `postgres.backup.*` (single instance) or `postgresHA.backup.*` (highly available). They are off by default.

**AWS S3** — create the bucket, a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account), and an IAM policy scoped to that bucket, then set `…backup.enabled: true`, `…backup.provider: aws`, and `…backup.aws.{bucket,region,cloudAccountName,policyName}`. The policy JSON is the same bucket-scoped document shown above for attachment storage.

**MinIO / S3-compatible** — set `…backup.provider: minio` and `…backup.minio.{endpoint,bucket}`; no cloud account is involved because keys authenticate directly. The two database paths take those keys differently:

- **Single instance** — create a dictionary secret and name it in `postgres.backup.minio.credentialsSecretName`:

  ```bash
  cpln secret create-dictionary --name my-twenty-minio-credentials \
    --entry accessKey=ACCESS_KEY \
    --entry secretKey=SECRET_KEY
  ```
- **Highly available** — set `postgresHA.backup.minio.credentialsSecretName` to the same secret created above.

The backing database template's own README carries the full per-provider walkthrough.

### Google Cloud Storage (database backups only)

1. Create the bucket and set `postgres.backup.gcp.bucket` (or `postgresHA.backup.gcp.bucket`).
2. Create a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account) for GCP and set `…backup.gcp.cloudAccountName`.
3. Grant that account's service account the **Storage Object Admin** role (`roles/storage.objectAdmin`) on the bucket — not on the whole project.

## Connecting

| What | Where |
|---|---|
| Web UI + REST + GraphQL (public) | the workload's canonical `cpln.app` HTTPS endpoint — read it from `status.canonicalEndpoint` in `cpln workload get {release}-twenty --gvc {gvc} -o yaml` |
| Health check | `GET /healthz` on the same endpoint |
| From another workload in the GVC | `http://{release}-twenty.{gvc}.cpln.local:3000` |
| Redis (internal only) | `{release}-twenty-redis.{gvc}.cpln.local:6379`, `password` key of the secret named by `redis.credentialsSecretName` |
| Database (internal only) | `{release}-postgres.{gvc}.cpln.local:5432`, or `{release}-postgres-ha-proxy.{gvc}.cpln.local:5432` in HA mode |
| Database credentials | `username` / `password` / `database` keys of the secret named by `postgres.config.credentialsSecretName` (HA mode: `postgresHA.config.credentialsSecretName`) — `cpln secret reveal SECRET_NAME -o yaml` |
| First login | there is no seeded account — **the first person to sign up becomes the workspace admin** |

## Rotating the database password

PostgreSQL keeps the password it was initialized with, and a running workload keeps the values it started with, so a rotation takes three steps in order (single-instance; in HA mode follow [Rotating the database password in HA mode](#rotating-the-database-password-in-ha-mode) instead):

1. Change it in the database: `ALTER ROLE DB_USERNAME PASSWORD 'NEW_PASSWORD';` (connected as that user, from inside the GVC; letters, digits, `-` and `_` only).
2. Update the secret: `cpln secret edit SECRET_NAME`.
3. Right away, redeploy Twenty: `cpln workload force-redeployment RELEASE_NAME-twenty-worker --gvc GVC_NAME`, then `RELEASE_NAME-twenty`, and wait until `get-deployments` shows a higher version number, alone and ready (right after the command the status may not show the restart yet, and `ready: true` alone can still describe the old replica). Do not redeploy the database: PostgreSQL reads the secret only when it is first initialized, so restarting it only adds downtime.

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

Then force-redeploy `RELEASE_NAME-twenty-worker`, then `RELEASE_NAME-twenty`, which keep the old password until they restart. The database itself drops connections for roughly 10–60 s at each switchover, but the app cannot open new connections from the `ALTER ROLE` until its own redeploy finishes (several minutes in all), so rotate in a quiet window. If a member stays `starting`, or `running` without `streaming` for several minutes, re-copy it from the leader. This copies the whole database, so it costs network traffic in proportion to its size:

```bash
pgx N curl -s -XPOST -d '{"force": true}' localhost:8008/reinitialize
```

## Rotating the Redis password

Redis keeps no password on disk: it takes the password from the secret each time it starts, and the server and worker do the same. So rotation is the secret and then the restarts:

1. Update the secret: `cpln secret edit SECRET_NAME` (letters, digits, `-` and `_` only), and check the new value with `cpln secret reveal SECRET_NAME -o yaml`.
2. Redeploy Redis, the worker and the server together: `cpln workload force-redeployment RELEASE_NAME-twenty-redis --gvc GVC_NAME`, then the same for `RELEASE_NAME-twenty-worker` and `RELEASE_NAME-twenty`. None of them picks up the change without its redeploy.

Expect a short interruption: until all three have restarted, Redis and the app hold different passwords, so queued jobs wait and the server cannot reach its cache.

## Upgrading from 1.4.0 or earlier (HA mode)

1.4.1 runs the highly available database (`postgresHA`) on `controlplanecorporation/patroni-postgres:0.8`, which carries pgvector 0.8.7 (CVE-2026-103484); earlier versions ran `0.7`. The fix takes effect when the upgrade restarts the Patroni members, and existing data needs nothing. Nothing limits the rollout of a stateful workload, so expect a short database outage while the members and the proxy restart, and upgrade in a quiet window. Twenty does not use the `vector` extension; if you created it yourself in a database, `\dx` keeps reporting the old version until you run `ALTER EXTENSION vector UPDATE;` there. If you set `postgresHA.image` in your values, set it to the `0.8` tag: tags `0.1` to `0.7` are refused at render. Single-instance installs (`postgres`) are unaffected.

## Upgrading from 1.3.x

`postgres.credentials` was removed: the database credentials are now a prerequisite secret, the same one the database templates require on their own. `redis.auth.password` was removed the same way: the Redis password is now a prerequisite secret named by `redis.credentialsSecretName`. Carrying either old key forward fails the render.

1.3.x created the database secret itself, so **this upgrade deletes it**. Before upgrading, create a secret under a **new** name holding the values your database was initialized with — not new ones, or Twenty loses its database connection. `OLD_SECRET_NAME` is the `credentialsSecretName` of the mode you use (default `my-twenty-db-credentials`):

```bash
cpln secret reveal OLD_SECRET_NAME -o yaml   # the CURRENT values, until the upgrade deletes this secret
cpln secret create-dictionary --name RELEASE_NAME-postgres-credentials \
  --entry username='YOUR_CURRENT_USERNAME' --entry password='YOUR_CURRENT_PASSWORD' --entry database='YOUR_CURRENT_DATABASE'
```

1.3.x also kept the Redis password in a secret it created, `RELEASE_NAME-twenty-creds` (key `redisPassword`), which this upgrade deletes too. Create the Redis secret under a different name, holding the **current** Redis password:

```bash
cpln secret reveal RELEASE_NAME-twenty-creds -o yaml   # redisPassword is the CURRENT Redis password
cpln secret create-dictionary --name RELEASE_NAME-twenty-redis \
  --entry password='YOUR_CURRENT_REDIS_PASSWORD'
```

Then upgrade with `postgres.config.credentialsSecretName` (single-instance mode) or `postgresHA.config.credentialsSecretName` (HA mode) set to the database secret's name, `redis.credentialsSecretName` set to the Redis secret's name, and `postgres.credentials` and `redis.auth` removed. Your current values are also in `postgres.credentials` and `redis.auth.password` of the 1.3.x release.

The upgrade restarts the bundled PostgreSQL and Redis too (they now read the new secrets), so Twenty loses its database for up to about 3 minutes and Redis briefly; it reconnects by itself. The new version of a workload can also wait about 10 minutes with `is not allowed to reveal the secret` in `get-deployments`, while access to the new secret propagates; the previous version keeps serving meanwhile, and it clears by itself.

## Upgrading from 1.0.x

`postgres.config.username/password/database` were removed. Put the values your single-instance database was initialized with into the database credentials secret under [Prerequisites](#prerequisites) (keys `username`, `password`, `database`), set `postgres.config.credentialsSecretName` to its name, and remove the three keys. `postgres.backup.minio.accessKey`/`secretKey` moved to a dictionary secret you create, named by `postgres.backup.minio.credentialsSecretName` (see Storage setup).

## Upgrading from 1.1.x (highly available path)

`postgresHA.postgres.username/password/database` were removed in 1.2.0 (postgres-highly-available 2.5.0). Put those three values **unchanged** into the database credentials secret under [Prerequisites](#prerequisites), set `postgresHA.config.credentialsSecretName` to its name, and delete the `postgresHA.postgres` block. `postgresHA.backup.minio.accessKey`/`secretKey` moved to a dictionary secret you create, named by `postgresHA.backup.minio.credentialsSecretName` (see Storage setup).

## Important Notes

- **First boot takes a few minutes, and logs some alarming-looking errors on the way.** A single-instance install reaches ready in roughly 4 minutes; the highly-available path takes closer to 9, because the server retries against the HAProxy endpoint until Patroni has elected a leader. During that window you will see `relation "core.appToken" does not exist` and similar for about a minute — that is the migration race resolving itself, not a failure. Give it the full window before intervening.

- **`local` storage uses a shared (read-write-many) volume mounted by both the server and the worker**, so attachments are visible to background jobs. Shared volumes support expansion only — **no snapshots** — and exist in a single location, so `storage.type: s3` remains the durable choice for production and is required for `twenty.replicas > 1`.

- **All three prerequisite secrets must exist before install** — a missing app-key, database credentials or Redis secret wedges the deployment with zero log lines; see Prerequisites for the diagnostic.
- **Changing the database credentials secret does not change the database password** — PostgreSQL keeps the password it was initialized with. Rotate with `ALTER ROLE` plus a forced redeployment of Twenty (not the database) — see [Rotating the database password](#rotating-the-database-password).
- **Rotating the Redis password needs a forced redeployment of Redis, the worker and the server** — see [Rotating the Redis password](#rotating-the-redis-password).
- **Rotating the database password in HA mode needs a leader switchover first** — follow [Rotating the database password in HA mode](#rotating-the-database-password-in-ha-mode). A plain redeploy can promote a member still holding the old password and split the cluster.
- **On a public endpoint, whoever reaches the URL first owns the CRM.** Sign up immediately after install, or set `publicAccess.enabled: false` until you are ready.
- **Treat the app key as write-once.** Changing `secrets.name` without pointing `secrets.fallbackName` at the old key makes stored OAuth tokens, TOTP secrets and app variables undecryptable and logs everyone out.
- **`twenty.replicas > 1` requires `storage.type: s3`**, and moves boot migrations to the worker — on a *fresh* multi-replica install the servers may serve errors for a minute or two until the worker finishes migrating.
- **Set `twenty.serverUrl` when you put a custom domain in front of Twenty**, with the scheme (`https://crm.example.com`); a mismatch breaks auth callbacks and CORS with opaque errors.
- **SMTP, AI provider keys, rate limits and OAuth/SSO are not values knobs** — configure them in *Settings → Admin Panel → Configuration Variables* inside the app; changes apply within about 15 seconds.
- **Foreign data wrappers ("remote objects") are unavailable** — they need upstream's custom Postgres image, which this template does not deploy.
- **Data survives reinstall** unless you delete the volume sets and the database; uninstalling the release removes them.

## Links

- [Twenty documentation](https://docs.twenty.com/)
- [Self-hosting setup and configuration variables](https://docs.twenty.com/developers/self-host/capabilities/setup)
- [Upgrade guide](https://docs.twenty.com/developers/self-host/capabilities/upgrade-guide)
- [REST and GraphQL API](https://docs.twenty.com/developers/extend/api)
- [Twenty on GitHub](https://github.com/twentyhq/twenty)
