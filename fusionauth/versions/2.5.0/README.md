# FusionAuth

FusionAuth is a modern, self-hosted identity and access management platform that provides user authentication, authorization, and secure single sign-on. It supports protocols such as OAuth2, OpenID Connect, and SAML. This template deploys FusionAuth with a bundled PostgreSQL database.

## Architecture

- **FusionAuth workload** — the identity provider, publicly reachable by default so applications can redirect users to it.
- **Bundled PostgreSQL** — deployed from the `postgres` template as a dependency, holding all FusionAuth state.
- **Database credentials secret** (dictionary) — *not created by this template*; you create it before install. Postgres initializes from it and FusionAuth connects with it.
- **Startup script secret** (opaque) — waits for PostgreSQL, then starts FusionAuth.
- **Identity and policy** — `reveal` on exactly those two secrets.
- **Backup cron** (optional) — deployed by the `postgres` template when `postgres.backup.enabled: true`.

There is no volume set on the application tier — all state lives in PostgreSQL.

## Prerequisites

**One dictionary secret must exist BEFORE you install** — the database credentials. The bundled Postgres initializes with them and FusionAuth connects with them. They are a prerequisite secret rather than values so the password never sits in plaintext in the Helm release:

```bash
cpln secret create-dictionary --name my-fusionauth-db-credentials \
  --entry username=fusionauth \
  --entry password="$(openssl rand -hex 24)" \
  --entry database=fusionauth
```

Set `postgres.config.credentialsSecretName` to that name. Secret names are org-wide, so give each fusionauth release its own secret.

- **`database` must be URL-safe** (letters, digits, `_`): FusionAuth's JDBC URL is assembled from it at container start. The snippet's hex password is URL-safe too.
- **Postgres reads the secret only when its data directory is first initialized.** To change the password later, run `ALTER ROLE` first, then edit the secret (`cpln secret edit my-fusionauth-db-credentials`), then right away force a redeployment of FusionAuth (`cpln workload force-redeployment RELEASE_NAME-fusionauth --gvc GVC_NAME`). A running workload keeps the values it started with. Do not redeploy the database: PostgreSQL reads the secret only when it is first initialized, so restarting it only adds downtime. Connections the app already has open keep working after `ALTER ROLE`; new ones fail until its redeploy finishes, so redeploy right away and rotate in a quiet window.
- **If the secret does not exist at install time the deployment wedges silently.** `cpln logs` returns zero lines — the containers never start. The only diagnostic is `status.versions[].message` in `cpln workload get-deployments RELEASE_NAME-fusionauth --gvc GVC_NAME -o yaml` (note **`get-deployments`** — plain `cpln workload get` has no `versions` key). Create the missing secret and it recovers on its own after several minutes, or skip the wait with `cpln workload force-redeployment`.
- **(Only for database backups)** an AWS S3 or Google Cloud Storage bucket and a Control Plane cloud account — see [Backing Up Postgres](#backing-up-postgres).

## Configuration

```yaml
image: controlplanecorporation/fusionauth:0.2
resources:
  cpu: 512m
  memory: 1024Mi
firewall:
  external:
    inboundAllowCIDR:
        - 0.0.0.0/0
    outboundAllowCIDR: [] # Set to 0.0.0.0/0 if communicating with an external IdP
  internal:
    type: same-gvc # options: same-gvc, same-org, workload-list
```

The `postgres` block configures the bundled database — the credentials secret it reads, resources, volume size and backups:

```yaml
postgres:
  image: postgres:18
  config:
    credentialsSecretName: my-fusionauth-db-credentials # PREREQUISITE dictionary secret (username, password, database) — must exist BEFORE install
  volumeset:
    capacity: 10 # initial capacity in GiB (minimum is 10)
  backup:
    enabled: false
    schedule: "0 2 * * *"   # daily at 2am UTC
    provider: aws # Options: aws, gcp, or minio (minio keys go in a prerequisite secret — see the postgres template README)
```

## Getting Started

1. **Automatic Database Setup**: A PostgreSQL database is automatically created and connected to FusionAuth.

    - The database credentials come from the secret you created under [Prerequisites](#prerequisites), named by `postgres.config.credentialsSecretName`.

2. **Firewall Configuration**: By default, inbound traffic is open to all (`0.0.0.0/0`). If FusionAuth needs to communicate with external Identity Providers (e.g. Google OAuth), set `firewall.external.outboundAllowCIDR` to `0.0.0.0/0` or the specific CIDRs required by your IdP.

    - Use the FusionAuth admin panel to configure your IdP after deployment.

3. **Setup and Integration**: Follow the setup wizard in the FusionAuth admin panel to create your app.

    - **Complete the setup wizard immediately after installing.** Inbound traffic is open to `0.0.0.0/0` by default and FusionAuth has no administrator until the wizard is finished, so whoever reaches it first creates that account. If you cannot complete it right away, install with `firewall.external.inboundAllowCIDR` restricted to your own address and widen it afterwards — allow a couple of minutes for a firewall change to propagate.
    - Configure your application with the corresponding `origin`, `redirect`, and `logout` URLs to your code
    - Be sure to configure your app's tenant to use the proper issuer for issuing tokens (e.g. `my-fusionauth-app.io`)

## Backing Up Postgres

Set your desired backup schedule in the values file and configure your AWS S3 or GCS bucket. You can also set a prefix where your backups will be stored in the bucket.

### AWS S3

For the cron job to have access to a S3 bucket, ensure the following prerequisites are completed in your AWS account before installing:

1. Create your bucket. Update the value `bucket` to include its name and `region` to include its region.

2. If you do not have a Cloud Account set up, refer to the docs to [Create a Cloud Account](https://docs.controlplane.com/guides/create-cloud-account). Update the value `cloudAccountName`.

3. Create a new AWS IAM policy with the following JSON (replace `YOUR_BUCKET_NAME`)

```JSON
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject",
                "s3:ListBucket",
                "s3:GetObjectVersion",
                "s3:DeleteObjectVersion",
                "s3:GetBucketLocation",
                "s3:AbortMultipartUpload",
                "s3:ListBucketMultipartUploads",
                "s3:ListMultipartUploadParts"
            ],
            "Resource": [
                "arn:aws:s3:::YOUR_BUCKET_NAME",
                "arn:aws:s3:::YOUR_BUCKET_NAME/*"
            ]
        }
    ]
}
```

4. Update `cloudAccountName` in your values file with the name of your Cloud Account.

5. Set `policyName` to match the policy created in step 3.

### GCS

For the cron job to have access to a GCS bucket, ensure the following prerequisites are completed in your GCP account before installing:

1. Create your bucket. Update the value `bucket` to include its name.

2. If you do not have a Cloud Account set up, refer to the docs to [Create a Cloud Account](https://docs.controlplane.com/guides/create-cloud-account). Update the value `cloudAccountName`.

**Important**: You must add the `Storage Admin` role to the created GCP service account.

### Restoring Backup

Run the following command from a client with access to the bucket and to the database (the internal hostname resolves only inside the GVC). `USERNAME` and `PASSWORD` are the `username` and `password` keys of your database credentials secret (`cpln secret reveal my-fusionauth-db-credentials -o yaml`).
S3
```SH
export PGPASSWORD="PASSWORD"

aws s3 cp "s3://BUCKET_NAME/PREFIX/BACKUP_FILE.sql.gz" - \
  | gunzip \
  | psql \
      --host=RELEASE_NAME-postgres.GVC_NAME.cpln.local \
      --port=5432 \
      --username=USERNAME \
      --dbname=postgres

unset PGPASSWORD
```

GCS
```SH
export PGPASSWORD="PASSWORD"

gsutil cp "gs://BUCKET_NAME/PREFIX/BACKUP_FILE.sql.gz" - \
  | gunzip \
  | psql \
      --host=RELEASE_NAME-postgres.GVC_NAME.cpln.local \
      --port=5432 \
      --username=USERNAME \
      --dbname=postgres

unset PGPASSWORD
```

## Upgrading from 2.4.1 or 2.4.0

`postgres.credentials` was removed: the database credentials are now a prerequisite secret, the same one the `postgres` template requires on its own. Carrying the old key forward fails the render.

2.4.x created the database secret itself, so **this upgrade deletes it**. Before upgrading, create a secret under a **new** name holding the values your database was initialized with — not new ones, or FusionAuth loses its database connection:

```bash
cpln secret create-dictionary --name RELEASE_NAME-fusionauth-db \
  --entry username=username --entry password='YOUR_CURRENT_PASSWORD' --entry database=test
```

(`username` and `test` were the 2.4.x defaults; use your own values if you overrode them.) Your current values are in `postgres.credentials` of the installed release, and also in the old secret (`cpln secret reveal my-fusionauth-db-credentials -o yaml`) until the upgrade deletes it. **If you installed 2.4.0 and never overrode the password, it is literally `password`** — put that in the new secret, and rotate it afterwards as described under [Prerequisites](#prerequisites).

Then upgrade with `postgres.config.credentialsSecretName` set to the new name and `postgres.credentials` removed.

The upgrade restarts the bundled PostgreSQL too (it now reads the new secret), so FusionAuth can briefly lose its database; it reconnects by itself. The new version of a workload can also wait about 10 minutes with `is not allowed to reveal the secret` in `get-deployments`, while access to the new secret propagates; the previous version keeps serving meanwhile, and it clears by itself.

## Upgrading from 2.3.x

`postgres.config.username`, `.password` and `.database` were removed. Put the values your database was initialized with into the database credentials secret under [Prerequisites](#prerequisites) (keys `username`, `password`, `database`), set `postgres.config.credentialsSecretName` to its name, and remove the three keys.

## Connecting

| What | Value |
|---|---|
| Admin UI and API | the canonical endpoint, since inbound defaults to `0.0.0.0/0` — read `status.canonicalEndpoint` from `cpln workload get RELEASE_NAME-fusionauth --gvc GVC_NAME -o yaml` |
| Internal (same GVC) | `RELEASE_NAME-fusionauth.GVC_NAME.cpln.local:9011` |
| Admin login | created by you in the setup wizard on first visit |
| Database credentials | `username` / `password` / `database` from your `postgres.config.credentialsSecretName` secret |

## Important Notes

- **Complete the setup wizard immediately after installing.** Inbound is open to `0.0.0.0/0` by default and FusionAuth has no administrator until the wizard is finished, so whoever reaches it first creates that account.
- **Create the database credentials secret before installing.** A missing prerequisite secret leaves the workloads waiting with zero log lines — see Prerequisites for how to diagnose it.
- **Rotating the database secret needs `ALTER ROLE` plus a forced redeployment** — Postgres keeps the password it was initialized with, and a running workload keeps the values it started with.
- **First boot waits on PostgreSQL by design.** The startup script polls for up to five minutes; a FusionAuth container that looks stuck early in an install is usually just waiting for the database.

## Links

- [FusionAuth Documentation](https://fusionauth.io/docs/)
- [FusionAuth setup wizard](https://fusionauth.io/docs/get-started/download-and-install/setup-wizard)
- [FusionAuth configuration reference](https://fusionauth.io/docs/reference/configuration)
- [`postgres` template README (backups, restore)](https://github.com/controlplane-com/templates/blob/main/postgres/versions/3.4.1/README.md)
