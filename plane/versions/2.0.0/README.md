# Plane

[Plane](https://plane.so) is an open-source project tracker: work items, cycles, modules, roadmaps and wiki pages with a real-time collaborative editor. This template deploys **Plane Community Edition** (AGPL-3.0) with its PostgreSQL, Redis, RabbitMQ and object store. It installs **private**: you claim the instance over a port-forward, then publish.

## Architecture

- **`{release}-plane`**: one workload, six containers on one network namespace: `proxy` (Caddy, the only exposed port), `web`, `space`, `admin` (God Mode), `live` (collaborative editor) and `api` (Django). Plane's frontends call the API on their own origin, so all six sit behind the one proxy.
- **`{release}-plane-worker`**: Celery workers for notifications, activity, imports, exports and invites.
- **`{release}-plane-beat`**: the Celery scheduler, always one replica. It also applies the database migrations on every start; on a first install the API turns ready once they have run.
- **`{release}-plane-redis`**: Valkey on a volume set, the Django cache and the live editor's channel.
- **`{release}-plane-mq`**: RabbitMQ on a volume set, the Celery broker.
- **`{release}-plane-minio`**: a single-node object store on a volume set ([Silo](https://github.com/pgsty/silo), the maintained MinIO fork). Not created with `storage.type: s3`.
- **`{release}-postgres`**: the bundled `postgres` template, on PostgreSQL 19. A boot guard refuses to start the server on a data directory of another PostgreSQL major and leaves it untouched. Every other workload is pinned to the single `location`.
- **Identity and policies**: `reveal` on exactly the secrets this release reads, and `view` on the install GVC, which the scheduler reads at start to report GVC locations Plane does not use.

## Prerequisites

A GVC with **one location**, and these `dictionary` secrets created **before** you install. If one is missing, the deployment waits with no log lines; `cpln workload get-deployments {release}-plane --gvc {gvc} -o yaml` names it under `status.versions[].message`. The database, Redis and RabbitMQ values go into connection URLs, so keep them URL-safe (letters, digits, `-`, `_`, `.`).

```bash
# 1. Application keys (secrets.name)
cpln secret create-dictionary --name my-plane-secrets \
  --entry SECRET_KEY="$(openssl rand -hex 32)" --entry LIVE_SERVER_SECRET_KEY="$(openssl rand -hex 32)"
# 2. Database credentials (postgres.config.credentialsSecretName)
cpln secret create-dictionary --name my-plane-db-credentials \
  --entry username=plane --entry password="$(openssl rand -hex 24)" --entry database=plane
# 3. Redis password (redis.credentialsSecretName)
cpln secret create-dictionary --name my-plane-redis-credentials --entry password="$(openssl rand -hex 24)"
# 4. RabbitMQ login (rabbitmq.credentialsSecretName)
cpln secret create-dictionary --name my-plane-mq-credentials --entry username=plane --entry password="$(openssl rand -hex 24)"
# 5. Object store keys (storage.minio.credentialsSecretName), only with the default storage.type: minio
cpln secret create-dictionary --name my-plane-minio-credentials \
  --entry accessKey=plane --entry secretKey="$(openssl rand -hex 24)"
```

`SECRET_KEY` signs sessions and encrypts the instance settings Plane stores (SMTP password, OAuth secrets): replacing it signs everyone out and makes those unreadable. For `storage.type: s3`, see **Storage setup**.

## Configuration

### Location, Plane and background jobs

```yaml
location: aws-us-east-1   # the ONE location of your GVC that Plane runs in; it must already be a GVC location

plane:
  imageTag: v1.4.3        # one tag for all six Plane images
  replicas: 1             # the whole HTTP tier; 2+ keeps Plane up through a rolling restart
  appUrl: ""              # empty = canonical endpoint; a custom domain with its scheme, e.g. https://plane.example.com
  fileSizeLimit: 5242880  # max upload in bytes (5 MiB)
  api:
    gunicornWorkers: 1    # each needs ~1 more CPU and ~300Mi
  resources:
    proxy: { minCpu: 50m, maxCpu: 200m, minMemory: 64Mi, maxMemory: 256Mi }
    ui: { minCpu: 50m, maxCpu: 250m, minMemory: 96Mi, maxMemory: 384Mi }      # each of web, space and admin
    live: { minCpu: 100m, maxCpu: 500m, minMemory: 192Mi, maxMemory: 512Mi }
    api: { minCpu: 250m, maxCpu: 1000m, minMemory: 512Mi, maxMemory: 1536Mi }

secrets:
  name: my-plane-secrets  # application keys (Prerequisites 1)

worker:
  replicas: 1
  concurrency: 4          # Celery children per replica (Celery's default follows the host CPU count); raise maxMemory with it
  resources: { minCpu: 200m, maxCpu: 1000m, minMemory: 384Mi, maxMemory: 2Gi }
beat:                     # always one replica
  resources: { minCpu: 50m, maxCpu: 1000m, minMemory: 192Mi, maxMemory: 512Mi }   # migrations run on the CPU ceiling
```

### Storage and datastores

```yaml
storage:
  type: minio             # minio (bundled) | s3 (your bucket)
  minio:
    image: pgsty/silo:RELEASE.2026-10-18T00-00-00Z
    credentialsSecretName: my-plane-minio-credentials   # Prerequisites 5
    bucket: uploads
  s3:
    bucket: my-plane-bucket
    region: us-east-1
    endpoint: ""          # S3-compatible servers only; users' browsers must reach it, e.g. https://s3.example.com
    cloudAccountName: my-s3-cloud-account   # AWS keyless
    policyName: my-plane-s3-policy          # AWS keyless
    auth:
      secretName: ""      # S3-compatible only: dictionary with AWS_ACCESS_KEY_ID + AWS_SECRET_ACCESS_KEY

postgres:
  image: postgres:19      # a release upgraded from 1.x keeps postgres:16 (see Upgrading from 1.x)
  config:
    credentialsSecretName: my-plane-db-credentials   # Prerequisites 2
redis:
  image: valkey/valkey:8.1.11
  credentialsSecretName: my-plane-redis-credentials  # Prerequisites 3
rabbitmq:
  image: rabbitmq:4.3.7-management-alpine
  credentialsSecretName: my-plane-mq-credentials     # Prerequisites 4; read on first boot only
  vhost: plane
```

Each datastore and the object store also takes `resources` and `volumeset.capacity` (GiB, minimum 10).

### Access

```yaml
publicAccess:
  enabled: false          # claim /god-mode over port-forward first, then set true
internalAccess:
  type: same-gvc          # same-gvc | same-org | workload-list
  workloads: []           # workload-list only; this release's own workloads are always allowed
```

The bundled PostgreSQL has its own `postgres.internalAccess`. With `workload-list` there, list `//gvc/{gvc}/workload/{release}-plane`, `{release}-plane-worker` and `{release}-plane-beat`; the chart refuses a list without them.

## Connecting

Plane has no bootstrap credential: whoever completes `/god-mode` first becomes the instance admin. Claim it privately, then publish:

```bash
cpln port-forward {release}-plane 8080:80 --gvc {gvc}
# open http://localhost:8080/god-mode/ and create the admin, then http://localhost:8080/ for your workspace
cpln helm upgrade {release} oci://ghcr.io/controlplane-com/templates/plane --version 2.0.0 --gvc {gvc} \
  -f values.yaml --set publicAccess.enabled=true   # the public firewall can take a few minutes to open
```

| What | Where |
|---|---|
| Plane UI | `status.canonicalEndpoint` of `{release}-plane` (`cpln workload get {release}-plane --gvc {gvc} -o yaml`) |
| God Mode | `{plane-url}/god-mode/` |
| Published views | `{plane-url}/spaces/` |
| REST API | `{plane-url}/api/v1/`, with a personal API token from the UI's settings |
| Plane (internal, same GVC) | `http://{release}-plane.{gvc}.cpln.local:80` |
| PostgreSQL (internal) | `{release}-postgres.{gvc}.cpln.local:5432` |

### God Mode (instance administration)

Instance settings live in God Mode (`{plane-url}/god-mode/`, the admin claimed above), not in chart values, and are stored in the database:

- **Email** (God Mode → Email): SMTP host, port, sender and security, required for invites, notifications and sign-in codes. A relay in the same GVC is `{smtp-workload}.{gvc}.cpln.local`.
- **Authentication** (God Mode → Authentication): "Unique codes" (emailed sign-in codes, needs Email), password sign-in, "Allow anyone to sign up", and GitHub, Google or GitLab sign-in. Each provider's OAuth app needs the callback `{plane-url}/auth/{github|google|gitlab}/callback/`; changing `plane.appUrl` means registering it again.
- **General**: instance name, admins and telemetry.

Webhooks (workspace settings → Webhooks) must point at a public URL; internal and private addresses are refused. Plane generates each webhook's signing secret and signs the body in `x-plane-signature` (HMAC-SHA256). Exports appear as download links under workspace settings → Exports. Uploads larger than `plane.fileSizeLimit` are refused with HTTP 413.

## Storage setup

Only for `storage.type: s3`. Browsers upload to and download from the bucket directly, so it needs a CORS rule for your Plane origin:

```json
[{ "AllowedHeaders": ["*"], "AllowedMethods": ["GET", "PUT", "POST", "HEAD"],
   "AllowedOrigins": ["{plane-url}"], "ExposeHeaders": ["ETag"], "MaxAgeSeconds": 3000 }]
```

**AWS S3 (keyless).** Create the bucket and its CORS rule, create a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account) for AWS, and create this IAM policy (replace `{bucket}`). Set `storage.s3.bucket`, `region`, `cloudAccountName` and `policyName` (the IAM policy's name); leave `auth.secretName` empty.

```json
{ "Version": "2012-10-17", "Statement": [
  { "Sid": "PlaneBucketObjects", "Effect": "Allow", "Resource": "arn:aws:s3:::{bucket}/*",
    "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"] },
  { "Sid": "PlaneBucketList", "Effect": "Allow", "Resource": "arn:aws:s3:::{bucket}",
    "Action": ["s3:ListBucket", "s3:GetBucketLocation", "s3:ListBucketMultipartUploads"] } ] }
```

**S3-compatible servers** (MinIO, SeaweedFS, Google Cloud Storage [interoperability](https://cloud.google.com/storage/docs/interoperability) with an HMAC key). Create the bucket and its CORS rule, store the keys as `cpln secret create-dictionary --name my-plane-s3-keys --entry AWS_ACCESS_KEY_ID={access-key} --entry AWS_SECRET_ACCESS_KEY={secret-key}`, and set `storage.s3.bucket`, `storage.s3.endpoint` and `storage.s3.auth.secretName: my-plane-s3-keys`. Plane gives browsers presigned URLs built from `endpoint`, so it must be a full URL that users' browsers can reach, such as a public HTTPS endpoint; an internal `*.cpln.local` address serves the API but not browser uploads and downloads.

## Upgrading from 1.x

New installs run PostgreSQL 19, while a 1.x release's database is PostgreSQL 16 (or the major of the `postgres.image` it ran). A data directory only opens with its own major, and the chart never converts it in place: before PostgreSQL starts, a guard compares the two majors, and on a mismatch it does not start the server and changes nothing on the volume. `{release}-postgres` then stays not ready, the api and worker wait for the database, and the database logs repeat `[pg-guard] REFUSING TO START` with the exact `--set postgres.image=...` to run:

```bash
cpln logs '{gvc="GVC_NAME", workload="RELEASE_NAME-postgres"} |= "pg-guard"' --since 15m
```

**Stay on PostgreSQL 16:** run the upgrade with the image pinned, and keep `postgres.image: postgres:16` in your values file for every later upgrade (`cpln helm upgrade` does not reuse the installed values). The Console upgrade wizard keeps the installed image for you (Datastores, PostgreSQL image).

```bash
cpln helm upgrade RELEASE_NAME oci://ghcr.io/controlplane-com/templates/plane --version 2.0.0 --gvc GVC_NAME \
  -f my-values.yaml --set postgres.image=postgres:16
```

**Move to PostgreSQL 19, side by side** (Plane gets a new endpoint and is unavailable during the copy):

1. Install this version as a NEW release in the same GVC and `location`, with the **same** `secrets.name` (its `SECRET_KEY` decrypts the stored SMTP and OAuth settings), `postgres.config.credentialsSecretName` and storage settings (the same `storage.minio.credentialsSecretName` and `bucket`, or the same `storage.s3` bucket). Keep it private and do not open `/god-mode` on it. Wait until `NEW_RELEASE-plane` is ready (its scheduler migrates an empty database).
2. Stop every Plane workload of both releases, so nothing writes during the copy (the databases and object stores keep running):

   ```bash
   cpln workload stop OLD_RELEASE-plane OLD_RELEASE-plane-worker OLD_RELEASE-plane-beat --gvc GVC_NAME
   cpln workload stop NEW_RELEASE-plane NEW_RELEASE-plane-worker NEW_RELEASE-plane-beat --gvc GVC_NAME
   ```

3. Replace the new release's database with the old one, from inside the new database container. The PostgreSQL 19 `pg_dump` reads the old server, and `--clean --if-exists` first drops what the new Plane created:

   ```bash
   cpln workload exec NEW_RELEASE-postgres --gvc GVC_NAME --container postgresql -- bash -c \
     'PGPASSWORD="$POSTGRES_PASSWORD" pg_dump -h OLD_RELEASE-postgres.GVC_NAME.cpln.local -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists | psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -q'
   ```

4. With the bundled object store (`storage.type: minio`), copy the attachments into the new one (replace `uploads` if you changed `storage.minio.bucket`). With `storage.type: s3` both releases use the same bucket, so skip this step.

   ```bash
   cpln workload exec NEW_RELEASE-plane-minio --gvc GVC_NAME --container minio -- sh -c \
     'export MC_CONFIG_DIR=/tmp/mc; mc alias set old http://OLD_RELEASE-plane-minio.GVC_NAME.cpln.local:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" && mc alias set new http://127.0.0.1:9000 "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" && mc mirror --overwrite old/uploads new/uploads'
   ```

5. Start the new release's Plane workloads (`cpln workload start NEW_RELEASE-plane NEW_RELEASE-plane-worker NEW_RELEASE-plane-beat --gvc GVC_NAME`) and sign in with your existing account to check your workspaces, work items and attachments. Then set `publicAccess.enabled: true` on it, point your custom domain (`plane.appUrl`) at it or register the new endpoint's OAuth callbacks, and uninstall the old release.

With `postgres.internalAccess.type: workload-list` on the old release, add `//gvc/GVC_NAME/workload/NEW_RELEASE-postgres` to its list before step 3.

## Important Notes

- **A `location` the GVC lacks runs nothing**: every Plane workload reports *"deactivated because maxScale is set to 0"* under `status.versions[].message` and logs nothing.
- **"Waiting for migrations" on the api or worker means `{release}-plane-beat` is not running**: only the scheduler applies migrations.
- **No highly available database or scheduled backups**: back up with `pg_dump` in the `postgresql` container; attachments live in the object store, so back that up too.
- **2.0.0 moves new databases to PostgreSQL 19.** A release from 1.x keeps PostgreSQL 16 only with `postgres.image: postgres:16` in its values; without it the database refuses to start and leaves the data untouched. See [Upgrading from 1.x](#upgrading-from-1x).
- **The bundled PostgreSQL is not pinned to `location`**: in a multi-location GVC an unused copy runs in every other location. Use a one-location GVC.
- **Secrets are read at replica start, and a paused deployment does not retry on its own**: after creating a missing prerequisite secret late, changing one, or an upgrade that changes which secrets the release reads, run `cpln workload force-redeployment {release}-plane --gvc {gvc}` and the same for `{release}-plane-worker`, `{release}-plane-beat` and the datastore whose secret it is (`{release}-postgres`, `{release}-plane-redis`, `{release}-plane-mq` or `{release}-plane-minio`). RabbitMQ creates its user on first boot only, and PostgreSQL its user on first initialization.
- **Plane sends usage telemetry to `telemetry.plane.so`**: turn it off in God Mode → General. Plane's integrations service (also named Silo, unrelated to the object store), Intake and Monitor are not in the Community Edition.

## Links

- [Plane self-hosting documentation](https://developers.plane.so/self-hosting/overview)
- [Plane architecture](https://developers.plane.so/self-hosting/plane-architecture)
- [External database and storage](https://developers.plane.so/self-hosting/govern/database-and-storage)
- [Plane REST API reference](https://developers.plane.so/api-reference/introduction)
- [Plane on GitHub](https://github.com/makeplane/plane)
