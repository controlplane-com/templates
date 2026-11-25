# Keycloak

> **Upgrading from 1.4.0:** the database credentials are now a secret you create before upgrading,
> under a **new** name — see [Upgrading from 1.4.0](#upgrading-from-140).

This app deploys [Keycloak](https://www.keycloak.org/) — open-source identity and access management providing single sign-on, OIDC/SAML, user federation, and fine-grained authorization. It runs clustered Keycloak 26 in production mode with a highly available PostgreSQL backing store by default, delivering zero-downtime restarts and upgrades.

## Architecture

- **Keycloak**: Stateful workload, 2 replicas by default, clustered via embedded Infinispan (JGroups JDBC_PING through the shared database — no extra infrastructure). `replicas: 1` runs a dev mode with clustering fully disabled.
- **PostgreSQL (HA, default)**: The `postgres-highly-available` template (PostgreSQL 18 for new clusters) — 3 Patroni replicas, 3 etcd replicas, and an HAProxy leader-routing endpoint Keycloak connects through.
- **PostgreSQL (dev/test, optional)**: The single-instance `postgres` template (PostgreSQL 19) instead, for lighter deployments.
- **Admin secret** (dictionary) — *not created by this template*; you create it before install and reference it by name. Holds the bootstrap admin login.
- **Database credentials secret** (dictionary) — *not created by this template*; you create it before install. The database initializes from it and Keycloak connects with it, in either store mode.
- **Startup script** (opaque secret) — waits for the database and configures clustering; mounted into the container.
- **Identity + policy**: a least-privilege policy granting the workload `reveal` on exactly three secrets — your admin secret, your database credentials secret, and the startup script.

All durable state — realms, users, and active sessions — lives in PostgreSQL; the Keycloak tier is stateless on disk.

## Prerequisites

**Two dictionary secrets must exist BEFORE you install.** They hold credentials, so they are prerequisite secrets rather than values — a value would sit in plaintext in the Helm release for the life of the install.

**1. Database credentials** — the bundled PostgreSQL initializes with these and Keycloak connects with them:

```bash
cpln secret create-dictionary --name my-keycloak-db-credentials \
  --entry username=keycloak \
  --entry password="$(openssl rand -hex 24)" \
  --entry database=keycloak
```

Set its name in the key of the store you use: `postgresHA.config.credentialsSecretName` (HA, the default) or `postgres.config.credentialsSecretName` (single-instance). Secret names are org-wide, so give each keycloak release its own secret.

- **`database` must be URL-safe** (letters, digits, `_`): Keycloak's JDBC URL is assembled from it at container start. The snippet's hex password needs no escaping either.
- **PostgreSQL reads the secret only when its data is first initialized.** To change the password later, run `ALTER ROLE` first, then edit the secret (`cpln secret edit my-keycloak-db-credentials`), then right away redeploy Keycloak: `cpln workload force-redeployment RELEASE_NAME-keycloak --gvc GVC_NAME`. Do not redeploy the database: PostgreSQL reads the secret only when it is first initialized, so restarting it only adds downtime. In HA mode follow [Rotating the database password in HA mode](#rotating-the-database-password-in-ha-mode) instead. A running workload keeps the values it started with.

**2. Admin login** — the bootstrap admin guards a login form on the public endpoint:

```bash
cpln secret create-dictionary --name my-keycloak-admin \
  --entry username=admin \
  --entry password="$(openssl rand -hex 24)"
```

Then set `admin.secretName` to that name. Read the password back with `cpln secret reveal my-keycloak-admin -o yaml` (the `-o yaml` is required — the default output does not show the values).

| Key | What it is |
|---|---|
| `username` | The temporary bootstrap admin's login name. |
| `password` | Its password. The login form is on the public endpoint. |

**If either secret does not exist at install time the deployment wedges silently.** `cpln logs` returns zero lines — the container never starts, so there is nothing to log. The only diagnostic is `status.versions[].message` in `cpln workload get-deployments RELEASE_NAME-keycloak --gvc GVC_NAME -o yaml` (note **`get-deployments`** — plain `cpln workload get` has no `versions` key). Create the missing secret and it recovers on its own within roughly 5.5–10.5 minutes — poll rather than giving up — or clear it immediately with `cpln workload force-redeployment RELEASE_NAME-keycloak --gvc GVC_NAME` (~90 s).

Optional: a cloud account + bucket if you enable the Postgres backup pass-through.

## Configuration

### Keycloak Settings

```yaml
image: quay.io/keycloak/keycloak:26.8.1

replicas: 2          # 2+ = clustered, zero-downtime restarts; 1 = dev mode

resources:           # per replica
  maxCpu: 1000m
  maxMemory: 2Gi        # JVM heap = 70% of this; do not set below 1.5Gi
  minCpu: 500m
  minMemory: 1Gi

admin:
  secretName: my-keycloak-admin # PREREQUISITE dictionary secret — must exist BEFORE install
```

### Backing Store

Exactly one of the two stores must be enabled (the chart enforces this at render).

```yaml
postgresHA:          # default: highly available PostgreSQL
  enabled: true
  config:
    credentialsSecretName: my-keycloak-db-credentials # PREREQUISITE dictionary secret (username, password, database) — must exist BEFORE install
  replicas: 3
  image: controlplanecorporation/patroni-postgres:0.9 # PostgreSQL 18 for new clusters (bundles 14-18); tags 0.1-0.7 are refused
  volumeset:
    capacity: 10     # GiB per replica
  backup:
    enabled: false   # see the postgres-highly-available template docs
```

```yaml
postgresHA:
  enabled: false
postgres:            # dev/test: single-instance PostgreSQL
  enabled: true
  image: postgres:19 # a release from an earlier version of this chart keeps postgres:18 (see Upgrading from 1.x)
  config:
    credentialsSecretName: my-keycloak-db-credentials # PREREQUISITE dictionary secret (username, password, database) — must exist BEFORE install
  volumeset:
    capacity: 10
  backup:
    enabled: false   # see the postgres template docs
```

### Backup retention

The backup job only uploads; it never deletes old backups. To keep a fixed window, add a lifecycle rule on the bucket that expires objects under the backup prefix. Each backup is a complete, standalone copy, so expiring old ones never affects restoring a newer one. Set the window to at least your retention plus one backup interval, and note that an age rule keeps no minimum: if backups stop running, the last ones expire too.

In `wal-g` mode (`postgresHA.backup.mode: wal-g`), a restore needs the newest full base backup plus the WAL files written after it, all under the same prefix and never rewritten. Older base backups and the WAL before them are not needed, so the same rule is safe as long as the window is longer than two base-backup intervals (`postgresHA.backup.walg.intervalSeconds`). If base backups stop while WAL archiving continues, the rule eventually expires the last base backup, so check that new `basebackups_005/` entries keep appearing.

The rules below use the default prefix `postgres/backups/`; change it if you changed `postgres.backup.<provider>.prefix` (or `postgresHA.backup.<provider>.prefix` in HA mode).

**AWS S3.** `put-bucket-lifecycle-configuration` **replaces every existing rule on the bucket**, so check for existing rules first and add them to the file:

```bash
aws s3api get-bucket-lifecycle-configuration --bucket BUCKET_NAME
cat > lifecycle.json <<'EOF'
{"Rules":[{"ID":"expire-db-backups","Filter":{"Prefix":"postgres/backups/"},"Status":"Enabled",
  "Expiration":{"Days":30},"NoncurrentVersionExpiration":{"NoncurrentDays":1}}]}
EOF
aws s3api put-bucket-lifecycle-configuration --bucket BUCKET_NAME --lifecycle-configuration file://lifecycle.json
```

**Google Cloud Storage.** `--lifecycle-file` also **replaces the bucket's existing rules**; check with `gcloud storage buckets describe gs://BUCKET_NAME --format='json(lifecycle_config)'` first:

```bash
cat > lifecycle.json <<'EOF'
{"rule":[
  {"action":{"type":"Delete"},"condition":{"age":30,"matchesPrefix":["postgres/backups/"]}},
  {"action":{"type":"Delete"},"condition":{"daysSinceNoncurrentTime":1,"isLive":false,"matchesPrefix":["postgres/backups/"]}}]}
EOF
gcloud storage buckets update gs://BUCKET_NAME --lifecycle-file=lifecycle.json
```

**MinIO** (adds a rule alongside existing ones; the access key needs `s3:PutLifecycleConfiguration`, which the built-in `readwrite` policy grants):

```bash
mc ilm rule add --expire-days 30 --noncurrent-expire-days 1 --prefix "postgres/backups/" ALIAS/BUCKET_NAME
mc ilm rule ls ALIAS/BUCKET_NAME
```

Lifecycle rules run in the background; objects are removed within about a day of reaching the age. The `Noncurrent` parts matter only on a versioned bucket, where expiry otherwise just adds a delete marker.

### Access

```yaml
publicAccess:
  enabled: true      # HTTPS via the canonical *.cpln.app endpoint

internalAccess:
  type: same-gvc     # options: none, same-gvc, same-org, workload-list
  workloads: []      # for workload-list; replicas > 1 requires type != none
```

Public access is **on** by default: browsers must reach Keycloak's login and OIDC endpoints for SSO to work at all, and the admin login is a credential you created rather than a published default. A firewall change takes 30 s to a few minutes to propagate, so re-test rather than trusting the first response.

## Connecting

| What | Value |
|---|---|
| Public URL | `status.canonicalEndpoint` from `cpln workload get RELEASE_NAME-keycloak --gvc GVC_NAME -o yaml` |
| Admin console | `https://{canonical-endpoint}/admin` |
| OIDC discovery | `https://{canonical-endpoint}/realms/{realm}/.well-known/openid-configuration` |
| In-GVC (internal) | `http://RELEASE_NAME-keycloak.GVC_NAME.cpln.local:8080` |
| Admin credentials | `username` / `password` from your `admin.secretName` secret — `cpln secret reveal my-keycloak-admin -o yaml` |
| Database credentials | the `username` / `password` / `database` keys of your secret named by `postgresHA.config.credentialsSecretName` (HA path) or `postgres.config.credentialsSecretName` (single-instance path) — `cpln secret reveal SECRET_NAME -o yaml` |

## Upgrading from 1.x

**HA mode (the default)** moves to the `postgres-highly-available` 3.0.0 template. New clusters run PostgreSQL 18; an existing cluster keeps PostgreSQL 17 in place, because the new image (`controlplanecorporation/patroni-postgres:0.9`) bundles PostgreSQL 14 to 18 and each member runs the version of its data directory. The upgrade needs no pin. What changes:

- The database members restart one after another onto the new image (and the latest 17 minor release), so writes pause briefly while the leader changes, even with 2 or more Keycloak replicas.
- If your values set `postgresHA.image`, use the `0.9` tag (`0.8` also keeps a 17 cluster running); tags `0.1` to `0.7` are refused at render.
- The default logical backup image moves to `postgres-backup:18.2.0`, which backs up 17 and 18 clusters, and the backup job gets 512Mi of memory.
- The backup identity no longer carries `cpln-connector` or `aws::ReadOnlyAccess`. With AWS backups, **update your bucket's IAM policy to the action list in the [postgres-highly-available README](https://github.com/controlplane-com/templates/blob/main/postgres-highly-available/versions/3.0.0/README.md#aws-s3) before upgrading.**

To move an existing HA cluster to PostgreSQL 18, copy it into a new release: follow [Upgrading an existing cluster to PostgreSQL 18](https://github.com/controlplane-com/templates/blob/main/postgres-highly-available/versions/3.0.0/README.md#upgrading-an-existing-cluster-to-postgresql-18) in the `postgres-highly-available` README, with a new Keycloak release (same two prerequisite secrets) in place of the second database release, and both Keycloak workloads stopped during the copy.

**Single-instance mode** (`postgres.enabled: true`) now installs PostgreSQL 19, while a 1.x release's database is PostgreSQL 18. A data directory only opens with its own major, and the chart never converts it in place: before PostgreSQL starts, a guard compares the two, and on a mismatch it does not start the server and changes nothing on the volume. `cpln workload get-deployments RELEASE_NAME-postgres --gvc GVC_NAME` then stays not ready, Keycloak waits for its database, and the logs repeat `[pg-guard] REFUSING TO START` every 30 seconds:

```bash
cpln logs '{gvc="GVC_NAME", workload="RELEASE_NAME-postgres"} |= "pg-guard"' --since 15m
```

**Stay on PostgreSQL 18:** upgrade with the image pinned, and keep `postgres.image: postgres:18` in your values file for every later upgrade (`cpln helm upgrade` does not reuse the installed values). The Console upgrade wizard keeps the installed image for you.

```bash
cpln helm upgrade RELEASE_NAME CHART --gvc GVC_NAME -f my-values.yaml --set postgres.image=postgres:18
```

**Move to PostgreSQL 19, side by side** (Keycloak gets a new endpoint, so every application must move to the new issuer URL; logins are down during the copy):

1. Stop the old Keycloak, so nothing writes to its database: `cpln workload stop OLD_RELEASE-keycloak --gvc GVC_NAME`.
2. Install this version as a NEW release in single-instance mode with the **same two prerequisite secrets** (`admin.secretName` and `postgres.config.credentialsSecretName`), so the copied tables belong to the role Keycloak connects as.
3. Once `NEW_RELEASE-keycloak` is ready, stop it (`cpln workload stop NEW_RELEASE-keycloak --gvc GVC_NAME`), then replace its new database with a copy of the old one, from inside the new PostgreSQL container:

   ```bash
   cpln workload exec NEW_RELEASE-postgres --gvc GVC_NAME --container postgresql -- bash -c \
     'export PGPASSWORD="$POSTGRES_PASSWORD"
      psql -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 -q \
        -c "DROP DATABASE \"$POSTGRES_DB\" WITH (FORCE)" -c "CREATE DATABASE \"$POSTGRES_DB\" OWNER \"$POSTGRES_USER\"" &&
      pg_dump -h OLD_RELEASE-postgres.GVC_NAME.cpln.local -U "$POSTGRES_USER" -d "$POSTGRES_DB" |
        psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -q'
   ```

4. Start the new Keycloak (`cpln workload start NEW_RELEASE-keycloak --gvc GVC_NAME`), log in to the admin console with your permanent admin, and check your realms, clients and users.
5. Point your applications at the new issuer (`https://{new-canonical-endpoint}/realms/{realm}`, or move your custom domain), then uninstall the old release (this deletes its database volume).

## Upgrading from 1.5.0

1.5.1 moves Keycloak from 26.6.3 to 26.8.1, which fixes an unauthenticated account-takeover vulnerability in the reset-credentials flow (CVE-2026-18963). No values change: upgrade with the values you already use. If your values set `image` (installs made through the Console wizard store it), change it to `quay.io/keycloak/keycloak:26.8.1` or remove it; the chart refuses an official Keycloak image older than 26.7.2.

The first 26.8.1 server to start migrates the database schema, and Keycloak cannot run an older version against a migrated database, so this upgrade cannot be rolled back to 1.5.0: a rolled-back release reports healthy, but every login page fails with HTTP 500. Take a database backup before upgrading (`postgresHA.backup` or `postgres.backup`, see [Configuration](#configuration)); to recover from a rollback, upgrade to 1.5.1 again or restore the backup.

With 2 or more replicas Keycloak keeps serving throughout the upgrade, apart from the brief interruption of database writes in HA mode described below. With `replicas: 1`, Keycloak is unavailable while its single server restarts.

In HA mode, 1.5.1 also moves the database to `controlplanecorporation/patroni-postgres:0.8`, which carries pgvector 0.8.7 (CVE-2026-103484). The database members restart and nothing limits that rollout, so expect a brief interruption of writes while the leader changes, even with 2 or more Keycloak replicas. Upgrade in a quiet window. Keycloak does not use the `vector` extension; if you created it yourself in a database, run `ALTER EXTENSION vector UPDATE;` there after the upgrade. If your values set `postgresHA.image`, set it to the `0.9` tag: tags `0.1` to `0.7` are refused at render.

## Upgrading from 1.4.0

`postgres.credentials` was removed: the database credentials are now a prerequisite secret, the same one the database templates require on their own. Carrying the old key forward fails the render.

1.4.0 created the database secret itself, so **this upgrade deletes it**. Before upgrading, create a secret under a **new** name holding the values your database was initialized with — not new ones, or Keycloak loses its database connection:

```bash
cpln secret create-dictionary --name RELEASE_NAME-keycloak-db \
  --entry username=keycloak --entry password='YOUR_CURRENT_PASSWORD' --entry database=keycloak
```

Your current values are in `postgres.credentials` of the 1.4.0 release, and also in the old secret (`cpln secret reveal my-keycloak-db-credentials -o yaml`, or the name your release set in `credentialsSecretName`) until the upgrade deletes it. Then upgrade with `postgresHA.config.credentialsSecretName` (HA mode) or `postgres.config.credentialsSecretName` (single-instance mode) set to the new name, and `postgres.credentials` removed.

The upgrade restarts the bundled PostgreSQL too (it now reads the new secret), so Keycloak can briefly lose its database; it reconnects by itself. The new version of a workload can also wait about 10 minutes with `is not allowed to reveal the secret` in `get-deployments`, while access to the new secret propagates; the previous version keeps serving meanwhile, and it clears by itself.

## Upgrading from 1.3.1

Resource blocks that expose both a floor and a ceiling name the ceiling `maxCpu`/`maxMemory` instead of `cpu`/`memory`. Rename those two keys in your values; an upgrade that still carries the old names is refused at render. Then follow [Upgrading from 1.4.0](#upgrading-from-140).

## Upgrading from 1.2.x

The HA store moved to `postgres-highly-available` 2.5.0, which no longer takes database credentials as values. Put the values of `postgresHA.postgres.username/password/database` **unchanged** into the database credentials secret under [Prerequisites](#prerequisites) — the password was set when the database was first initialized — set `postgresHA.config.credentialsSecretName` to its name, and delete the `postgresHA.postgres` block. With `postgresHA.backup.provider: minio`, `postgresHA.backup.minio.accessKey`/`secretKey` moved to a dictionary secret named by `postgresHA.backup.minio.credentialsSecretName` (that knob arrived in 1.3.1).

## Upgrading from 1.1.0

`postgres.config.username/password/database` were removed. Put the values your single-instance database was initialized with into the database credentials secret under [Prerequisites](#prerequisites), set `postgres.config.credentialsSecretName` to its name, and remove the three keys. With `postgres.backup.provider: minio`, `postgres.backup.minio.accessKey`/`secretKey` moved to a dictionary secret named by `postgres.backup.minio.credentialsSecretName`.

## Upgrading from 1.0.x

The bootstrap admin credentials moved out of `values.yaml` into the prerequisite dictionary secret above. Carrying either old key forward fails the render with a message naming its replacement; there are no compatibility fallbacks.

| Removed key | Now a key in the admin secret |
|---|---|
| `admin.username` | `username` |
| `admin.password` | `password` |

**An existing install's admin password does not change on upgrade.** The account already lives in the database, and `KC_BOOTSTRAP_ADMIN_*` is only consulted when no admin exists yet. Put your current credentials into the secret so the install still renders, and change the password in the Keycloak admin console. If the install is still carrying the published 1.0.x default (`change-me-keycloak-admin`), treat that password as compromised and change it in the console now.

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

Then force-redeploy `RELEASE_NAME-keycloak`, which keeps the old password until it restarts. The database itself drops connections for roughly 10–60 s at each switchover, but the app cannot open new connections from the `ALTER ROLE` until its own redeploy finishes (several minutes in all), so rotate in a quiet window. If a member stays `starting`, or `running` without `streaming` for several minutes, re-copy it from the leader. This copies the whole database, so it costs network traffic in proportion to its size:

```bash
pgx N curl -s -XPOST -d '{"force": true}' localhost:8008/reinitialize
```

## Important Notes

- **2.0.0 moves new databases to PostgreSQL 18 (HA, the default) and 19 (single-instance).** An existing HA cluster keeps PostgreSQL 17 with no action. A single-instance release from 1.x keeps PostgreSQL 18 only with `postgres.image: postgres:18` in its values; without it the database refuses to start and leaves the data untouched. See [Upgrading from 1.x](#upgrading-from-1x).
- **Create both secrets before installing.** A missing prerequisite secret leaves the workload waiting on something that does not exist, with zero log lines — see Prerequisites for how to diagnose it.
- **Rotating the database secret needs `ALTER ROLE` plus a forced redeployment** — PostgreSQL keeps the password it was initialized with, and a running workload keeps the values it started with.
- **The bootstrap admin is temporary by design** — log in, create a permanent admin, then remove the bootstrap one (Keycloak warns until you do).
- **Keep `publicAccess` enabled for browser SSO** — end-user browsers must reach Keycloak's login endpoints; disable it only for pure service-to-service deployments.
- **Do not disable the HA proxy** (`postgresHA.proxy.enabled`) — Keycloak writes through the HAProxy leader endpoint; the chart enforces this at render.
- **Scaling is operator-driven** — change `replicas` via `helm upgrade`; there is deliberately no autoscaling, so cluster membership only changes intentionally.
- **Never turn `postgresHA.multiZone` (or `postgresHA.etcd.multiZone`) off once it has been on** — the members' volumes stay in their zones, and a member whose volume is in another zone cannot be scheduled, so the rollout stops. Turning it on later is safe; keep the setting in your values file on every upgrade, and recover with an upgrade that turns it back on plus `cpln workload force-redeployment`.
- **Uninstall deletes the database volumesets** — all realms, users and sessions. Enable backups if the data matters.
- **Rotating the database password in HA mode needs a leader switchover first** — follow [Rotating the database password in HA mode](#rotating-the-database-password-in-ha-mode). A plain redeploy can promote a member still holding the old password and split the cluster.

## Links

- [Keycloak documentation](https://www.keycloak.org/documentation)
- [Server configuration reference](https://www.keycloak.org/server/all-config)
- [Caching and clustering](https://www.keycloak.org/server/caching)
