# MongoDB Cluster — Maintainer Briefing

## What it is
- A MongoDB replica set (Percona Server for MongoDB, `percona/percona-server-mongodb:8.0`) with automatic failover, deployable in **one location or stretched across several**.
- **2.0.0 deploys into an existing GVC** (`createsGvc: false`). 1.x created its own; that path is now refused at render time.
- Optional HAProxy in front so clients hit one endpoint instead of tracking the primary, and optional logical (mongodump) backups. Physical (PBM) was removed in 2.0.0 — see the traps.

## Common use cases
- Application datastore needing automatic failover rather than a single instance.
- Multi-region deployment where a whole region can be lost.
- A team's shared MongoDB, where the credential is typed into every app's connection string.

## Architecture on cpln
| Resource | Purpose |
|---|---|
| workload `{release}-mongo` (stateful, `replicaDirect`) | mongod members; per-replica DNS for peer discovery |
| workload `{release}-mongo-proxy` (HAProxy, standard, optional) | Single endpoint routing to the current primary |
| workload `{release}-mongo-backup` (cron, optional) | Logical `mongodump` to object storage |
| volumeset per replica | `/data/db`, ext4, snapshots retained 7d |
| identity | Cloud-account binding when backups are enabled |
| policy `{release}-mongo-policy` | `reveal` on the two user secrets plus the chart's scripts |
| policy `{release}-mongo-gvc-policy` | `view` on the ONE install GVC, for the boot-time GVC read |

## Key knobs (shipped 2.0.0 defaults)
`locations` (**one** location, `aws-us-east-1` × 3) | `image` (`percona/percona-server-mongodb:8.0`) | `multiZone` (false) | `resources.cpu`/`.memory` (1 / 2Gi) | `mongodb.credentialsSecretName` (`my-mongodb-credentials`, **must exist before install**) | `mongodb.keyfileSecretName` (`my-mongodb-keyfile`, **must exist before install**) | `volumeset.capacity` (10) | `firewall.internalAllowType` (`same-gvc`) | `proxy.enabled` (true, 2 replicas per location) | `backup.enabled` (false) | `backup.mode` (logical \| physical) | `backup.location` (`aws-us-east-1`, **new in 2.0.0**)

## The GVC conversion (2.0.0)
Three-layer defence, per the standing ruling:
1. **Render-time `fail`** on any top-level `gvc` values key — `helm template -f` against the shipped 1.1.1 values file is refused, which is the real upgrade path, not just `--set`.
2. **`defaultOptions.minScale/maxScale: 0`** on both the mongod and the HAProxy tier, with complete per-location `localOptions`. An undeclared GVC location gets `desiredScale: 0` and no volume.
3. **Boot-time GVC read** — `curl` against `$CPLN_ENDPOINT/org/$CPLN_ORG/gvc/$CPLN_GVC` with `Authorization: $CPLN_TOKEN`, policy scoped `targetKind: gvc` + `targetLinks` to that one GVC. **Fatal on a fresh `/data/db`, warn on an initialised one.**

## Troubleshooting / considerations
- **1.x's DEFAULT WAS BROKEN, and nobody had deploy-tested it.** It shipped 3 locations × 3 replicas = **nine** members. MongoDB permits at most **7 voting** members and every member this chart adds votes (`rs.add` defaults to `votes: 1`), so `replSetReconfig` rejects the 8th. The startup script swallows that error, so members 8 and 9 would have run a mongod that passed its TCP probe, reported `ready: true`, and was **never in the replica set**. 2.0.0 refuses a total above 7 at render time and defaults to 3 in one location.
- **A 2-member set is refused too.** A majority of 2 is 2, so losing either member leaves no primary and the set goes read-only — strictly worse than a single member, which is always its own primary. It is the shape a user reaches by scaling 1 → 2 thinking it is an improvement. There is also a boot-time warning for the case where values say 3 but the GVC is missing a location, leaving 2 members actually running.
- **THE KEYFILE CHARSET TRAP.** mongod accepts **6-1024 characters from the base64 alphabet only** (`A-Z a-z 0-9 + / =`). A `change-me-mongodb-key` style placeholder **will not boot** — hyphens are outside the alphabet — and mongod's own error is unhelpful. Generate with `openssl rand -base64 756`. The startup script validates length and charset at boot; this cannot be a render-time guard because a chart cannot see a secret's contents.
- **The keyfile cannot be a plain secret mount.** mongod refuses a keyfile readable by group or other, and a `cpln://secret/...` mount cannot carry `chmod 400` — so the startup script copies it to `/tmp/mongo-keys/keyfile` and chmods it there. Do not "simplify" this back to a direct mount.
- **Credentials and keyfile are deliberately TWO secrets.** Granting an application `reveal` on the database credentials must not also hand it the key to join the replica set.
- **`workload-list` self-inclusion was present in 1.x and is fixed.** The internal firewall list governs member-to-member replication, HAProxy's health checks and the backup cron — not just client traffic. A list naming only clients cuts the replica set off from itself while every replica still reports `ready: true` (the probes only open a TCP connection to the member's own port, which says nothing about membership). 2.0.0 renders it from a single `mongo-cluster.ownWorkloadLinks` helper used at every call site, gated per workload on the toggle that creates it. 1.x also emitted `inboundAllowWorkload` regardless of `internalAllowType`.
- **1.x sent a PARTIAL `localOptions` entry on the backup cron** (`location` + `suspend` only). The API completes a partial entry from **platform** defaults, not from the workload's `defaultOptions` — measured elsewhere as `capacityAI: true` and `autoscaling {metric: concurrency, maxScale: 5}`, i.e. five concurrent backup pods. 2.0.0 sends the whole block on every entry, everywhere.
- **`backup.location` is now explicit.** 1.x derived it from `backup.aws.region` (and silently used the first GVC location for GCP), tying where the job runs to where the bucket lives. It is validated against `locations`, because the platform accepts a `localOptions` location that does not exist, stores it, and the cron then never runs anywhere with nothing to observe.
- **HAProxy backends were wrong for a mixed roster in 1.x.** It emitted the LARGEST location's replica count for every location, so a 3 + 1 roster produced backends for members that never existed. 2.0.0 emits exactly each location's own `replicas`.
- **PHYSICAL (PBM) BACKUPS WERE REMOVED IN 2.0.0, and `backup.mode: physical` now fails at render** (including when `backup.enabled` is false, so a 1.x values file gets the signal immediately rather than on the day someone enables backups). Its restore could never work: PBM's physical restore must execute `mongod`, and the `pbm-agent` image does not contain it — `check mongod binary: run: exec: "mongod": executable file not found in $PATH`. It failed **silently**, with `pbm status` reporting nothing running while the agent heartbeated into the bucket indefinitely, so it wrote real 300 KB WiredTiger snapshots that could never be restored. An earlier hypothesis blamed the platform restarting mongod as PID 1; that was wrong. Use `backup.mode: logical`, whose restore is verified end to end.
- **The logical restore in 1.x could not work as written.** It told users to run `mongorestore` from "a machine with network access to the cluster" against a `*.cpln.local` address, which no external machine can resolve. 2.0.0 routes it through `cpln port-forward`.

## Status
- **NOT yet deploy-tested at 2.0.0** — this is a build, not a test round. The 1.1.1 baseline was also never deploy-tested.
- Cleared at build time, in the pinned image (`percona/percona-server-mongodb:8.0`, uid 1001/gid 0): it **has `curl` 7.76.1 and no `wget`**; `--connect-timeout 8` bounds a blackholed connect at 8 s and `--max-time 10` bounds an accept-never-respond server at 10 s, while `--connect-timeout` **alone does not bound the second arm** (measured running past 25 s). A refused connection and an NXDOMAIN both return in 0 s and prove nothing about either bound. All five boot-check branches were then exercised against the real image with a mock GVC endpoint: undeclared location → exit 1; all locations present → exit 0; missing location + fresh `/data/db` → exit 1; missing location + `WiredTiger` present → warn, exit 0; unreachable endpoint → warn, exit 0 in ~30 s.
- A test round still owes: both prerequisite secrets resolving at boot, the keyfile guard firing on a bad value, replica-set formation, failover, the proxy path, both backup modes, the `workload-list` path, an undeclared GVC location genuinely reading `deactivated because maxScale is set to 0`, the refused-upgrade row, and the no-op `helm upgrade` drift gate.
