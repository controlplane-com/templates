# MongoDB Cluster — Maintainer Briefing

## What it is
- A MongoDB replica set (Percona Server for MongoDB, `percona/percona-server-mongodb:8.0`) with automatic failover, deployable in **one location or stretched across several**.
- **Creates its own GVC** (`createsGvc: true`) — one of the few templates that does. Default is three locations (`aws-us-east-1`, `aws-us-west-2`, `aws-eu-central-1`) × 3 replicas = **nine members across three regions**.
- Optional HAProxy in front so clients hit one endpoint instead of tracking the primary, and optional logical or physical (PBM) backups.

## Common use cases
- Application datastore needing automatic failover rather than a single instance.
- Multi-region deployment where a whole region can be lost.
- A team's shared MongoDB, where the credential is typed into every app's connection string.

## Architecture on cpln
| Resource | Purpose |
|---|---|
| **gvc** `{gvc.name}` | Created by this chart, with `staticPlacement.locationLinks` sorted alphabetically (the API stores them that way; unsorted renders drift from creation) |
| workload `{release}-mongo` (stateful, `replicaDirect`) | mongod members; per-replica DNS for peer discovery |
| workload `{release}-mongo-proxy` (HAProxy, optional) | Single endpoint routing to the current primary |
| workload `{release}-mongo-backup` (cron, optional) | Logical dump or PBM physical backup |
| volumeset per replica | `/data/db` |
| identity + policy | `reveal` on exactly the two user secrets plus the chart's startup script |

## Key knobs (shipped 1.1.0 defaults)
`gvc.name` (`mongodb-gvc`) | `gvc.locations` (3 regions × 3 replicas) | `image` (`percona/percona-server-mongodb:8.0`) | `mongodb.credentialsSecretName` (`my-mongodb-credentials`, **must exist before install**) | `mongodb.keyfileSecretName` (`my-mongodb-keyfile`, **must exist before install**) | `resources.cpu`/`.memory` (1 / 2Gi) | `volumeset.capacity` (10) | `backup.enabled` (false) | `backup.mode` (logical | physical)

## Troubleshooting / considerations
- **Security history — 1.0.0 is dangerous.** It shipped `password: mypassword` and a **live working `replicaSetKey`** as values defaults, both published in this repo. The keyfile is what authenticates replica-set members, so anyone holding it can join a member to the cluster. Tier 2 of the 2026-08-14 catalog secrets audit. A standalone datastore's credentials are the product — typed into every app's connection string — so the bundled-plumbing exception does not apply.
- **THE KEYFILE CHARSET TRAP.** mongod accepts **6-1024 characters from the base64 alphabet only** (`A-Z a-z 0-9 + / =`). A `change-me-mongodb-key` style placeholder **will not boot** — hyphens are outside the alphabet — and mongod's own error is unhelpful. Generate with `openssl rand -base64 756`. The startup script validates length and charset at boot and fails with an explicit message naming the secret; this could not be a render-time guard because a chart cannot see a secret's contents.
- **The keyfile cannot be a plain secret mount.** mongod refuses a keyfile readable by group or other, and a `cpln://secret/...` mount cannot carry `chmod 400` — so the startup script copies it to `/tmp/mongo-keys/keyfile` and chmods it there. Do not "simplify" this back to a direct mount.
- **Credentials and keyfile are deliberately TWO secrets.** Granting an application `reveal` on the database credentials must not also hand it the key to join the replica set. Same reasoning as mysql/mariadb splitting root from the app credentials.
- **A GVC-CREATING TEMPLATE CAN DESTROY A GVC IT DID NOT CREATE.** If `gvc.name` matches an existing GVC, Helm **adopts** it and `helm uninstall` then **deletes it**, taking every unrelated workload with it — observed 2026-08-07 destroying `test-gvc`, and it happened *despite* a `helm.sh/resource-policy: keep` annotation. Adoption also pins the release name permanently. Never point this at a shared or pre-existing GVC. For testing, `gvc.name` must start with a test prefix — the policy hook only permits a chart-created GVC under that condition.
- **The default is nine members across three regions, and cross-region traffic is billed.** Whether that should be the shipped default is an open maintainer question; it is a large default bill for someone who installs without reading.
- **`aws::ReadOnlyAccess` is on the identity.** A broad managed policy CLAUDE.md forbids, but it is a catalog-wide pattern across 22 templates pending a maintainer ruling — deliberately left alone in 1.1.0.

## Status
- **NOT yet deploy-tested at 1.1.0.** The build landed the security changes, the keyfile handling and a clean bare render. A test round still owes: both prerequisite secrets resolving at boot, the keyfile guard firing on a bad value, replica-set formation, failover, the proxy path, both backup modes, and the no-op `helm upgrade` drift gate.
- The build was interrupted twice mid-run; its work was committed by the orchestrator and the README and this briefing completed afterwards. Treat the untested rows above as genuinely untested, not merely unreported.
- **`aws::ReadOnlyAccess` was removed from the backup identity in 1.1.1.** It granted read access to every bucket in the AWS account and contains no write actions, so it was never carrying the backup — what it did carry was account-wide read. The identity is now `cpln-connector` plus the user's bucket-scoped policy only. The documented IAM policy was widened to ten actions at the same time, because `ReadOnlyAccess` had been silently supplying any read action a user's policy omitted; **an upgrading user must update their IAM policy first**.
