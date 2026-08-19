# MinIO — Maintainer Briefing

## What it is

- MinIO in **distributed mode**: `replicas` nodes forming one erasure-coded pool, each on its own
  volume at `/data`. S3 API on 9000, console on 9001. There is no standalone shape in this chart.
- **Internal only** — no `publicAccess` knob, no `loadBalancer.direct`; the console is reached with
  `cpln port-forward`. That is why the credential defect here was graded tier 2, not tier 1.
- AGPL-3.0, free to self-host. **Never a subchart** — but ~8 templates' backup blocks point at a
  MinIO install and document its credentials (see the last trap).

## Common use cases

- The S3 target for other templates' backups (`provider: minio` in postgres, timescaledb, glitchtip,
  listmonk, umami, chatwoot, temporal, nocodb).
- Object storage for an in-GVC app that speaks S3 but should not reach a cloud provider.

## Architecture on cpln

| Resource | Purpose |
|---|---|
| `workload` (stateful) `{release}-minio` | `minScale`=`maxScale`=`replicas`, ports 9000/9001, `replicaDirect: true` |
| `volumeset` `{release}-minio-vs` | `/data` per replica, `ext4`, SSD, final snapshot + 7-day retention |
| `secret` (opaque) `{release}-minio-startup` | Boot script: builds the peer list, self-maps `replica-N` into `/etc/hosts` |
| `identity` + `policy` | `reveal` on the startup secret and the user's credentials secret only |

No probes, and no cloud bindings on the identity — there is no `aws::ReadOnlyAccess` to remove here.
`cpu:minCpu` is 2:1 on a stateful tier, inside the 4:1 cap.

## Key knobs (defaults as shipped in 1.3.0)

| Knob | Default | Meaning |
|---|---|---|
| `image` | `minio/minio:RELEASE.2025-09-07T16-13-09Z` | |
| `replicas` | `6` | Must be **even and ≥ 4**; above the default org replica quota |
| `admin.credentialsSecretName` | `my-minio-credentials` | **REQUIRED prerequisite `dictionary` secret** with `username`, `password` |
| `resources.minCpu`/`maxCpu` | `1` / `2` | Block exposes both, so min/max naming is correct here |
| `resources.minMemory`/`maxMemory` | `2Gi` / `4Gi` | |
| `volumeset.capacity` | `10` GiB | **Per replica.** Usable ≈ `replicas × capacity ÷ 2` after parity |
| `internalAccess.type` | `same-gvc` | `none` breaks the cluster, not just external reach |

## Troubleshooting / considerations

- **A missing prerequisite secret wedges the deploy SILENTLY.** `cpln logs` returns **zero lines**;
  the only diagnostic is `status.versions[].message` from `cpln workload get-deployments` (plain
  `cpln workload get` has no `versions` key). Self-heals ~6–8.5 min after the secret appears, or
  `force-redeployment` in ~90 s. The likeliest support question on 1.3.0.
- **`internalAccess.type: none` is not "lock it down", it is "break it".** Nodes discover each other
  over internal GVC traffic; with `none` every replica boots and no pool ever forms.
- **`outboundAllowCIDR` is `[]` — no egress to the internet.** Fine for a storage server, but bucket
  replication to a remote S3 and external notification targets fail with no obvious cause.
- **The peer list is baked at render time** from `.Values.replicas`, so changing it rewrites every
  node's view of the existing pool. MinIO grows by adding server pools, which this chart does not
  model — treat `replicas` as fixed at install.
- **The `/etc/hosts` line in the startup script is load-bearing.** A node cannot resolve its own
  `replica-N` name, so the script maps it to `LOCAL_IP` first. The index comes from `HOSTNAME##*-`,
  which is only an index because the tier is `stateful`; on a `standard` tier every node would
  claim index 0.
- **`helm uninstall` deletes the volume sets** — objects do not survive a reinstall. The credentials
  secret is the user's and is left alone. Rotating it needs a restart to apply, and is fleet-wide:
  every client and every template holding those keys must be updated in the same window.
- **~8 templates' READMEs still say "for the MinIO template these are its `admin.username` and
  `admin.password`"** (postgres 3.4.x, postgres-multi-location, postgres-highly-available, docmost,
  twenty, sftpgo). Those value names no longer exist. Sweeping them is a follow-up, not this change.

## Status

1.3.0 is a security-conventions release: the root credentials (`admin.username: myuser`,
`admin.password: mypassword123` — a working credential in a public repo, shared by every install
that did not override it) became a user-created prerequisite `dictionary` secret named by
`admin.credentialsSecretName`; the chart-created `{release}-minio-admin` secret is gone; `fail`
guards name the replacement; the README was rewritten to the seven-section structure; and drift
fields were declared. Hard break, no shim. **Not yet deployed** — the drift gate, the wedge timings
and rotation-by-restart are inherited from sibling templates, not measured on MinIO.
