# GlitchTip

This app deploys [GlitchTip](https://glitchtip.com/) — Sentry-API-compatible error tracking, fully MIT-licensed with nothing feature-gated. Apps report crashes with standard Sentry SDKs pointed at a GlitchTip DSN; a stateless web tier serves the UI and event ingest, a background worker processes events and alerts, and all state lives in PostgreSQL and Redis.

## Architecture

- **GlitchTip web**: Standard workload (default 1 replica, `replicas` knob for more) serving the UI, API, and SDK event ingest on port 8000.
- **GlitchTip worker**: Single-replica standard workload running the vtasks worker + scheduler; runs database migrations and superuser bootstrap at boot.
- **PostgreSQL (HA, default)** (subchart): the `postgres-highly-available` template — 3× Patroni Postgres, 3× etcd, and an HAProxy leader endpoint. Holds all issue/event data.
- **PostgreSQL (dev/lightweight, optional)** (subchart): the single-instance `postgres` template instead.
- **Redis + Sentinel (default, optional)** (subchart): the `redis` template — task queue, cache, and sessions; disable to run those on PostgreSQL instead.
- **Auth secret** (dictionary): *not created by this template*; you create it before install and reference it by name. Holds the Django signing key and the initial superuser login.
- **Database credentials secret** (dictionary): the bundled single-instance database's `username`, `password` and `database`, built by this template from `postgres.credentials.*` and handed to the Postgres subchart by name. Nothing for you to create. (Not rendered on the HA path — `postgres-highly-available` still makes its own.)
- **Secrets, identity, and policy**: two start scripts, and a least-privilege policy granting the shared identity `reveal` on exactly the secrets used — nothing broader.

## Prerequisites

**One dictionary secret must exist BEFORE you install.** The signing key and the superuser login are credentials, so they are a prerequisite secret rather than values — a value would sit in plaintext in the Helm release for the life of the install, and the admin login form is on a public endpoint.

Create it with exactly these three keys:

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

**If the secret does not exist at install time the deployment wedges silently.** `cpln logs` returns zero lines — the container never starts, so there is nothing to log. The only diagnostic is `status.versions[].message` in `cpln workload get-deployments <release>-glitchtip --gvc <gvc> -o yaml` (note **`get-deployments`** — plain `cpln workload get` has no `versions` key). Create the missing secret and it recovers on its own in roughly 6–8 minutes, or clear it immediately with `cpln workload force-redeployment <release>-glitchtip --gvc <gvc>` (~90 s). The worker workload wedges the same way and needs the same treatment.

Also:

- **Optional — outbound email (invites, alerts, password resets)**: an **opaque** secret in your org whose payload is a full email URL, e.g. `smtp://user:password@smtp.example.com:587`. Set its name in `email.secretName`. Create it BEFORE installing; leave empty to run without email.
- For optional database backups: a bucket and access setup for one of the supported providers (see [Backup storage setup](#backup-storage-setup)). With `provider: minio` on the single-instance store, the endpoint's keys are a prerequisite `dictionary` secret — see that section.

**The database password is not a prerequisite** — it is bundled plumbing, so this template creates that secret for you from `postgres.credentials.*` (HA mode) or `postgres.credentials.*` (single-instance mode).

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
      password:
        enabled: true # required when redis is enabled (the chart enforces this)
        value: change-me-glitchtip-redis # change before installing (any characters OK — the boot script percent-encodes it)
    persistence:
      enabled: true
  sentinel:
    replicas: 3 # sentinel auth must stay disabled — GlitchTip cannot send a sentinel password
    persistence:
      enabled: true
```

### PostgreSQL

Exactly one of the two databases must be enabled (the chart enforces this at render). Both passwords are bundled plumbing — used as-is, so change them before installing.

```yaml
postgresHA: # default: highly available PostgreSQL
  enabled: true
  config:
    credentialsSecretName: my-glitchtip-db-credentials # see Prerequisites — must exist before install
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
  credentials: # this template builds the DB credential secret from these
    username: glitchtip
    password: change-me-glitchtip-db # change before installing
    database: glitchtip
  config:
    # name of the dictionary secret this template CREATES and Postgres reads;
    # secret names are org-wide; a second release on this name is refused at install
    credentialsSecretName: my-glitchtip-db-credentials
  volumeset:
    capacity: 10 # initial capacity in GiB (minimum is 10)
  backup:
    enabled: false # optional — see Backup storage setup
```

## Connecting

| What | Value |
|---|---|
| UI (public) | `https://<canonical>.cpln.app` — `status.canonicalEndpoint` of `{release}-glitchtip` |
| Local access (public access off) | `cpln port-forward {release}-glitchtip 8000:8000 --gvc {gvc}` then open `http://localhost:8000` |
| SDK DSN | Copy from the UI: project → Settings → DSN (embeds the public endpoint) |
| Internal (same GVC) | `http://{release}-glitchtip.{gvc}.cpln.local:8000` |
| Login | the `adminEmail` / `adminPassword` keys of your `auth.secretName` secret |
| Django admin (user management) | `https://<canonical>.cpln.app/admin/` |
| Postgres (internal, HA mode) | `{release}-postgres-ha-proxy.{gvc}.cpln.local:5432`, credentials in the `{release}-postgres-config` secret |
| Postgres (internal, single mode) | `{release}-postgres.{gvc}.cpln.local:5432`, credentials in the secret named by `postgres.config.credentialsSecretName` |

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
2. Set `backup.minio.endpoint` to the S3 API address including port. For the `minio` marketplace template in the same GVC, this is `http://WORKLOAD_NAME:9000`.
3. For `postgresHA.backup`, set `backup.minio.accessKey` and `backup.minio.secretKey` to credentials with access to the bucket. For `postgres.backup` (single-instance), create a `dictionary` secret with those credentials and set `postgres.backup.minio.credentialsSecretName` to its name:

```bash
cpln secret create-dictionary --name my-glitchtip-minio-credentials \
  --entry accessKey=YOUR_ACCESS_KEY \
  --entry secretKey=YOUR_SECRET_KEY
```

## Important Notes

- **The default HA stack takes about six and a half minutes to converge**, and the worker crash-loops with `Connection reset by peer` for the first several minutes while Patroni elects a database leader. This is expected and self-correcting — do not treat it as a failed install.
- **Create the auth secret before installing.** A missing prerequisite secret leaves both workloads waiting on something that does not exist, with zero log lines — see Prerequisites for how to diagnose it.
- **Never rotate `secretKey` on a live install unless you intend to** — it logs every user out and invalidates password-reset links in flight. Nothing is corrupted, but everyone has to sign in again.
- **Change the database password and the redis password before installing** — both are bundled plumbing used as-is.
- **With registration closed (default), invites only work for accounts that already exist** — create teammate accounts first at `/admin/` (Django admin, superuser login), then invite them to the organization. Invite and alert emails require `email.secretName`.
- **Do not scale the worker** — it is a fixed singleton (scheduler + boot-time migrations). Web `replicas` is the scaling knob; a worker outage pauses processing but ingest keeps accepting and catches up.
- **First boot: the web tier stays not-ready until the worker finishes migrations** (several minutes in HA mode) — check worker logs first if it seems stuck.
- **The first `helm upgrade` after an install re-applies the bundled database and Redis**, so expect GlitchTip to be briefly unreachable while they restart; later upgrades do not do this.
- **DSNs embed the endpoint URL** — if you add a custom domain later, set `domain`, upgrade, and update the DSNs in your apps.
- **Source-map/artifact uploads are ephemeral** (local disk) — lost on restart and not shared across web replicas; error ingest itself is unaffected.
- **Upgrading from 1.1.0**: the single-instance database credentials moved from `postgres.config.username/password/database` to `postgres.credentials.username/password/database`, named by the new `postgres.config.credentialsSecretName`. Carrying the old keys fails the render with `config.username was REMOVED in postgres 3.4.0` — move the three keys and you are done. **Ignore that message's advice to create a secret yourself; this template creates it**, and the database password stays a value. `postgres.backup.minio.accessKey`/`secretKey` were removed the same way (see Backup storage setup). The HA path (`postgresHA.*`), Redis, and the `auth.secretName` prerequisite secret are all unchanged.
- **Give each glitchtip release its own `postgres.config.credentialsSecretName`** (single-instance mode only). Secret names are org-wide, so a second release left on the default name is **refused at install** — `The resource '…' cannot be updated because it is being managed by a different release` — and creates nothing. Nothing is shared or overwritten, and the first release is unaffected; you simply cannot install the second until you give it a distinct name.
- **Uninstall deletes the database volumesets** — all issues, events, and users. Enable backups if the data matters.

## Links

- [GlitchTip documentation](https://glitchtip.com/documentation)
- [Installation and configuration reference](https://glitchtip.com/documentation/install)
- [Sentry SDKs (client setup)](https://docs.sentry.io/platforms/)
- [GlitchTip 6 release notes](https://glitchtip.com/blog/2026-02-03-glitchtip-6-released/)
- [GlitchTip backend source](https://gitlab.com/glitchtip/glitchtip-backend)
