# Umami

This app deploys [Umami](https://umami.is/) — a privacy-first, cookieless web and product analytics platform (a self-hosted Google Analytics alternative, MIT-licensed). It runs the stateless Umami v3 app tier backed by a PostgreSQL store, serving the analytics dashboard and the tracking endpoint on one port. The install is private by default; you publish it once the admin password is changed.

## Architecture

- **Umami**: Stateless `standard` workload on port 3000 — dashboard and tracking/collect endpoint share the same port. `replicas: 1` by default (proven single-instance shape); `≥2` forms an always-on scaled tier for zero-downtime rolling restarts. All state lives in PostgreSQL, so replicas are independent (no clustering).
- **PostgreSQL (single-instance, default)**: The `postgres` template — the backing store for all users, websites, sessions, and events.
- **PostgreSQL (HA, optional)**: The `postgres-highly-available` template instead — 3 Patroni replicas with automatic failover and an HAProxy leader endpoint, for a durable production store.
- **Identity and policy**: A least-privilege policy granting the workload `reveal` on exactly two secrets — the app secret you create and the active database's credential secret. The template creates no secret of its own.

## Prerequisites

**One opaque secret must exist BEFORE you install** — the deployment wedges waiting on it otherwise. Its value never passes through Helm values, so it never lands in the release.

**App secret** (`app.appSecretName`) — signs Umami's auth tokens and sessions; anyone holding it can forge a login. Generate a random one:

```bash
printf '%s' "$(openssl rand -base64 32)" | cpln secret create-opaque --name my-umami-app-secret --encoding plain -f -
```

Keep it for the life of the install — changing it logs every user out.

Nothing else is required for a default install. Optional: a cloud account + bucket if you enable the Postgres backup pass-through.

## Configuration

### Application

```yaml
image: ghcr.io/umami-software/umami:3.2.0

replicas: 1            # 1 = proven single-instance; 2+ = always-on, zero-downtime restarts

resources:            # per replica
  cpu: 500m
  memory: 512Mi
  minCpu: 100m
  minMemory: 256Mi

app:
  # Opaque secret (encoding: plain) holding the app secret, which signs auth
  # tokens and sessions. Must EXIST BEFORE INSTALL, and its value must stay
  # stable — changing it logs everyone out.
  appSecretName: my-umami-app-secret
  disableTelemetry: true  # opt out of Umami's anonymous usage telemetry
```

### Tracker

```yaml
tracker:
  scriptName: ""      # custom tracker script path, e.g. "s.js" (dodges ad blockers); "" = default /script.js
  collectEndpoint: "" # custom collect API path, e.g. "/api/track"; "" = default /api/send
```

### Backing Store

Exactly one of the two stores must be enabled (the chart enforces this at render).

```yaml
postgres:             # default: single-instance PostgreSQL
  enabled: true
  config:
    username: umami
    password: change-me-umami-db
    database: umami
  volumeset:
    capacity: 10      # GiB
  backup:
    enabled: false           # true = scheduled backups of the analytics DB to object storage
    provider: aws            # aws | gcp | minio
    aws:
      bucket: my-backup-bucket
      region: us-east-1
      cloudAccountName: my-backup-cloudaccount
      policyName: my-backup-policy
```

```yaml
postgres:
  enabled: false
postgresHA:           # durable HA: 3-replica Patroni store with an HAProxy leader endpoint
  enabled: true
  postgres:
    username: umami
    password: change-me-umami-db
    database: umami
  replicas: 3
  volumeset:
    capacity: 10      # GiB per replica
  backup:
    enabled: false           # true = scheduled backups to object storage
    mode: logical            # logical | wal-g
    provider: aws            # aws | gcp | minio
    aws:
      bucket: my-backup-bucket
      region: us-east-1
      cloudAccountName: my-backup-cloudaccount
      policyName: my-backup-policy
```

Backups are off by default. When enabled they run as a scheduled job in the backing
Postgres store (`gcp`/`minio` providers are configured the same way). See **Storage setup** below.

### Access

```yaml
publicAccess:
  enabled: false      # true = HTTPS dashboard + tracking endpoint on the canonical *.cpln.app endpoint

internalAccess:
  type: same-gvc      # options: none, same-gvc, same-org, workload-list
  workloads: []       # only for same-gvc / workload-list
```

`publicAccess.enabled: false` is the default because Umami seeds a hardcoded `admin` / `umami` account that no environment variable can override — a public default install would stand on the internet with published credentials. Change that password first, then turn public access on: **tracking only works while it is on**, since browsers on the sites you track must reach `/script.js` and `/api/send`. See the first-run sequence in Important Notes.

## Connecting

| What | Value |
|---|---|
| Local access (public access off) | `cpln port-forward {release}-umami 3000:3000 --gvc {gvc}` then open `http://localhost:3000` |
| Public URL | `status.canonicalEndpoint` from `cpln workload get {release}-umami -o yaml` — only when `publicAccess.enabled: true` |
| Dashboard / login | `https://{canonical-endpoint}/login` |
| Tracking script | `https://{canonical-endpoint}/script.js` (embed on your site) |
| Collect endpoint | `https://{canonical-endpoint}/api/send` (where the tracker POSTs events) |
| In-GVC (internal) | `http://{release}-umami.{gvc}.cpln.local:3000` — subject to `internalAccess.type` |
| Default admin | `admin` / `umami` (hardcoded — change it before publishing, see below) |
| App secret | the payload of your `app.appSecretName` secret; never stored in the Helm release |

To start collecting data, add a website in the dashboard, then paste the generated `<script>` tag (which loads `/script.js` and POSTs to `/api/send`) into your site's HTML.

## Storage setup (only if you enable backups)

Backups are off by default and need no cloud account. To turn them on, set `<store>.backup.enabled: true` (where `<store>` is `postgres` or `postgresHA`) and configure a provider. The backup runs in the backing Postgres store, so this is the same setup as that template.

**AWS S3** — create the bucket, a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account), and an IAM policy scoped to the bucket:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    { "Effect": "Allow", "Action": ["s3:ListBucket"], "Resource": "arn:aws:s3:::my-backup-bucket" },
    { "Effect": "Allow", "Action": ["s3:PutObject","s3:GetObject","s3:DeleteObject"], "Resource": "arn:aws:s3:::my-backup-bucket/*" }
  ]
}
```

Then set `provider: aws` and `aws.{bucket,region,cloudAccountName,policyName}`.

**GCP Cloud Storage** — create the bucket and a cloud account, grant its service account **Storage Object Admin** (`roles/storage.objectAdmin`) on the bucket, then set `provider: gcp` and `gcp.{bucket,cloudAccountName}`.

**MinIO / S3-compatible** — set `provider: minio` and `minio.{endpoint,bucket,accessKey,secretKey}` (no cloud account needed; keys authenticate directly).

The backing template's README has the full per-provider walkthrough.

## Important Notes

- **First run — secure the admin account, then publish.** The bootstrap admin is a hardcoded `admin` / `umami`, seeded by the first database migration, and there is no environment variable to override it, so the install starts private:
  1. Install with `publicAccess.enabled: false` (the default).
  2. Reach the dashboard privately with `cpln port-forward {release}-umami 3000:3000 --gvc {gvc}`, open `http://localhost:3000`, log in as `admin` / `umami`, and change the password in **Settings → Profile**.
  3. Run `cpln helm upgrade` with `publicAccess.enabled: true` to publish the dashboard and the tracking endpoint.

  Firewall changes take up to a couple of minutes (30–150 s) to propagate, so re-test the public URL rather than trusting the first response.
- **Tracking does not collect anything until `publicAccess.enabled: true`** — browsers on the sites you track must reach `/script.js` and `/api/send`. Public access is a deliberate second step, not an optional one, if you are collecting analytics.
- **Create the app-secret before installing.** A missing `app.appSecretName` secret leaves the workload waiting on a secret that does not exist, which looks like a platform fault rather than a missing prerequisite.
- **The first `helm upgrade` after an install re-applies the bundled Postgres** — including the upgrade that turns public access on. Expect Umami to be briefly unreachable (~2 minutes) while the database restarts; later upgrades do not do this.
- **Ad blockers block the default `/script.js` and `/api/send`** — set `tracker.scriptName` / `tracker.collectEndpoint` to custom paths to reduce blocking.
- **`replicas ≥ 2` is recommended for production** — replicas are independent and share the database and `appSecret`; rolling restarts cycle one at a time with no downtime.
- **Database volumes survive reinstalls under the same release name; uninstalling deletes them** — all analytics data is lost. Use `postgresHA` and/or enable the backup pass-through for durable production data.

## Links

- [Umami documentation](https://umami.is/docs)
- [Environment variables](https://umami.is/docs/environment-variables)
- [Tracker configuration](https://umami.is/docs/tracker-configuration)
- [Collect API](https://umami.is/docs/api/sending-stats)
