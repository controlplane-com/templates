# OpenSearch — maintainer briefing

**What it is.** A multi-node OpenSearch cluster (search + log analytics, Apache-2.0) with an optional
Dashboards UI, an optional demo log pipeline, and optional scheduled snapshots to S3 or GCS. Deploys into
an existing GVC.

**Common use cases.** Self-hosted log search, application search, and analytics where the user wants to own
the index and the retention policy rather than query the platform's built-in log aggregation.

## Architecture

| Resource | Notes |
|---|---|
| workload `-opensearch` (stateful) | `replicas` nodes, HTTP `9200` + transport `9300`, `replicaDirect: true` for peer discovery |
| volumeset `-opensearch-vs` | per-node data directory, optional autoscaling |
| secret `-opensearch-startup` (opaque, plain) | node startup script; installs the snapshot repository plugin when backups are on |
| identity + policy | `reveal` on exactly this release's secrets; cloud-account binding only when backups are on |
| workload `-opensearch-dashboard` *(optional)* | UI on `5601`, reachable only via `cpln port-forward` |
| workload `-backup-setup` *(optional)* | one-time job: registers `backup-repo` and the snapshot policy |
| demo pipeline *(optional)* | log generator + Fluent Bit, with its own identity, policy and volumeset |

`securityOptions.filesystemGroupId: 1000` — the image runs as uid 1000 and cannot write a root-owned volume
without it.

## Key knobs (shipped defaults)

| Knob | Default | Notes |
|---|---|---|
| `replicas` | `3` | **must be odd** — rejected at render otherwise |
| `resources` | `500m`/`2Gi` → `1`/`4Gi` | min/max; ratio stays under the 4:1 stateful cap |
| `volumeset.capacity` | `10` | GiB per node |
| `internal_access.type` | `same-gvc` | external inbound is closed and NOT configurable |
| `dashboard.enabled` | `true` | |
| `demoLogs.enabled` | `false` | |
| `backup.enabled` / `.provider` | `false` / `aws` | `aws` or `gcp`; validated |

**There are no credentials anywhere in this template.** `DISABLE_SECURITY_PLUGIN: true` is set on the nodes
and `DISABLE_SECURITY_DASHBOARDS_PLUGIN: true` on the UI, so anything `internal_access` admits has full
admin access to every index. That is why the credential audit never flagged this template — there is nothing
to flag. `internal_access` is the *only* control, which is worth remembering before recommending `same-org`.

## Troubleshooting traps

- **1.0.0 and 1.0.1 are broken for everyone.** Both workloads' `identityLink` and both policies'
  `principalLinks` were hardcoded to `//gvc/test-gvc/...`. Any install into a GVC not literally named
  `test-gvc` created the identity in the target GVC while every reference pointed elsewhere. Fixed in 1.0.2.
  **The bug is invisible when testing in `test-gvc`** — test this template in `test-gvc-2` or `-3`.
- **1.0.0/1.0.1 with `demoLogs.enabled: true` granted `reveal` on EVERY secret in the org.** The demo-logs
  policy carried `targetQuery: {match: all, terms: []}` beside its `targetLinks`; measured against the live
  API, that query resolves to the entire org secret list (10/10 in the test org). Fixed in 1.0.2 by dropping
  `targetQuery`, mirroring manticore 2.1.0. Anyone who ran the demo pipeline on an older version should be
  told.
- **Enabling backups on a RUNNING cluster fails for ~4-5 minutes first.** The repository plugin installs at
  node startup, so nodes must roll before `backup-repo` can be registered. Meanwhile the setup job logs
  `repository type [s3] does not exist` and restarts. It converges on its own. Enabling backups at install
  time avoids it entirely.
- **Switching `backup.provider` leaves the old cloud binding attached forever.** The API merges identity
  updates and never removes a provider block — measured: even a direct `cpln apply` omitting `aws:` does not
  clear it, while a freshly created identity from the same render has none. Only delete/recreate clears it.
  This is a platform behaviour, not an opensearch bug, and it affects every backup-capable template.
- **The S3 IAM policy needs BOTH ARNs.** `s3:ListBucket` and `s3:GetBucketLocation` authorize against
  `arn:aws:s3:::BUCKET`, the object actions against `BUCKET/*`. The README through 1.0.1 listed only `/*`.
- **Use the fully-qualified internal hostname.** `RELEASE_NAME-opensearch.GVC_NAME.cpln.local:9200`.

## Test status (1.0.2, `test-gvc-2`, 2026-08-21)

Proven: install into a non-`test-gvc` GVC; 3-node cluster forms green with the cluster manager elected;
write + read-back of a document; FQDN reachable from a second workload; demo-logs pipeline ships into a
`demo-logs` index; demo-logs policy resolves to exactly 1 secret; drift gate passes (upgrade #2 fully
`Unchanged`, volumeset/identity/policy byte-identical, workload diffs only `readyCheckTimestamp`); identity
renders `aws:` only for aws and `gcp:` only for gcp with `status.aws.usable: true` and no
`aws::ReadOnlyAccess`; clean uninstall with no orphans.

**Not proven: a snapshot actually landing in a bucket.** The test org has no S3 bucket for this, and the GCS
attempt reached the bucket and authenticated but returned `403 — the billing account for the owning project
is disabled`. Repository registration was exercised up to the storage call; the upload itself was not.
