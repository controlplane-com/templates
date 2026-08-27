# pgEdge — maintainer briefing

**What it is.** pgEdge Distributed PostgreSQL (PostgreSQL 17 + Spock 5) — multi-master logical replication
across regions, with a pgcat connection pooler in front. **From 2.0.0 this template deploys into an existing
GVC and creates none.** 1.x created its own; see the upgrade trap below, which is a data-loss path.

**Common use cases.** Read-local/write-anywhere workloads spanning regions: multi-region SaaS, low-latency
reads near users, and active-active deployments that must survive the loss of a whole region.

## Architecture

| Resource | Notes |
|---|---|
| workload `-pgedge` (stateful) | `replicas` per location, `replicaDirect` so each node is addressable |
| workload `-pgcat` (standard) | connection pooler, `minReplicas`..`maxReplicas` **per location** (2.0.0 gave it `localOptions`; before that it ran in every GVC location) |
| volumeset | per-replica storage, `ext4`, 7-day snapshots |
| secret `-startup` | pgEdge/Spock start script; topology comes from `PGEDGE_*` env, not from Helm loops (2.0.0) |
| secret `-pgcat-config` | **a startup script** from 1.1.0, not a TOML file; from 2.0.0 it also builds the `servers` list itself, in POSIX `sh`, from the same `PGEDGE_*` env |
| secret `-config` | backup destination only (1.1.0+), and only when `backup.enabled` |
| workload `-backup` (cron, optional) | `pg_dump` to S3 or GCS; `defaultOptions.suspend: true` from 2.0.0, unsuspended in `locations[0]` only |
| identity | plus the conditional `aws:`/`gcp:` cloud binding when backups are on |
| policy `-pgedge-policy` | `reveal` on this release's secrets plus the prerequisite credentials secret |
| policy `-pgedge-gvc-policy` | **new in 2.0.0** — `view` on the ONE install GVC, so a node can read its own GVC's location list at boot. Scoped with `targetLinks`, never `target: all` |

## Key knobs (shipped defaults)

| Knob | Default | Notes |
|---|---|---|
| `locations[]` | 3 locations × 3 replicas | was `gvc.locations[]`. **Every entry must exist in the GVC you install into; extra GVC locations are fine** |
| `image` | `ghcr.io/pgedge/pgedge-postgres:17-spock5-standard` | |
| `postgres.credentialsSecretName` | `my-pgedge-credentials` | **prerequisite** `dictionary` secret (1.1.0+): `username`, `password`, `database` |
| `pgcat.image` | `ghcr.io/postgresml/pgcat:v1.2.0` | pinned in 1.1.0; was `:latest` |
| `pgcat.poolMode` / `minReplicas` / `maxReplicas` | `transaction` / 2 / 4 | min/max are per location |
| `resources` | `500m`/`1Gi` → `2`/`4Gi` | `2` / `500m` is exactly 4:1, the stateful ceiling — raising `maxCpu` alone is rejected at apply |
| `multiZone` | `false` | |
| `internal_access.type` | `same-gvc` | off-convention key name, deliberately left alone in 2.0.0 |
| `backup.enabled` | `false` | `aws` or `gcp`; target is `locations[0]`, not configurable |

`global.cpln.gvc` is injected at install and is not declared in values.

## Troubleshooting traps

- **No in-place upgrade from 1.x — it destroys data.** A 1.x release's chart owned its GVC, so `helm upgrade`
  onto 2.0.0 drops `kind: gvc` from the manifest and Helm deletes what a chart stops declaring, taking the
  GVC and **every workload, volumeset and identity in it**. The chart refuses to render when the values still
  carry a `gvc:` key, but a pure-defaults 1.x install has no such key and is **not** protected. Migrate:
  back up, install 2.0.0 as a NEW release (new name — secrets are org-wide) into an existing GVC, restore,
  cut over, then uninstall the old release **against the GVC it was installed into**, not the one it created.
- **The location prerequisite is one-directional.** The GVC must contain every location you list; it may
  contain more. Extra locations run nothing — `defaultOptions.minScale`/`maxScale` are `0` on both the
  pgEdge and pgcat workloads, so the platform never places a replica there. That is what makes it safe to
  share a GVC with other workloads.
- **A missing location fails at BOOT, not at install.** The platform does not validate `localOptions`
  locations, so `helm install` succeeds and the pgEdge container then exits 1 with
  `FATAL: locations declared in values are not in GVC …`. Use a server-side filter
  (`cpln logs '{gvc="…", workload="…-pgedge"}' |= "FATAL"`), not the install exit code.
- **The boot check only hard-fails a node with no data yet.** An already-initialised node logs a WARNING and
  keeps serving — deliberate, because a peer being unreachable is a *normal* state for a multi-master
  database and must never crash a live cluster. Consequence: shrinking the GVC's location list under a
  running cluster leaves every node warning on each restart; shrink `locations` in your values too.
- **The check fails OPEN.** A non-200, a timeout, a missing `view` grant or an unparseable body all produce a
  WARNING and continue. So a missing grant degrades the check rather than wedging the install — and a
  `[pgedge] WARNING: could not read the location list` line means the check did not run, not that it passed.
- **A replica that somehow lands in an undeclared location exits 1 unconditionally**, fresh or not. That
  guard exists because the failure it prevents is the only one here that loses writes: a location-derived
  `NODE_NAME` no peer subscribes to accepts writes, replicates in, never replicates out, and is invisible
  to pgcat.
- **The backup cron is suspended by default and unsuspended only in `locations[0]`** (2.0.0). Before that it
  defaulted to unsuspended, so any GVC location the values did not list ran a **second** concurrent full
  backup into the same bucket.
- **Credentials are a prerequisite secret from 1.1.0** (`username`, `password`, `database`). Through 1.0.2
  they were values shipping `password: password`. Values still carrying them are refused at render.
- **A missing prerequisite secret wedges the deployment silently** — `cpln logs` returns zero lines; read
  `status.versions[].message` from `get-deployments`.
- **pgcat could not use a secret reference before 1.1.0.** Its config is a TOML *file*, and `cpln://` is only
  resolved for env vars — inside a file it stays literal text. So 1.1.0 replaced the rendered TOML with a
  startup script that assembles the file at container start from env, using an unquoted heredoc. If you edit
  that script, keep the heredoc unquoted or the expansion silently stops working. Verified against a password
  containing `|`, `&` and `$`: shell expansion is single-pass, so the password cannot be re-interpreted.
- **pgcat's admin password is the database password** (1.1.0+). Earlier versions shipped a fixed
  `pgcat_admin`/`pgcat_admin` pair in the rendered config.
- **Both tiers derive the topology from ONE render site** (`pgedge.locationEnv` → `PGEDGE_LOCATIONS`,
  `PGEDGE_REPLICAS`, `PGEDGE_WORKLOAD`). pgcat needs `PGEDGE_WORKLOAD` because its own `CPLN_WORKLOAD` names
  pgcat. The prefix is not `CPLN_` because env names starting `CPLN_` are rejected at apply, invisibly to
  `helm template`. The first replica of the first location is pgcat's `primary`; everything else is a
  `replica`, even though Spock is multi-master.
- **`helm upgrade` restarts every pgEdge replica at once** — the API drops
  `rolloutOptions.maxUnavailableReplicas` on a `stateful` workload, so nothing serialises the rollout.
  Treat an upgrade as a planned write interruption.
- **In-container verification works from 2.0.0.** The `createsGvc` policy-hook trap is gone: resources land
  in the GVC named by `--gvc`, so `exec`, `logs` and `uninstall` all work against the slot you installed into.
- **GVC-level env vars cannot reach these containers** — all three set `inheritEnv: false`. Newly relevant
  now that the GVC may be shared.
- **`aws::ReadOnlyAccess` was removed from the backup identity in 1.1.1.** It granted read access to every bucket in the AWS account and contains no write actions, so it was never carrying the backup — what it did carry was account-wide read. The identity is now `cpln-connector` plus the user's bucket-scoped policy only. The documented IAM policy was widened to ten actions at the same time, because `ReadOnlyAccess` had been silently supplying any read action a user's policy omitted.
