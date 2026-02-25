# FusionAuth

## Overview
FusionAuth is a modern, self-hosted identity and access management platform that provides user authentication, authorization, and secure single sign-on. It supports protocols such as OAuth2, OpenID Connect, and SAML.

### Getting Started
1. **Automatic Database Setup**: A PostgreSQL database is automatically created and connected to FusionAuth. No manual database configuration required.

2. **Identity Provider Configuration**: FusionAuth allows easy integration for Identity Providers (IdP) to your login interface. To allow sign in with Google, enable Google OAuth integration by setting `identityProviders.google.enabled: true`

    - This will automatically configure the necessary firewall rules for Google OAuth services. Use the FusionAuth admin panel to configure your IdP.

3. **Setup and Integration**: Follow the setup wizard in the FusionAuth admin panel to create your app.
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

## Additional Resources
- [FusionAuth Documentation](https://fusionauth.io/docs/)