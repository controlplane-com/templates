# TiDB — Maintainer Briefing

## What it is
- TiDB: a distributed, MySQL-compatible SQL database that scales horizontally and keeps serving through node loss. Three tiers: **PD** (placement driver — the cluster's brain, holds metadata and decides where data lives), **TiKV** (the storage nodes), and **tidb-server** (the stateless MySQL-protocol front door).
- Apache-2.0. Nothing gated, nothing to register.
- **From 2.0.0 the chart deploys into `global.cpln.gvc` and creates no GVC** (`createsGvc: false`). 1.x created its own from `gvc.name`.

## Common use cases
- A MySQL-compatible database that outgrows a single instance — same wire protocol, so existing clients and ORMs work unchanged.
- Multi-location deployments where data should be replicated across locations rather than sitting in one.
- Workloads wanting horizontal write scaling, which the single-primary `mysql` and `postgres` templates cannot offer.

## Architecture on cpln
| Resource | Purpose |
|---|---|
| workload `{release}-pd` (stateful) | PD quorum, `pdReplicas` members spread across `locations`, `replicaDirect` |
| workload `{release}-tikv` (stateful) | Storage nodes, `locations[].replicas` per location |
| workload `{release}-server` (standard) | MySQL front door :4000, status :10080 |
| workload `{release}-tidb-db-init` | One-shot database/user bootstrap when `autoCreateDatabase.deployInitWorkload` |
| workload `{release}-tidb-backup` (cron) | Optional `br` backup to S3 or GCS, unsuspended in one location |
| volumesets, secrets (startup scripts), identity, 2 policies | Per-tier config, secret reveal, and `view` on the ONE install GVC |

## Key knobs (shipped defaults, 2.0.0)
| Knob | Default | Meaning |
|---|---|---|
| `locations` | one entry: `aws-us-east-1` × 3 | Must already exist in the install GVC. `replicas` = TiKV **and** tidb-server nodes there |
| `pdReplicas` | `3` | `1`, `3`, `5`, `7`. Spread evenly, remainder to the first locations |
| `images.{pd,tikv,server}` | `v8.5.7` | Bump with `backup.image` — `br` enforces a version match |
| `resources.{pd,server,tikv}` | 2 cpu / 4-2-4 Gi | Single-value blocks, so bare `cpu`/`memory` |
| `autoCreateDatabase.*` | on, `deployInitWorkload: true`, `credentialsSecretName: my-tidb-credentials` | Prerequisite `dictionary` secret with `rootPassword`, `user`, `password`, `db` |
| `volumeset.{tikv,pd}.capacity` | `10` GiB | TiKV supports autoscaling; PD does not |
| `exposeServer` | `false` | Opens public inbound — but see traps, it does NOT publish MySQL |
| `external_access.*_outboundAllowCIDR` | `[]` | Per-tier egress; backups force `0.0.0.0/0` on TiKV |
| `internal_access.{server,tikv,pd}.type` | `same-gvc` | Who may reach each tier. This release's own workloads are ALWAYS included |
| `backup.*` | off, `provider: aws`, `location: aws-us-east-1` | `location` must be one of `locations` — refused at render otherwise |

## What 2.0.0 changed
- **No `kind: gvc`.** Deploys into the install GVC; `gvc.locations` → `locations`, `gvc.pdReplicas` → `pdReplicas`, `gvc.name` gone.
- **Three-layer defence against a location mismatch**: (1) a render-time `fail` if the `gvc` values key is still present, so an in-place 1.x upgrade cannot run; (2) `defaultOptions.minScale/maxScale: 0` on every tier with `localOptions` carrying the real counts, so an undeclared GVC location starts nothing; (3) a boot-time GVC read in PD's startup script (`$CPLN_ENDPOINT/org/$CPLN_ORG/gvc/$CPLN_GVC`, `view` scoped by `targetLinks` to that one GVC) that hard-fails on a fresh data directory and warns on an initialised one. PD and TiKV also refuse to start in a location not in `locations`.
- **`devMode` removed.** It only waived the three-location requirement; the default is now one location, and PD's `max-replicas` is derived (TiKV node count, capped at 3) instead of special-cased.
- **`replicas: 0` refused.** 1.x mapped it to `localOptions[].suspend`, which permanently withdraws a workload's endpoints from other locations' service discovery.
- **`workload-list` self-inclusion.** A single `tidb.ownWorkloadLinks` helper adds all five of this release's workloads to every tier's internal firewall list. Without it a `workload-list` naming only clients cuts the cluster off from itself while every replica still reports `ready: true` — confirmed in four other templates this batch.
- **PD endpoints rendered once** (`tidb.pdEndpointList`). The startup scripts previously assumed one PD per location, which is only true while `pdReplicas` equals the location count.
- **Complete `localOptions` blocks everywhere.** The backup cron and db-init previously sent `location` + `suspend` only; the API completes a partial entry from PLATFORM defaults, so they actually ran with `capacityAI: true`, a 5-second timeout, and (for the cron) autoscaling up to 5 concurrent pods.
- **`location-labels = ["region"]` is now set on every shape**, not only multi-location ones. PD persists `[replication]` at bootstrap, so a cluster that starts without it can never become region-aware afterwards.

## Availability posture
- Default is **one location, 3 TiKV + 3 PD**: survives a node loss, not a location loss.
- Location survival needs **≥3 locations with PD spread one per location**. Verified on 1.x: converged in 2 m 51 s, query-ready ~5 min, 66 regions replicated one per location.
- tidb-server readiness requires 2 TiKV stores `Up` (1 on a single-store install) — a quorum, not all of them, so one location down does not make it unready.

## Troubleshooting / considerations
- **NOT YET TESTED.** 2.0.0 was built after the four merged GVC conversions and has not been deployed. Everything below carried forward from 1.x still applies; the 2.0.0-specific items are chart-level and unverified live.
- **`exposeServer` is a defect, not a feature.** It opens public inbound on the server workload, but MySQL is TCP on 4000 and would need a `loadBalancer.direct` block, which the template does not render — so it publishes nothing usable, while the workload's only `http` port is TiDB's unauthenticated status/API port 10080. It has never been tested (three test rounds all left it `false`). Left unchanged in 2.0.0 and documented as untested; **needs a maintainer ruling** — fix it with a direct LB on 4000, or remove the knob.
- **GCS backups did not work before 1.7.0.** Two causes, both fixed: `backup.sh` never passed `--send-credentials-to-tikv=false`, and TiKV's legacy GCS backend could not use the metadata server. v8.5.7 enables `gcp_v2`, which supports ADC. AWS S3 was unaffected.
- **The backup image version must match the cluster.** From v8.5.7 `br` enforces the check even with `--check-requirements=false`.
- **The restore path has never been exercised** against a backup this template produced, and SST object naming differs between the S3 (`1/<name>`) and GCS (`1_<name>`) backends. The README says so rather than implying a rehearsed procedure.
- **Region-aware placement was broken before 1.7.0** — store labels went to a top-level `[labels]` table TiKV ignores, under the key `zone`, which no `location-labels` entry referenced. Fixed there (`[server] labels`, key `region`) and verified: each store reports `region=<its location>`. 2.0.0 does not change the mechanism; it only extends `location-labels` to single-location installs so the option stays open later.
- **PD reads `[replication]` only at bootstrap**, then persists it to etcd and ignores the file forever. Always check the PD API, not `pd.toml`. This is also why `max-replicas` is fixed for the life of the cluster.
- **`db-init` completes then restarts forever** (it exits 0 and is restarted), so a healthy install never shows all-green. Known, not fixed. Set `autoCreateDatabase.deployInitWorkload: false` after first boot.
- **The `tidb-server` image has no mysql client** — connect from another workload in the GVC.
- **A missing credentials secret wedges the deployment silently.** `cpln logs` returns zero lines; read `status.versions[].message` via `get-deployments`. Self-heals in ~5.5–10.5 min once created.
- Spec/reports: archived under `.pipeline-archive/tidb/`. Adjacent: `mysql` (single-instance MySQL), `cockroach` (other distributed SQL, and the closest reference for this conversion).
- **`aws::ReadOnlyAccess` was removed from the backup identity in 1.8.1.** It granted read on every bucket in the account and no write actions. The documented IAM policy was widened to ten actions at the same time; an upgrading user must update their IAM policy first.
