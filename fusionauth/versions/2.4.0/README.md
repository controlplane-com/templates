# FusionAuth

## Overview
FusionAuth is a modern, self-hosted identity and access management platform that provides user authentication, authorization, and secure single sign-on. It supports protocols such as OAuth2, OpenID Connect, and SAML.

### Getting Started
1. **Automatic Database Setup**: A PostgreSQL database is automatically created and connected to FusionAuth. No manual database configuration required.

    - Set the credentials under `postgres.credentials` (`username`, `password`, `database`). They are used **exactly as given**, so change the password before installing.
    - This template builds a `dictionary` secret from those three values and hands the bundled Postgres its **name** — you create nothing yourself. The name comes from `postgres.config.credentialsSecretName` (default `my-fusionauth-db-credentials`).
    - Secret names are org-wide, so **give each fusionauth release its own name**. A second release left on the default name is *refused at install* (`cannot be updated because it is being managed by a different release`) and creates nothing — nothing is shared, overwritten or deleted, and the first release is unaffected.

2. **Firewall Configuration**: By default, inbound traffic is open to all (`0.0.0.0/0`). If FusionAuth needs to communicate with external Identity Providers (e.g. Google OAuth), set `firewall.external.outboundAllowCIDR` to `0.0.0.0/0` or the specific CIDRs required by your IdP.

    - Use the FusionAuth admin panel to configure your IdP after deployment.

3. **Setup and Integration**: Follow the setup wizard in the FusionAuth admin panel to create your app.
    - Configure your application with the corresponding `origin`, `redirect`, and `logout` URLs to your code
    - Be sure to configure your app's tenant to use the proper issuer for issuing tokens (e.g. `my-fusionauth-app.io`)

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