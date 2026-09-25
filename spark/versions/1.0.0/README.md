# Apache Spark

Deploys an Apache Spark standalone cluster — a master (cluster manager + Web UI), a horizontally-scalable worker tier, an optional Spark Connect gRPC server, and an optional object-storage-backed History Server. A distributed engine for batch ETL, large-scale data transformation, and SQL/DataFrame analytics.

## Architecture

- **Master** — cluster manager and Web UI (:8080), cluster RPC (:7077). Fixed single replica.
- **Worker** — executor host tier, Web UI (:8081). `workers.replicas` (default 1); >1 forms a multi-worker cluster.
- **Spark Connect** (optional) — gRPC server (:15002) for thin/remote client submission. Default off.
- **History Server** (optional) — Web UI (:18080) that reads completed applications' event logs back from an S3/GCS bucket. Default off; requires object storage.
- **identity + policy** — shared by all workloads; carries the cloud-account binding (keyless) when the History Server is on, and `reveal` on the rendered config secret.
- **config secret** — a rendered `spark-defaults.conf` (reverse proxy, pinned RPC ports, event-log + S3A config).

No GVC and no persistent volume are created. The S3/GCS bucket and cloud account are **user-created prerequisites** when the History Server is enabled.

## Prerequisites

- **Default install:** none.
- **History Server (`historyServer.enabled: true`):** an object-storage bucket and a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account) — AWS S3 or GCS. See **Storage setup**.

## Configuration

### Image

```yaml
image: apache/spark:4.0.4-scala2.13-java17-python3-ubuntu
```

### Workers

```yaml
workers:
  replicas: 1        # 1 = proven single shape; >1 forms a multi-worker cluster
  cores: 2           # cores this worker offers to the cluster (SPARK_WORKER_CORES)
  memory: 2g         # memory offered to executors (keep below maxMemory)
  minCpu: 500m
  maxCpu: 2
  minMemory: 1Gi
  maxMemory: 4Gi
```

### Master / Spark Connect / History Server

Each tier exposes `minCpu`/`maxCpu`/`minMemory`/`maxMemory`. Connect and the History Server are off by default:

```yaml
master:
  minCpu: 250m
  maxCpu: 1
  minMemory: 512Mi
  maxMemory: 1Gi

connect:
  enabled: false     # true starts a Spark Connect gRPC server on :15002
  minCpu: 250m
  maxCpu: 1
  minMemory: 512Mi
  maxMemory: 1Gi

historyServer:
  enabled: false     # true starts the History Server on :18080 — requires storage.* + a bucket
  minCpu: 250m
  maxCpu: 1
  minMemory: 512Mi
  maxMemory: 1Gi
```

### Object storage (required when `historyServer.enabled`)

Keyless (UCI) — no access keys in values. See **Storage setup** for the per-provider steps.

```yaml
storage:
  provider: aws              # aws | gcp
  bucket: my-spark-events    # bucket you created for event logs
  prefix: spark/events       # folder within the bucket
  region: us-east-1          # aws only
  cloudAccountName: my-spark-cloud-account   # cpln cloud account linked to your provider
  policyName: my-spark-events-policy         # aws only: bucket-scoped IAM policy name
```

### Extra Spark configuration

```yaml
sparkDefaults: {}
  # spark.sql.shuffle.partitions: "200"   # merged verbatim into spark-defaults.conf
```

### Access

```yaml
internalAccess:
  type: same-gvc      # same-gvc (recommended) | same-org | workload-list
  # workloads:        # only when type is workload-list — MUST include the cluster's own workloads
  #   - //gvc/GVC/workload/WORKLOAD

publicAccess:
  enabled: false      # true exposes the Master + History Web UIs publicly — NO AUTH; see notes
```

## Submitting jobs

Submit from the master container or any client workload in the GVC. **A driver must advertise its pod IP** — set `spark.driver.host`, or executors cannot connect back to it and the job stalls relaunching executors:

```bash
cpln workload exec RELEASE-spark-master --gvc GVC --container spark-master -- bash -c '
  export SPARK_LOCAL_IP=$(hostname -i)
  /opt/spark/bin/spark-submit \
    --master spark://RELEASE-spark-master.GVC.cpln.local:7077 \
    --conf spark.driver.host=$SPARK_LOCAL_IP \
    --class org.apache.spark.examples.SparkPi \
    /opt/spark/examples/jars/spark-examples_2.13-4.0.4.jar 20'
```

## Connecting

| Target | Endpoint | Notes |
|---|---|---|
| Cluster RPC (submit) | `RELEASE-spark-master.GVC.cpln.local:7077` | `spark://…:7077`; internal |
| Master Web UI | `RELEASE-spark-master.GVC.cpln.local:8080` | worker + app UIs proxied behind it |
| Spark Connect | `sc://RELEASE-spark-connect.GVC.cpln.local:15002` | when `connect.enabled` |
| History Server | `RELEASE-spark-history.GVC.cpln.local:18080` | when `historyServer.enabled` |

Reach a private UI in a browser with `cpln port-forward RELEASE-spark-master 8080:8080 --gvc GVC` (and `RELEASE-spark-history 18080:18080`). There are no credentials — Spark's Web UIs and cluster port are unauthenticated.

## Storage setup

The History Server reads completed applications' event logs from a bucket that the cluster's driver tiers also write to. Access is keyless — the workload identity federates with your cloud account; no keys are stored in values.

### AWS S3

1. Create your bucket; set `storage.bucket` and `storage.region`.
2. If you do not have one, create a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account) for AWS; set `storage.cloudAccountName`.
3. Create an AWS IAM policy scoped to the bucket (replace `YOUR_BUCKET_NAME`), and set `storage.policyName` to its name:

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

### GCS

1. Create your bucket; set `storage.bucket` and `storage.provider: gcp`.
2. Create a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account) for GCP; set `storage.cloudAccountName`.
3. Grant the created GCP service account the **Storage Admin** (`roles/storage.objectAdmin`) role on the bucket. `policyName` and `region` are not used for GCP.

## Important Notes

- **No authentication anywhere by default** — every Web UI and the cluster port are open to whoever can reach them. Keep `publicAccess: false` and reach UIs via `cpln port-forward`. Setting `publicAccess: true` puts the unauthenticated Master and History UIs on the public internet.
- **A driver must set `spark.driver.host` to its pod IP** (see Submitting jobs) — without it the driver advertises a non-routable pod hostname and the job stalls relaunching executors.
- **History Server needs object storage before it shows anything** — enable `historyServer.enabled` AND set `storage.*` to a real bucket + cloud account, or the workload wedges. An empty History Server list is normal until a job completes; the connector jars are downloaded from Maven Central at container start, so first boot takes longer when it is enabled.
- **A missing prerequisite wedges the deploy silently** — `cpln logs` shows nothing; read `status.versions[].message` via `cpln workload get-deployments RELEASE-spark-history --gvc GVC -o yaml`.
- **Provider switch (aws↔gcp) needs a fresh install**, not an upgrade — cloud-binding blocks on an identity are never cleared on update.
- **`internalAccess.type: workload-list` must include the cluster's own workloads** — the master, workers, and Connect address each other over the GVC network. `same-gvc` (the default) avoids this.
- **Worker spill is ephemeral** and `workers.memory` is Spark's offer to executors, not the container limit — keep it below `workers.maxMemory`. Master loss is minutes of downtime, not data loss (no HA in v1).

## Links

- [Spark Standalone mode](https://spark.apache.org/docs/latest/spark-standalone.html)
- [Monitoring / History Server / event logs](https://spark.apache.org/docs/latest/monitoring.html)
- [Spark Connect overview](https://spark.apache.org/docs/latest/spark-connect-overview.html)
- [Submitting applications](https://spark.apache.org/docs/latest/submitting-applications.html)
- [Hadoop-AWS S3A](https://hadoop.apache.org/docs/r3.4.1/hadoop-aws/tools/hadoop-aws/index.html)
