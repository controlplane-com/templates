# Plane

[Plane](https://plane.so) is an open-source project and issue tracker — work items, cycles,
modules, roadmaps and wiki-style pages with a real-time collaborative editor. This template
deploys **Plane Community Edition 1.4.2** (AGPL-3.0) with everything it needs: PostgreSQL,
Redis, RabbitMQ and object storage.

## Architecture

- **`{release}-plane`** — one workload, six containers on a shared network namespace: `proxy`
  (Caddy, the only exposed port), `web`, `space`, `admin` (God Mode), `live` (collaborative
  editor) and `api` (Django). Plane's frontends are built with *relative* URLs, so all six
  must answer on one origin — this is a requirement, not an optimisation.
- **`{release}-plane-worker`** — Celery worker: notifications, activity feeds, exports,
  imports, invites.
- **`{release}-plane-beat`** — Celery scheduler, always exactly one replica. **Also runs the
  database migrations.**
- **`{release}-plane-redis`** — Valkey + volumeset. Django's cache and the live editor's
  cross-replica channel.
- **`{release}-plane-mq`** — RabbitMQ + volumeset. The Celery broker.
- **`{release}-plane-minio`** — bundled single-node object storage + volumeset. *Omitted
  entirely when `storage.type: s3`.*
- **`{release}-postgres`** — the `postgres` template as a subchart, pinned to PostgreSQL 16.
- **identity + two policies** — `reveal` on this release's secrets, and `view` on **this one
  GVC**, which the scheduler reads at boot to reconcile its location against the GVC's (it
  reports any GVC locations this release does not use, and warns if the GVC is reshaped under
  a running release).

A default install is **7 workloads, ~1.05 vCPU and ~3.2 GiB reserved**. Plane genuinely needs
a database, a cache, a broker, an object store and six HTTP services; this is the smallest
shape the platform allows.

## Prerequisites

- **A `dictionary` secret holding `SECRET_KEY` and `LIVE_SERVER_SECRET_KEY`, created BEFORE
  you install.** See below.
- The GVC you install into must already have the location named by `location`.
- For `storage.type: s3` only: an S3 bucket plus either a Control Plane
  [cloud account](https://docs.controlplane.com/guides/create-cloud-account) (AWS, keyless) or
  a static-key secret (S3-compatible servers). See **Storage setup**.

Create the required secret first — the deployment wedges silently without it:

```bash
cpln secret create-dictionary --name my-plane-secrets \
  --entry SECRET_KEY="$(openssl rand -hex 32)" \
  --entry LIVE_SERVER_SECRET_KEY="$(openssl rand -hex 32)"
```

`SECRET_KEY` signs sessions **and encrypts your instance configuration** (SMTP password, OAuth
client secrets), so treat it as write-once — rotating it makes those unreadable and logs
everyone out. `LIVE_SERVER_SECRET_KEY` is required by the live editor, which refuses to start
without one.

## First run

Plane has **no admin bootstrap credential**: whoever opens `/god-mode` first becomes the
instance administrator. The template therefore ships closed to the internet, and you claim the
instance over a tunnel before exposing anything.

```bash
# 1. Install with the defaults (publicAccess.enabled: false).
# 2. Wait for the workload to report ready, then tunnel to it:
cpln port-forward RELEASE-plane 8080:80 --gvc GVC_NAME

# 3. Open http://localhost:8080/god-mode/ and create the instance admin,
#    then http://localhost:8080/ to create your first workspace.
# 4. Only then, if you want it public, upgrade with publicAccess.enabled=true.
```

A firewall change takes **30 s to ~10 minutes** to propagate — re-poll rather than concluding
the knob is broken.

## Configuration

### Location

```yaml
# The ONE location of your GVC that Plane runs in. It MUST already be a location
# of that GVC — nothing validates this and nothing fails; see Important Notes for
# what a wrong value looks like. Every workload this chart OWNS is pinned here —
# the bundled `postgres` subchart is NOT, so an extra GVC location starts a second
# Postgres there with its own empty volume. Prefer a single-location GVC.
location: aws-us-east-1
```

### Plane

```yaml
plane:
  imageTag: v1.4.2       # ONE tag for all six Plane images — never mix versions
  replicas: 1            # whole HTTP tier; >=2 gives a rolling restart with no downtime
  appUrl: ""             # empty = derive from the platform canonical endpoint; set WITH https:// for a custom domain
  fileSizeLimit: 5242880 # max upload in bytes (5 MiB); enforced by the proxy and the object store, not the API
  api:
    gunicornWorkers: 1   # each extra worker is ~1 CPU and ~300Mi
  resources:
    proxy:               # Caddy — the single public entry point
      minCpu: 50m
      maxCpu: 200m
      minMemory: 64Mi
      maxMemory: 256Mi
    ui:                  # applied to EACH of web, space and admin
      minCpu: 50m
      maxCpu: 250m
      minMemory: 96Mi
      maxMemory: 384Mi
    live:                # collaborative-editing server
      minCpu: 100m
      maxCpu: 500m
      minMemory: 192Mi
      maxMemory: 512Mi
    api:                 # Django + gunicorn — the heavy tier
      minCpu: 250m
      maxCpu: 1000m
      minMemory: 512Mi
      maxMemory: 1536Mi
```

### Background processing

```yaml
worker:
  replicas: 1            # Celery workers; scale up for heavy imports/exports
  concurrency: 4         # prefork children PER replica — pinned, see below
  resources:
    minCpu: 200m
    maxCpu: 1000m
    minMemory: 384Mi
    maxMemory: 2Gi       # sized for `concurrency` children plus the parent

# The scheduler is ALWAYS one replica (two would run every periodic task twice),
# so there is no replicas knob. It also applies the database migrations.
beat:
  resources:
    minCpu: 50m
    maxCpu: 250m
    minMemory: 192Mi
    maxMemory: 512Mi
```

`worker.concurrency` is pinned rather than left to Celery, and it is not the same knob as
`worker.replicas`. Celery's own default is inferred from the **host's** CPU count rather than
this container's `cpu` limit, so an unpinned worker forks 16 Django children into whatever
memory limit you set and is OOM-killed on any reasonable one. `worker.replicas` does not help:
replicas multiply pools, they do not narrow one. Raise `concurrency` for more parallelism
within a replica and `maxMemory` with it (measured ~150Mi per child at idle, before task payloads);
raise `replicas` for more throughput and fault tolerance.

### Prerequisite secret

```yaml
secrets:
  name: my-plane-secrets   # dictionary secret with SECRET_KEY + LIVE_SERVER_SECRET_KEY — MUST exist before install
```

### Storage

```yaml
storage:
  type: minio             # minio | s3
  minio:                  # bundled single-node MinIO (default)
    image: minio/minio:RELEASE.2025-09-07T16-13-09Z
    credentials:          # internal plumbing; never typed into a client
      accessKey: change-me-plane-minio-access
      secretKey: change-me-plane-minio-secret
    bucket: uploads
    resources:
      cpu: 500m
      memory: 512Mi
    volumeset:
      capacity: 10        # GiB (minimum 10); mounted at /export
  s3:                     # external S3 or S3-compatible (set storage.type: s3)
    bucket: my-plane-bucket
    region: us-east-1
    endpoint: ""          # set for S3-compatible servers, e.g. http://my-minio.GVC.cpln.local:9000
    cloudAccountName: my-s3-cloud-account   # keyless AWS auth (preferred)
    policyName: my-plane-s3-policy          # your bucket-scoped IAM policy (JSON below)
    auth:
      secretName: ""      # OPTIONAL dictionary secret with AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY — S3-compatible servers ONLY
```

### PostgreSQL (subchart)

```yaml
postgres:
  image: postgres:16      # Plane supports PostgreSQL 15.7+ / 16.x only
  credentials:
    username: plane
    password: change-me-plane-db   # template-managed cred for the bundled DB
    database: plane
  config:
    credentialsSecretName: my-plane-db-credentials   # this chart CREATES it; give each release its own name
  resources:
    minCpu: 250m
    maxCpu: 1000m
    minMemory: 512Mi
    maxMemory: 1Gi
  volumeset:
    capacity: 10          # GiB (minimum 10)
```

### Redis and RabbitMQ

```yaml
redis:                    # REQUIRED — the live editor refuses to start without it
  image: valkey/valkey:8.1.9
  password: change-me-plane-redis   # template-managed; wired into REDIS_URL
  resources:
    cpu: 250m
    memory: 512Mi
  volumeset:
    capacity: 10          # GiB (minimum 10); AOF at /data

rabbitmq:                 # REQUIRED — Plane runs Celery over AMQP, not Redis
  image: rabbitmq:3.13.6-management-alpine
  username: plane
  password: change-me-plane-mq      # template-managed; wired into AMQP_URL
  vhost: plane
  resources:
    cpu: 500m
    memory: 768Mi
  volumeset:
    capacity: 10          # GiB (minimum 10); mnesia at /var/lib/rabbitmq
```

Keep these three bundled passwords URL-safe (letters, digits, `-`, `_`, `.`): they are
interpolated into connection URLs, so `@`, `:`, `/`, `?` and `#` would break them.

### Access

```yaml
publicAccess:
  enabled: false          # ships CLOSED — see "First run" above

internalAccess:
  type: same-gvc          # options: same-gvc, same-org, workload-list
  workloads: []           # only with workload-list, e.g. - //gvc/GVC_NAME/workload/WORKLOAD_NAME
```

Every workload this release creates is **always** allowed to reach the others, whatever
`internalAccess` is set to.

## Connecting

| What | Where | Credentials |
|---|---|---|
| Plane UI | `https://{release}-plane-{suffix}.cpln.app` when `publicAccess.enabled: true`; read the exact value from `status.canonicalEndpoint` | The account you create at `/god-mode/` and in the app |
| God Mode (instance admin) | `{public URL}/god-mode/`, or `http://localhost:8080/god-mode/` over a port-forward | First visitor claims it — see **First run** |
| Published views / pages | `{public URL}/spaces/` | Public by design when you press Publish |
| REST API | `{public URL}/api/` | Personal API token, created in the UI under workspace settings |
| PostgreSQL (internal) | `{release}-postgres.{gvc}.cpln.local:5432` | `postgres.credentials` |
| Redis (internal) | `{release}-plane-redis.{gvc}.cpln.local:6379` | `redis.password` |
| RabbitMQ (internal) | `{release}-plane-mq.{gvc}.cpln.local:5672`; management UI on `:15672` via port-forward | `rabbitmq.username` / `.password` |
| MinIO (internal) | `{release}-plane-minio.{gvc}.cpln.local:9000` | `storage.minio.credentials` |

## Storage setup

Only needed for `storage.type: s3`. The bundled MinIO default needs nothing.

**Whichever provider you use, the browser talks to your bucket directly**, so the bucket needs
a CORS policy allowing your Plane origin — without it attachments fail to load with a CORS
error in the browser console:

```json
[
  {
    "AllowedHeaders": ["*"],
    "AllowedMethods": ["GET", "PUT", "POST", "HEAD"],
    "AllowedOrigins": ["https://YOUR-PLANE-URL"],
    "ExposeHeaders": ["ETag"],
    "MaxAgeSeconds": 3000
  }
]
```

### AWS S3 (keyless — preferred)

1. Create the bucket in your target region.
2. Apply the CORS policy above (S3 console → the bucket → Permissions → CORS).
3. Create an IAM policy scoped to that bucket — replace `YOUR-BUCKET`:

   ```json
   {
     "Version": "2012-10-17",
     "Statement": [
       {
         "Sid": "PlaneBucketObjects",
         "Effect": "Allow",
         "Action": [
           "s3:GetObject",
           "s3:PutObject",
           "s3:DeleteObject",
           "s3:AbortMultipartUpload",
           "s3:ListMultipartUploadParts"
         ],
         "Resource": "arn:aws:s3:::YOUR-BUCKET/*"
       },
       {
         "Sid": "PlaneBucketList",
         "Effect": "Allow",
         "Action": [
           "s3:ListBucket",
           "s3:GetBucketLocation",
           "s3:ListBucketMultipartUploads"
         ],
         "Resource": "arn:aws:s3:::YOUR-BUCKET"
       }
     ]
   }
   ```

4. Create a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account)
   for AWS.
5. Set `storage.type: s3`, `storage.s3.bucket`, `storage.s3.region`,
   `storage.s3.cloudAccountName` and `storage.s3.policyName` (the IAM policy's **name**).
   Leave `storage.s3.auth.secretName` empty — no keys are stored anywhere.

### Google Cloud Storage

GCS's S3-compatible ("interoperability") endpoint is what Plane can use; Plane supports
S3-compatible storage only.

1. Create the bucket, and apply the CORS policy above with `gcloud storage buckets update`.
2. Create a service account and grant it **`roles/storage.objectAdmin`** on that bucket only
   (Cloud Console → the bucket → Permissions → Grant access).
3. Create an HMAC key for that service account (Cloud Storage → Settings → Interoperability).
4. Store the HMAC key as a dictionary secret and use the S3-compatible path below, setting
   `storage.s3.endpoint` to the interoperability endpoint — `storage.googleapis.com` with an
   `https://` scheme. See
   [Cloud Storage interoperability](https://cloud.google.com/storage/docs/interoperability).

### S3-compatible servers (MinIO, SeaweedFS, GCS interoperability, …)

1. Create the bucket on your server and apply the CORS policy above.
2. Store the credentials as a dictionary secret:

   ```bash
   cpln secret create-dictionary --name my-plane-s3-keys \
     --entry AWS_ACCESS_KEY_ID=YOUR_ACCESS_KEY \
     --entry AWS_SECRET_ACCESS_KEY=YOUR_SECRET_KEY
   ```

3. Set `storage.type: s3`, `storage.s3.bucket`, `storage.s3.endpoint` (the full URL, e.g.
   `http://my-minio.GVC_NAME.cpln.local:9000`) and
   `storage.s3.auth.secretName: my-plane-s3-keys`.

Static keys are rejected without an endpoint — AWS S3 is always keyless.

## Restricting internal access

`internalAccess.type: workload-list` with an empty `workloads` list restricts Plane to **this
release only**; the chart always adds its own workloads, so it cannot lock itself out.

The bundled PostgreSQL is a **subchart with its own setting** that this chart cannot template.
To tighten it too, set `postgres.internalAccess.type: workload-list` and list the Plane
workloads by hand (substitute `RELEASE` and `GVC_NAME`):

```yaml
postgres:
  internalAccess:
    type: workload-list
    workloads:
      - //gvc/GVC_NAME/workload/RELEASE-plane
      - //gvc/GVC_NAME/workload/RELEASE-plane-worker
      - //gvc/GVC_NAME/workload/RELEASE-plane-beat
```

## Backing up the database

The `postgres` template's scheduled-backup feature needs PostgreSQL 17 or newer, and Plane
supports 15.7/16.x only — so it is **not usable here** and this chart does not surface it.
Take dumps with `pg_dump`, which ships in the `postgres:16` image. **Dump to a file inside
the container and move it out base64-encoded** — `cpln workload exec` decodes the container's
stdout as UTF-8 and replaces every invalid byte with U+FFFD, which silently corrupts a `-Fc`
archive (a 661,277-byte dump arrived as 692,603 bytes, and `pg_restore -l` segfaulted on it).
Base64 is ASCII, so it survives intact.

```bash
# ── Back up ───────────────────────────────────────────────────────────────────
# 1. Dump inside the container.
cpln workload exec RELEASE-postgres --gvc GVC_NAME --container postgresql -- \
  sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc -f /tmp/plane.dump'

# 2. Stream it out base64-encoded and decode it locally.
cpln workload exec RELEASE-postgres --gvc GVC_NAME --container postgresql --quiet -- \
  sh -c 'base64 -w0 /tmp/plane.dump' | tr -d '\r\n' | base64 -d > plane.dump

# 3. Check the archive before you rely on it — this lists its contents.
#    Your LOCAL pg_restore must be at least as new as the server (16), or it
#    fails with "unsupported version (1.15) in file header". If yours is older,
#    list it in the container instead, which always has a matching client:
cpln workload exec RELEASE-postgres --gvc GVC_NAME --container postgresql -- \
  pg_restore -l /tmp/plane.dump | head

cpln workload exec RELEASE-postgres --gvc GVC_NAME --container postgresql -- rm -f /tmp/plane.dump
```

```bash
# ── Restore ───────────────────────────────────────────────────────────────────
# 1. Copy the dump back in. --stdin is REQUIRED: it defaults to false, and
#    without it your input is discarded silently and the file arrives 0 bytes.
cpln workload exec RELEASE-postgres --gvc GVC_NAME --container postgresql --stdin -- \
  sh -c 'cat > /tmp/plane.dump' < plane.dump

# 2. Restore from the file inside the container.
cpln workload exec RELEASE-postgres --gvc GVC_NAME --container postgresql -- \
  sh -c 'PGPASSWORD="$POSTGRES_PASSWORD" pg_restore -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists /tmp/plane.dump'

cpln workload exec RELEASE-postgres --gvc GVC_NAME --container postgresql -- rm -f /tmp/plane.dump

# 3. Redeploy the backend workloads so they reconnect against the restored data.
cpln workload force-redeployment RELEASE-plane --gvc GVC_NAME
cpln workload force-redeployment RELEASE-plane-worker --gvc GVC_NAME
cpln workload force-redeployment RELEASE-plane-beat --gvc GVC_NAME
```

Both directions were run end to end, verbatim, against a live release: a table was dropped
after the dump and came back with its rows intact after the restore.

Plane keeps serving during a restore, and there is no supported way to stop it first
(`worker.replicas: 0` is refused at render, and the scheduler has no replicas knob). Expect
errors in the api and worker logs while `--clean --if-exists` drops and recreates objects;
the forced redeployments above clear them.

Attachments live in the object store, not the database — back up the bucket separately (or
snapshot the MinIO volumeset).

## Important Notes

- **Create the prerequisite secret before installing.** Without it the deployment wedges
  *silently*: `cpln logs` returns zero lines. The only diagnostic is
  `cpln workload get-deployments RELEASE-plane --gvc GVC_NAME -o yaml`, under
  `status.versions[].message`. Recovery takes ~6-10 minutes once the secret exists, or force a
  redeployment to skip the wait.
- **A `location` your GVC does not have makes the release run nothing, anywhere — and
  nothing reports an error.** The platform accepts the value, Helm prints success, and every
  Plane workload then sits at `ready: false` with the message *"This workload location is
  deactivated because maxScale is set to 0."* while `cpln logs` returns **zero lines** for all
  of them. (The bundled PostgreSQL is not location-pinned, so it starts normally and looks
  healthy, which makes the install look half-working rather than misconfigured.) That message
  is the diagnostic — read it under `status.versions[].message` with
  `get-deployments`. No boot-time check can catch this: the scheduler that would run one is
  pinned to the same missing location, so it never starts.
- **Whoever opens `/god-mode` first becomes the instance administrator.** Claim it over a
  port-forward before turning `publicAccess` on — see **First run**.
- **The first `helm upgrade` after an install may re-apply the bundled datastores** — and the
  upgrade that turns public access on, in **First run**, is exactly that upgrade for most
  installs. Postgres, Redis, RabbitMQ and MinIO are single-replica, so expect Plane to be
  briefly unreachable (a couple of minutes) while one of them restarts. Later upgrades do not
  do this.
- **`plane.appUrl` must include the scheme** (`https://your.domain`) — the chart refuses to
  render without one. It is trusted for CORS *and* CSRF (Plane sets `CSRF_TRUSTED_ORIGINS` to
  the same list), and Django rejects a scheme-less trusted origin, so a bare hostname makes
  every POST fail. It also decides whether attachment URLs are signed for https, and it is the
  base URL in invite and notification mail.
- **"Waiting for migrations" forever means the `beat` workload is not running.** Migrations
  run only there; the api and worker block on them with no timeout and no other error.
- **Rotating a secret does not redeploy anything.** `cpln://` references resolve once, at
  replica start. After changing `SECRET_KEY` or any password, run
  `cpln workload force-redeployment` or the old value keeps working indefinitely.
- **`rabbitmq.username` / `.password` apply on first boot only.** They seed an empty broker;
  changing them on an existing release does not change the broker's credentials.
- **Plane sends usage telemetry to `telemetry.plane.so` by default.** There is no environment
  variable for it — turn it off in God Mode under Instance settings.
- **Silo (GitHub/GitLab/Slack integrations), Intake (email-to-work-item) and Monitor are not
  in the Community Edition** and are not part of this template.

## Links

- [Plane self-hosting documentation](https://developers.plane.so/self-hosting/overview)
- [Plane architecture](https://developers.plane.so/self-hosting/plane-architecture)
- [External database and storage](https://developers.plane.so/self-hosting/govern/database-and-storage)
- [Plane REST API reference](https://developers.plane.so/api-reference/introduction)
- [Plane on GitHub](https://github.com/makeplane/plane)
