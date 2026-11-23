# pgvector — Maintainer Briefing

## What it is
- PostgreSQL 19 (2.0.0; 18 on 1.x) with **pgvector 0.8.7** — the extension adding a `vector` column type and approximate nearest-neighbour indexes (`hnsw`, `ivfflat`), i.e. similarity search over AI embeddings — pre-installed **and pre-created**. Single instance on a persistent volume.
- License: **PostgreSQL License** (permissive; free to self-host, nothing to buy or register).
- Added for variety alongside `qdrant` / `weaviate`; it replaces or deprecates nothing.

## Common use cases
- RAG (retrieval-augmented generation) where the team wants embeddings in the same database as their relational data.
- Semantic / similarity search: recommendations, dedupe, "find things like this".
- A drop-in target for LangChain / LlamaIndex / Spring AI, all of which speak pgvector natively.

## Architecture on cpln
| Resource | Purpose |
|---|---|
| stateful workload `{release}-pgvector` | PostgreSQL 19 + pgvector 0.8.7 on 5432, pinned to 1 replica; a boot guard runs before the entrypoint (2.0.0) |
| volumeset `{release}-pgvector-vs` | `PGDATA`, ext4, SSD, 10 GiB default, 7-day final snapshot, optional autoscaling |
| opaque secret `{release}-pgvector-init` | first-boot SQL mounted at `/docker-entrypoint-initdb.d/00-pgvector.sql` — this is what runs `CREATE EXTENSION` |
| identity + policy | `reveal` on the user's credentials secret + the init secret (+ MinIO creds when used); cloud binding only when backups are on; the AWS binding carries only the user's bucket policy (`cpln-connector` removed in 1.0.3) |
| serverless workload `{release}-pgbouncer` (optional) | connection pooler |
| cron workload `{release}-pgvector-backup` (optional) | nightly `pg_dumpall` → S3 / GCS / MinIO |

- Same family as `postgis` / `timescaledb`: a Postgres template differing only by image. Creates no GVC; touches no cloud resource unless `backup.enabled`.
- Deviations from `postgis` worth knowing: no chart-created `-config` dictionary secret (backup settings go straight into the cron env, per `postgres` 3.4.1), PgBouncer is included, and `publicAccess` is offered (default off).

## Key knobs (shipped defaults)
`image` `pgvector/pgvector:0.8.7-pg19` | `config.credentialsSecretName` `my-pgvector-credentials` (**must exist before install**) | `config.extraExtensions` `[]` (first boot only) | `resources` 300m/512Mi → 1000m/2048Mi | `volumeset.capacity` `10` | `internalAccess.type` `same-gvc` | `publicAccess.enabled` `false` | `pgbouncer.enabled` `false` | `backup.enabled` `false` (`aws` | `gcp` | `minio`; `backup.image` `postgres-backup:19.1.0`)

## Troubleshooting / considerations
- **The image does NOT create the extension — this template does.** The pgvector image only installs the extension files (verified against the `v0.8.6` Dockerfile: `make install`, no initdb script). This is the opposite of the timescaledb image, so reasoning by analogy from that sibling gets it wrong. If the extension is missing, check the init secret exists and that the volume was empty at first boot.
- **Init scripts run only when `PGDATA` is empty**, so `config.extraExtensions` and the credentials apply at first boot and never again. Adding one later is one statement: `CREATE EXTENSION IF NOT EXISTS pg_trgm;`.
- **Bad `extraExtensions` name → one crash, then a healthy server missing that extension.** Measured locally on the pinned image: `initdb` writes `PG_VERSION` before the init file runs, `ON_ERROR_STOP=1` exits the container (code 3), and the next start logs `Skipping initialization`. Because `vector` is emitted first and psql autocommits, `vector` survives — the half-state is milder than a total loss, but the offending extension is simply absent.
- **The readiness probe uses `pg_isready -h 127.0.0.1` on purpose.** Measured: mid-init, bare (unix-socket) `pg_isready` returns rc=0 while TCP returns rc=2, because the entrypoint's temporary bootstrap server binds the socket only. A socket probe would report ready before `CREATE EXTENSION` ran. Startup window ≈ 15 s + 30 × 10 s = 315 s (the readiness-implied startup kill; `failureThreshold` does not count). From 2.0.0 the probe also fails while `/tmp/pg-major-guard` exists, printing its first lines.
- **`vector` indexes cap at 2,000 dimensions** (`halfvec` 4,000). 1,536-dim embeddings are fine; 3,072-dim ones are not indexable as `vector`.
- **PgBouncer in `transaction` mode LEAKS session GUCs between clients** — this is an isolation hazard, not a tuning one. Measured with 16 concurrent clients: 5 kept their own `hnsw.ef_search`, **9 read another client's value**, 2 errored with `unrecognized configuration parameter`. Direct connections do not leak; `poolMode: session` and `SET LOCAL` inside a transaction were both clean 16/16. It bites this template specifically because `ef_search` is the recall knob (400 took an exact-match test from 4/5 to 5/5). PgBouncer is off by default, so this is opt-in.
- **A missing prerequisite secret wedges the deployment silently** — `cpln logs` returns zero lines. The only diagnostic is `status.versions[].message` from `cpln workload get-deployments` (plain `get` has no `versions` key). Self-heals in ~6–10 min, or force a redeployment.
- **Rotating the credentials secret does nothing on its own, twice over**: the values are read only when `PGDATA` is empty, *and* a `cpln://` reference is not re-resolved without a forced redeployment.
- **Do not scale this workload.** A second stateful replica gets its own volume — a second empty database. HA lives in `postgres-highly-available`, whose image carries pgvector **0.8.0 on PostgreSQL 17** (vs 0.8.7 on 19 here); both index types exist there, so the delta is fixes, not features — including CVE-2026-103484, which 0.8.0 is still open to. The README states both deltas.
- **A `helm upgrade` is a planned write outage** — `maxUnavailableReplicas` is dropped by the API on stateful workloads, so nothing limits the rollout. The chart deliberately renders **no `rolloutOptions` block at all**; measured on a live stateful workload that the API then stores none (no `terminationGracePeriodSeconds: 90` backfill), which is the drift-free choice.
- **Restores need a pgvector image.** `pg_dumpall` output contains `CREATE EXTENSION IF NOT EXISTS vector`, so replaying into a stock `postgres` image fails. `backup.image` must be at least the server major: the 19.1.0 default also dumps a server pinned to -pg18, but that dump restored back into 18 can print harmless `SET` parameter errors (`18.1.0` avoids them for long-term 18 users).
- **Switching `backup.provider` on an existing release leaves the old cloud binding attached** — the API merges identity blocks and never removes them. Uninstall/reinstall to change providers cleanly.
- **Base OS is Debian bookworm**, while our `postgres` template's `postgres:18`/`19` is trixie. Moving one volume between those images produces a collation-version mismatch warning and wants a `REINDEX`. `0.8.7-pg19-trixie` exists if base parity is ever wanted.
- **Icon:** pgvector publishes no logo — the GitHub org avatar is a blank blue square and the repo contains no image assets — so the icon is the official PostgreSQL mark (Slonik) cropped from this repo's own `postgres/icon.png`, deliberately without the "PostgreSQL" wordmark so the card is not confused with the three templates that ship the full lockup.

- **Major-version guard (2.0.0).** The container command is now `/bin/bash -c <guard>` (inline, `$` doubled), ending `exec docker-entrypoint.sh postgres`, so on the pass path PostgreSQL is PID 1 as before. It compares `$PGDATA/PG_VERSION` with `postgres -V` (fallback `$PG_MAJOR`); on a mismatch it starts nothing, changes nothing, writes the refusal to `/tmp/pg-major-guard` and repeats it in the logs every 30 s. The message names the pin `--set image=pgvector/pgvector:0.8.7-pg<data major>`. A pinned re-upgrade recovers a held replica without a forced redeployment (measured on the postgres spike, ~32 s). A held container is restarted by the readiness-implied startup kill about every 5 min, and prints again on each start.
- **Upgrading a 1.x release:** a plain `cpln helm upgrade` lands on 19 and is refused (data untouched). Fix: upgrade again with `--set image=pgvector/pgvector:0.8.7-pg18`, and the user keeps it in their values (no `--reuse-values`). Moving 18 → 19 = `pg_dumpall` from the old release piped into a NEW 2.0.0 release with the SAME credentials secret (the dump carries the password hash) and the same `extraExtensions`; HNSW indexes rebuild during the restore (raise `maxMemory`). The pin is never `0.8.6` (CVE render guard).
- **Wizard:** the major is the tag's `-pgNN` part, never `imageMajor()` (which reads `0` from `0.8.7-pg19`). A computed migration keeps the installed image on upgrade from 1.x (rewriting a pre-0.8.7 official tag to 0.8.7, same suffix), and a warning rule blocks a change of the `-pgNN` major. `NOTES.txt` prints the 1.x upgrade warning unconditionally (`cpln helm` always renders `IsUpgrade` false), or a "pinned to 18" line when the image is `-pg18`.
- **Snapshots:** the volume set still has no `snapshots.schedule` (work item 5219), so only the final snapshot on uninstall is taken; the README says exactly that.

## Version history
- **1.0.1** (2026-10): pgvector 0.8.7 for CVE-2026-103484 (IVFFlat index build overflow: a user who can create an index can run code as the server). `pgvector.validateImage` refuses an official `pgvector/pgvector` tag below 0.8.7, because a wizard install stores `image` in the release values and a `helm upgrade -f` would otherwise keep 0.8.6; other registries, digests and non-version tags (`pg18`) pass. The fix is in `vector.so`, so the upgrade's restart applies it; the 0.8.6→0.8.7 extension script only rewrites comments, and `\dx` reports 0.8.6 until `ALTER EXTENSION vector UPDATE`. Trivy does not see extension versions, so OS-package counts are unchanged between the two tags (same bookworm base).

1.0.2 declares the fields the API backfills on the pgvector,PgBouncer workload(s) (`autoscaling.maxConcurrency: 0`, `scaleToZeroDelay: 300`, `target: 95`, `defaultOptions.timeoutSeconds: 5`), found by drift-diff on a template bundling 1.0.1. Its e2e drift check blocks (`driftBlocks: true`). Nothing about how it runs changes.

- **2.0.0** (2026-11): PostgreSQL 19 default (`0.8.7-pg19`), backup image `postgres-backup:19.1.0`, the major-version boot guard and guard-aware readiness probe, `NOTES.txt`, the wizard's `-pgNN` major rule plus the image-keeping migration, and a README "Upgrading from 1.x" section. Workload shape, resources, secrets and policy are unchanged; the AWS backup identity has no `cpln-connector` (dropped in 1.0.3; policyRefs = only the user's bucket-scoped policy). e2e: `fresh-is-19`, and a refused-then-pinned upgrade from 1.0.3 and 1.0.0 with a `guard-holds` check.
