# Apache Spark — Maintainer Briefing

## What it is
- Apache Spark **standalone** cluster: a master (cluster manager + Web UI), a horizontally-scalable worker tier, an optional Spark Connect gRPC server, and an optional object-storage-backed History Server. Image `apache/spark:4.0.4-scala2.13-java17-python3-ubuntu` (USER 185).
- License: Apache-2.0 (permissive OSS — no paid edition, nothing gated, no registration).
- Distributed data-processing engine for batch ETL, large-scale transforms, and SQL/DataFrame analytics.

## Common use cases
- Batch ETL / large-scale data transformation over a shared cluster.
- Ad-hoc SQL / DataFrame analytics (PySpark, spark-sql) from a client in the GVC.
- Remote/thin-client job submission via Spark Connect (`sc://…:15002`, optional).
- Post-hoc job analysis via the History Server (completed apps read from a bucket).

## Architecture on cpln
| Resource | Purpose |
|---|---|
| `{release}-spark-master` (standard, 1 replica, :8080 http, :7077 tcp) | cluster manager + Web UI + RPC |
| `{release}-spark-worker` (standard, `workers.replicas`, :8081 tcp, :7078 tcp) | executor host tier |
| `{release}-spark-connect` (standard, :15002 grpc) | optional Connect server (default off) |
| `{release}-spark-history` (standard, :18080 http) | optional History Server (default off, needs a bucket) |
| secret `{release}-spark-conf` (opaque, `encoding: plain`) | rendered `spark-defaults.conf` — reverse proxy, pinned ports, event-log/S3A config. **Always rendered** (base config), not conditional |
| identity + policy (one shared pair) | `reveal` on the conf secret; carries the AWS/GCP cloud-account binding when `historyServer.enabled` |

- Standard workloads, **no volumeset, no GVC created**. Only the master (and optionally the history) UI needs ingress; private by default. The S3/GCS bucket + cloud account are **user-created prerequisites** when the History Server is on.
- Ports 8080/8081/7077/7078/7071/7072/7079/4040/15002/18080 all clear the reserved-port set.

## Key knobs (shipped defaults)
| Knob | Default | Meaning |
|---|---|---|
| `image` | `apache/spark:4.0.4-scala2.13-java17-python3-ubuntu` | one image, all tiers; `appVersion` tracks it |
| `workers.replicas` | `1` | >1 forms a multi-worker cluster (proven — tasks spread across replicas) |
| `workers.cores` / `workers.memory` | `2` / `2g` | resources each worker offers; keep `memory` below `workers.maxMemory` |
| `master/workers/connect/historyServer.{minCpu,maxCpu,minMemory,maxMemory}` | 250m–2 / 512Mi–4Gi | per-tier reservation+limit (maxCpu→cpu, maxMemory→memory) |
| `connect.enabled` | `false` | Spark Connect gRPC server on :15002 |
| `historyServer.enabled` | `false` | History Server :18080 — requires `storage.*` + a real bucket |
| `storage.provider` / `bucket` / `prefix` / `region` / `cloudAccountName` / `policyName` | `aws` / placeholders | keyless (UCI) event-log store; `region`+`policyName` are aws-only |
| `sparkDefaults` | `{}` | extra `key: value` merged verbatim into spark-defaults.conf |
| `internalAccess.type` / `.workloads` | `same-gvc` / — | `same-gvc` \| `same-org` \| `workload-list` |
| `publicAccess.enabled` | `false` | exposes the **unauthenticated** master + history UIs on `*.cpln.app` |

## Frozen pins (build-verified)
- Image `apache/spark:4.0.4-scala2.13-java17-python3-ubuntu` (Docker Hub tag confirmed present).
- S3A/AWS: `org.apache.hadoop:hadoop-aws:3.4.1` + `software.amazon.awssdk:bundle:2.24.6` (the exact `<aws-java-sdk-v2.version>` from hadoop-project 3.4.1's POM). The bundle is **558 MB** but downloads from Maven Central in ~3.5 s from AWS us-east-1.
- GCS: `com.google.cloud.bigdataoss:gcs-connector:hadoop3-2.2.29-shaded` (resolves on Maven Central; **GCS path is unverified end-to-end — see below**).

## Troubleshooting / considerations
- **No authentication anywhere by default** — every Web UI and the cluster port are open to whoever can reach them. Keep `publicAccess: false`; reach UIs via `cpln port-forward {release}-spark-master 8080:8080 --gvc {gvc}`.
- **Daemon UIs bind `0.0.0.0`; RPC advertises the pod IP via `--host`.** This is deliberate: `SPARK_LOCAL_IP` is left **unset** so the Web UI is reachable over both the mesh and port-forward (loopback). Setting `SPARK_LOCAL_IP` binds the UI to the pod IP only and **breaks port-forward** — do not "restore" it.
- **A driver MUST set `spark.driver.host` to its pod IP** (README Submitting jobs). Without it Spark reverse-resolves `SPARK_LOCAL_IP` to a non-routable pod hostname, executors cannot connect back, and the app crash-loops relaunching executors (looks like a resource problem, is a networking one).
- **History Server crash-loops if the bucket does not exist** (`UnknownStoreException`/`NoSuchBucket`) — the bucket must exist before enabling it. An empty History list is normal until a job completes.
- **Connect clients need `pandas`/`pyarrow`/`grpcio`** — the `apache/spark` image ships only the server side; a PySpark Connect client installs `pyspark[connect]` separately.
- **Provider switch (aws↔gcp) needs a fresh install**, not an upgrade — identity cloud-binding blocks never clear on update (CLAUDE.md).
- **`internalAccess.type: workload-list` must include the cluster's own workloads** — master/worker/connect address each other over the GVC network. `same-gvc` (default) avoids this.
- **REST submission port 6066 is intentionally never enabled** (unauthenticated remote code). Submit via `spark://…:7077` or Spark Connect.
- **Master loss = minutes of downtime, not data loss** — no Master HA in v1 (out of scope).

## Test evidence (2026-09-25, test-gvc, aws-us-east-1)
- Core: master + single worker register (Master JSON `aliveworkers=1`); SparkPi completed (`Pi is roughly 3.14`), 20 tasks on the worker.
- `workers.replicas: 2`: both ALIVE; SparkPi tasks split across both worker pod IPs (97 / 103).
- `connect.enabled`: PySpark Connect client from a GVC workload → `spark.range(1000).count() == 1000`.
- Reverse proxy: `GET /proxy/{workerId}/` through the master (port-forward) → 200 with worker UI content.
- History `[UNPROVEN-4]`: **jar-load PROVEN** (read AND write sides) — prelude downloaded hadoop-aws + SDK v2 bundle (size-verified); the History **daemon** (via `SPARK_DIST_CLASSPATH`) and a **user `spark-submit` driver** (via `spark.driver.extraClassPath` in spark-defaults.conf) both loaded `S3AFileSystem` + `software.amazon.awssdk.services.s3` and made a **live authenticated S3 call** (404 NoSuchBucket, not 403, not ClassNotFound). **Keyless creds PROVEN at auth level** (assumed-role vended, S3A consumed them). **NOT completed:** the full write→read-back headline (submit → event log in bucket → History UI lists it) and the History UI empty-state render — both need a **real S3 bucket the maintainer provisions** (the test cloud account `my-s3-cloudaccount` cannot create or list buckets). The GCS path was not exercised at all.
  - **Write-path note:** daemons get the S3A jars from `SPARK_DIST_CLASSPATH` (prelude); user submits from a fresh exec shell get them from `spark.{driver,executor}.extraClassPath` in the mounted spark-defaults.conf — a shell-scoped `SPARK_DIST_CLASSPATH` alone would NOT reach an exec-shell driver.
- Drift gate: no-op `helm upgrade` on the default config → every resource `Unchanged`.
