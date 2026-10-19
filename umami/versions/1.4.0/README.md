# Umami

> **Upgrading from 1.3.x:** the database credentials are now a secret you create before upgrading,
> under a **new** name — see [Upgrading from 1.3.x](#upgrading-from-13x).

This app deploys [Umami](https://umami.is/) — a privacy-first, cookieless web and product analytics platform (a self-hosted Google Analytics alternative, MIT-licensed). It runs the stateless Umami v3 app tier backed by a PostgreSQL store, serving the analytics dashboard and the tracking endpoint on one port. The install is private by default; you publish it once the admin password is changed.

## Architecture

- **Umami**: Stateless `standard` workload on port 3000 — dashboard and tracking/collect endpoint share the same port. `replicas: 1` by default (proven single-instance shape); `≥2` forms an always-on scaled tier for zero-downtime rolling restarts. All state lives in PostgreSQL, so replicas are independent (no clustering).
- **PostgreSQL (single-instance, default)**: The `postgres` template — the backing store for all users, websites, sessions, and events.
- **PostgreSQL (HA, optional)**: The `postgres-highly-available` template instead — 3 Patroni replicas with automatic failover and an HAProxy leader endpoint, for a durable production store.
- **Database credentials secret** (dictionary) — *not created by this template*; you create it before install. The bundled PostgreSQL initializes from it and Umami connects with it, in either store mode.
- **Identity and policy**: A least-privilege policy granting the workload `reveal` on exactly two secrets — the app secret and the active database's credentials secret, both of which you create.

## Prerequisites

**Two secrets must exist BEFORE you install** — the deployment wedges waiting on them otherwise. They hold credentials, so they are prerequisite secrets rather than values — a value would sit in plaintext in the Helm release for the life of the install.

**1. Database credentials** (`dictionary`) — the bundled PostgreSQL initializes with these and Umami connects with them:

```bash
cpln secret create-dictionary --name my-umami-db-credentials \
  --entry username=umami \
  --entry password="$(openssl rand -hex 24)" \
  --entry database=umami
```

Set its name in the key of the store you use: `postgres.config.credentialsSecretName` (single-instance, the default) or `postgresHA.config.credentialsSecretName` (HA). Umami builds its connection URL from the three keys, so keep them URL-safe (letters, digits, `-`, `_`). PostgreSQL reads the secret only when its data is first initialized — see [Rotating the database password](#rotating-the-database-password).

**2. App secret** (`app.appSecretName`, opaque) — signs Umami's auth tokens and sessions; anyone holding it can forge a login. Generate a random one:

```bash
printf '%s' "$(openssl rand -base64 32)" | cpln secret create-opaque --name my-umami-app-secret --encoding plain -f -
```

Keep it for the life of the install — changing it logs every user out.

**If either secret does not exist at install time the deployment wedges silently.** `cpln logs` returns zero lines — the container never starts, so there is nothing to log. The only diagnostic is `status.versions[].message` in `cpln workload get-deployments RELEASE_NAME-umami --gvc GVC_NAME -o yaml` (note **`get-deployments`** — plain `cpln workload get` has no `versions` key). Create the missing secret and it recovers on its own, but Umami can take up to about 12 minutes to serve again — poll rather than giving up — or skip the wait with `cpln workload force-redeployment`.

Optional, only if you turn on backups: a cloud account + bucket (AWS/GCP), or — for `provider: minio` — a `dictionary` secret holding the S3-compatible endpoint's keys (see **Storage setup**).

## Configuration

### Application

```yaml
image: ghcr.io/umami-software/umami:3.2.0

replicas: 1            # 1 = proven single-instance; 2+ = always-on, zero-downtime restarts

resources:            # per replica
  minCpu: 100m
  maxCpu: 500m
  minMemory: 256Mi
  maxMemory: 512Mi

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
postgres:             # default: single-instance PostgreSQL (or use postgresHA below for failover)
  enabled: true
  config:
    credentialsSecretName: my-umami-db-credentials # PREREQUISITE dictionary secret (username, password, database) — must exist BEFORE install
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
  config:
    credentialsSecretName: my-umami-db-credentials # PREREQUISITE dictionary secret (username, password, database) — must exist BEFORE install
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
| Public URL | `status.canonicalEndpoint` from `cpln workload get {release}-umami --gvc {gvc} -o yaml` — only when `publicAccess.enabled: true` |
| Dashboard / login | `https://{canonical-endpoint}/login` |
| Tracking script | `https://{canonical-endpoint}/script.js` (embed on your site) |
| Collect endpoint | `https://{canonical-endpoint}/api/send` (where the tracker POSTs events) |
| In-GVC (internal) | `http://{release}-umami.{gvc}.cpln.local:3000` — subject to `internalAccess.type` |
| Default admin | `admin` / `umami` (hardcoded — change it before publishing, see below) |
| App secret | the payload of your `app.appSecretName` secret; never stored in the Helm release |
| Database | `{release}-postgres.{gvc}.cpln.local:5432` (single-instance) or `{release}-postgres-ha-proxy.{gvc}.cpln.local:5432` (HA), with the `username` / `password` / `database` keys of your database credentials secret — `cpln secret reveal SECRET_NAME -o yaml` |

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

**MinIO / S3-compatible** — no cloud account needed, but the keys are a prerequisite secret. Create a `dictionary` secret with the endpoint's credentials, then set `provider: minio`, `minio.{endpoint,bucket}` and `minio.credentialsSecretName` to its name:

```bash
cpln secret create-dictionary --name my-umami-minio-credentials \
  --entry accessKey=MINIO_ACCESS_KEY \
  --entry secretKey=MINIO_SECRET_KEY
```

The backing template's README has the full per-provider walkthrough.

## Rotating the database password

PostgreSQL keeps the password it was initialized with, and a running workload keeps the values it started with, so a rotation takes three steps in order (single-instance; in HA mode follow [Rotating the database password in HA mode](#rotating-the-database-password-in-ha-mode) instead):

1. Change it in the database: `ALTER ROLE DB_USERNAME PASSWORD 'NEW_PASSWORD';` (connected as that user, from inside the GVC).
2. Update the secret: `cpln secret edit SECRET_NAME`.
3. Right away, redeploy Umami: `cpln workload force-redeployment RELEASE_NAME-umami --gvc GVC_NAME`, and wait until `get-deployments` shows a higher version number, alone and ready (right after the command the status may not show the restart yet, and `ready: true` alone can still describe the old replica). Do not redeploy the database: PostgreSQL reads the secret only when it is first initialized, so restarting it only adds downtime.

Umami keeps serving on the database connections it already has open, so with one replica logins failed only for a few seconds while its replica was swapped (measured). Do step 3 right away: if those connections drop before Umami restarts, it cannot open new ones.

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

Then force-redeploy `RELEASE_NAME-umami`, which keeps the old password until it restarts. The database itself drops connections for roughly 10–60 s at each switchover, but the app cannot open new connections from the `ALTER ROLE` until its own redeploy finishes (several minutes in all), so rotate in a quiet window. If a member stays `starting`, or `running` without `streaming` for several minutes, re-copy it from the leader. This copies the whole database, so it costs network traffic in proportion to its size:

```bash
pgx N curl -s -XPOST -d '{"force": true}' localhost:8008/reinitialize
```

## Upgrading from 1.3.x

`postgres.credentials` was removed: the database credentials are now a prerequisite secret, the same one the database templates require on their own. Carrying the old key forward fails the render.

1.3.x created the database secret itself, so **this upgrade deletes it**. Before upgrading, create a secret under a **new** name holding the values your database was initialized with — not new ones, or Umami loses its database connection:

```bash
cpln secret reveal my-umami-db-credentials -o yaml   # the CURRENT values, until the upgrade deletes this secret
cpln secret create-dictionary --name RELEASE_NAME-postgres-credentials \
  --entry username='YOUR_CURRENT_USERNAME' --entry password='YOUR_CURRENT_PASSWORD' --entry database='YOUR_CURRENT_DATABASE'
```

Then upgrade with `postgres.config.credentialsSecretName` (single-instance mode) or `postgresHA.config.credentialsSecretName` (HA mode) set to that name, and `postgres.credentials` removed. Your current values are also in `postgres.credentials` of the 1.3.x release. Read the old secret under the name your release set in `credentialsSecretName`, if you changed the default.

The upgrade restarts the bundled PostgreSQL too (it now reads the new secret), so Umami loses its database for about a minute and a half; it reconnects by itself. The new version of a workload can also wait about 10 minutes with `is not allowed to reveal the secret` in `get-deployments`, while access to the new secret propagates; the previous version keeps serving meanwhile, and it clears by itself.

## Upgrading from 1.2.x (HA store)

`postgresHA.postgres.username/password/database` were removed in 1.3.0 (postgres-highly-available 2.5.0). Put those three values **unchanged** into the database credentials secret under [Prerequisites](#prerequisites), set `postgresHA.config.credentialsSecretName` to its name, and delete the `postgresHA.postgres` block. `postgresHA.backup.minio.accessKey`/`secretKey` moved to a prerequisite secret named by `postgresHA.backup.minio.credentialsSecretName` (see **Storage setup**).

## Upgrading from 1.1.0

`postgres.config.username/password/database` were removed. Put the values your single-instance database was initialized with into the database credentials secret under [Prerequisites](#prerequisites) (keys `username`, `password`, `database`), set `postgres.config.credentialsSecretName` to its name, and remove the three keys.

## Important Notes

- **First run — secure the admin account, then publish.** The bootstrap admin is a hardcoded `admin` / `umami`, seeded by the first database migration, and there is no environment variable to override it, so the install starts private:
  1. Install with `publicAccess.enabled: false` (the default).
  2. Reach the dashboard privately with `cpln port-forward {release}-umami 3000:3000 --gvc {gvc}`, open `http://localhost:3000`, log in as `admin` / `umami`, and change the password in **Settings → Profile**.
  3. Run `cpln helm upgrade` with `publicAccess.enabled: true` to publish the dashboard and the tracking endpoint.

  Firewall changes take up to a couple of minutes (30–150 s) to propagate, so re-test the public URL rather than trusting the first response.
- **Tracking does not collect anything until `publicAccess.enabled: true`** — browsers on the sites you track must reach `/script.js` and `/api/send`. Public access is a deliberate second step, not an optional one, if you are collecting analytics.
- **Create both prerequisite secrets before installing.** A missing app secret or database credentials secret leaves the workload waiting on something that does not exist, with zero log lines — see Prerequisites for the diagnostic.
- **Rotating the database password needs `ALTER ROLE` plus a forced redeployment of Umami** (not the database) — editing the secret alone changes nothing; see [Rotating the database password](#rotating-the-database-password).
- **Rotating the database password in HA mode needs a leader switchover first** — follow [Rotating the database password in HA mode](#rotating-the-database-password-in-ha-mode). A plain redeploy can promote a member still holding the old password and split the cluster.
- **The first `helm upgrade` after an install re-applies the bundled Postgres** — including the upgrade that turns public access on. Expect Umami to be briefly unreachable (~2 minutes) while the database restarts; later upgrades do not do this.
- **Ad blockers block the default `/script.js` and `/api/send`** — set `tracker.scriptName` / `tracker.collectEndpoint` to custom paths to reduce blocking.
- **`replicas ≥ 2` is recommended for production** — replicas are independent and share the database and `appSecret`; rolling restarts cycle one at a time with no downtime.
- **Uninstalling deletes all data** — `helm uninstall` removes the database volumesets with the release, so all analytics data is lost. Use `postgresHA` and/or enable the backup pass-through for durable production data.

## Links

- [Umami documentation](https://umami.is/docs)
- [Environment variables](https://umami.is/docs/environment-variables)
- [Tracker configuration](https://umami.is/docs/tracker-configuration)
- [Collect API](https://umami.is/docs/api/sending-stats)
