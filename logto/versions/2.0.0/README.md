# Logto

This app deploys [Logto](https://logto.io/), the open-source auth and identity platform: OIDC and OAuth sign-in pages, users, roles, organizations, connectors and a Management API, with an Admin Console to manage them. It runs two interchangeable Logto replicas on a highly available PostgreSQL by default, and creates the Admin Console account from a secret you provide.

## Architecture

- **Logto** (`RELEASE_NAME-logto`): standard workload, 2 replicas by default, serving the sign-in pages, OIDC and the Management API on port 3001. Replicas share only the database, so they are interchangeable.
- **Admin Console** (`RELEASE_NAME-logto-admin`, default on): a second workload that serves the Admin Console on its own public URL. It does not start serving until the admin account exists.
- **PostgreSQL (HA, default)**: the `postgres-highly-available` template (PostgreSQL 18 for new clusters): 3 Patroni replicas, 3 etcd replicas and an HAProxy leader endpoint Logto connects through.
- **PostgreSQL (single instance, optional)**: the `postgres` template (PostgreSQL 19) instead, for development or lighter installs.
- **Custom domains (optional)**: one `domain` resource per hostname you set, routed to the matching workload.
- **Identity + policy**: `reveal` on exactly two secrets, your admin secret and your database credentials secret.

All data, including signing keys and the admin account, lives in PostgreSQL.

## Prerequisites

**Two dictionary secrets must exist BEFORE you install.**

**1. Admin account**: Logto creates the Admin Console account from it on first boot:

```bash
cpln secret create-dictionary --name my-logto-admin \
  --entry username=admin \
  --entry password="$(openssl rand -hex 32)"
```

The username may contain letters, digits and `_`, and must start with a letter or `_`. The password needs 8 or more characters and must not be a known breached password. Read it back with `cpln secret reveal my-logto-admin -o yaml`.

**2. Database credentials**: the bundled PostgreSQL initializes with them and Logto connects with them:

```bash
cpln secret create-dictionary --name my-logto-db-credentials \
  --entry username=logto \
  --entry password="$(openssl rand -hex 32)" \
  --entry database=logto
```

All three values must be URL-safe (letters, digits, `-`, `_`, `.`). Secret names are org-wide, so give each release its own secrets.

**If either secret does not exist at install time, the deployment waits silently**: `cpln logs` returns nothing. The only signal is `status.versions[].message` in `cpln workload get-deployments RELEASE_NAME-logto --gvc GVC_NAME -o yaml`, which reads `The secret <name> no longer exists. Workload updates are paused until the secret is added or the reference to the secret removed.` Create the secret and it recovers on its own within about 10 minutes, or right away with `cpln workload force-redeployment RELEASE_NAME-logto --gvc GVC_NAME`.

**Custom domains (optional)**: the apex domain must be [registered with Control Plane](https://docs.controlplane.com/guides/configure-domain), and each hostname needs a CNAME to the GVC endpoint before you install.

**Backups (optional)**: a cloud account and bucket, as described in the [postgres-highly-available](https://docs.controlplane.com/template-catalog/templates/postgres-highly-available) template.

## Configuration

### Logto

```yaml
image: ghcr.io/logto-io/logto:1.45.0

# Logto replicas (sign-in pages, OIDC and the Management API). All state lives in
# PostgreSQL, so replicas are interchangeable. 2 keeps sign-in up through restarts and
# upgrades; 1 is the lighter shape. Allowed: 1-4.
replicas: 2

resources: # per Logto process (each replica, and the Admin Console workload)
  minCpu: 250m
  minMemory: 512Mi
  maxCpu: 1000m
  maxMemory: 1Gi
```

### Admin account

```yaml
# ─── Admin Account ────────────────────────────────────────────────────────────
# REQUIRED PREREQUISITE SECRET — CREATE IT BEFORE YOU INSTALL. A `dictionary`
# secret with exactly two keys, `username` (letters, digits, _; starts with a
# letter or _) and `password` (8+ characters; use `openssl rand -hex 32`). Logto
# creates the Admin Console account from it on FIRST boot only; later changes to
# the secret change nothing. If it does not exist the deployment WEDGES silently.
admin:
  secretName: my-logto-admin
```

### Access

```yaml
publicAccess:
  enabled: true # sign-in pages + OIDC on the canonical *.cpln.app URL; false = reach Logto only via cpln port-forward

adminConsole:
  publicAccess:
    # true = a second workload serves the Admin Console on its own *.cpln.app URL (sign-in only).
    # false = no public Console; use `cpln port-forward {release}-logto 3002:3002` instead.
    enabled: true

customDomain: # bare hostnames; the chart creates the domains (apex must be verified, CNAME required — see README)
  core: ""         # e.g. auth.example.com; empty = canonical *.cpln.app. Becomes the OIDC issuer — set it at install
  adminConsole: "" # e.g. auth-admin.example.com; needs adminConsole.publicAccess.enabled

internalAccess: # which workloads inside Control Plane can call Logto
  type: same-gvc # options: none, same-gvc, same-org, workload-list
  workloads: [] # used with workload-list
  # workloads:
  #   - //gvc/GVC_NAME/workload/WORKLOAD_NAME

webhooks:
  # true = webhooks may call workloads inside Control Plane (*.cpln.local URLs). Off, Logto
  # refuses internal addresses and sends webhooks only to public URLs.
  allowInternalTargets: false
```

### Database

Highly available PostgreSQL is the default; new clusters run PostgreSQL 18. For a lighter install, set `postgresHA.enabled: false` and `postgres.enabled: true` (PostgreSQL 19). The `backup` blocks pass through to the [postgres-highly-available](https://docs.controlplane.com/template-catalog/templates/postgres-highly-available) and [postgres](https://docs.controlplane.com/template-catalog/templates/postgres) templates.

```yaml
# ─── Database: Highly Available PostgreSQL (default) ──────────────────────────
# Deploys the postgres-highly-available template: 3 Patroni replicas, 3 etcd
# replicas, and an HAProxy leader endpoint Logto connects to. New clusters run
# PostgreSQL 18; a cluster created by an earlier version of this chart keeps
# PostgreSQL 17 (README, "Upgrading from 1.x").
postgresHA:
  enabled: true
  config:
    # REQUIRED PREREQUISITE SECRET (HA mode) — CREATE IT BEFORE YOU INSTALL. If it
    # does not exist the deployment WEDGES silently and looks like a platform fault.
    # A `dictionary` secret with exactly three URL-safe keys: username, password,
    # database. PostgreSQL reads it once, when its data is first initialized, and
    # Logto connects with the same keys. See README Prerequisites for the command.
    credentialsSecretName: my-logto-db-credentials
  replicas: 3
  image: controlplanecorporation/patroni-postgres:0.9 # PostgreSQL 18 for new clusters (bundles 14-18); tags 0.1-0.7 are refused (CVE-2026-103484)
  volumeset:
    capacity: 10 # initial capacity in GiB per replica (minimum is 10)

  backup: # pass-through to the postgres-highly-available template's backup feature
    enabled: false
    mode: logical # logical or wal-g
    resources:
      cpu: 100m
      memory: 512Mi # 128Mi OOM-kills wal-g mid-backup
    logical:
      image: ghcr.io/controlplane-com/backup-images/postgres-backup:18.2.0 # backs up PostgreSQL 17 and 18 clusters
      schedule: "0 2 * * *" # daily at 2am UTC
    walg:
      intervalSeconds: 21600 # every 6 hours
    provider: aws # Options: aws, gcp, or minio
    aws:
      bucket: my-logto-backup-bucket
      region: us-east-1
      cloudAccountName: my-logto-backup-cloudaccount
      policyName: my-logto-backup-policy
      prefix: postgres/backups
    gcp:
      bucket: my-logto-backup-bucket
      cloudAccountName: my-logto-backup-cloudaccount
      prefix: postgres/backups
    minio: # any S3-compatible endpoint, e.g. an internal MinIO template deployment
      endpoint: http://my-minio-workload:9000
      bucket: my-logto-backup-bucket
      # REQUIRED PREREQUISITE SECRET when provider is `minio` — a `dictionary`
      # secret holding exactly `accessKey` and `secretKey` (see the postgres-highly-available docs).
      credentialsSecretName: my-logto-minio-credentials
      prefix: postgres/backups
```

```yaml
# ─── Database: Single-instance PostgreSQL (dev/lightweight) ───────────────────
# Enable this and disable postgresHA for a lighter non-HA deployment.
postgres:
  enabled: false
  # PostgreSQL 19 for new installs. A release installed with an earlier version of this chart
  # has PostgreSQL 18 data: keep image: postgres:18 in your values (README, "Upgrading from 1.x").
  image: postgres:19
  upgradeHint: # how the PostgreSQL boot guard names the fix in its log; leave as is
    imageKey: postgres.image
    consoleField: "Upgrade > Database server > Postgres image"
    readme: 'README, "Upgrading from 1.x"'
  config:
    # REQUIRED PREREQUISITE SECRET (single-instance mode) — the same kind of
    # `dictionary` secret as postgresHA.config.credentialsSecretName above
    # (keys: username, password, database). Create it BEFORE you install.
    credentialsSecretName: my-logto-db-credentials
  volumeset:
    capacity: 10 # initial capacity in GiB (minimum is 10)

  backup: # pass-through to the postgres template's backup feature (Postgres 17+)
    enabled: false
    image: ghcr.io/controlplane-com/backup-images/postgres-backup:19.1.0 # PostgreSQL 19 client; also backs up a server pinned to 18
    schedule: "0 2 * * *" # daily at 2am UTC
    resources:
      cpu: 100m
      memory: 128Mi
    provider: aws # Options: aws, gcp, or minio
    aws:
      bucket: my-logto-backup-bucket
      region: us-east-1
      cloudAccountName: my-logto-backup-cloudaccount
      policyName: my-logto-backup-policy
      prefix: postgres/backups
    gcp:
      bucket: my-logto-backup-bucket
      cloudAccountName: my-logto-backup-cloudaccount
      prefix: postgres/backups
    minio:
      endpoint: http://my-minio-workload:9000
      bucket: my-logto-backup-bucket
      # REQUIRED prerequisite dictionary secret holding `accessKey` and `secretKey`,
      # only when backup is enabled with provider: minio (see the postgres template docs).
      credentialsSecretName: my-logto-minio-credentials
      prefix: postgres/backups
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

## Connecting

Logto serves two URLs. Give each audience only its own:

| Who | URL | What they do there |
|---|---|---|
| Administrators | `https://{customDomain.adminConsole}/console`, or the canonical endpoint of `RELEASE_NAME-logto-admin` + `/console` | The Admin Console: applications, users, sign-in experience, connectors, MFA, roles. Sign in with the admin secret's `username` and `password`. |
| Your app's users | `https://{customDomain.core}`, or the canonical endpoint of `RELEASE_NAME-logto` | Nothing directly: your app redirects them to Logto's sign-in and sign-up pages here and back. Opened on its own, the URL shows an error page, because no app started a sign-in. To try sign-in as a user, open `/demo-app` on this URL. |
| Your applications (OIDC) | Issuer: the users' URL above + `/oidc` (discovery at `/oidc/.well-known/openid-configuration`) | Paste the issuer, App ID and App secret from Admin Console → Applications into your app. |
| Workloads in the same GVC | `http://RELEASE_NAME-logto.GVC_NAME.cpln.local:3001` | The same endpoints over the internal network. |
| Admin Console without public access | `cpln port-forward RELEASE_NAME-logto 3001:3001 3002:3002 --gvc GVC_NAME`, then `http://localhost:3002/console` | Only with `adminConsole.publicAccess.enabled: false`. |

Find a canonical endpoint with `cpln workload get RELEASE_NAME-logto --gvc GVC_NAME -o yaml` (`status.canonicalEndpoint`).

## Upgrading from 1.x

**HA mode (the default)** moves to the `postgres-highly-available` 3.0.0 template. New clusters run PostgreSQL 18; an existing cluster keeps PostgreSQL 17 in place, because the new image (`controlplanecorporation/patroni-postgres:0.9`) bundles PostgreSQL 14 to 18 and each member runs the version of its data directory. The upgrade needs no pin. What changes:

- The database members restart one after another onto the new image (and the latest 17 minor release), so sign-in pauses briefly while the leader changes.
- If your values set `postgresHA.image`, use the `0.9` tag (`0.8` also keeps a 17 cluster running); tags `0.1` to `0.7` are refused at render.
- The default logical backup image moves to `postgres-backup:18.2.0`, which backs up 17 and 18 clusters.
- The backup identity no longer carries `cpln-connector`; your bucket-scoped IAM policy needs no change.

To move an existing HA cluster to PostgreSQL 18, copy it into a new release: follow [Upgrading an existing cluster to PostgreSQL 18](https://github.com/controlplane-com/templates/blob/main/postgres-highly-available/versions/3.0.0/README.md#upgrading-an-existing-cluster-to-postgresql-18) in the `postgres-highly-available` README, with a new Logto release (same two prerequisite secrets) in place of the second database release, and both Logto workloads stopped during the copy.

**Single-instance mode** (`postgres.enabled: true`) now installs PostgreSQL 19, while a 1.x release's database is PostgreSQL 18. A data directory only opens with its own major, and the chart never converts it in place: before PostgreSQL starts, a guard compares the two, and on a mismatch it does not start the server and changes nothing on the volume. `cpln workload get-deployments RELEASE_NAME-postgres --gvc GVC_NAME` then stays not ready, and the logs repeat `[pg-guard] REFUSING TO START` every 30 seconds:

```bash
cpln logs '{gvc="GVC_NAME", workload="RELEASE_NAME-postgres"} |= "pg-guard"' --since 15m
```

**Stay on PostgreSQL 18:** upgrade with the image pinned, and keep `postgres.image: postgres:18` in your values file for every later upgrade (`cpln helm upgrade` does not reuse the installed values). The Console upgrade wizard keeps the installed image for you (Database server, Postgres image).

```bash
cpln helm upgrade RELEASE_NAME CHART --gvc GVC_NAME -f my-values.yaml --set postgres.image=postgres:18
```

**Move to PostgreSQL 19, side by side.** Sign-in is down during the copy, and the new release gets new canonical URLs, so its OIDC issuer differs: apps configured against the old `*.cpln.app` URL need the new issuer. With custom domains the issuer stays, but a hostname belongs to one release at a time: install the new release without `customDomain`, and set it on the new release once the old one is uninstalled (step 5).

1. Stop the old Logto, so nothing writes to its database:

   ```bash
   cpln workload stop OLD_RELEASE-logto --gvc GVC_NAME
   cpln workload stop OLD_RELEASE-logto-admin --gvc GVC_NAME
   ```

2. Install this version as a NEW release in the same GVC, in single-instance mode, with the **same two prerequisite secrets** (the copy connects to the old database with the database credentials, and the copied tables keep the old admin account):

   ```bash
   cpln helm install NEW_RELEASE CHART --gvc GVC_NAME \
     --set postgresHA.enabled=false --set postgres.enabled=true \
     --set admin.secretName=my-logto-admin \
     --set postgres.config.credentialsSecretName=my-logto-db-credentials
   ```

3. Once `NEW_RELEASE-logto` is ready, stop both new Logto workloads, then replace the new, empty database with a copy of the old one, from inside the new PostgreSQL container:

   ```bash
   cpln workload stop NEW_RELEASE-logto --gvc GVC_NAME
   cpln workload stop NEW_RELEASE-logto-admin --gvc GVC_NAME
   cpln workload exec NEW_RELEASE-postgres --gvc GVC_NAME --container postgresql -- bash -c \
     'export PGPASSWORD="$POSTGRES_PASSWORD"
      psql -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 -q \
        -c "DROP DATABASE \"$POSTGRES_DB\" WITH (FORCE)" -c "CREATE DATABASE \"$POSTGRES_DB\" OWNER \"$POSTGRES_USER\"" &&
      pg_dump -h OLD_RELEASE-postgres.GVC_NAME.cpln.local -U "$POSTGRES_USER" -d "$POSTGRES_DB" |
        psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -v ON_ERROR_STOP=1 -q'
   ```

   Logto connects each tenant through its own database role, and the new release created those roles with new passwords while the copied `tenants` table holds the old ones. Set the roles to the copied passwords:

   ```bash
   cpln workload exec NEW_RELEASE-postgres --gvc GVC_NAME --container postgresql -- bash -c \
     'export PGPASSWORD="$POSTGRES_PASSWORD"
      psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -qtA \
        -c "select format('"'"'ALTER ROLE %I PASSWORD %L;'"'"', db_user, db_user_password) from tenants" |
        psql -U "$POSTGRES_USER" -d postgres -v ON_ERROR_STOP=1 -q'
   ```

4. Start the new Logto, sign in to the new Admin Console with your existing admin password, and check your applications and users. Signing keys, users and applications come with the database.

   ```bash
   cpln workload start NEW_RELEASE-logto --gvc GVC_NAME
   cpln workload start NEW_RELEASE-logto-admin --gvc GVC_NAME
   ```

5. Point your apps at the new issuer, then uninstall the old release (this deletes its volumes). With custom domains, upgrade the new release with the `customDomain` values the old one had instead; the issuer then stays the same.

## Important Notes

- **2.0.0 moves new databases to PostgreSQL 18 (HA, the default) and 19 (single-instance).** An existing HA cluster keeps PostgreSQL 17 with no action. A single-instance release from 1.x keeps PostgreSQL 18 only with `postgres.image: postgres:18` in its values; without it the database refuses to start and leaves the data untouched. See [Upgrading from 1.x](#upgrading-from-1x).
- The admin secret is read once, when the database is first initialized. Afterwards change the admin password in the Admin Console; editing the secret changes nothing. There is no supported reset for a lost admin password, so store it safely.
- Choose `publicAccess` and the custom domains at install: the public URL is the OIDC issuer, and changing it later breaks every app configured against it.
- First boot needs outbound HTTPS to `api.pwnedpasswords.com`: Logto checks the admin password against known breaches and refuses it if the check cannot run.
- To send verification and sign-in emails, add an email connector (SMTP or a provider) under Admin Console → Connectors. Logto reaches the mail server over outbound TCP, which the template allows.
- Webhooks are sent only to public URLs unless `webhooks.allowInternalTargets` is on. Turning it on lets anyone who can manage webhooks (Console admin, or an app with Management API access) make Logto call any workload it can reach inside Control Plane; leave it off unless you need internal receivers.
- With the public Admin Console on, a Console opened through `cpln port-forward` can sign in but cannot load data. Use the public Console URL, or turn the public Console off.
- With custom domains set, give users the domain URLs: the `*.cpln.app` URLs still answer, but the Admin Console's one then serves the sign-in service instead of the Console.
- Uninstalling removes the domain resources. Reinstalling recreates them, and no re-verification is needed while the apex domain stays registered.
- A database failover interrupts sign-in for about a minute while PostgreSQL promotes a new leader; Logto reconnects on its own.
- The first `helm upgrade` after an install can restart the bundled database, which briefly interrupts sign-in.
- Use a single-location GVC: the bundled database runs in one location.
- Uninstalling deletes the database volumes, and with them every user and signing key.
- The open-source edition has one Admin Console account; inviting more admins is a paid Logto feature.

## Links

- [Logto documentation](https://docs.logto.io/)
- [Logto OSS configuration](https://docs.logto.io/concepts/core-service/configuration)
- [Integrate an app with Logto](https://docs.logto.io/quick-starts)
- [Logto on GitHub](https://github.com/logto-io/logto)
