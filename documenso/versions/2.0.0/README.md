# Documenso

Open-source e-signature: upload a PDF, place signature fields, send it to recipients, and get back a digitally signed PDF with an audit trail. This template deploys the Documenso server with a bundled PostgreSQL, single-instance by default and highly available behind one flag.

## Architecture

- **`{release}-documenso`** — a `standard` workload on HTTP :3000: UI, REST API, signing pages and background jobs in one image; applies database migrations on every start. Pinned to `location`.
- **`{release}-postgres`** — the bundled `postgres` template (default), PostgreSQL 19, holding all data, and the PDFs too when `storage.type: database`. A boot guard refuses to start the server on a data directory of another PostgreSQL major and leaves it untouched (see **Upgrading from 1.x**).
- **`{release}-postgres-ha` + `{release}-postgres-ha-proxy`** *(optional)* — the `postgres-highly-available` template instead: 3 Patroni replicas, 3 etcd and an HAProxy leader endpoint. New clusters run PostgreSQL 18; a cluster created by a 1.x release stays on PostgreSQL 17.
- **Identity and policy** — `reveal` on exactly the secrets Documenso reads, plus the AWS cloud-account link in keyless S3 mode.

## Prerequisites

Three secrets must exist **before** you install, in a GVC with **one location**. If a secret is missing, the deployment waits with no log lines; `cpln workload get-deployments {release}-documenso --gvc {gvc} -o yaml` names it under `status.versions[].message`.

**1. Signing certificate** — an `opaque` secret holding the base64 text of a PKCS#12 file. Use the default `openssl pkcs12 -export`, without `-legacy`. Reading the passphrase into a variable keeps it out of your shell history:

```bash
read -rs P12_PASS && export P12_PASS
openssl req -x509 -newkey rsa:2048 -nodes -keyout private.key -out certificate.crt \
  -days 730 -subj "/CN=Documenso Signing"
openssl pkcs12 -export -out certificate.p12 -inkey private.key -in certificate.crt -passout env:P12_PASS
base64 < certificate.p12 | tr -d '\n' | \
  cpln secret create-opaque --name my-documenso-signing-cert --encoding plain -f -
```

**2. Application keys** — a `dictionary`; `signingPassphrase` is the certificate's password:

```bash
cpln secret create-dictionary --name my-documenso-secrets \
  --entry nextAuthSecret="$(openssl rand -hex 32)" \
  --entry encryptionKey="$(openssl rand -hex 32)" \
  --entry encryptionSecondaryKey="$(openssl rand -hex 32)" \
  --entry signingPassphrase="$P12_PASS"
```

**3. Database credentials** — a `dictionary` the bundled PostgreSQL initializes with and Documenso connects with. All three values go into a connection URL, so keep them URL-safe:

```bash
cpln secret create-dictionary --name my-documenso-db-credentials \
  --entry username=documenso --entry password="$(openssl rand -hex 24)" --entry database=documenso
```

Optional: an S3 bucket for documents (**Storage setup**), a backup bucket, and an SMTP relay.

## Configuration

```yaml
location: aws-us-east-1        # the ONE location of your GVC that Documenso runs in
documenso:
  image: documenso/documenso:v2.22.0  # published tags carry the leading v
  replicas: 1                         # stateless; 2+ keeps the UI up through a rolling restart
  publicUrl: ""                       # empty = canonical endpoint (http://localhost:3000 when private); custom domain with scheme, e.g. https://sign.example.com
  resources: { minCpu: 500m, maxCpu: 2000m, minMemory: 1Gi, maxMemory: 2Gi }
secrets:
  name: my-documenso-secrets                         # application keys (Prerequisites 2)
signing:
  certificateSecretName: my-documenso-signing-cert   # signing certificate (Prerequisites 1)
signup:
  disabled: false        # open so you can create your account; set true right after
  allowedDomains: ""     # comma-separated, e.g. "example.com,acme.org"; empty = any
storage:
  type: database              # database (PDFs stored in PostgreSQL) | s3 (see Storage setup)
  documentSizeLimitMb: 5      # max single upload
smtp:
  enabled: false              # off = no verification or signature-request mail
  host: smtp.example.com
  port: 587
  secure: false               # false = STARTTLS/plain (587); true = implicit TLS (465)
  fromAddress: documenso@example.com   # read even with SMTP off
  fromName: Documenso
  auth: { secretName: "" }    # optional dictionary with username + password, e.g. my-documenso-smtp
telemetry: { enabled: false }     # true = upstream's PostHog startup event and hourly heartbeat
publicAccess: { enabled: true }   # signers are external, so signing links need the public endpoint
internalAccess:
  type: same-gvc              # none | same-gvc | same-org | workload-list
  workloads: []               # workload-list only; this release's own workloads are always added
```

### Database

```yaml
# set postgresHA.enabled: true (and postgres.enabled: false) for near-zero-downtime upgrades and failover
postgres:
  enabled: true
  image: postgres:19            # new installs; keep postgres:18 when upgrading a 1.x release (Upgrading from 1.x)
  config: { credentialsSecretName: my-documenso-db-credentials }   # Prerequisites 3
  volumeset: { capacity: 10 }   # GiB (minimum 10); raise it for `database` storage
  backup: { enabled: false }    # scheduled pg_dump; provider aws | gcp | minio, schedule "0 2 * * *"
postgresHA:
  enabled: false
  config: { credentialsSecretName: my-documenso-db-credentials }   # same shape, in HA mode
  replicas: 3                   # new clusters PostgreSQL 18; a 1.x cluster stays on 17
  backup: { enabled: false }    # mode logical (logical.schedule) | wal-g (walg.intervalSeconds)
```

The full `backup` blocks in `values.yaml` pass straight through to the `postgres` and `postgres-highly-available` templates, whose READMEs carry the bucket, cloud account and IAM policy setup and the restore steps. With `storage.type: s3` a database backup holds only object keys, so protect the bucket too (versioning or replication).

## Storage setup

Only for `storage.type: s3`. Both paths set `storage.s3.bucket` and `storage.s3.region`.

**AWS S3 (keyless)** — create the bucket and a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account) for the AWS account, and set `storage.s3.cloudAccountName`. Create this IAM policy (replace `YOUR_BUCKET_NAME`), set `storage.s3.policyName` to its name, and leave `storage.s3.auth.secretName` empty.

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"],
    "Resource": ["arn:aws:s3:::YOUR_BUCKET_NAME", "arn:aws:s3:::YOUR_BUCKET_NAME/*"]
  }]
}
```

**S3-compatible (MinIO, SeaweedFS, Google Cloud Storage)** — create the bucket, set `storage.s3.endpoint` with its scheme and fully qualified host (`http://{release}-minio.{gvc}.cpln.local:9000`, or `https://storage.googleapis.com` with region `auto`), set `storage.s3.forcePathStyle: true`, then create the keys secret and set `storage.s3.auth.secretName` to it. For GCS the keys are an [HMAC key](https://cloud.google.com/storage/docs/authentication/hmackeys) with Storage Object Admin on the bucket.

```bash
cpln secret create-dictionary --name my-documenso-s3-keys \
  --entry accessKeyId=ACCESS_KEY --entry secretAccessKey=SECRET_KEY
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

## Upgrading from 1.x

**Highly available database (`postgresHA.enabled: true`):** a plain upgrade works, and the cluster stays on PostgreSQL 17, the major it was created with; new HA releases start on PostgreSQL 18. Moving an existing cluster to 18 is a copy into a new release: see [Upgrading an existing cluster to PostgreSQL 18](https://github.com/controlplane-com/templates/blob/main/postgres-highly-available/versions/3.0.0/README.md#upgrading-an-existing-cluster-to-postgresql-18) in the postgres-highly-available template.

**Single-instance database (`postgres.enabled: true`, the default):** new installs run PostgreSQL 19. A 1.x release's data directory was created by PostgreSQL 18 (or the major of the `postgres.image` it ran), and a data directory only opens with its own major. The chart never converts data in place: before PostgreSQL starts, a guard compares the two majors, and on a mismatch it does not start the server and changes nothing on the volume. `{release}-postgres` then stays not ready, Documenso stays not ready without its database, and the logs repeat `[pg-guard] REFUSING TO START` with the exact `--set postgres.image=...` to run.

```bash
cpln logs '{gvc="GVC_NAME", workload="RELEASE_NAME-postgres"} |= "pg-guard"' --since 15m
```

**Stay on PostgreSQL 18:** run the upgrade with the image pinned, and keep `postgres.image: postgres:18` in your values file for every later upgrade (`cpln helm upgrade` does not reuse the installed values). The Console upgrade wizard keeps the installed image for you.

```bash
cpln helm upgrade RELEASE_NAME CHART --gvc GVC_NAME -f my-values.yaml --set postgres.image=postgres:18
```

**Move to PostgreSQL 19, side by side** (Documenso gets a new endpoint; signing pauses during the copy):

1. Install this version as a NEW release in the same GVC with the **same** `secrets.name`, `signing.certificateSecretName` and `postgres.config.credentialsSecretName`, and the same `storage` settings. The same application keys matter: `encryptionKey` protects two-factor secrets and API tokens stored in the database. With `storage.type: s3` the documents stay in your bucket and the database holds their keys, so nothing else needs copying.
2. Stop writes to the old release by stopping its Documenso workload (`cpln workload stop OLD_RELEASE-documenso --gvc GVC_NAME`; the database keeps running).
3. Replace the new release's database with the old one, from inside the new database container. The PostgreSQL 19 `pg_dump` reads the old server, and `--clean --if-exists` first drops what the new Documenso created. With `storage.type: database` this copies the documents too:

   ```bash
   cpln workload exec NEW_RELEASE-postgres --gvc GVC_NAME --container postgresql -- bash -c \
     'PGPASSWORD="$POSTGRES_PASSWORD" pg_dump -h OLD_RELEASE-postgres.GVC_NAME.cpln.local -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists | psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -q'
   ```

4. Run `cpln workload force-redeployment NEW_RELEASE-documenso --gvc GVC_NAME`, sign in to check your documents, point signers and integrations at the new endpoint (or move your custom domain and `documenso.publicUrl`), then uninstall the old release. Signing links already sent carry the old endpoint, so resend open documents unless the domain moved with them.

## Connecting

| Target | Address | Credentials |
|---|---|---|
| Public UI and API | `status.canonicalEndpoint` of `cpln workload get {release}-documenso --gvc {gvc} -o yaml` | your account |
| Private UI | `cpln port-forward {release}-documenso 3000:3000 --gvc {gvc}`, then `http://localhost:3000` | your account |
| Internal | `http://{release}-documenso.{gvc}.cpln.local:3000` | your account |
| Health | `GET /api/health` (database and certificate), `GET /api/certificate-status` | none |
| PostgreSQL | `{release}-postgres.{gvc}.cpln.local:5432`, or `{release}-postgres-ha-proxy.{gvc}.cpln.local:5432` in HA mode | the database credentials secret |

### First run

Documenso has no admin bootstrap and requires a verified email before the first sign-in; without SMTP no verification mail is sent. Register on the public endpoint, then verify yourself and become an admin (use your credentials secret's `username` and `database`):

```bash
cpln workload exec {release}-postgres --gvc {gvc} --container postgresql -- \
  psql -U documenso -d documenso \
  -c "UPDATE \"User\" SET \"emailVerified\" = NOW(), roles = '{ADMIN}' WHERE email = 'you@example.com';"
```

In HA mode run the same `psql` in `{release}-postgres-ha`, container `patroni-postgres`, adding `-h {release}-postgres-ha-proxy.{gvc}.cpln.local`. Then sign in and close sign-up.

## Important Notes

- **Close sign-up as soon as your account exists**: set `signup.disabled: true` or `signup.allowedDomains`.
- **Check the certificate after installing**: `/api/certificate-status` must return `{"isAvailable":true}`. The boot line `Certificate not found or not readable` refers to a certificate file and can be ignored.
- **Rotating a secret does not restart Documenso**: run `cpln workload force-redeployment {release}-documenso --gvc {gvc}` afterwards. Never replace `encryptionKey`; it protects two-factor secrets and API tokens.
- **Upgrading a 1.x release with the single-instance database needs `postgres.image: postgres:18`** in your values on that and every later upgrade, or the database refuses to start (data untouched); moving the data to PostgreSQL 19 is a dump and restore into a new release. See **Upgrading from 1.x**.
- **The first `helm upgrade` can briefly restart the single-instance PostgreSQL**, and Documenso with it; use `postgresHA` when that matters.
- **Install into a GVC with one location** and set `location` to it (the default is `aws-us-east-1`): if the GVC lacks that location, Documenso runs nothing and its deployments report `deactivated because maxScale is set to 0`. The bundled PostgreSQL starts in every GVC location.
- **Without SMTP no mail is sent**: copy each signing link out of the UI and send it yourself.

## Links

- [Documenso self-hosting guide](https://docs.documenso.com/docs/self-hosting)
- [Environment variables](https://docs.documenso.com/docs/self-hosting/configuration/environment)
- [Signing certificate](https://docs.documenso.com/docs/developers/local-development/signing-certificate)
- [Documenso on GitHub](https://github.com/documenso/documenso)
