# GlitchTip

> **Upgrading from 1.3.x:** the database credentials and the Redis password are now secrets you create
> before upgrading, under **new** names — see [Upgrading from 1.3.1](#upgrading-from-131).

This app deploys [GlitchTip](https://glitchtip.com/) — Sentry-API-compatible error tracking, fully MIT-licensed with nothing feature-gated. Apps report crashes with standard Sentry SDKs pointed at a GlitchTip DSN; a stateless web tier serves the UI and event ingest, a background worker processes events and alerts, and all state lives in PostgreSQL and Redis.

## Architecture

- **GlitchTip web**: Standard workload (default 1 replica, `replicas` knob for more) serving the UI, API, and SDK event ingest on port 8000.
- **GlitchTip worker**: Single-replica standard workload running the vtasks worker + scheduler; runs database migrations and superuser bootstrap at boot.
- **PostgreSQL (HA, default)** (subchart): the `postgres-highly-available` template — 3× Patroni Postgres, 3× etcd, and an HAProxy leader endpoint. Holds all issue/event data.
- **PostgreSQL (dev/lightweight, optional)** (subchart): the single-instance `postgres` template instead.
- **Redis + Sentinel (default, optional)** (subchart): the `redis` template — task queue, cache, and sessions; disable to run those on PostgreSQL instead.
- **Auth secret** (dictionary): *not created by this template*; you create it before install and reference it by name. Holds the Django signing key and the initial superuser login.
- **Database credentials secret** (dictionary): *not created by this template*; you create it before install. The database initializes from it and GlitchTip connects with it, in either database mode.
- **Redis password secret** (dictionary, when Redis is enabled): *not created by this template*; you create it before install. Redis, Sentinel and GlitchTip all read it.
- **Secrets, identity, and policy**: two start scripts, and a least-privilege policy granting the shared identity `reveal` on exactly the secrets used — nothing broader.

## Prerequisites

**Three dictionary secrets must exist BEFORE you install** (the third only with Redis enabled, the default). They hold credentials, so they are prerequisite secrets rather than values — a value would sit in plaintext in the Helm release for the life of the install.

**1. Database credentials** — the bundled PostgreSQL initializes with these and GlitchTip connects with them:

```bash
cpln secret create-dictionary --name my-glitchtip-db-credentials \
  --entry username=glitchtip \
  --entry password="$(openssl rand -hex 24)" \
  --entry database=glitchtip
```

Set its name in the key of the database mode you use: `postgresHA.config.credentialsSecretName` (HA, the default) or `postgres.config.credentialsSecretName` (single-instance). PostgreSQL reads the secret only when its data is first initialized — see Important Notes for how to change the password later.

**2. Auth** — the Django signing key and the superuser login; the admin login form is on a public endpoint. Create it with exactly these three keys:

```bash
cpln secret create-dictionary --name my-glitchtip-auth \
  --entry secretKey="$(openssl rand -hex 32)" \
  --entry adminEmail=admin@example.com \
  --entry adminPassword="$(openssl rand -hex 24)"
```

Then set `auth.secretName` to that name. Read it back later with `cpln secret reveal my-glitchtip-auth -o yaml` (the `-o yaml` is required — the default output does not show the values).

| Key | What it is |
|---|---|
| `secretKey` | Django's `SECRET_KEY` — signs sessions and tokens. Keep it for the life of the install: changing it logs every user out. |
| `adminEmail` / `adminPassword` | The initial superuser, seeded on first boot only. Afterwards manage accounts in the UI; editing the secret does not change the existing login. |

**3. Redis password** — Redis requires it, and Sentinel and GlitchTip connect with it. No spaces, backslashes or double quotes: Redis writes it into its config file and will not start on them (the hex value below is safe):

```bash
cpln secret create-dictionary --name my-glitchtip-redis \
  --entry password="$(openssl rand -hex 24)"
```

Set `redis.redis.auth.fromSecret.name` to that name. To change the password later, see [Rotating the Redis password](#rotating-the-redis-password).

**If any of these secrets does not exist at install time the deployment wedges silently.** `cpln logs` returns zero lines — the container never starts, so there is nothing to log. The only diagnostic is `status.versions[].message` in `cpln workload get-deployments <release>-glitchtip --gvc <gvc> -o yaml` (note **`get-deployments`** — plain `cpln workload get` has no `versions` key). Create the missing secret and it recovers on its own, but GlitchTip can take up to about 12 minutes to serve again — poll rather than giving up — or clear it immediately with `cpln workload force-redeployment <release>-glitchtip --gvc <gvc>` (~90 s). The worker workload wedges the same way and needs the same treatment, and a missing Redis secret also wedges `<release>-redis` and `<release>-sentinel`.

Also:

- **Optional — outbound email (invites, alerts, password resets)**: an **opaque** secret in your org whose payload is a full email URL, e.g. `smtp://user:password@smtp.example.com:587`. Set its name in `email.secretName`. Create it BEFORE installing; leave empty to run without email.
- For optional database backups: a bucket and access setup for one of the supported providers (see [Backup storage setup](#backup-storage-setup)). With `provider: minio` (either database mode), the endpoint's keys are a prerequisite `dictionary` secret — see that section.

## Configuration

### GlitchTip

```yaml
image: glitchtip/glitchtip:6.2.2

replicas: 1 # web tier — stateless; set 2+ for high availability (state lives in PostgreSQL/Redis)

resources: # web workload
  minCpu: 250m
  minMemory: 512Mi
  maxCpu: 1000m
  maxMemory: 1Gi

worker:
  resources:
    minCpu: 250m
    minMemory: 512Mi
    maxCpu: 1000m
    maxMemory: 1Gi
  concurrency: 20 # async tasks processed in parallel (VTASKS_CONCURRENCY)

auth:
  secretName: my-glitchtip-auth # PREREQUISITE dictionary secret — must exist BEFORE install

registration:
  enabled: false # open self-signup on the endpoint; admin-created users and invites work regardless

email:
  secretName: "" # name of a pre-created opaque secret whose payload is an EMAIL_URL, e.g. smtp://user:pass@smtp.example.com:587 (create BEFORE install; empty = outbound email off)
  fromAddress: glitchtip@example.com # DEFAULT_FROM_EMAIL — used only when secretName is set
```

### Access

```yaml
domain: "" # full URL used in DSNs and email links (e.g. https://errors.example.com); empty = canonical *.cpln.app endpoint
publicAccess:
  enabled: true # UI + SDK event ingest (DSN) on the canonical *.cpln.app HTTPS endpoint

internalAccess: # internal firewall scope (in-GVC SDK callers)
  type: same-gvc # options: none, same-gvc, same-org, workload-list
  workloads: [] # used with workload-list
```

Public access is **on** by default: SDK event ingest is the point of the service, and browser SDKs and apps outside the GVC must reach the endpoint to report anything. The admin login is a credential you created, not a published default, and self-signup is closed. Set `publicAccess.enabled: false` to restrict GlitchTip to in-GVC reporters; reach the UI with `cpln port-forward {release}-glitchtip 8000:8000 --gvc {gvc}`. A firewall change takes 30 s to a few minutes to propagate, so re-test rather than trusting the first response.

### Redis

```yaml
redis:
  enabled: true # false = PostgreSQL carries the task queue, cache, and sessions (lighter dev shape)
  redis:
    replicas: 2
    auth:
      fromSecret:
        enabled: true # required when redis is enabled (the chart enforces this)
        name: my-glitchtip-redis # PREREQUISITE dictionary secret (key: password) — must exist BEFORE install
    persistence:
      enabled: true
  sentinel:
    replicas: 3 # sentinel auth must stay disabled — GlitchTip cannot send a sentinel password
    persistence:
      enabled: true
```

### PostgreSQL

Exactly one of the two databases must be enabled (the chart enforces this at render).

```yaml
postgresHA: # default: highly available PostgreSQL
  enabled: true
  image: controlplanecorporation/patroni-postgres:0.8   # pgvector 0.8.7; tags 0.1-0.7 are refused (CVE-2026-103484)
  config:
    credentialsSecretName: my-glitchtip-db-credentials # PREREQUISITE dictionary secret (username, password, database) — must exist BEFORE install
  replicas: 3
  volumeset:
    capacity: 10 # initial capacity in GiB per replica (minimum is 10)
  backup:
    enabled: false # optional — see Backup storage setup
```

```yaml
postgresHA:
  enabled: false
postgres: # dev/lightweight: single-instance PostgreSQL
  enabled: true
  config:
    credentialsSecretName: my-glitchtip-db-credentials # PREREQUISITE dictionary secret (username, password, database) — must exist BEFORE install
  volumeset:
    capacity: 10 # initial capacity in GiB (minimum is 10)
  backup:
    enabled: false # optional — see Backup storage setup
```

## Connecting

| What | Value |
|---|---|
| UI (public) | the canonical endpoint — read `status.canonicalEndpoint` from `cpln workload get {release}-glitchtip --gvc {gvc} -o yaml` |
| Local access (public access off) | `cpln port-forward {release}-glitchtip 8000:8000 --gvc {gvc}` then open `http://localhost:8000` |
| SDK DSN | Copy from the UI: project → Settings → DSN (embeds the public endpoint) |
| Internal (same GVC) | `http://{release}-glitchtip.{gvc}.cpln.local:8000` |
| Login | the `adminEmail` / `adminPassword` keys of your `auth.secretName` secret |
| Django admin (user management) | `/admin/` on the canonical endpoint |
| Postgres (internal, HA mode) | `{release}-postgres-ha-proxy.{gvc}.cpln.local:5432`, credentials from your `postgresHA.config.credentialsSecretName` secret (`cpln secret reveal SECRET_NAME -o yaml`) |
| Postgres (internal, single mode) | `{release}-postgres.{gvc}.cpln.local:5432`, credentials from your `postgres.config.credentialsSecretName` secret |

## Upgrading from 1.4.0 or earlier

1.4.1 moves the HA database (`postgresHA`) to `controlplanecorporation/patroni-postgres:0.8`, which carries
pgvector 0.8.7 (CVE-2026-103484). The fix is in the server library and takes effect when the upgrade restarts
the Patroni members; existing data needs nothing. Nothing limits that rollout, so expect a
brief interruption of writes while the leader changes. GlitchTip itself restarts without a gap: the new replica serves before the old one stops. Upgrade in a quiet window. If you pinned
`postgresHA.image` in your values, set it to the `0.8` tag: tags `0.1` to `0.7` are refused at render. GlitchTip itself does not need pgvector. If you created the `vector` extension in a database yourself, `\dx` keeps reporting the old version there until you run `ALTER EXTENSION vector UPDATE;`, which only updates that record.
Single-instance mode (`postgres`) is unchanged.

## Upgrading from 1.3.1

`postgres.credentials` was removed: the database credentials are now a prerequisite secret, the same one the database templates require on their own. Carrying the old key forward fails the render. This applies to 1.3.0 as well.

1.3.x created the database secret itself, so **this upgrade deletes it**. Before upgrading, create a secret under a **new** name holding the values your database was initialized with — not new ones, or GlitchTip loses its database connection:

```bash
cpln secret create-dictionary --name RELEASE_NAME-glitchtip-db \
  --entry username=glitchtip --entry password='YOUR_CURRENT_PASSWORD' --entry database=glitchtip
```

Then upgrade with `postgresHA.config.credentialsSecretName` (HA mode) or `postgres.config.credentialsSecretName` (single-instance mode) set to that name, and `postgres.credentials` removed. Your current values are in `postgres.credentials` of the 1.3.x release, and also in the old secret (`cpln secret reveal SECRET_NAME -o yaml`, the name in `credentialsSecretName`, `my-glitchtip-db-credentials` by default) until the upgrade deletes it.

`redis.redis.auth.password` was removed the same way (Redis enabled only): the Redis password is now a prerequisite secret too, and this upgrade deletes the `RELEASE_NAME-redis-auth-password` secret 1.3.x had the redis chart create. Create one under a **new** name holding your **current** Redis password — a new one would leave the Sentinels, which keep the password they started with on their volume, unable to reach Redis:

```bash
cpln secret create-dictionary --name RELEASE_NAME-glitchtip-redis --entry password='YOUR_CURRENT_REDIS_PASSWORD'
```

Your current password is `redis.redis.auth.password.value` of the 1.3.x release, and also in `cpln secret reveal RELEASE_NAME-redis-auth-password -o yaml` until the upgrade deletes it. Upgrade with `redis.redis.auth.fromSecret.name` set to the new name and the whole `redis.redis.auth.password` block removed.

The upgrade restarts the bundled PostgreSQL and Redis too (they now read the new secrets), so GlitchTip can briefly lose its database and task queue; it reconnects by itself. The new version of a workload can also wait about 10 minutes with `is not allowed to reveal the secret` in `get-deployments`, while access to the new secret propagates; the previous version keeps serving meanwhile, and it clears by itself.

## Upgrading from 1.2.x (HA mode)

1.3.0 moved the HA database to `postgres-highly-available` 2.5.0, which no longer takes credentials as values. Put the values of `postgresHA.postgres.username/password/database` **unchanged** into the database credentials secret under Prerequisites, set `postgresHA.config.credentialsSecretName` to its name, and delete the `postgresHA.postgres` block. Carrying the old block fails the render with `the postgres block was REMOVED in 2.5.0`.

With `postgresHA.backup.provider: minio`, `postgresHA.backup.minio.accessKey`/`secretKey` are refused by the same subchart — put them in a `dictionary` secret and set `postgresHA.backup.minio.credentialsSecretName` to its name (see [Backup storage setup](#backup-storage-setup)). For single-instance mode, follow [Upgrading from 1.3.1](#upgrading-from-131).

## Upgrading from 1.1.0

`postgres.config.username/password/database` were removed (postgres 3.4.0). Put the values your single-instance database was initialized with into the database credentials secret under Prerequisites (keys `username`, `password`, `database`), set `postgres.config.credentialsSecretName` to its name, and remove the three keys. Carrying them fails the render with `config.username was REMOVED in postgres 3.4.0`. `postgres.backup.minio.accessKey`/`secretKey` were removed the same way (see [Backup storage setup](#backup-storage-setup)). For HA mode, follow the 1.2.x section above.

## Upgrading from 1.0.x

Two changes, both clean breaks with no compatibility fallbacks — carrying an old key forward fails the render with a message naming its replacement.

| Removed key | Replacement |
|---|---|
| `django.secretKey` | `secretKey` in the prerequisite auth secret |
| `admin.email` / `admin.password` | `adminEmail` / `adminPassword` in the same secret |
| `resources.cpu` / `resources.memory` | `resources.maxCpu` / `resources.maxMemory` |
| `worker.resources.cpu` / `.memory` | `worker.resources.maxCpu` / `.maxMemory` |

**Put your EXISTING `secretKey` into the secret — do not generate a new one.** It signs live sessions and tokens; a new value logs every user out and invalidates password-reset links in flight.

If your install is still carrying the published 1.0.x default (`change-me-glitchtip-secret-key`), its sessions and tokens are signed with a value printed in a public repository. Rotating it is the fix, and the cost is that everyone has to log in again — so plan the upgrade for a quiet window rather than skipping it. Change the admin password in the UI at the same time.

## Backup storage setup

Only needed when backups are enabled (`postgresHA.backup.enabled` or `postgres.backup.enabled`). Complete the steps for your provider before installing.

### AWS S3

1. Create your S3 bucket. Set `backup.aws.bucket` and `backup.aws.region`.
2. If you do not have one, create a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account) for your AWS account. Set `backup.aws.cloudAccountName`.
3. Create an AWS IAM policy with the JSON below (replace `YOUR_BUCKET`), then set `backup.aws.policyName` to the policy's name:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:ListBucket", "s3:GetBucketLocation", "s3:GetObject", "s3:GetObjectVersion",
               "s3:PutObject", "s3:DeleteObject", "s3:DeleteObjectVersion", "s3:AbortMultipartUpload"],
    "Resource": ["arn:aws:s3:::YOUR_BUCKET", "arn:aws:s3:::YOUR_BUCKET/*"]
  }]
}
```

### Google Cloud Storage

1. Create your GCS bucket. Set `backup.gcp.bucket`.
2. If you do not have one, create a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account) for your GCP project. Set `backup.gcp.cloudAccountName` — access is keyless (no stored credentials).
3. Grant the **Storage Admin** role (`roles/storage.objectAdmin` scoped to the bucket also works) to the GCP service account created for the cloud account.

### S3-compatible (MinIO, R2, Wasabi, …)

1. Create your bucket on the server. Set `backup.minio.bucket`.
2. Set `backup.minio.endpoint` to the S3 API address including port. For the `minio` marketplace template in the same GVC, this is `http://WORKLOAD_NAME.GVC_NAME.cpln.local:9000`.
3. Create a `dictionary` secret holding the bucket credentials, and set `credentialsSecretName` to its name on whichever store you use — `postgresHA.backup.minio.credentialsSecretName` or `postgres.backup.minio.credentialsSecretName`. Both take the same secret:

```bash
cpln secret create-dictionary --name my-glitchtip-minio-credentials \
  --entry accessKey=YOUR_ACCESS_KEY \
  --entry secretKey=YOUR_SECRET_KEY
```

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

Then force-redeploy `RELEASE_NAME-glitchtip-worker` and `RELEASE_NAME-glitchtip`, which keep the old password until they restart. The database itself drops connections for roughly 10–60 s at each switchover, but the app cannot open new connections from the `ALTER ROLE` until its own redeploy finishes (several minutes in all), so rotate in a quiet window. If a member stays `starting`, or `running` without `streaming` for several minutes, re-copy it from the leader. This copies the whole database, so it costs network traffic in proportion to its size:

```bash
pgx N curl -s -XPOST -d '{"force": true}' localhost:8008/reinitialize
```

## Rotating the Redis password

Redis keeps no password on disk, but the Sentinels do, so a new password is applied live in three places before anything restarts. Each Redis node first accepts both passwords, which keeps replication and every connected client working throughout. `rx` and `sx` run a command on one Redis node or Sentinel (`LOCATION` is your GVC's location; nodes and Sentinels are numbered from 0 up to `redis.redis.replicas` and `redis.sentinel.replicas` minus one):

```bash
rx() { cpln workload exec RELEASE_NAME-redis --gvc GVC_NAME --location LOCATION \
  --container redis --replica "RELEASE_NAME-redis-$1" -- "${@:2}"; }
sx() { cpln workload exec RELEASE_NAME-sentinel --gvc GVC_NAME --location LOCATION \
  --container sentinel --replica "RELEASE_NAME-sentinel-$1" -- "${@:2}"; }
# 1. On EVERY Redis node: accept the new password alongside the old one, and replicate with it
rx 0 redis-cli --no-auth-warning -a OLD_PASSWORD ACL SETUSER default ">NEW_PASSWORD"
rx 0 redis-cli --no-auth-warning -a OLD_PASSWORD CONFIG SET masterauth NEW_PASSWORD
# 2. On EVERY Sentinel
sx 0 redis-cli -p 26379 SENTINEL SET mymaster auth-pass NEW_PASSWORD
# 3. Put the new password in the secret and read it back
cpln secret edit SECRET_NAME
cpln secret reveal SECRET_NAME -o yaml
# 4. Restart GlitchTip, which keeps the old password until it restarts
cpln workload force-redeployment RELEASE_NAME-glitchtip --gvc GVC_NAME
cpln workload force-redeployment RELEASE_NAME-glitchtip-worker --gvc GVC_NAME
# 5. Once get-deployments shows a higher version, alone and ready, for both: retire the old password on EVERY Redis node
rx 0 redis-cli --no-auth-warning -a NEW_PASSWORD ACL SETUSER default "<OLD_PASSWORD"
```

GlitchTip is briefly unavailable while it restarts. Redis and Sentinel need no restart: when they next start they read the new password from the secret.

## Important Notes

- **The default HA stack takes about six and a half minutes to converge**, and the worker crash-loops with `Connection reset by peer` for the first several minutes while Patroni elects a database leader. This is expected and self-correcting — do not treat it as a failed install.
- **Create the prerequisite secrets before installing** (auth, database credentials and, with Redis enabled, the Redis password). A missing prerequisite secret leaves the workloads waiting on something that does not exist, with zero log lines — see Prerequisites for how to diagnose it.
- **Never rotate `secretKey` on a live install unless you intend to** — it logs every user out and invalidates password-reset links in flight. Nothing is corrupted, but everyone has to sign in again.
- **Changing the Redis password takes more than a secret edit** — the Sentinels keep the old one; follow [Rotating the Redis password](#rotating-the-redis-password).
- **Changing the database password is a database change first.** Editing the secret alone does nothing to the database, and a running workload keeps the values it started with. Run `ALTER ROLE <username> PASSWORD '...'` in PostgreSQL, then `cpln secret edit SECRET_NAME`, then right away force-redeploy `RELEASE_NAME-glitchtip` and `RELEASE_NAME-glitchtip-worker` (in HA mode follow [Rotating the database password in HA mode](#rotating-the-database-password-in-ha-mode) instead). Do not redeploy the database: PostgreSQL reads the secret only when it is first initialized, so restarting it only adds downtime.
- **With registration closed (default), invites only work for accounts that already exist** — create teammate accounts first at `/admin/` (Django admin, superuser login), then invite them to the organization. Invite and alert emails require `email.secretName`.
- **Do not scale the worker** — it is a fixed singleton (scheduler + boot-time migrations). Web `replicas` is the scaling knob; a worker outage pauses processing but ingest keeps accepting and catches up.
- **First boot: the web tier stays not-ready until the worker finishes migrations** (several minutes in HA mode) — check worker logs first if it seems stuck.
- **The first `helm upgrade` after an install re-applies the bundled database and Redis**, so expect GlitchTip to be briefly unreachable while they restart; later upgrades do not do this.
- **DSNs embed the endpoint URL** — if you add a custom domain later, set `domain`, upgrade, and update the DSNs in your apps.
- **Source-map/artifact uploads are ephemeral** (local disk) — lost on restart and not shared across web replicas; error ingest itself is unaffected.
- **Uninstall deletes the database volumesets** — all issues, events, and users. Enable backups if the data matters.
- **Rotating the database password in HA mode needs a leader switchover first** — follow [Rotating the database password in HA mode](#rotating-the-database-password-in-ha-mode). A plain redeploy can promote a member still holding the old password and split the cluster.

## Links

- [GlitchTip documentation](https://glitchtip.com/documentation)
- [Installation and configuration reference](https://glitchtip.com/documentation/install)
- [Sentry SDKs (client setup)](https://docs.sentry.io/platforms/)
- [GlitchTip 6 release notes](https://glitchtip.com/blog/2026-02-03-glitchtip-6-released/)
- [GlitchTip backend source](https://gitlab.com/glitchtip/glitchtip-backend)
