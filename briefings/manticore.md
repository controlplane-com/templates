# Manticore — Maintainer Briefing

## What it is

- A **Galera-replicated Manticore Search cluster** plus a Control Plane-specific **orchestrator** (our own code, `controlplane-com/manticore-orchestrator`) that performs coordinated CSV imports from S3 into every replica using a dual-slot (A/B) swap, so searches keep serving during a reload.
- Manticore is GPL-2.0 and free to self-host; the orchestrator/agent/UI/backup images are ours. `appVersion` tracks the Manticore image (`25.0.0`), not the orchestrator (`v6.0.5`).
- **Not a general-purpose search service you point an app at and forget.** The value is the bulk-import pipeline: data arrives as CSV in a bucket, and the orchestrator turns it into a distributed table.

## Common use cases

- Full-text search over a large dataset that is regenerated periodically upstream (address books, catalogs, reference data) and republished as CSV.
- A read-heavy search tier that must stay up while data is reloaded.
- Multi-segment tables: one logical table fanned across several CSVs and queried as one distributed table.

## Architecture on cpln

| Resource | Purpose |
|---|---|
| `workload` (stateful) `{release}-manticore` | searchd + **agent sidecar**; `replicaDirect: true`, peers found as `{workload}-{i}.{workload}` |
| `workload` (standard) `{release}-orchestrator-api` | REST API; coordinates init/import/repair/backup, drives the cron job via the CPLN API |
| `workload` (cron) `{release}-orchestrator-job` | Does the actual work. **Ships suspended**; `orchestrator.action` selects init/import/health/repair |
| `workload` (standard) `{release}-ui` | Dashboard. Internal-only by default as of 2.1.0 |
| `workload` (cron) `{release}-manticore-backup` | Optional delta/main logical backups to S3 |
| `workload` ×2 (standard + cron) | Optional k6 load-test runner and the controller that scales it 0→N→0 |
| `volumeset` ×2 | Per-replica `ext4` data volume, plus a `shared` volume used to hand import artifacts between the job and the replicas |
| `identity` ×3–6 + `policy` ×3–5 | S3 via cloud account; `reveal` on exactly four secrets; `exec.runCronWorkload` so the API can trigger the job |
| `domain` | Optional; `/api/*` → orchestrator API, `/*` → UI |

## Key knobs (defaults as shipped in 2.1.0)

| Knob | Default | Meaning |
|---|---|---|
| `orchestrator.agent.tokenSecretName` | `my-manticore-agent-token` | **REQUIRED prerequisite opaque secret** — must exist before install |
| `orchestrator.ui.publicAccess.enabled` | `false` | Was `allowExternalAccess: true` in 2.0.x. See the trap below |
| `orchestrator.ui.internalAccess.type` | `same-gvc` | New in 2.1.0; was hardcoded |
| `manticore.autoscaling.minScale` / `maxScale` | `3` / `4` | `minScale` is also the replica count the orchestrator coordinates across |
| `manticore.resources.cpu` / `.memory` | `4` / `8Gi` | Limits only — bare names are correct per the 2026-08-06 ruling |
| `manticore.volumeset.capacity` / `sharedVolumeset.capacity` | `200` / `100` (GB) | Sized for real datasets; shrink for a trial install |
| `buckets.sourceBucket` / `cloudAccountName` / `awsPolicyRefs` | `my-manticore-*` | AWS only. **Read-only is sufficient** (see below) |
| `orchestrator.action` / `schedule` / `suspend` | `import` / hourly / `true` | The cron ships suspended; the schedule only matters once un-suspended |
| `tables[]` | one `addresses` example | `segmentCount` must equal `len(csvPath)` — enforced by a render-time `fail` |
| `orchestrator.backup.*` | disabled | Separate bucket, cloud account and policy — the only one needing S3 write |
| `loadTest.*` | disabled | k6; `loadTest.controller.schedule: ""` means manual trigger only. Results (thresholds included) are read from the runner's own `cpln logs` |

## Troubleshooting / considerations

- **The agent token is a prerequisite secret as of 2.1.0.** 2.0.1 and earlier shipped a **real working token as a values default**, so every install that did not override it shared one credential published in a public repo. Installing 2.1.0 without creating the secret first leaves the deployment waiting on a secret that does not exist — which looks like a platform fault, not a missing prerequisite. The README carries the `cpln secret create-opaque` one-liner.
- **The UI has no login of its own, and never did.** It holds `ORCHESTRATOR_AUTH_TOKEN` server-side and injects it for whoever connects, so reaching the UI *is* holding the admin token — imports, restores and repairs included. 2.0.x defaulted it to public; 2.1.0 defaults it to internal-only. The bearer token protects the API, not the edge. Anyone asking to expose the UI needs an authenticating proxy in front.
- **2.1.0 is a clean break with render-time guards.** Carrying 2.0.x values forward fails fast: `orchestrator.agent.token` and `orchestrator.ui.allowExternalAccess` each `fail` with the replacement named. This is deliberate — silently ignoring the old UI key would have re-exposed the console.
- **`targetQuery: {match: all, terms: []}` grants the policy over EVERY secret in the org.** It sat next to `targetLinks` in manticore 1.x–2.0.1, making those links decorative and handing four identities `reveal` on unrelated org secrets — dynamically, including secrets created later. Measured 2026-08-17 with `cpln secret access-report`: an identity bound through that shape had `reveal` on a secret it was never linked to, while a `targetLinks`-only control identity did not. Removed in 2.1.0. **`opensearch` 1.0.0/1.0.1 still carries the same block** (gated behind `demoLogs.enabled`) — not fixed here, flagged for the maintainer.
- **The source bucket needs READ ONLY — this was documented backwards until 2026-08-18.** The chart set `INDEXER_WORK_DIR=/mnt/s3/indexer-temp`, and everyone (including the briefing) concluded imports write scratch into the user's data bucket, so the README mandated `PutObject`/`DeleteObject` on it. The env var is dead: the string appears in **neither** the v6.0.5 orchestrator nor the agent binary. The indexer's real `workDir` is `/mnt/shared/indexer-output/...` on the shared volumeset, and S3 appears only as `source=`. Proven by running real imports under a strictly read-only policy on two separate releases — 500 rows, counts cross-checked against the source CSV, bucket byte-identical afterwards — and `repair` likewise never touches it. The var is now removed and the README policy is read-only. **Only the optional backup bucket needs write**, and it has its own bucket, identity and policy.
- **`orchestrator.backup.*` never worked before 2026-08-18, for a one-line reason.** The startup script wrote the generated searchd config to `/tmp`, but the agent runs `manticore-backup --config=/var/lib/manticore/manticore-runtime.conf` with that path **compiled into the binary** — and `/tmp` is per-container, so the agent could never see it. Every backup died on `Failed to find passed config[0]`. The config now lives on the data volume (both containers mount it), and delta + main backups and a restore are all verified end to end against a real bucket. If a backup ever fails on a config path again, this is the file to look at.
- **`maxUnavailableReplicas` is dropped by the API on a stateful workload**, so 2.0.x rendered permanent drift and implied a serialized rolling restart that was never in force. 2.1.0 stops sending it and declares what the API backfills instead; a rendered-vs-stored diff over all four core workloads is now clean apart from the catalog-wide `identityLink` qualification.
- **Every `helm upgrade` costs a full serial rolling restart — a no-op one included.** Measured 542 s at the default 3 replicas (`scalingPolicy: OrderedReady`, one replica at a time); the earlier round measured 388 s. Data survived intact both times and searches keep serving from the replicas still up, but anything that changes a mounted secret (a `tables[]` edit changes the schema secret) pays it too. Now stated in the README.
- **Multi-segment and `clusterMain: true` are NOT proven, and the failures are noisy — treat this as open.** Under a deliberately under-resourced cluster (1 CPU / 4 Gi vs the shipped 4 / 8 Gi), a 2-segment import completed once out of three attempts; `clusterMain: true` failed twice with `replication timeout: table addresses_main_a_1 not replicated to all nodes after 30 attempts`, and the other failure was replicas taking a platform SIGTERM mid-import ("agent did not recover within 5m"). The one success still left one replica with an empty segment, so per-replica counts disagreed (500 / 502 / 252). **None of it was S3-related** — every segment reads from the mount and writes to `/mnt/shared` — so it does not change the read-only conclusion above. Needs a dedicated round at default resources before either is claimed to work; the orchestrator's own 3→4→3 scale cycle during an import is the first thing to rule out.
- **The API stores `containers[].env` alphabetically sorted** (measured 2026-08-17). Charts render env in logical order, so rendered-vs-stored always differs by ordering. Benign and catalog-wide, but it will show up in any drift investigation.
- **An install alone indexes nothing.** Tables exist but are empty until an `init` then an `import` is triggered. A "search returns no results" report is almost always this.
- **`manticore.firewall.internalAccess.type` must stay `same-gvc`** — Galera replication between replicas depends on it. Manticore's own 9306/9308 ports are unauthenticated and rely entirely on that firewall.
- **Uninstall deletes both volumesets**, so indexed data does not survive a reinstall.

## Status

- 2.1.0 is a security fix (token secret, UI default, org-wide policy grant), drift pre-emption, and — after two test rounds — the first version in which `orchestrator.backup.*` has ever worked.
- Live-tested end to end on `test-gvc-3`: cluster bootstrap, import from S3 under a read-only policy, delta + main backup to a real bucket, restore, `repair`, the k6 load test, both access knobs, and a no-op-upgrade drift gate (all `Updated` resources proved spec-identical; only the release tag moved).
- **Open for the maintainer:** multi-segment / `clusterMain: true` (above), and a restore that lands on the cluster unevenly — after a restore plus a rolling restart, one replica had the restored rows and another did not while every node reported `synced`. Verify per-replica counts after a restore rather than trusting the cluster status.
