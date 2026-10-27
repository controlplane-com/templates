# Unleash

> **Upgrading from 1.5.0 or earlier:** the HA database moves to patroni-postgres 0.8 (pgvector 0.8.7) — see [Upgrading from 1.5.0 or earlier](#upgrading-from-150-or-earlier).
>
> **Upgrading from 1.4.0:** the database credentials are now a secret you create before upgrading,
> under a **new** name — see [Upgrading from 1.4.0](#upgrading-from-140).

This app deploys [Unleash](https://www.getunleash.io/) — the open-source feature-flag server — backed by a highly available PostgreSQL cluster by default. The admin UI and the Admin, Client, and Frontend APIs are served on one public HTTPS endpoint; the server is stateless, so it scales to multiple replicas with a single value.

## Architecture

- **Unleash**: Standard workload (default 1 replica, `replicas` knob for more) serving the admin UI and all APIs on port 4242; `UNLEASH_URL` is derived from the canonical endpoint at start.
- **PostgreSQL (HA, default)** (subchart): the `postgres-highly-available` template — 3× Patroni Postgres, 3× etcd, and a 2-replica HAProxy leader endpoint Unleash connects through. Holds every flag, user, and token.
- **PostgreSQL (dev/lightweight, optional)** (subchart): the single-instance `postgres` template instead, for lighter deployments.
- **Admin secret** (dictionary) — *not created by this template*; you create it before install and reference it by name. Holds the initial admin login.
- **Database credentials secret** (dictionary) — *not created by this template*; you create it before install. The database initializes from it and Unleash connects with it, in either database mode.
- **API-token secret** (dictionary, optional) — likewise user-created; seeds SDK tokens on first boot.
- **Start script** (opaque secret) and **identity + policy**: a least-privilege policy granting the Unleash identity `reveal` on exactly the secrets it uses.
- **Optional database backups** (subchart): logical dumps or WAL-G archiving to S3, GCS, or an S3-compatible endpoint.

## Prerequisites

**Two dictionary secrets must exist BEFORE you install.** They hold credentials, so they are prerequisite secrets rather than values — a value would sit in plaintext in the Helm release for the life of the install.

**1. Database credentials** — the bundled PostgreSQL initializes with these and Unleash connects with them:

```bash
cpln secret create-dictionary --name my-unleash-db-credentials \
  --entry username=unleash \
  --entry password="$(openssl rand -hex 24)" \
  --entry database=unleash
```

Set its name in the key of the database mode you use: `postgresHA.config.credentialsSecretName` (HA, the default) or `postgres.config.credentialsSecretName` (single-instance). PostgreSQL reads the secret only when its data is first initialized; to change the password later, change it in the database first, then update the secret and force a redeployment of the Unleash workload.

**2. Admin login** — the initial admin guards a login form on the public endpoint:

```bash
cpln secret create-dictionary --name my-unleash-admin \
  --entry username=admin \
  --entry password="$(openssl rand -hex 24)"
```

Then set `admin.secretName` to that name. Read the password back with `cpln secret reveal my-unleash-admin -o yaml` (the `-o yaml` is required — the default output does not show the values).

| Key | What it is |
|---|---|
| `username` | The initial admin's login name. |
| `password` | Its password. The login form is on the public endpoint. |

**If either secret does not exist at install time the deployment wedges silently.** `cpln logs` returns zero lines — the container never starts, so there is nothing to log. The only diagnostic is `status.versions[].message` in `cpln workload get-deployments {release}-unleash --gvc {gvc} -o yaml` (note **`get-deployments`** — plain `cpln workload get` has no `versions` key). Create the missing secret and it recovers on its own within roughly 5.5–10.5 minutes — poll rather than giving up — or clear it immediately with `cpln workload force-redeployment {release}-unleash --gvc {gvc}` (~90 s).

**Optional — first-boot SDK API tokens**: a **dictionary** secret with exactly two keys, `backend` and `frontend`, each a full Unleash token string in the format `<project>:<environment>.<secret>` (OSS environments are `development` and `production`):

```bash
cpln secret create-dictionary --name my-unleash-api-tokens \
  --entry backend="default:production.$(openssl rand -hex 24)" \
  --entry frontend="default:production.$(openssl rand -hex 24)"
```

Set its name in `apiTokens.secretName`. Leave it empty to create tokens in the admin UI after install instead.

For optional database backups: a bucket and access setup for one of the supported providers (see [Backup storage setup](#backup-storage-setup)). With `provider: minio` (either store), the endpoint's keys are a prerequisite `dictionary` secret — see that section.

## Configuration

### Unleash

```yaml
image: unleashorg/unleash-server:8.0.3

resources:
  maxCpu: 1000m
  maxMemory: 1Gi
  minCpu: 250m
  minMemory: 512Mi

replicas: 1                   # stateless — set 2+ for high availability (recommended for production)

admin:                        # initial admin login, seeded on first boot only
  secretName: my-unleash-admin # PREREQUISITE dictionary secret — must exist BEFORE install

apiTokens:
  secretName: ""              # your pre-created dictionary secret (see Prerequisites); empty = create tokens in the UI
```

### Access

```yaml
publicAccess:
  enabled: true               # admin UI + SDK APIs on the canonical *.cpln.app HTTPS endpoint

internalAccess:               # internal firewall scope (in-GVC SDK callers)
  type: same-gvc              # none, same-gvc, same-org, workload-list
  workloads: []               # used with workload-list, e.g. //gvc/GVC/workload/NAME
```

Public access is **on** by default and is load-bearing: SDKs in browsers and in applications outside the GVC call `/api/frontend` and `/api/client` directly. A firewall change takes 30 s to a few minutes to propagate, so re-test rather than trusting the first response.

### PostgreSQL

Exactly one of the two databases must be enabled (the chart enforces this at render).

```yaml
postgresHA:                   # default: highly available PostgreSQL
  enabled: true
  image: controlplanecorporation/patroni-postgres:0.8 # pgvector 0.8.7 (CVE-2026-103484); tags 0.1-0.7 are refused
  config:
    credentialsSecretName: my-unleash-db-credentials # PREREQUISITE dictionary secret (username, password, database) — must exist BEFORE install
  replicas: 3
  volumeset:
    capacity: 10              # GiB per replica
  backup:
    enabled: false            # optional — see Backup storage setup
```

```yaml
postgresHA:
  enabled: false
postgres:                     # dev/lightweight: single-instance PostgreSQL
  enabled: true
  config:
    credentialsSecretName: my-unleash-db-credentials # PREREQUISITE dictionary secret (username, password, database) — must exist BEFORE install
  volumeset:
    capacity: 10              # GiB
  backup:
    enabled: false            # optional — see Backup storage setup
```

## Connecting

| What | Value |
|---|---|
| Admin UI / Admin API (public) | the canonical endpoint — read `status.canonicalEndpoint` from `cpln workload get {release}-unleash --gvc {gvc} -o yaml` |
| Client API (backend SDKs) | `{canonical-endpoint}/api/client` — `Authorization: <backend token>` |
| Frontend API (browser/mobile SDKs) | `{canonical-endpoint}/api/frontend` — `Authorization: <frontend token>` |
| Internal (same GVC) | `http://{release}-unleash.{gvc}.cpln.local:4242` |
| Login | `username` / `password` from your `admin.secretName` secret — `cpln secret reveal my-unleash-admin -o yaml` |
| Postgres (internal, HA mode) | `{release}-postgres-ha-proxy.{gvc}.cpln.local:5432`, credentials from your `postgresHA.config.credentialsSecretName` secret (`cpln secret reveal SECRET_NAME -o yaml`) |
| Postgres (internal, single mode) | `{release}-postgres.{gvc}.cpln.local:5432`, credentials from your `postgres.config.credentialsSecretName` secret |

## Upgrading from 1.5.0 or earlier

1.5.1 moves the HA database to `controlplanecorporation/patroni-postgres:0.8`, which carries pgvector 0.8.7 (CVE-2026-103484). The fix takes effect when the upgrade restarts the Patroni members; existing data needs nothing. Nothing limits the rollout of a stateful workload, so expect a short database outage while the members and the proxy restart, and upgrade in a quiet window. If you pinned `postgresHA.image`, set it to the `0.8` tag: tags `0.1` to `0.7` are refused at render. Unleash does not use the `vector` extension; if you created it yourself in a database, run `ALTER EXTENSION vector UPDATE;` there, which only updates the version `\dx` reports. Single-instance mode is unchanged.

## Upgrading from 1.4.0

`postgres.credentials` was removed: the database credentials are now a prerequisite secret, the same one the database templates require on their own. Carrying the old key forward fails the render.

1.4.0 created the database secret itself, so **this upgrade deletes it**. Before upgrading, create a secret under a **new** name holding the values your database was initialized with — not new ones, or Unleash loses its database connection:

```bash
cpln secret create-dictionary --name RELEASE_NAME-unleash-db \
  --entry username=unleash --entry password='YOUR_CURRENT_PASSWORD' --entry database=unleash
```

Then upgrade with `postgresHA.config.credentialsSecretName` (HA mode) or `postgres.config.credentialsSecretName` (single-instance mode) set to that name, and `postgres.credentials` removed. Your current values are in `postgres.credentials` of the 1.4.0 release, and also in the old secret (`cpln secret reveal my-unleash-db-credentials -o yaml`, or the name your release set in `credentialsSecretName`) until the upgrade deletes it.

The upgrade restarts the bundled PostgreSQL too (it now reads the new secret), so Unleash can briefly lose its database; it reconnects by itself. The new version of a workload can also wait about 10 minutes with `is not allowed to reveal the secret` in `get-deployments`, while access to the new secret propagates; the previous version keeps serving meanwhile, and it clears by itself.

## Upgrading from 1.3.x

Resource blocks that expose both a floor and a ceiling name the ceiling `maxCpu`/`maxMemory` instead of `cpu`/`memory`. Rename those two keys in your values; an upgrade that still carries the old names is refused at render. Then follow [Upgrading from 1.4.0](#upgrading-from-140).

## Upgrading from 1.2.x (HA mode)

1.3.0 moved the HA database to `postgres-highly-available` 2.5.0, which no longer takes credentials as values. Put the values of `postgresHA.postgres.username/password/database` **unchanged** into the database credentials secret under Prerequisites, set `postgresHA.config.credentialsSecretName` to its name, and delete the `postgresHA.postgres` block.

With `postgresHA.backup.provider: minio`, `postgresHA.backup.minio.accessKey`/`secretKey` are refused by the same subchart — put them in a `dictionary` secret and set `postgresHA.backup.minio.credentialsSecretName` to its name (that knob arrived in 1.3.1; 1.3.0 still showed the removed keys). See [Backup storage setup](#backup-storage-setup).

## Upgrading from 1.1.0

`postgres.config.username/password/database` were removed. Put the values your single-instance database was initialized with into the database credentials secret under Prerequisites (keys `username`, `password`, `database`), set `postgres.config.credentialsSecretName` to its name, and remove the three keys.

With `postgres.backup.provider: minio`, `postgres.backup.minio.accessKey`/`secretKey` were likewise removed — put them in a `dictionary` secret and set `postgres.backup.minio.credentialsSecretName` to its name (see [Backup storage setup](#backup-storage-setup)).

The HA path (`postgresHA.*`) was unchanged in 1.2.0; it changed in 1.3.0 — see above.

## Upgrading from 1.0.x

The initial admin credentials moved out of `values.yaml` into the prerequisite dictionary secret above. Carrying either old key forward fails the render with a message naming its replacement; there are no compatibility fallbacks. `apiTokens.secretName` was already a prerequisite secret and is unchanged.

| Removed key | Now a key in the admin secret |
|---|---|
| `admin.username` | `username` |
| `admin.password` | `password` |

**An existing install's admin password does not change on upgrade.** `UNLEASH_DEFAULT_ADMIN_*` is seeded on first boot only; the account then lives in the database, so the secret's contents only matter to a fresh install. Change the password in the admin UI. If the install is still carrying the published 1.0.x default (`change-me-unleash-admin`), treat that password as compromised and change it now.

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
cpln secret create-dictionary --name my-unleash-minio-credentials \
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

Then force-redeploy `RELEASE_NAME-unleash`, which keeps the old password until it restarts. The database itself drops connections for roughly 10–60 s at each switchover, but the app cannot open new connections from the `ALTER ROLE` until its own redeploy finishes (several minutes in all), so rotate in a quiet window. If a member stays `starting`, or `running` without `streaming` for several minutes, re-copy it from the leader. This copies the whole database, so it costs network traffic in proportion to its size:

```bash
pgx N curl -s -XPOST -d '{"force": true}' localhost:8008/reinitialize
```

## Important Notes

- **Create both secrets before installing.** A missing prerequisite secret leaves the workload waiting on something that does not exist, with zero log lines — see Prerequisites for how to diagnose it.
- **Rotating the database secret needs a forced redeployment** (`cpln workload force-redeployment`) — a running workload keeps the values it started with, and the database keeps the password it was initialized with until you change it there.
- **Admin credentials and API tokens are seeded on first boot only** — they live in the database afterwards; change the password or manage tokens in the admin UI, not by editing the secrets.
- **Backend tokens must stay secret** (server-side SDKs, `/api/client`); frontend tokens are safe to embed in browsers (`/api/frontend`). A 401 usually means the wrong token type or environment.
- **The free edition ships exactly two environments** (`development`, `production`); SSO, role-based access control, multiple projects, change requests, and audit logs require an Unleash Enterprise license and are not available in this template.
- **HA-mode first boot takes ~5–7 minutes** — transient `Failed to migrate db` log errors while the database cluster starts are expected and self-heal, at any replica count.
- **Uninstall deletes the database volumesets** — all flags, users, and tokens. Enable backups if the data matters.
- **Rotating the database password in HA mode needs a leader switchover first** — follow [Rotating the database password in HA mode](#rotating-the-database-password-in-ha-mode). A plain redeploy can promote a member still holding the old password and split the cluster.

## Links

- [Unleash documentation](https://docs.getunleash.io/)
- [Configuring Unleash (environment variables)](https://docs.getunleash.io/deploy/configuring-unleash)
- [API tokens and client keys](https://docs.getunleash.io/concepts/api-tokens-and-client-keys)
- [SDK overview](https://docs.getunleash.io/sdks)
- [Scaling Unleash](https://docs.getunleash.io/guides/scaling-unleash)
