# FusionAuth

## Overview
FusionAuth is a modern, self-hosted identity and access management platform that provides user authentication, authorization, and secure single sign-on. It supports protocols such as OAuth2, OpenID Connect, and SAML.

### Architecture

- **FusionAuth workload** — the identity provider, publicly reachable by default so applications can redirect users to it.
- **Bundled PostgreSQL** — deployed from the `postgres` template as a dependency, holding all FusionAuth state.
- **Secrets** — the database credentials secret this chart creates from your values, and the startup script.
- **Identity and policy** — `reveal` on exactly those secrets.

There is no volume set on the application tier — all state lives in PostgreSQL.

### Prerequisites

None. The database is deployed and wired up for you; there is no secret to create beforehand.

### Getting Started
1. **Automatic Database Setup**: A PostgreSQL database is automatically created and connected to FusionAuth. No manual database configuration required.

    - Set the credentials under `postgres.credentials` (`username`, `password`, `database`). They are used **exactly as given**, so change `change-me-fusionauth-db` before installing. They are internal plumbing — nothing outside this release connects to that database — which is why they stay values rather than becoming a prerequisite secret.
    - This template builds a `dictionary` secret from those three values and hands the bundled Postgres its **name** — you create nothing yourself. The name comes from `postgres.config.credentialsSecretName` (default `my-fusionauth-db-credentials`).
    - Secret names are org-wide, so **give each fusionauth release its own name**. A second release left on the default name is *refused at install* (`cannot be updated because it is being managed by a different release`) and creates nothing — nothing is shared, overwritten or deleted, and the first release is unaffected.

2. **Firewall Configuration**: By default, inbound traffic is open to all (`0.0.0.0/0`). If FusionAuth needs to communicate with external Identity Providers (e.g. Google OAuth), set `firewall.external.outboundAllowCIDR` to `0.0.0.0/0` or the specific CIDRs required by your IdP.

    - Use the FusionAuth admin panel to configure your IdP after deployment.

3. **Setup and Integration**: Follow the setup wizard in the FusionAuth admin panel to create your app.

    - **Complete the setup wizard immediately after installing.** Inbound traffic is open to `0.0.0.0/0` by default and FusionAuth has no administrator until the wizard is finished, so whoever reaches it first creates that account. If you cannot complete it right away, install with `firewall.external.inboundAllowCIDR` restricted to your own address and widen it afterwards — allow a couple of minutes for a firewall change to propagate.
    - Configure your application with the corresponding `origin`, `redirect`, and `logout` URLs to your code
    - Be sure to configure your app's tenant to use the proper issuer for issuing tokens (e.g. `my-fusionauth-app.io`)

## Upgrading from 2.4.0

**Only one thing changed: the default `postgres.credentials.password` is now `change-me-fusionauth-db` instead of `password`.**

That matters because the bundled database initialized its data directory with whatever password was in force at **first boot**, and changing the value afterwards does not change the database. So:

- **If you already set your own password**, nothing changes — upgrade normally.
- **If you never overrode it**, your database's password is literally `password`. Do **one** of these before upgrading, or FusionAuth will fail to authenticate:

  1. **Keep it working as-is** — set `postgres.credentials.password: password` explicitly in your values. The upgrade is then a no-op.
  2. **Rotate it properly** (recommended — `password` was a published default, so treat it as compromised). Change it inside Postgres first, then set the value to match:

     ```sql
     ALTER ROLE username WITH PASSWORD 'YOUR-STRONG-PASSWORD';
     ```

`postgres.credentials.username` and `postgres.credentials.database` are deliberately unchanged, for the same reason — they are baked into the initialized data directory, and `database` also forms the JDBC URL.

These credentials stay plain values rather than becoming a prerequisite secret because they are genuinely internal plumbing: the chart creates the secret from them, the bundled Postgres is the only consumer, and no human ever types this password anywhere else.

## Upgrading from 2.3.x

The bundled Postgres moved to the `postgres` 3.4.1 template, which no longer takes
database credentials as values. FusionAuth absorbed that change rather than passing it
on, so **there is no new prerequisite** — only a rename:

| Removed key | Replacement |
|---|---|
| `postgres.config.username` | `postgres.credentials.username` |
| `postgres.config.password` | `postgres.credentials.password` |
| `postgres.config.database` | `postgres.credentials.database` |

Carrying an old key forward fails the render with the **Postgres template's** message,
which tells you to create a dictionary secret yourself. Ignore that advice here — this
template creates it. Move the three keys and you are done.

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
                "s3:DeleteObjectVersion"
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

Run the following command with password from a client with access to the bucket.
S3
```SH
export PGPASSWORD="PASSWORD"

aws s3 cp "s3://BUCKET_NAME/PREFIX/BACKUP_FILE.sql.gz" - \
  | gunzip \
  | psql \
      --host=WORKLOAD_NAME \
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
      --host=WORKLOAD_NAME \
      --port=5432 \
      --username=USERNAME \
      --dbname=postgres

unset PGPASSWORD
```

## Supported External Services
- [FusionAuth Documentation](https://fusionauth.io/docs/)

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

The `postgres` block configures the bundled database — its credentials, the name of the secret this chart creates from them, resources, and volume size. See [Getting Started](#getting-started) for how those credentials are used.

## Connecting

| What | Value |
|---|---|
| Admin UI and API | the workload's public endpoint, since inbound defaults to `0.0.0.0/0` |
| Internal (same GVC) | `RELEASE_NAME-fusionauth.GVC_NAME.cpln.local:9011` |
| Credentials | created by you in the setup wizard on first visit |

## Important Notes

- **Complete the setup wizard immediately after installing.** Inbound is open to `0.0.0.0/0` by default and FusionAuth has no administrator until the wizard is finished, so whoever reaches it first creates that account.
- **The database credentials are used exactly as given.** Change `change-me-fusionauth-db` before installing; they are applied when the data directory is first initialized and cannot be changed by editing values afterwards.
- **Give each release its own `postgres.config.credentialsSecretName`.** Secret names are organization-wide, so a second release left on the default is refused at install.
- **First boot waits on PostgreSQL by design.** The startup script polls for up to five minutes; a FusionAuth container that looks stuck early in an install is usually just waiting for the database.
