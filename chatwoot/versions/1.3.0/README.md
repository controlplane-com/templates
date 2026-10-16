# Chatwoot

> **Upgrading from 1.2.x:** the database credentials are now a secret you create before upgrading,
> under a **new** name — see [Upgrading from 1.2.x](#upgrading-from-12x).

Chatwoot is an open-source customer engagement platform — a live-chat widget, shared email inbox, and omni-channel agent desk. This template deploys the **Community Edition** (MIT core) as a Rails web tier plus a Sidekiq worker, backed by a highly available pgvector-capable PostgreSQL and a bundled Redis, with local or object-storage attachments.

## Architecture

- **Chatwoot web** — a `stateful` HTTP workload (`{release}-chatwoot`, port 3000) serving the dashboard, API, chat widget, and ActionCable WebSockets; scale with `chatwoot.replicas` (requires object storage).
- **Chatwoot worker** — a `standard` workload (`{release}-chatwoot-worker`) running Sidekiq; it also runs the database migrations and the first-run onboarding bootstrap, so it stays at one replica.
- **PostgreSQL** — highly available by default (`postgres-highly-available` subchart: 3 Patroni replicas on PostgreSQL 17.5, 3 etcd replicas, an HAProxy leader endpoint). Its image ships **pgvector**, which Chatwoot's schema requires. A single-instance `postgres` alternative is available for dev.
- **Redis** — a single-node `stateful` workload (`{release}-chatwoot-redis`, port 6379) with AOF persistence and password auth; Sidekiq queues, ActionCable pub/sub, cache, and the one-time install-onboarding flag.
- **Attachment volumeset** — local attachment storage at `/app/storage`; rendered only when `storage.type: local`.
- **Redis volumeset** — AOF persistence at `/data`.
- **Start-script secrets** — the Chatwoot image declares no entrypoint, so the web and worker containers each mount their own start script.
- **Credentials secret** — the template-managed Redis password.
- **Database credentials secret** (dictionary) — *not created by this template*; you create it before install. The bundled PostgreSQL initializes from it and Chatwoot connects with it, in either database mode.
- **Identity + policy** — one identity shared by web and worker, granted `reveal` on exactly the secrets they mount; it also carries the AWS cloud-account link in keyless S3 mode.

## Prerequisites

**Two dictionary secrets must exist BEFORE you install.** They hold credentials, so they are prerequisite secrets rather than values — a value would sit in plaintext in the Helm release for the life of the install.

- **Database credentials** — the bundled PostgreSQL initializes with these and Chatwoot connects with them:

  ```bash
  cpln secret create-dictionary --name my-chatwoot-db-credentials \
    --entry username=chatwoot \
    --entry password="$(openssl rand -hex 24)" \
    --entry database=chatwoot
  ```

  Set its name in the key of the database mode you use: `postgresHA.config.credentialsSecretName` (HA, the default) or `postgres.config.credentialsSecretName` (single-instance). Secret names are org-wide, so give each chatwoot release its own secret. PostgreSQL reads the secret only when its data is first initialized — see [Rotating the database password](#rotating-the-database-password).

- **Root-of-trust keys — create it BEFORE installing.** The workloads reference it by name (`secrets.name`, default `my-chatwoot-secrets`) and the deployment wedges on a missing secret. All four keys are **write-once**: rotating `SECRET_KEY_BASE` logs out every user, and rotating an `ACTIVE_RECORD_ENCRYPTION_*` key makes stored two-factor secrets undecryptable.

  ```bash
  cpln secret create-dictionary --name my-chatwoot-secrets \
    --entry SECRET_KEY_BASE="$(openssl rand -hex 64)" \
    --entry ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY="$(openssl rand -hex 16)" \
    --entry ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY="$(openssl rand -hex 16)" \
    --entry ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT="$(openssl rand -hex 16)"
  ```

- **(Only for `storage.type: s3`)** an AWS S3 bucket, a Control Plane cloud account, and a bucket-scoped IAM policy — keyless; static keys are not accepted for AWS. See Storage setup.
- **(Only for `storage.type: s3-compatible`)** a bucket on a MinIO / SeaweedFS / Spaces server plus a dictionary secret holding its static keys. See Storage setup.
- **(Only for database backups)** a bucket on AWS S3, Google Cloud Storage, or a MinIO endpoint, plus the matching cloud account. See Storage setup. For `provider: minio` (either database mode) the endpoint's keys are a prerequisite dictionary secret — see Storage setup.
- **(Optional, only for authenticated SMTP)** a dictionary secret with `SMTP_USERNAME` + `SMTP_PASSWORD`, referenced via `smtp.auth.secretName`.

  ```bash
  cpln secret create-dictionary --name my-chatwoot-smtp \
    --entry SMTP_USERNAME=apikey --entry SMTP_PASSWORD=...
  ```

**If either secret does not exist at install time the deployment wedges silently.** `cpln logs` returns zero lines — the containers never start, so there is nothing to log. The only diagnostic is `status.versions[].message` in `cpln workload get-deployments RELEASE_NAME-chatwoot --gvc GVC_NAME -o yaml` (note **`get-deployments`** — plain `cpln workload get` has no `versions` key). Create the missing secret and it recovers on its own, but Chatwoot can take up to about 12 minutes to serve again — poll rather than giving up — or skip the wait with `cpln workload force-redeployment`.

## Configuration

### Chatwoot web

```yaml
chatwoot:
  image: chatwoot/chatwoot:v4.16.2-ce   # Community Edition (MIT core); pin a released tag
  replicas: 1                 # >1 requires object storage — local attachments are per-replica
  frontendUrl: ""             # empty = derive from the canonical *.cpln.app endpoint; set (with https://) for a custom domain
  resources:
    minCpu: 250m
    maxCpu: 1000m
    minMemory: 512Mi
    maxMemory: 2Gi
```

### Sidekiq worker

```yaml
worker:
  concurrency: 10             # SIDEKIQ_CONCURRENCY; also this process's Postgres pool size
  resources:
    minCpu: 250m
    maxCpu: 1000m
    minMemory: 512Mi
    maxMemory: 2Gi
```

### Prerequisite secret

```yaml
secrets:
  name: my-chatwoot-secrets   # dictionary secret with the four root-of-trust keys — MUST exist before install
```

### Attachment storage

```yaml
storage:
  type: local                 # local | s3 | s3-compatible (object storage required for replicas > 1)
  local:
    volumeset:
      capacity: 10            # GiB (minimum 10); mounted at /app/storage
  s3:                         # AWS S3 — keyless only
    bucket: my-chatwoot-bucket
    region: us-east-1
    cloudAccountName: my-s3-cloud-account     # Control Plane cloud account
    policyName: my-chatwoot-s3-policy         # your bucket-scoped IAM policy (JSON below)
  s3Compatible:               # MinIO / SeaweedFS / Spaces — static keys
    bucket: my-chatwoot-bucket
    region: us-east-1         # any value; most S3-compatible servers ignore it
    endpoint: http://my-minio-workload:9000   # S3 API address, with scheme and port
    forcePathStyle: true      # true for most S3-compatible servers
    auth:
      secretName: my-chatwoot-s3-keys         # dictionary secret with STORAGE_ACCESS_KEY_ID + STORAGE_SECRET_ACCESS_KEY
```

### SMTP / outbound email (optional)

```yaml
smtp:
  enabled: false              # off = agent invites, password resets and email replies FAIL
  address: smtp.example.com   # SMTP_ADDRESS (note: not SMTP_HOST)
  port: 587
  domain: ""                  # HELO domain; empty = omitted
  authentication: login       # plain | login | cram_md5; empty = unauthenticated relay
  enableStarttlsAuto: true    # false for a plaintext mail catcher
  fromEmail: Chatwoot <no-reply@example.com>
  auth:
    secretName: ""            # optional dictionary secret with SMTP_USERNAME + SMTP_PASSWORD; empty = no auth
```

### Access

```yaml
publicAccess:
  enabled: true               # HTTPS UI, API, widget and WebSockets on the auto *.cpln.app endpoint
internalAccess:
  type: same-gvc              # none | same-gvc | same-org | workload-list
  workloads: []               # used only with workload-list
```

### Database

Enable exactly one of `postgresHA` (default) and `postgres`.

```yaml
postgresHA:
  enabled: true
  config:
    credentialsSecretName: my-chatwoot-db-credentials # PREREQUISITE dictionary secret (username, password, database) — must exist BEFORE install
  replicas: 3
  volumeset:
    capacity: 10              # GiB per replica (minimum 10)
  backup:
    enabled: false            # see Storage setup
    mode: logical             # logical | wal-g
    provider: aws             # aws | gcp | minio

postgres:                     # single-instance alternative (dev/lightweight)
  enabled: false
  image: pgvector/pgvector:pg18   # MUST carry pgvector — stock postgres:18 does not
  config:
    credentialsSecretName: my-chatwoot-db-credentials # PREREQUISITE dictionary secret (username, password, database) — must exist BEFORE install
  volumeset:
    capacity: 10              # GiB (minimum 10)
  backup:
    enabled: false            # see Storage setup
    provider: aws             # aws | gcp | minio
```

### Redis

```yaml
redis:
  image: redis:8
  auth:
    password: change-me-chatwoot-redis   # wired into REDIS_URL — letters/digits/-/_ only; change before install
  resources:
    minCpu: 100m
    maxCpu: 400m
    minMemory: 256Mi
    maxMemory: 512Mi
  volumeset:
    capacity: 10              # GiB (minimum 10); AOF at /data
```

## Storage setup

The default install (`storage.type: local`, backups off) needs none of this.

### AWS S3 attachments (keyless)

1. Create your bucket. Set `storage.s3.bucket` and `storage.s3.region`.
2. If you do not have a Cloud Account, follow [Create a Cloud Account](https://docs.controlplane.com/guides/create-cloud-account). Set `storage.s3.cloudAccountName`.
3. Create an AWS IAM policy with the following JSON (replace `YOUR_BUCKET_NAME` with your bucket) and set `storage.s3.policyName` to its name:

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

4. Set `storage.type: s3`. No access keys are needed — the workload identity authenticates through the cloud account.

### MinIO / S3-compatible attachments (static keys)

1. Create the bucket on your server (for the in-catalog `minio` template in the same GVC: `http://WORKLOAD_NAME.GVC_NAME.cpln.local:9000`).
2. Set `storage.type: s3-compatible`, `storage.s3Compatible.endpoint` to the S3 API address (with scheme and port), and keep `forcePathStyle: true`.
3. Create the static-key dictionary secret and set `storage.s3Compatible.auth.secretName` to its name:

```bash
cpln secret create-dictionary --name my-chatwoot-s3-keys \
  --entry STORAGE_ACCESS_KEY_ID=... --entry STORAGE_SECRET_ACCESS_KEY=...
```

### Database backups

Set `postgresHA.backup.enabled: true` (or `postgres.backup.enabled: true` in single-instance mode) and pick a provider (the same `aws`/`gcp`/`minio` sub-keys exist under both blocks):

- **AWS** — create the bucket, create a [cloud account](https://docs.controlplane.com/guides/create-cloud-account), and create an IAM policy with the JSON above (substituting your backup bucket). Set `backup.provider: aws` plus `backup.aws.bucket`, `region`, `cloudAccountName`, and `policyName`.
- **GCP** — create the bucket, create a [cloud account](https://docs.controlplane.com/guides/create-cloud-account), and grant its service account **Storage Object Admin** (`roles/storage.objectAdmin`) on that bucket. Set `backup.provider: gcp` plus `backup.gcp.bucket` and `cloudAccountName`.
- **MinIO / S3-compatible** — create the bucket on your server. Set `backup.provider: minio` plus `backup.minio.endpoint` (scheme + port) and `bucket`. On both paths the keys are a prerequisite dictionary secret, named by `postgresHA.backup.minio.credentialsSecretName` or `postgres.backup.minio.credentialsSecretName`. The same secret serves either:

  ```bash
  cpln secret create-dictionary --name my-chatwoot-minio-credentials \
    --entry accessKey=YOUR_ACCESS_KEY \
    --entry secretKey=YOUR_SECRET_KEY
  ```

## Connecting

| Target | Address | Credentials |
|---|---|---|
| Public UI / widget | the canonical endpoint — read `status.canonicalEndpoint` (below) | first visit runs `/installation/onboarding` and creates the super admin |
| Internal (same GVC) | `http://{release}-chatwoot.{gvc}.cpln.local:3000` | account login |
| Health | `GET /api` (readiness — checks Postgres + Redis), `GET /health` (liveness) | none |
| Database | `{release}-postgres-ha-proxy.{gvc}.cpln.local:5432` (HA) or `{release}-postgres.{gvc}.cpln.local:5432` | your database credentials secret (`postgresHA.config.credentialsSecretName` or `postgres.config.credentialsSecretName`) — `cpln secret reveal SECRET_NAME -o yaml` |

The canonical `*.cpln.app` hostname appears under `status.canonicalEndpoint` (`cpln workload get {release}-chatwoot --gvc {gvc} -o yaml`).

## Rotating the database password

PostgreSQL keeps the password it was initialized with, and a running workload keeps the values it started with, so a rotation takes three steps in order (single-instance; in HA mode follow [Rotating the database password in HA mode](#rotating-the-database-password-in-ha-mode) instead):

1. Change it in the database: `ALTER ROLE DB_USERNAME PASSWORD 'NEW_PASSWORD';` (connected as that user, from inside the GVC).
2. Update the secret: `cpln secret edit SECRET_NAME`.
3. Right away, redeploy Chatwoot: `cpln workload force-redeployment RELEASE_NAME-chatwoot-worker --gvc GVC_NAME`, then `RELEASE_NAME-chatwoot`, and wait until `get-deployments` no longer shows `will be restarted shortly` — `ready: true` alone can still describe the old replica. Do not redeploy the database: PostgreSQL reads the secret only when it is first initialized, so restarting it only adds downtime.

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

Then force-redeploy `RELEASE_NAME-chatwoot-worker`, then `RELEASE_NAME-chatwoot`, which keep the old password until they restart. The database itself drops connections for roughly 10–60 s at each switchover, but the app cannot open new connections from the `ALTER ROLE` until its own redeploy finishes (several minutes in all), so rotate in a quiet window. If a member stays `starting`, or `running` without `streaming` for several minutes, re-copy it from the leader. This copies the whole database, so it costs network traffic in proportion to its size:

```bash
pgx N curl -s -XPOST -d '{"force": true}' localhost:8008/reinitialize
```

## Upgrading from 1.2.x

`postgres.credentials` was removed: the database credentials are now a prerequisite secret, the same one the database templates require on their own. Carrying the old key forward fails the render.

1.2.x created the database secret itself, so **this upgrade deletes it**. Before upgrading, create a secret under a **new** name holding the values your database was initialized with — not new ones, or Chatwoot loses its database connection:

```bash
cpln secret reveal my-chatwoot-db-credentials -o yaml   # the CURRENT values, until the upgrade deletes this secret
cpln secret create-dictionary --name RELEASE_NAME-chatwoot-db \
  --entry username=YOUR_CURRENT_USERNAME --entry password=YOUR_CURRENT_PASSWORD --entry database=YOUR_CURRENT_DATABASE
```

Then upgrade with `postgresHA.config.credentialsSecretName` (HA mode) or `postgres.config.credentialsSecretName` (single-instance mode) set to that name, and `postgres.credentials` removed. Your current values are also in `postgres.credentials` of the 1.2.x release.

The upgrade restarts the bundled PostgreSQL too (it now reads the new secret), so Chatwoot can briefly lose its database; it reconnects by itself. The new version of a workload can also wait about 10 minutes with `is not allowed to reveal the secret` in `get-deployments`, while access to the new secret propagates; the previous version keeps serving meanwhile, and it clears by itself.

## Upgrading from 1.1.x (HA mode)

`postgresHA.postgres.username/password/database` were removed in 1.2.0 (postgres-highly-available 2.5.0). Put those three values **unchanged** into the database credentials secret under [Prerequisites](#prerequisites), set `postgresHA.config.credentialsSecretName` to its name, and delete the `postgresHA.postgres` block. `postgresHA.backup.minio.accessKey`/`secretKey` moved to a prerequisite secret named by `postgresHA.backup.minio.credentialsSecretName` (see Storage setup).

## Upgrading from 1.0.x

`postgres.config.username/password/database` were removed. Put the values your single-instance database was initialized with into the database credentials secret under [Prerequisites](#prerequisites) (keys `username`, `password`, `database`), set `postgres.config.credentialsSecretName` to its name, and remove the three keys. `postgres.backup.minio.accessKey`/`secretKey` were removed the same way (see Storage setup).

## Important Notes

- **Restart the web workload after any Redis restart.** If the bundled Redis restarts (a redeploy, a reschedule, or an upgrade), background jobs and the cache reconnect on their own, but the web tier's real-time subscriber does **not** — live updates stop silently. Nothing is logged and the health endpoint stays green, so the only symptom is that agents and visitors stop seeing new messages until they refresh. Force-redeploy the `{release}-chatwoot` workload to restore it (about 3–4 minutes).
- **Expect a few minutes of 503s during `helm upgrade`.** The upgrade restarts the bundled Redis, and the web readiness endpoint reports unhealthy without Redis, so every replica leaves the load balancer until Redis is back — measured at roughly 32% failed requests over a ~3 minute window. Upgrade during a quiet period.

- **Choose the database mode before installing — it cannot be switched later.** Flipping `postgresHA.enabled` / `postgres.enabled` on a live release points Chatwoot at a different, empty database (separate volume set, and a different PostgreSQL major: 17.5 for the HA path, 18 for single-instance), so the app re-runs onboarding and your existing data is orphaned rather than migrated.

- **Both prerequisite secrets must exist before install** — a missing `secrets.name` or database credentials secret wedges the deployment with zero log lines; see Prerequisites for the diagnostic.
- **Rotating the database password needs `ALTER ROLE` plus a forced redeployment of Chatwoot** (not the database) — see [Rotating the database password](#rotating-the-database-password).
- **Complete the onboarding wizard promptly** — the first browser session to reach the endpoint creates the super admin account with no email confirmation.
- **The bundled database image must carry pgvector** — Chatwoot's schema runs `CREATE EXTENSION "vector"`. The HA path has it natively; in single-instance mode keep `postgres.image` on a pgvector build (the chart refuses to render against a stock `postgres:` image).
- **`chatwoot.replicas > 1` requires `storage.type` `s3` or `s3-compatible`** — local attachments live on a per-replica volumeset; the chart refuses to render otherwise.
- **In `local` storage mode the Sidekiq worker cannot read attachments** — the volumeset is attached to the web workload only, so attachment emails and ActiveStorage analyze/purge jobs fail. Use object storage for production.
- **With SMTP off, no mail is delivered** — agent invites, password resets, and email-channel replies fail. Configure `smtp.*` before inviting agents.
- **The worker stays at one replica** — it also runs migrations and the first-run bootstrap. Scale background throughput with `worker.concurrency` instead.
- **Redis is a single node and cannot be scaled** — Chatwoot's ActionCable adapter reads `REDIS_URL` directly (no Sentinel support), and Redis does not propagate pub/sub between replicas, so a second node would silently drop live updates.
- **Self-serve signup is toggled after install, not in values** — Chatwoot stores the flag in its database, so sign in as the super admin at `/super_admin`, open **Settings**, and set `ENABLE_ACCOUNT_SIGNUP`. It is disabled on a fresh install.
- **Enterprise features are not included** — the `-ce` image omits SSO/SAML, audit logs, agent capacity management, custom branding, SLA policies, and Captain AI.
- **Uninstalling deletes all data** — `helm uninstall` removes the database and storage volumesets with the release, so conversations and local attachments are gone. Back up first if you need them.
- **Rotating the database password in HA mode needs a leader switchover first** — follow [Rotating the database password in HA mode](#rotating-the-database-password-in-ha-mode). A plain redeploy can promote a member still holding the old password and split the cluster.

## Links

- [Chatwoot self-hosted docs](https://developers.chatwoot.com/self-hosted/deployment/docker)
- [Environment variables reference](https://developers.chatwoot.com/self-hosted/configuration/environment-variables)
- [System requirements](https://developers.chatwoot.com/self-hosted/deployment/requirements)
- [Community vs Enterprise edition](https://developers.chatwoot.com/self-hosted/enterprise-edition)
- [GitHub](https://github.com/chatwoot/chatwoot)
