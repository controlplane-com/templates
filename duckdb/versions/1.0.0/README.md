# DuckDB Scheduled SQL Job

DuckDB is an in-process analytical SQL engine that reads and writes Parquet, CSV and JSON directly, queries object storage over the S3 API, and can attach live PostgreSQL, MySQL and SQLite databases. This template runs a SQL script of yours on a cron schedule and exits — **it is a batch job runner, not a query service**. Nothing listens on a port, and there is no endpoint to connect to. If you want an always-on SQL endpoint for BI tools, install `trino` instead.

## Architecture

- **Cron workload** — runs the official `duckdb/duckdb` image once per schedule and exits; no ports, no inbound traffic.
- **Preamble secret** — template-generated `SET` statements mounted at `/etc/duckdb/preamble.sql` and run before your script.
- **Script secret** — your SQL, mounted at `/etc/duckdb/job.sql`. Created from `sql.inline`, or skipped entirely when you bring your own secret via `sql.secretName`.
- **Identity + policy** — grants the job `reveal` on exactly the secrets it mounts, plus the AWS cloud-account binding when `objectStore.type: aws`.

No volume is attached. Each run starts from an empty in-memory database and writes its extensions to `/tmp/duckdb-extensions` and its scratch to `/tmp/duckdb-temp` inside the container.

## Prerequisites

None for a default install — it runs a self-test script with no credentials and no cloud account.

The job needs outbound access to `extensions.duckdb.org:443` on **every** run — see Important Notes. The template's firewall allows all outbound traffic, so this works out of the box unless your organization restricts egress.

Required only for the features you turn on:

- **`objectStore.type: aws`** — an AWS account with a bucket, a Control Plane cloud account, and a bucket-scoped IAM policy (see [Object storage setup](#object-storage-setup)).
- **`objectStore.type: s3-compatible`** — a reachable S3-compatible endpoint and a dictionary secret holding its access keys (see [Object storage setup](#object-storage-setup)).
- **`sql.secretName`** — an opaque secret containing your SQL, created before install.
- **`secretEnv[]`** — each referenced secret must exist before install.

## Configuration

### Image

```yaml
image: duckdb/duckdb:1.5.5
```

### Schedule

```yaml
schedule: "0 2 * * *" # cron expression in UTC — always quote it (e.g. "*/15 * * * *")
suspend: false # true = never run automatically; start it with `cpln workload cron start`
activeDeadlineSeconds: 3600 # a run still going after this many seconds is terminated
```

### SQL

```yaml
sql:
  inline: |
    -- Default self-test. Replace with your own transform.
    SELECT 'duckdb-template-ok' AS status, version() AS duckdb_version, now() AS run_at;
  secretName: "" # opaque secret (encoding plain, payload = SQL) used INSTEAD of inline, e.g. my-duckdb-script
```

`secretName` wins when both are set, and the inline script secret is then not created at all. Use it for scripts that are too large for a values file or that you want to update without a `helm upgrade`:

```bash
printf '%s' "SELECT 42 AS answer;" | cpln secret create-opaque --name my-duckdb-script --encoding plain -f -
```

### Credentials referenced from SQL

```yaml
secretEnv: []
# secretEnv:
#   - name: PG_PASSWORD
#     secretName: my-postgres-credentials # must exist BEFORE install
#     secretKey: password # omit for an opaque secret (uses its payload)
```

Each entry becomes a container environment variable sourced from a Control Plane secret, read in your SQL with `getenv('NAME')`. This is how an `ATTACH` of an in-GVC database gets its password without the password ever appearing in your values file:

```sql
ATTACH 'dbname=postgres user=postgres host=my-postgres.my-gvc.cpln.local password=' || getenv('PG_PASSWORD') AS pg (TYPE postgres);
COPY (SELECT * FROM pg.public.events) TO 's3://my-bucket/events.parquet' (FORMAT parquet);
```

The four AWS credential variable names are rejected here — object-store credentials are owned by `objectStore`.

### Resources

```yaml
resources:
  minCpu: 500m
  maxCpu: 2000m # also sets DuckDB threads: one per whole core, minimum 1
  minMemory: 1Gi
  maxMemory: 4Gi

tuning:
  memoryLimitPercent: 60 # DuckDB memory_limit = this percent of maxMemory (20–80)
```

DuckDB reads the host machine's RAM and core count, not the container's limits, so the template derives `memory_limit` and `threads` from these values and sets them explicitly in the preamble. At the defaults that is `memory_limit = '2457MiB'` and `threads = 2`. A `SET` in your own script still wins, because the preamble runs first.

`maxMemory` is the knob that sizes what the job can process — see Important Notes.

### Object storage

```yaml
objectStore:
  type: none # options: none, aws, s3-compatible

  aws: # keyless — credentials come from the workload identity, no keys anywhere
    region: us-east-1
    cloudAccountName: my-s3-cloud-account # must exist BEFORE install
    policyName: my-duckdb-bucket-policy # IAM policy scoped to your bucket (see README)

  s3Compatible: # SeaweedFS, MinIO, Cloudflare R2, GCS interoperability, Tigris
    endpoint: my-seaweedfs.my-gvc.cpln.local:8333 # host:port, no http:// prefix
    region: us-east-1
    urlStyle: path # options: path, vhost
    useSsl: false
    credentialsSecretName: my-duckdb-s3-credentials # dictionary secret: access-key-id, secret-access-key
```

Anything other than `none` registers a DuckDB S3 secret in the preamble, so your SQL can read and write `s3://` paths directly.

## Object storage setup

### AWS S3 (keyless)

The job gets short-lived credentials from its own workload identity — no access keys are created, stored or injected anywhere.

1. Create your bucket. Set `objectStore.aws.region` to its region.
2. If you do not already have one, create a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account) for your AWS account, and set `objectStore.aws.cloudAccountName` to its name.
3. Create an AWS IAM policy scoped to that bucket (replace `YOUR_BUCKET_NAME`):

```JSON
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:ListBucket",
                "s3:GetBucketLocation"
            ],
            "Resource": "arn:aws:s3:::YOUR_BUCKET_NAME"
        },
        {
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject"
            ],
            "Resource": "arn:aws:s3:::YOUR_BUCKET_NAME/*"
        }
    ]
}
```

4. Set `objectStore.aws.policyName` to the name of the policy created in step 3, and `objectStore.type` to `aws`.

Drop `s3:PutObject` and `s3:DeleteObject` if the job only reads.

### S3-compatible servers

Covers SeaweedFS, MinIO, Cloudflare R2, Tigris, and Google Cloud Storage through its S3 interoperability endpoint. Credentials are passed as static keys, so no Control Plane cloud account is needed.

1. Create your bucket on the server, and create an access key / secret key pair with read and write access to it.
2. Create a dictionary secret holding the pair:

```bash
cpln secret create-dictionary --name my-duckdb-s3-credentials \
  --entry access-key-id=YOUR_ACCESS_KEY \
  --entry secret-access-key=YOUR_SECRET_KEY
```

3. Set `objectStore.type` to `s3-compatible`, `credentialsSecretName` to that secret's name, and `endpoint` to the server's `host:port` — with **no** `http://` or `https://` prefix. Set `useSsl` to match.

Per-provider endpoint values:

| Provider | `endpoint` | `urlStyle` | `useSsl` |
|---|---|---|---|
| SeaweedFS in the same GVC | `my-seaweedfs.my-gvc.cpln.local:8333` | `path` | `false` |
| MinIO in the same GVC | `my-minio.my-gvc.cpln.local:9000` | `path` | `false` |
| Google Cloud Storage | `storage.googleapis.com` | `path` | `true` |
| Cloudflare R2 | `<account-id>.r2.cloudflarestorage.com` | `path` | `true` |
| AWS S3 with static keys | `s3.us-east-1.amazonaws.com` | `vhost` | `true` |

For Google Cloud Storage, the keys are HMAC keys created under Cloud Storage → Settings → Interoperability.

## Connecting

This template exposes nothing to connect to — it is a job, not a server. Observe and drive it instead:

| What | How |
|---|---|
| Public URL | None. The workload binds no port and accepts no inbound traffic. |
| Internal host:port | None. |
| Job output | `cpln logs '{gvc="GVC_NAME", workload="RELEASE_NAME-duckdb"}' --limit 200 --since 1h` |
| Success signal | The line `duckdb-job-complete` in that output. |
| Run history | `cpln workload cron get RELEASE_NAME-duckdb --gvc GVC_NAME` |
| Run it now | `cpln workload cron start RELEASE_NAME-duckdb --gvc GVC_NAME` |
| Credentials | None are issued. The job reads secrets you name in `secretEnv` and `objectStore`. |

## Important Notes

- **This is a batch job, not a query service.** Nothing is listening after install; that is correct behavior. For an always-on SQL endpoint that BI tools connect to, use the `trino` template.
- **Alert on the absence of `duckdb-job-complete`, not on the exit status.** DuckDB's CLI can exit 0 on some failed scripts ([upstream issue #16574](https://github.com/duckdb/duckdb/issues/16574)). The template sets `.bail on`, so the marker prints only after your script finishes cleanly.
- **Never `SET memory_limit` higher than the container.** Change `tuning.memoryLimitPercent` instead — the template derives the real limit from `resources.maxMemory`, and DuckDB left to itself targets 80% of the *host* machine and gets OOM-killed.
- **Every job must fit in memory.** No volume is attached, so size the work with `resources.maxMemory` (and `tuning.memoryLimitPercent`) rather than relying on spill. DuckDB's out-of-core operators still work, but they spill to container-local scratch bounded by container disk, not to a sized volume — do not plan around it.
- **No `.duckdb` database file is kept.** Every run starts from an empty in-memory database; write results to object storage or an attached database.
- **Extensions are re-downloaded on every run** from `extensions.duckdb.org:443`, since there is no cache volume. Every execution therefore depends on that host being reachable — a job that runs fine today will fail if egress to it is later blocked. `httpfs` and `aws` autoload on first use of an `s3://` path.
- **Runs never overlap** (`concurrencyPolicy: Forbid`) and a failed run is not retried (`restartPolicy: Never`) — the next scheduled run starts normally.
- **Installing this template several times is scale-out, not high availability.** N releases with different scripts or schedules run independently, but there is no failover: if tonight's container dies, tonight's job did not happen.
- **One script per install, by design.** Multi-step, conditional or retrying pipelines belong in `airflow`.

## Links

- [DuckDB documentation](https://duckdb.org/docs/stable/)
- [CLI arguments](https://duckdb.org/docs/stable/clients/cli/arguments.html)
- [Configuration reference](https://duckdb.org/docs/stable/configuration/overview.html)
- [S3 API support](https://duckdb.org/docs/stable/core_extensions/httpfs/s3api.html)
- [Tuning workloads (memory and threads)](https://duckdb.org/docs/stable/guides/performance/how_to_tune_workloads.html)
