# pgvector — Maintainer Briefing

## What it is
- PostgreSQL 18 with **pgvector 0.8.6** — the extension adding a `vector` column type and approximate nearest-neighbour indexes (`hnsw`, `ivfflat`), i.e. similarity search over AI embeddings — pre-installed **and pre-created**. Single instance on a persistent volume.
- License: **PostgreSQL License** (permissive; free to self-host, nothing to buy or register).
- Added for variety alongside `qdrant` / `weaviate`; it replaces or deprecates nothing.

## Common use cases
- RAG (retrieval-augmented generation) where the team wants embeddings in the same database as their relational data.
- Semantic / similarity search: recommendations, dedupe, "find things like this".
- A drop-in target for LangChain / LlamaIndex / Spring AI, all of which speak pgvector natively.

## Architecture on cpln
| Resource | Purpose |
|---|---|
| stateful workload `{release}-pgvector` | PostgreSQL 18 + pgvector 0.8.6 on 5432, pinned to 1 replica |
| volumeset `{release}-pgvector-vs` | `PGDATA`, ext4, SSD, 10 GiB default, 7-day final snapshot, optional autoscaling |
| opaque secret `{release}-pgvector-init` | first-boot SQL mounted at `/docker-entrypoint-initdb.d/00-pgvector.sql` — this is what runs `CREATE EXTENSION` |
| identity + policy | `reveal` on the user's credentials secret + the init secret (+ MinIO creds when used); cloud binding only when backups are on |
| serverless workload `{release}-pgbouncer` (optional) | connection pooler |
| cron workload `{release}-pgvector-backup` (optional) | nightly `pg_dumpall` → S3 / GCS / MinIO |

- Same family as `postgis` / `timescaledb`: a Postgres template differing only by image. Creates no GVC; touches no cloud resource unless `backup.enabled`.
- Deviations from `postgis` worth knowing: no chart-created `-config` dictionary secret (backup settings go straight into the cron env, per `postgres` 3.4.1), PgBouncer is included, and `publicAccess` is offered (default off).

## Key knobs (shipped defaults)
`image` `pgvector/pgvector:0.8.6-pg18` | `config.credentialsSecretName` `my-pgvector-credentials` (**must exist before install**) | `config.extraExtensions` `[]` (first boot only) | `resources` 300m/512Mi → 1000m/2048Mi | `volumeset.capacity` `10` | `internalAccess.type` `same-gvc` | `publicAccess.enabled` `false` | `pgbouncer.enabled` `false` | `backup.enabled` `false` (`aws` | `gcp` | `minio`)

## Troubleshooting / considerations
- **The image does NOT create the extension — this template does.** The pgvector image only installs the extension files (verified against the `v0.8.6` Dockerfile: `make install`, no initdb script). This is the opposite of the timescaledb image, so reasoning by analogy from that sibling gets it wrong. If the extension is missing, check the init secret exists and that the volume was empty at first boot.
- **Init scripts run only when `PGDATA` is empty**, so `config.extraExtensions` and the credentials apply at first boot and never again. Adding one later is one statement: `CREATE EXTENSION IF NOT EXISTS pg_trgm;`.
- **Bad `extraExtensions` name → one crash, then a healthy server missing that extension.** Measured locally on the pinned image: `initdb` writes `PG_VERSION` before the init file runs, `ON_ERROR_STOP=1` exits the container (code 3), and the next start logs `Skipping initialization`. Because `vector` is emitted first and psql autocommits, `vector` survives — the half-state is milder than a total loss, but the offending extension is simply absent.
- **The readiness probe uses `pg_isready -h 127.0.0.1` on purpose.** Measured: mid-init, bare (unix-socket) `pg_isready` returns rc=0 while TCP returns rc=2, because the entrypoint's temporary bootstrap server binds the socket only. A socket probe would report ready before `CREATE EXTENSION` ran. Budget is 15s + 18×10s.
- **`vector` indexes cap at 2,000 dimensions** (`halfvec` 4,000). 1,536-dim embeddings are fine; 3,072-dim ones are not indexable as `vector`.
- **PgBouncer in `transaction` mode LEAKS session GUCs between clients** — this is an isolation hazard, not a tuning one. Measured with 16 concurrent clients: 5 kept their own `hnsw.ef_search`, **9 read another client's value**, 2 errored with `unrecognized configuration parameter`. Direct connections do not leak; `poolMode: session` and `SET LOCAL` inside a transaction were both clean 16/16. It bites this template specifically because `ef_search` is the recall knob (400 took an exact-match test from 4/5 to 5/5). PgBouncer is off by default, so this is opt-in.
- **A missing prerequisite secret wedges the deployment silently** — `cpln logs` returns zero lines. The only diagnostic is `status.versions[].message` from `cpln workload get-deployments` (plain `get` has no `versions` key). Self-heals in ~6–10 min, or force a redeployment.
- **Rotating the credentials secret does nothing on its own, twice over**: the values are read only when `PGDATA` is empty, *and* a `cpln://` reference is not re-resolved without a forced redeployment.
- **Do not scale this workload.** A second stateful replica gets its own volume — a second empty database. HA lives in `postgres-highly-available`, whose image carries pgvector **0.8.0 on PostgreSQL 17** (vs 0.8.6 on 18 here); both index types exist there, so the delta is fixes, not features. The README states both deltas.
- **A `helm upgrade` is a planned write outage** — `maxUnavailableReplicas` is dropped by the API on stateful workloads, so nothing limits the rollout. The chart deliberately renders **no `rolloutOptions` block at all**; measured on a live stateful workload that the API then stores none (no `terminationGracePeriodSeconds: 90` backfill), which is the drift-free choice.
- **Restores need a pgvector image.** `pg_dumpall` output contains `CREATE EXTENSION IF NOT EXISTS vector`, so replaying into a stock `postgres:18` fails. Match `backup.image` to the server major (`18.1.0` = PG18).
- **Switching `backup.provider` on an existing release leaves the old cloud binding attached** — the API merges identity blocks and never removes them. Uninstall/reinstall to change providers cleanly.
- **Base OS is Debian bookworm**, while our `postgres` template's `postgres:18` is trixie. Moving one volume between those images produces a collation-version mismatch warning and wants a `REINDEX`. `0.8.6-pg18-trixie` exists if base parity is ever wanted.
- **Icon:** pgvector publishes no logo — the GitHub org avatar is a blank blue square and the repo contains no image assets — so the icon is the official PostgreSQL mark (Slonik) cropped from this repo's own `postgres/icon.png`, deliberately without the "PostgreSQL" wordmark so the card is not confused with the three templates that ship the full lockup.
