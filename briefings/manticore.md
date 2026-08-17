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
| `buckets.sourceBucket` / `cloudAccountName` / `awsPolicyRefs` | `my-manticore-*` | AWS only. Needs **write**, not just read (see below) |
| `orchestrator.action` / `schedule` / `suspend` | `import` / hourly / `true` | The cron ships suspended; the schedule only matters once un-suspended |
| `tables[]` | one `addresses` example | `segmentCount` must equal `len(csvPath)` — enforced by a render-time `fail` |
| `orchestrator.backup.*` | disabled | Separate bucket, cloud account and policy |
| `loadTest.*` | disabled | k6; `loadTest.controller.schedule: ""` means manual trigger only |

## Troubleshooting / considerations

- **The agent token is a prerequisite secret as of 2.1.0.** 2.0.1 and earlier shipped a **real working token as a values default**, so every install that did not override it shared one credential published in a public repo. Installing 2.1.0 without creating the secret first leaves the deployment waiting on a secret that does not exist — which looks like a platform fault, not a missing prerequisite. The README carries the `cpln secret create-opaque` one-liner.
- **The UI has no login of its own, and never did.** It holds `ORCHESTRATOR_AUTH_TOKEN` server-side and injects it for whoever connects, so reaching the UI *is* holding the admin token — imports, restores and repairs included. 2.0.x defaulted it to public; 2.1.0 defaults it to internal-only. The bearer token protects the API, not the edge. Anyone asking to expose the UI needs an authenticating proxy in front.
- **2.1.0 is a clean break with render-time guards.** Carrying 2.0.x values forward fails fast: `orchestrator.agent.token` and `orchestrator.ui.allowExternalAccess` each `fail` with the replacement named. This is deliberate — silently ignoring the old UI key would have re-exposed the console.
- **`targetQuery: {match: all, terms: []}` grants the policy over EVERY secret in the org.** It sat next to `targetLinks` in manticore 1.x–2.0.1, making those links decorative and handing four identities `reveal` on unrelated org secrets — dynamically, including secrets created later. Measured 2026-08-17 with `cpln secret access-report`: an identity bound through that shape had `reveal` on a secret it was never linked to, while a `targetLinks`-only control identity did not. Removed in 2.1.0. **`opensearch` 1.0.0/1.0.1 still carries the same block** (gated behind `demoLogs.enabled`) — not fixed here, flagged for the maintainer.
- **The orchestrator writes into the SOURCE bucket.** `INDEXER_WORK_DIR=/mnt/s3/indexer-temp` is inside the mounted source bucket, so a read-only IAM policy breaks imports at a point that looks like a parsing failure. The README's policy JSON grants `PutObject`/`DeleteObject` for this reason.
- **`maxUnavailableReplicas` is dropped by the API on a stateful workload**, so 2.0.x rendered permanent drift and implied a serialized rolling restart that was never in force. 2.1.0 stops sending it and declares what the API backfills instead; a rendered-vs-stored diff over all four core workloads is now clean apart from the catalog-wide `identityLink` qualification. Treat a `helm upgrade` as a restart of every replica at once.
- **The API stores `containers[].env` alphabetically sorted** (measured 2026-08-17). Charts render env in logical order, so rendered-vs-stored always differs by ordering. Benign and catalog-wide, but it will show up in any drift investigation.
- **An install alone indexes nothing.** Tables exist but are empty until an `init` then an `import` is triggered. A "search returns no results" report is almost always this.
- **`manticore.firewall.internalAccess.type` must stay `same-gvc`** — Galera replication between replicas depends on it. Manticore's own 9306/9308 ports are unauthenticated and rely entirely on that firewall.
- **Uninstall deletes both volumesets**, so indexed data does not survive a reinstall.

## Status

- 2.1.0 is a security fix (token secret, UI default, org-wide policy grant) plus drift pre-emption. Not yet live-tested end to end — an import/init cycle and the backup path still need a full test round.
