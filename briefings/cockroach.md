# CockroachDB — maintainer briefing

**What it is.** CockroachDB — distributed SQL with PostgreSQL wire compatibility — spanning one or more
locations, with a PgBouncer pooler in front and optional backups to S3/GCS. **From 2.0.0 it deploys into
an existing GVC and creates none of its own.**

**Common use cases.** Applications that want PostgreSQL semantics but must survive the loss of a whole
region, and multi-region deployments needing a single logical database rather than per-region shards.

## Architecture

| Resource | Notes |
|---|---|
| workload `-cockroach` (stateful) | nodes per location, `replicaDirect`, drain hook on shutdown |
| workload `-cockroach-pgbouncer` (standard) | connection pooler, autoscales on RPS **per location** |
| volumeset | `ext4`, one per node, 7-day snapshots |
| secrets | cockroach startup script, pgbouncer startup script, a `dictionary` db-config secret |
| workload `-cockroach-backup` (cron, optional) | `BACKUP INTO` S3/GCS; **carries no identity** — the nodes do the upload |
| identity + policy | `reveal` on this release's secrets |
| **policy `-cockroach-gvc-policy`** | **new in 2.0.0** — `view` scoped to the ONE install GVC, for the boot-time location check |

## Key knobs (shipped defaults)

| Knob | Default | Notes |
|---|---|---|
| `locations` | `[{aws-us-east-1, replicas: 3}]` | top-level from 2.0.0 (was `gvc.locations`); **single-location default**, was 3×3 |
| `image` | `cockroachdb/cockroach:v25.4.0` | `appVersion` `25.4.0`, bare — correct |
| `resources` | `cpu: 2`, `memory: 4Gi` | limit-only block, so bare names are right |
| `multiZone` | `false` | **confirm the GVC's locations support multi-zone first** — an unsupported location accepts it and wedges with no error. Isolated 2026-08-27 to *stateful + block volumeset* in `aws-us-west-2`; standard workloads and volume-less stateful ones are fine there, and east-1/east-2 are unaffected |
| `pgbouncer.enabled` | `true` | 2–4 replicas **per location** |
| `backup.enabled` / `.location` | `false` / `aws-us-east-1` | `.location` must be one of `locations` — **enforced at render** |

## What 2.0.0 changed

- **No `kind: gvc`.** `gvc.name`/`gvc.locations` removed; a render-time `fail` refuses any values file still carrying a `gvc:` key, because a `helm upgrade` across that boundary deletes the GVC and everything in it.
- **`defaultOptions.minScale/maxScale: 0`** on both the cockroach and pgbouncer workloads, with `localOptions` supplying the real counts. Closes "the GVC has a location the values do not list" by construction. Previously `defaultOptions.minScale` was `locations[0].replicas`, so an unlisted GVC location silently started **three more CockroachDB nodes** that joined the cluster.
- **PgBouncer's backend list moved out of Helm** into its own startup script, deriving from the same `CRDB_*` env the nodes use for `--join`. The two tiers can no longer disagree.
- **Boot-time GVC read** (`$CPLN_ENDPOINT/org/$CPLN_ORG/gvc/$CPLN_GVC`) — hard-fails on a node with no data, warns on one that already has data.
- **Render-time check that `backup.location` is one of `locations`.**
- **`replicas: 0` is now refused** — it used to suspend a location while still counting it as a region.

## Troubleshooting traps

- **The startup guards are the first thing to read in `cpln logs`.** Every one prints a `[cockroach]`-prefixed line naming exactly what is wrong. A node in an undeclared location exits 1; a node whose GVC lacks a declared location exits 1 only if it has no data yet.
- **`SURVIVE REGION FAILURE` used to fail silently.** It ran bare under `set -e` inside a backgrounded subshell, so a failure killed the subshell without printing an error *or* the completion line, while the install reported success and the database sat at the default zone survival goal. 2.0.0 wraps it and prints `SHOW REGIONS FROM CLUSTER` on failure. If you are debugging a 1.x cluster, check the survival goal directly — do not trust the log's silence.
- **The documented restore in 1.x could not work.** `backup.sh` runs `BACKUP INTO` with no target, i.e. a **full-cluster** backup, and 1.x told users to restore it with a bare `RESTORE FROM LATEST IN`. CockroachDB refuses a full-cluster restore on any cluster that has user databases, and this template always creates `mydb` + `myuser` on first deploy — so the documented command fails with `full cluster restore can only be run on a cluster with no tables or databases`. Measured locally. 2.0.0 documents `RESTORE DATABASE mydb ... WITH new_db_name` for a live cluster, and drop-then-restore for a full-cluster restore.
- **The cluster runs in insecure mode** — the drain hook calls `cockroach node drain --insecure`. There are no SQL credentials, so access control is `internal_access` and the GVC boundary, nothing else.
- **Survivability comes from location count.** Fewer than three locations cannot survive a region loss no matter what CockroachDB is configured to do, and 2.0.0's default is one location.
- **Env vars are `CRDB_`, not `COCKROACH_`.** The cockroach binary maps `COCKROACH_<FLAG>` onto its own flag defaults, so that namespace belongs to it. (Measured: unknown `COCKROACH_*` names are currently ignored without complaint — but the collision risk is free to avoid.) `CPLN_*` is rejected outright by the API at apply time.
- **The GVC read is bounded with `timeout`, not curl's `--retry`.** Measured in this image against an unroutable address: `--max-time 10 --retry 3 --retry-delay 2` cost **46 s per call**, because `--max-time` is per attempt. The shipped form (3 shell retries of `timeout 8 curl --max-time 6`) completes the whole guard in ~22 s worst case and still starts the node with a warning.
