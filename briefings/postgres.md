# Postgres — Maintainer Briefing

## What it is

- **One** PostgreSQL server (`postgres:19`, the moving major tag, from 4.0.0) on one persistent volume set. Not a cluster: no
  replication, no failover, and the workload is pinned to exactly 1 replica. `postgres-highly-available`
  is the single-location Patroni cluster; `postgres-multi-location` stretches one across regions.
- PostgreSQL is PostgreSQL Licence (permissive) — free to self-host with nothing to buy or register.
- **The most-consumed chart in the catalog.** 20 templates bundle it as a subchart: chatwoot, docmost,
  fusionauth, gitea, glitchtip, grafana, infisical, keycloak, langfuse, listmonk, litellm, metabase,
  n8n, nocodb, polaris, temporal, tooljet, twenty, umami, unleash. Every one pins an exact version,
  so nothing picks up a new version until it deliberately bumps. **Read the subchart trap below
  before bumping any of them.**

## Common use cases

- The application database for something a team runs themselves, connected to over internal GVC DNS.
- The bundled datastore inside another marketplace template.
- A dev/staging database where minutes of downtime on a restart are acceptable — a node failure
  reschedules and reattaches the same volume, so the exposure is downtime, not data loss.

## Architecture on cpln

| Resource | Purpose |
|---|---|
| `workload` (stateful) `{release}-postgres` | PostgreSQL 19, port 5432, `minScale`=`maxScale`=1; a boot guard runs before the server |
| `volumeset` `{release}-pg-vs` | `PGDATA` on `ext4`, general-purpose SSD; a final snapshot on delete, kept 7 d. **No scheduled snapshots** (no `schedule`; work item 5219) |
| `workload` (serverless) `{release}-pgbouncer` | Connection pooler. Optional (`pgbouncer.enabled`) |
| `workload` (cron) `{release}-postgres-backup` | Scheduled `pg_dumpall` (19 client) to S3/GCS/MinIO. Optional (`backup.enabled`) |
| `identity` + `policy` | `reveal` on the user's credentials secret (plus the MinIO one when in use) |

- **This chart creates no secret of its own as of 3.4.0.** The `{release}-pg-config` dictionary
  secret that 3.3.0 and earlier created is gone.
- Postgres is the only tier with probes: a readiness exec that fails while the guard holds, else
  `pg_isready -h 127.0.0.1` (TCP, so the socket-only first-boot server does not count as ready);
  `initialDelaySeconds: 15`, `periodSeconds: 10`, `failureThreshold: 6` → startup window ≈ 315 s
  (was 167 s in 3.x).
- `cpu:minCpu` is 500m:200m = 2.5:1 on the stateful tier, inside the 4:1 cap that applies to
  stateful workloads. Raising `maxCpu` without raising `minCpu` can cross it and is rejected at apply.

## Key knobs (defaults as shipped in 4.0.0)

| Knob | Default | Meaning |
|---|---|---|
| `image` | `postgres:19` | A 3.x release must pin `postgres:18` (its data's major); the wizard does it on upgrade |
| `resources.minCpu`/`maxCpu` | `200m` / `500m` | Block exposes both, so min/max naming is correct here |
| `resources.minMemory`/`maxMemory` | `128Mi` / `256Mi` | |
| `config.credentialsSecretName` | `my-postgres-credentials` | **REQUIRED prerequisite `dictionary` secret** holding `username`, `password`, `database` |
| `volumeset.capacity` | `10` GiB | Minimum 10; `volumeset.autoscaling.*` off by default |
| `internalAccess.type` | `same-gvc` | `none` cuts the workload off from everything |
| `pgbouncer.enabled` | `false` | Reads the same credentials secret and identity — nothing extra to configure |
| `backup.enabled` | `false` | `provider`: `aws` \| `gcp` \| `minio` |
| `backup.image` | `postgres-backup:19.1.0` | One default: the 19 client also dumps a server pinned to 17 or 18 |
| `backup.minio.credentialsSecretName` | `my-postgres-minio-credentials` | **Prerequisite `dictionary` secret** with `accessKey`, `secretKey`, required only when `provider: minio` |

## Troubleshooting / considerations

- **"Not ready after upgrade" plus `[pg-guard] REFUSING TO START` in the logs (4.0.0):** a 3.x release
  (data on PostgreSQL 18) was upgraded without pinning the image. PostgreSQL was not started and the
  volume is untouched. Fix: run the upgrade again with `--set image=postgres:18`; a pinned re-upgrade
  recovered a held replica in ~32 s in the spike, with no `force-redeployment`. The user must keep the
  pin in their values from then on (no `--reuse-values`). The guard holds rather than crash-looping and
  repeats the fix every 30 s; the readiness-implied startup probe restarts the held container roughly
  every 5 min, and it prints again on each start.
- **Moving 18 → 19 is a dump and restore into a new release with the SAME credentials secret**
  (README "Upgrading from 3.x"): `pg_dumpall` carries the old password hash, so a different secret
  breaks logins. No in-place `pg_upgrade` and no custom image (ruling).
- **The guard's three layers:** wizard (a computed migration keeps the installed image; an `oldSelf`
  major rule warns if the user switches it), CLI (NOTES.txt prints the 3.x warning on every install
  and upgrade, because `cpln helm` always reports `IsUpgrade=false`, revision 1), runtime (the guard).
- **A 19.1.0 dump of a pinned-18 server** restores into 19 cleanly; replayed into 18 it can print
  harmless `SET` parameter errors (README Restoring section; `backup.image …:18.1.0` for long-term 18).
- **The backup identity is unchanged from 3.4.2** (`cpln-connector` + the bucket policy) while the
  maintainer reviews whether `cpln-connector` is needed; see the bullet below.

- **A missing prerequisite secret wedges the deploy SILENTLY.** `cpln logs` returns **zero lines** —
  the container never starts, so there is nothing to log — and every summary surface looks like a
  slow deploy. The only diagnostic is `status.versions[].message` on the workload. It self-heals
  about 6 minutes after the secret appears, or `cpln workload force-redeployment` clears it in ~90 s.
  This is the single most likely support question on 3.4.0.
- **THE SUBCHART TRAP — a parent adopting 3.4.0 breaks in three places, only one of them loudly.**
  1. `postgres.config.username` / `.password` / `.database` in the parent's values now **fail at
     render** with a message naming the replacement. Loud, and intentional.
  2. The parent's app workload references `cpln://secret/{release}-pg-config.password`, a name it
     reconstructs in its own `_helpers.tpl` (`printf "%s-pg-config"`). **That secret no longer
     exists**, so the parent's app wedges silently per the bullet above.
  3. The parent's own policy grants `reveal` on that same dead secret name.

  In a bundled context the credential genuinely IS internal plumbing — no human types it — so the
  bundled-plumbing exception applies and the parent should **create the dictionary secret itself**
  from its existing `postgres.config.*` values and pass the name down as
  `postgres.config.credentialsSecretName`, rather than making its users create one. That is a
  maintainer decision per parent; it is not made here. Bumping a parent to 3.4.0 without doing it
  produces a template that installs successfully and never starts.
- **Rotating the secret after first boot does nothing.** `POSTGRES_USER`/`PASSWORD`/`DB` are read
  only when `PGDATA` is empty. Use `ALTER ROLE ... PASSWORD` and then update the secret to match.
- **`helm uninstall` deletes the volume set** — data does not survive a reinstall. The credentials
  secret is the user's and is left alone, which is a real improvement over 3.3.0's chart-owned secret.
- **A `helm upgrade` restarts the server.** `rolloutOptions.maxUnavailableReplicas` is dropped by
  the API on stateful workloads, so nothing limits the rollout; the chart deliberately does not send
  it. Treat every upgrade as a planned write outage. The FIRST upgrade after an install re-applies
  resources even with byte-identical values.
- **`aws::ReadOnlyAccess` was REMOVED from the backup identity in 3.4.0**, leaving `cpln-connector`
  plus the user's bucket-scoped policy (`cpln-connector` itself went in 3.4.3). The spike that settled it is worth knowing, because the same
  reasoning applies to the ~21 other templates that still carry it: Control Plane attaches each
  `policyRef` as a managed policy on a **per-identity derived IAM role**, so permissions are the
  **union** of refs — and `ReadOnlyAccess` contains **no write actions at all** (its S3 portion is
  `Get*`/`List*` on `*`). It could never have been carrying the upload; what it carried was read
  access to every object in every bucket in the account. Proven, not argued: backups succeeded
  without it, while a negative control (dropping the scoped policy and keeping `ReadOnlyAccess`)
  failed on the very next run with `AccessDenied` on `PutObject`.
- **Existing user IAM policies do NOT need updating for this.** A forced 30.9 MB multipart upload
  succeeded under the old six-action policy, because multipart authorizes under `s3:PutObject`. The
  four preflight/multipart actions added to the README policy JSON are defensive only — worth having,
  since orphaned multipart parts bill silently, but nothing breaks without them.
- **`cpln-connector` was REMOVED from the backup identity in 3.4.3.** A backup completes with the
  scoped policy alone, and attaching `cpln-connector` granted `iam:CreateRole` / `AttachRolePolicy`
  over cpln-tagged resources — more than the backup uses. It stays on the parent cloud-account role,
  where it is required.
- **Firewall changes take 30–150 s to propagate.** Re-poll before concluding `internalAccess` is broken.

## Status

3.4.0 is a security-conventions release: the database credentials (`config.username`, `.password`,
`.database` — shipped as `password: password`) and the MinIO backup credentials became user-created
prerequisite secrets, the chart-created `{release}-pg-config` secret was removed, placeholders were
brought onto the `my-{service}-{purpose}` rule, the README was rewritten to the seven-section
structure, and drift fields (`terminationGracePeriodSeconds: 90`, the empty firewall lists) were
declared. Hard break, no compatibility shim — the version bump is the migration path. **Not yet
deployed**: the wedge-and-recovery timings above are inherited from sibling templates, and whether
the API retains `rolloutOptions` on the `serverless` PgBouncer tier is unverified.

3.4.2 declares the fields the API backfills on the postgres and PgBouncer workloads
(`autoscaling.maxConcurrency: 0`, `scaleToZeroDelay: 300`, `target: 95`, `defaultOptions.timeoutSeconds: 5`,
and `rolloutOptions.minReadySeconds: 0` on postgres), found by drift-diff on a template bundling 3.4.1.
Nothing about how PostgreSQL runs changes.

4.0.0 makes PostgreSQL 19 the default for new installs (`postgres:19`, backup image 19.1.0) and adds the
major-version boot guard, a guard-aware TCP readiness probe, NOTES.txt, and wizard carry-over of the
installed image (3.x keeps its image; 2.x is set to `postgres:17`). Existing releases stay on their major;
moving data is a dump and restore. Snapshot scheduling is deliberately NOT in this version (work item 5219):
the README now says plainly that only a final snapshot is taken. The 3.4.2 volumeset render already matches
what the API stores for this shape (no autoscaling, a `snapshots` block without `schedule`), so a version
bump's `Updated` on it comes from the chart-version tags, not drift. CI adds `fresh-is-19`, `guard-passes`
and a refused-then-pinned upgrade from 3.4.2 and 3.2.0 (`guard-holds`).
