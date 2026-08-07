# DuckDB — Maintainer Briefing

## What it is
- **DuckDB** — an in-process analytical SQL engine ("SQLite for analytics") that reads and writes Parquet, CSV and JSON directly, queries object storage over the S3 API, and can `ATTACH` live PostgreSQL, MySQL and SQLite databases. MIT licensed — free, nothing to register or buy.
- This template ships it as a **scheduled batch job runner**: image `duckdb/duckdb:1.5.5`, unmodified, run as a `cron` workload that executes one SQL script and exits. **It binds no port, has no UI, and there is nothing to connect to.** The always-on alternative in the catalog is `trino`.

## Common use cases
- Nightly/hourly transforms over Parquet in object storage (raw → aggregated) that cost container-minutes instead of a standing cluster.
- Exporting or reshaping data out of an in-GVC `postgres`/`mysql` into Parquet on `seaweedfs`, MinIO or S3.
- Joining object-storage files with a live database in one script, without moving either side into a warehouse.
- Cheap scheduled data-quality checks whose output lands in the workload logs.

## Architecture on cpln
| Resource | Purpose |
|---|---|
| `{release}-duckdb` (**cron** workload, 1 replica, **no ports**) | Runs `/duckdb -batch -no-stdin -init preamble.sql -f job.sql -c "SELECT 'duckdb-job-complete'"` and exits |
| secret `{release}-duckdb-preamble` (opaque, plain) | Generated `SET` statements — `memory_limit`, `threads`, `temp_directory`, `extension_directory`, plus the S3 `CREATE SECRET` when object storage is on |
| secret `{release}-duckdb-script` (opaque, plain) | The user's SQL from `sql.inline`; **not created at all** when `sql.secretName` is set (verified) |
| identity + policy | `reveal` on exactly the secrets mounted (preamble, script, S3 creds, each `secretEnv` secret, deduplicated); AWS cloud-account binding only when `objectStore.type: aws` |

- **No volumeset, no database, no GVC.** A default install is exactly 5 resources.
- Job semantics: `concurrencyPolicy: Forbid` (runs never overlap), `restartPolicy: Never` (a failed run is not retried), `historyLimit: 5`, `capacityAI: false`, `minScale = maxScale = 1`.
- Firewall is closed in both directions inbound (`internal.inboundAllowType: none`, `external.inboundAllowCIDR: []`); outbound is `0.0.0.0/0` and is genuinely needed (see extensions below).
- Measured: **38 s** from `cpln workload cron start` to `Successful` on a default install, of which ~14 s is image pull and container start before any SQL runs.

## Where the data goes (the thing users get wrong)
- **Nothing persists between runs.** `/tmp/duckdb-extensions` and `/tmp/duckdb-temp` are container-local ephemeral scratch, and there is **no `.duckdb` file** — every run starts from an empty in-memory database.
- A job must therefore **read from object storage or an `ATTACH`ed database and write its results back to one of those**, or the work is thrown away. The default `sql.inline` is an inert self-test (`SELECT 'duckdb-template-ok', version(), now()`) that writes nothing anywhere — a "successful install" proves the plumbing, not a pipeline.
- **Every job must fit in memory.** Spill goes to `/tmp/duckdb-temp`, bounded by container disk, not by a sized volume. Size work with `resources.maxMemory`; do not plan around spill.

## Key knobs
| Knob | Default | Meaning |
|---|---|---|
| `image` | `duckdb/duckdb:1.5.5` | distroless, **no shell** — the command is pure argv, no wrapper script possible |
| `schedule` | `"0 2 * * *"` | 5-field cron in UTC, render-validated for field count; `*/5 * * * *` survives render → API → spec intact and fires on its own |
| `suspend` | `false` | `true` = never runs automatically; trigger with `cpln workload cron start {release}-duckdb` |
| `activeDeadlineSeconds` | `3600` | runaway guard; enforced with lag — see troubleshooting |
| `sql.inline` | self-test script | the script, mounted at `/etc/duckdb/job.sql` |
| `sql.secretName` | `""` | opaque prerequisite secret (encoding plain, payload = SQL); **wins over `inline`**, and the chart's own script secret is then not created |
| `secretEnv[]` | `[]` | secrets → env vars, readable as `getenv('NAME')`; validated UPPER_SNAKE_CASE, no duplicates, and the four `AWS_*` names are rejected |
| `resources.*` | 500m/2000m · 1Gi/4Gi | `minCpu`/`maxCpu` · `minMemory`/`maxMemory`; render-validated including the 4:1 cpu cap |
| `tuning.memoryLimitPercent` | `60` | render-validated 20–80; at the defaults the preamble emits `memory_limit = '2457MiB'` and `threads = 2` |
| `objectStore.type` | `none` | `none` \| `aws` (keyless, `CHAIN 'instance'`) \| `s3-compatible` (`CHAIN 'env'` from a dictionary secret with `access-key-id` / `secret-access-key`) |

Prerequisite secrets, when used, must exist **before** install: the `sql.secretName` script secret, each `secretEnv[].secretName`, and `objectStore.s3Compatible.credentialsSecretName`. Uninstall correctly leaves them in place (verified).

## Availability posture
- **Single replica, pinned, and that is inherent** — DuckDB is one process over one database, with no clustering and no failover in any edition. There is deliberately no `replicas` knob.
- Installing the template N times (different scripts, schedules, regions) is real scale-out but **is not high availability**: if tonight's container dies, tonight's job did not happen. `restartPolicy: Never` means it is not retried either.
- Nothing is stateful, so uninstall/reinstall is free — verified clean, no orphans.

## Troubleshooting / considerations
- **"It installed but nothing is listening."** Correct, and the single most likely support call. It is a cron job; no port, no endpoint, no credentials issued. Point BI-tool users at `trino`.
- **Success = the marker AND the run status. Never one alone.** `duckdb-job-complete` prints only after the script finishes cleanly (`.bail on` stops at the first error, verified: a `Catalog Error` suppressed both the marker and the following statement). But a **deadline-exceeded run printed the marker 88 s after its deadline while the platform recorded `status: failed`** — so the marker alone can pass a failed run. Check `cpln workload cron get {release}-duckdb` too.
- **`activeDeadlineSeconds` is detected on time but enforced late.** Detection was exact to the second (30 s deadline → `FailureTarget DeadlineExceeded` at +30 s), but the kill landed **91 s and 123 s later** in two observations, with the container consuming its full CPU/memory allocation throughout. Users sizing this as a cost guard should assume a ceiling of deadline + ~2 min. Two observations is a small sample and the lag is platform-side.
- **`getenv()` cannot be concatenated into an `ATTACH` string.** `ATTACH` takes a string *literal*, so `'... password=' || getenv('PGPASSWORD')` dies with `Parser Error: syntax error at or near "||"` — this shipped as the README's only worked `secretEnv` example and was fixed after testing. The working form: name the entry after the driver's own env var (`PGPASSWORD` for postgres, `MYSQL_PWD` for mysql) and leave `password=` out of the connection string. Proven end to end against an in-GVC `postgres` over service DNS. `getenv()` still works anywhere an ordinary expression is allowed.
- **Extensions re-download from `extensions.duckdb.org:443` on every run** — confirmed by two independent runs both starting with an empty extension directory and reporting `install_mode = REPOSITORY`. This is a real per-run network dependency: a job that works today fails if egress to that host is later blocked. `httpfs` autoloads on first `s3://` use with no explicit `INSTALL`.
- **DuckDB reads the HOST's RAM and core count, not the container's** (upstream #15080/#6519/#7651). Left alone it targets 80 % of a much larger machine and gets OOM-killed, so the template always sets `memory_limit` and `threads` from `resources.max*` in the same render — they cannot drift. On an OOM report, lower `tuning.memoryLimitPercent` or raise `maxMemory`; a `SET` in the user's own script also wins, because the preamble runs first.
- **The scratch paths must stay one level under `/tmp`.** DuckDB creates `temp_directory` only one level deep — `/tmp/duckdb/temp` fails at the moment a query first spills (`IO Error: Failed to create directory`), while `/tmp/duckdb-temp` spills a 30M-row sort cleanly. This is why the constants look oddly flat. Also never mount anything at `/duckdb` — that path *is* the binary.
- **No volumeset by design (maintainer ruling).** Control Plane block volumesets are accepted only by `stateful`/`vm` workloads, so a cron job could only have had a `shared` (network) volume — the wrong fit for extension cache and spill, and upstream advises against DuckDB's native format on network storage in read-write mode. The earlier spec's `/data` volume and `storage.*` knobs do not exist in the shipped chart.
- **Credentials never reach the workload spec** — verified: only `cpln://secret/...` references appear, no key material in the rendered preamble, and the policy grants `reveal` on exactly the secrets the release touches.
- **`objectStore.type: aws` was proven at build time, not in the test round.** The keyless path (`CHAIN 'instance'`, which resolves eagerly at `CREATE SECRET` so a broken identity binding fails loudly) worked against a real bucket during the build; the tested end-to-end round-trip is the `s3-compatible` branch, against in-GVC SeaweedFS with the Parquet object independently confirmed in the bucket. Treat `aws` as the less-exercised branch.
- **One script per install, by design.** Multi-step, conditional or retrying pipelines belong in `airflow` — point users there rather than growing this template.
