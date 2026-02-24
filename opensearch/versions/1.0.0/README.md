## OpenSearch

Creates an OpenSearch cluster with a dedicated volume set, optional Dashboards UI, optional demo log ingestion, and automated snapshot backups to S3 or GCS.

### Configuration

Key values to set before installing:

| Value | Description |
|---|---|
| `replicas` | Number of OpenSearch nodes (default: 3) |
| `clusterName` | OpenSearch cluster name |
| `resources.cpu` | CPU per replica |
| `resources.memory` | Memory per replica |
| `volumeset.capacity` | Storage per volume in GiB (minimum 10) |
| `internal_access.type` | Internal firewall to OpenSearch (`same-gvc`, `same-org`, or `workload-list`) |
| `dashboard.enabled` | Enable the OpenSearch Dashboards UI |

The dashboard is set to block all traffic, access the dashboard securely by port forwarding to it.

### Demo Logs

The demo logs option deploys a log generator workload that continuously ships sample log data into your OpenSearch cluster using Fluent Bit. This is provided for quick visualization via OpenSearch and it's dashboard and also how to configure Fluent Bit to tail your app and forward logs to OpenSearch.

To enable it, set:

```yaml
demoLogs:
  enabled: true
```

Once the setup workload has finished its job, you can disable it to reduce resource usage:

```yaml
demoLogs:
  remove_setup_workload: true
```

Upgrade the template after making this change.

### Backups

Set your desired backup schedule in the values file and configure your AWS S3 or GCS bucket. You can also set a prefix where your snapshots will be stored in the bucket.

To enable backups, set `backup.enabled: true` and choose a `provider` (`aws` or `gcp`).

#### AWS S3

For the backup workload to have access to an S3 bucket, ensure the following prerequisites are completed in your AWS account before installing:

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

#### GCS

For the backup workload to have access to a GCS bucket, ensure the following prerequisites are completed in your GCP account before installing:

1. Create your bucket. Update the value `bucket` to include its name.

2. If you do not have a Cloud Account set up, refer to the docs to [Create a Cloud Account](https://docs.controlplane.com/guides/create-cloud-account). Update the value `cloudAccountName`.

**Important**: You must add the `Storage Admin` role to the created GCP service account.

#### Disabling the Backup Setup Workload

The backup configuration is performed by a one-time setup workload that calls the OpenSearch API to register the snapshot repository and creates the snapshot policy. Once it has run successfully, you can remove it to reduce resource usage:

```yaml
backup:
  remove_setup_workload: true
```

Upgrade the template after making this change.

### Restoring a Snapshot

OpenSearch snapshots are stored as raw index data in your bucket, not as portable SQL dumps. Restoration is done through the OpenSearch API from any workload in the same GVC that can reach port 9200.

**List available snapshots:**

```sh
curl http://WORKLOAD_NAME:9200/_snapshot/backup-repo/_all?pretty
```

**Restore a specific snapshot** (restores all indices by default):

```sh
curl -X POST \
  'http://WORKLOAD_NAME.cpln.local:9200/_snapshot/backup-repo/SNAPSHOT_NAME/_restore?pretty' \
  -H 'Content-Type: application/json' \
  -d '{
    "indices": "*",
    "ignore_unavailable": true,
    "include_global_state": false
  }'
```

**Check restore progress:**

```sh
curl http://WORKLOAD_NAME:9200/_cat/recovery?v
```

> **Note:** You cannot restore a snapshot into an index that is currently open. Either delete the existing index first or restore into a new index name using the `rename_pattern` and `rename_replacement` options in the restore request.

## Supported External Services

- [OpenSearch Documentation](https://docs.opensearch.org/latest/)