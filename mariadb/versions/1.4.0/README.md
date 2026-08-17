# MariaDB

MariaDB is a community-developed, MySQL-compatible relational database. This template deploys a single MariaDB instance on a persistent volume, with an optional phpMyAdmin console and optional scheduled dumps to S3 or GCS.

## Architecture

- **Workload** (`stateful`) — MariaDB serving TCP on port 3306, one replica.
- **Volume set** — `ext4` volume mounted at `/var/lib/mysql`, holding all database data.
- **Identity + policy** — grants the database and backup workloads `reveal` on exactly the two credential secrets you created; nothing else.
- **phpMyAdmin workload** (`serverless`, optional) — browser admin console on port 80. Off by default, and internal-only when enabled. It holds no identity and reads no secret.
- **Backup workload** (`cron`, optional) — scheduled dump to an S3 or GCS bucket via a Control Plane cloud account.
- **No template-created secret** — every credential lives in your own prerequisite secrets.

## Prerequisites

**Two secrets must exist BEFORE you install** — the deployment wedges waiting on them otherwise. Neither value passes through Helm values, so neither lands in the release.

**Application credentials** (`credentialsSecretName`) — a `dictionary` secret with exactly the keys `username`, `password` and `database`. MariaDB creates this user and this database on first boot, and this is the credential you put in your applications' connection strings:

```bash
cpln secret create-dictionary --name my-mariadb-credentials \
  --entry username=appuser \
  --entry password='YOUR-STRONG-PASSWORD' \
  --entry database=appdb
```

**Root password** (`rootPasswordSecretName`) — an `opaque` secret (`encoding: plain`) holding the MariaDB `root` password. It is kept separate from the credentials above so that sharing the application credentials with a teammate or another workload does not hand out root:

```bash
printf '%s' 'YOUR-STRONG-ROOT-PASSWORD' | cpln secret create-opaque --name my-mariadb-root-password --encoding plain -f -
```

Backups additionally require a bucket and a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account) — see **Storage setup**. Nothing else is required.

## Configuration

### Image

```yaml
image: mariadb:11
```

### Credentials

```yaml
credentialsSecretName: my-mariadb-credentials   # dictionary secret: username, password, database — must EXIST BEFORE INSTALL
rootPasswordSecretName: my-mariadb-root-password # opaque secret (encoding: plain): the root password — must EXIST BEFORE INSTALL
```

### Resources and storage

```yaml
resources:
  minCpu: 100m
  minMemory: 128Mi
  maxCpu: 250m
  maxMemory: 264Mi

timeoutSeconds: 15

volumeset:
  capacity: 10                # initial capacity in GiB (minimum is 10)
  autoscaling:
    enabled: false            # Set to true to enable autoscaling
    maxCapacity: 100          # Maximum capacity in GiB when autoscaling is enabled
    minFreePercentage: 10     # Minimum free percentage to trigger scaling when autoscaling is enabled
    scalingFactor: 1.2        # Scaling factor to determine how much to scale up when autoscaling is triggered
```

### Database access

```yaml
internalAccess:               # Which workloads may reach MariaDB on port 3306
  type: same-gvc              # options: none, same-gvc, same-org, workload-list
  workloads: []               # only used when type is workload-list
    #- //gvc/GVC_NAME/workload/WORKLOAD_NAME
```

MariaDB is never published to the internet by this template. Reach it from inside the GVC, or from outside through your own proxy.

### phpMyAdmin

```yaml
phpMyAdmin:
  enabled: false              # true deploys a phpMyAdmin console alongside the database
  image: phpmyadmin:5.2.3-apache
  publicAccess:
    enabled: false            # true publishes the console, and its login form, to the whole internet
  internalAccess:
    type: same-gvc            # options: none, same-gvc, same-org, workload-list
    workloads: []             # only used when type is workload-list
      #- //gvc/GVC_NAME/workload/WORKLOAD_NAME
  resources:
    cpu: 100m
    memory: 128Mi
```

phpMyAdmin is off by default, and internal-only when turned on. It presents a login form and you supply either the application credentials or `root` plus the root password; nothing is pre-filled, and the workload has no access to any secret. `phpMyAdmin.internalAccess` governs the console only — the database's own `internalAccess` is a separate knob.

### Backups

```yaml
backup:
  enabled: false
  image: ghcr.io/controlplane-com/backup-images/mysql-backup:1.0.0 # compatible with all MariaDB versions
  schedule: "0 2 * * *"       # daily at 2am UTC

  resources:
    cpu: 100m
    memory: 128Mi

  provider: aws               # Options: aws or gcp

  aws:
    bucket: my-backup-bucket
    region: us-east-1
    cloudAccountName: my-backup-cloudaccount
    policyName: my-backup-policy
    prefix: mariadb/backups   # folder name where your backups will be stored

  gcp:
    bucket: my-backup-bucket
    cloudAccountName: my-backup-cloudaccount
    prefix: mariadb/backups   # folder name where your backups will be stored
```

## Storage setup

Only needed when `backup.enabled: true`.

### AWS S3

1. Create your bucket. Set `backup.aws.bucket` to its name and `backup.aws.region` to its region.
2. Create a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account) for the AWS account holding the bucket, and set `backup.aws.cloudAccountName` to its name.
3. Create an IAM policy with the JSON below (replace `YOUR_BUCKET_NAME`) and set `backup.aws.policyName` to its name. The template attaches it to the workload's identity:

```json
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

### GCS

1. Create your bucket. Set `backup.gcp.bucket` to its name.
2. Create a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account) for the GCP project holding the bucket, granting its service account the **Storage Admin** role, and set `backup.gcp.cloudAccountName` to its name. The template binds `roles/storage.objectAdmin` on exactly that bucket.

## Connecting

| Path | Address | Notes |
|---|---|---|
| Database | `<release>-maria.<gvc>.cpln.local:3306` | Subject to `internalAccess.type`. |
| phpMyAdmin (internal) | `http://<release>-phpmyadmin.<gvc>.cpln.local` | Only when `phpMyAdmin.enabled: true`. |
| phpMyAdmin (public) | `https://<canonical-endpoint>` | Only when `phpMyAdmin.publicAccess.enabled: true`. Read it from `status.canonicalEndpoint` in `cpln workload get <release>-phpmyadmin -o yaml`. |
| Application credentials | your `credentialsSecretName` secret — `cpln secret reveal <name>` | Never stored in the Helm release. |
| Root password | your `rootPasswordSecretName` secret — `cpln secret reveal <name>` | Never stored in the Helm release. |

## Restoring a Backup

Run the following from a client with access to the bucket (replace `aws s3 cp` with `gsutil cp` for GCS):

```sh
aws s3 cp s3://BUCKET_NAME/PREFIX/BACKUP_FILE.gz - \
  | gunzip \
  | sed '/^SET @@GLOBAL.GTID_PURGED/d' \
  | mariadb \
      --host=WORKLOAD_NAME \
      --port=3306 \
      --user=root
```

## Important Notes

- **Create both secrets before installing** — the workload wedges waiting on a secret that does not exist, and looks broken.
- **Credentials are read only when the volume is first initialized.** Rotating either secret afterwards does not change the stored passwords; change them with `ALTER USER` inside MariaDB instead.
- **Do not scale past one replica.** This is a single-instance MariaDB on one volume; extra replicas would mount nothing and corrupt nothing usefully.
- **`phpMyAdmin.publicAccess.enabled: true` puts a database console on the internet.** Anyone reaching it needs only a valid database password to read and write everything. Prefer leaving it off and reaching the console from inside the GVC.
- **Access changes take up to a couple of minutes** to propagate after an `internalAccess` or `publicAccess` change.
- **Data lives on the volume set** and survives redeploys; `cpln helm uninstall` deletes it, taking the database with it.
- **Upgrading from 1.3.x is a breaking change.** `config.*` and `enablePhpMyAdmin` no longer exist — an install that still sets them fails at render with instructions. Create the two secrets first, and expect the credentials on an existing volume to stay whatever they already were.

## Links

- [MariaDB documentation](https://mariadb.com/docs/)
- [MariaDB Docker image](https://hub.docker.com/_/mariadb)
- [phpMyAdmin documentation](https://docs.phpmyadmin.net/)
- [Control Plane cloud accounts](https://docs.controlplane.com/guides/create-cloud-account)
