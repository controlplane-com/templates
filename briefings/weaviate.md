# Weaviate — Maintainer Briefing

## What it is
- Weaviate, the open-source (BSD-3) AI-native vector database: stores objects alongside their vector embeddings and serves hybrid (vector + keyword) search over them. Free to self-host, no registration, no key.
- Template ships `semitechnologies/weaviate:1.38.0` (appVersion `1.38.0`) as a 3-replica raft cluster, one persistent volume per replica.
- Optional AI modules let Weaviate call a provider (OpenAI, Anthropic, Cohere, HuggingFace) to embed on insert and query, instead of the caller supplying vectors.

## Common use cases
- Semantic / hybrid search over a document corpus, with the app supplying its own embeddings (`defaultVectorizerModule: none`).
- RAG retrieval layer where Weaviate does the embedding itself via a `text2vec-*` module.
- Recommendation / similarity lookup on existing vectors.

## Architecture on cpln
| Resource | Purpose |
|---|---|
| workload `{release}-weaviate` (stateful, `replicas: 3`) | Weaviate nodes, HTTP `8080` + gRPC; raft cluster |
| volumeset (20 GiB/replica, autoscaling to 200) | HNSW index + object store, one per replica |
| secret `{release}-weaviate-credentials` (dictionary) | Holds `api-user` only — NOT the key |
| secret `{release}-weaviate-start-script` | Boot script |
| workload `{release}-weaviate-backup` (cron, optional) | Scheduled backup to S3 or GCS |
| identity + policy | `reveal` on exactly: the two chart secrets, the user's API-key secret, and any provider secrets actually named |

- **No public endpoint, unconditionally.** `inboundAllowCIDR` is hardcoded empty — not gated on a knob — because Weaviate holds the user's embeddings and its only auth is a single bearer key. Reachability is `internalAccess.type` only (default `same-gvc`).

## Key knobs (shipped 1.1.0 defaults)
`replicas` (3) | `image` (`semitechnologies/weaviate:1.38.0`) | `apiKeySecretName` (`my-weaviate-api-key`, **must exist before install**) | `apiUser` (`admin@example.com`) | `queryDefaultsLimit` (25) | `defaultVectorizerModule` (`none`) | `modules.enabled` (`[]`) | `modules.{openai,anthropic,cohere,huggingface}.apiKeySecretName` (`""` = off) | `cpu`/`memory` (2 / 4Gi) | `volumes.data.initialCapacity` (20) | `multiZone.enabled` (false) | `internalAccess.type` (`same-gvc`) | `backup.enabled` (false)

## Troubleshooting / considerations
- **Security history — 1.0.1 and earlier are dangerous.** They shipped `apiKey: 21203583df…` as a values default: one live 64-hex credential, published in our public repo, shared by every install that did not override it. It is the *only* auth Weaviate has, so it grants read and write on every collection. Tier 2 of the 2026-08-14 catalog secrets audit. Anyone on ≤1.0.1 should treat their key as compromised and rotate it, not merely upgrade.
- **The API key is a REQUIRED prerequisite secret with a placeholder default**, so a bare render passes but installing without creating the secret **wedges** the deployment waiting on a nonexistent secret — and it looks broken rather than misconfigured. This has embarrassed us in a live demo before. Recovery is not obvious either: creating the secret afterwards may not un-wedge it on its own; `cpln workload force-redeployment` does.
- **Provider keys were also values, and are now OPTIONAL prerequisite secrets.** Empty means genuinely off — no env var, no `reveal` grant, no dangling policy target (verified on a bare render). Anyone enabling a vectorizer module on ≤1.0.1 put their own OpenAI/Anthropic **billing** key into the Helm release in plaintext.
- **Naming a provider secret does NOT enable the module.** `modules.enabled` is a separate list and must name the module too. This is the most likely "I configured it and nothing happened" report.
- **`apiUser` is deliberately not a secret.** It is the admin-list identity, not a credential; it lands in a chart dictionary secret purely so the workload can reference it as an env var.
- **Memory is the sizing constraint, not CPU.** HNSW indexes are RAM-resident; the values comment carries the rule of thumb (`vectors × dimensions × 4 bytes × 1.5`). Under-provisioning shows up as OOM, not as slow queries.
- **Resource block is limit-only, so bare `cpu`/`memory` is correct** per the 2026-08-05 naming ruling — do not "fix" these to `maxCpu`/`maxMemory`.
- **`aws::ReadOnlyAccess` is on the identity.** A broad managed policy CLAUDE.md forbids, but it is a catalog-wide pattern across 22 templates and is pending a maintainer ruling — deliberately left alone in 1.1.0.

## Status — deploy-tested 2026-08-18: 8 PASS, 2 FAIL

The **security change is fully proven**: the key is enforced (401 unauthenticated, 401 wrong key, 200 correct, a real object written and returned by a `nearVector` search), absent from computed values, manifest, stored specs, secret reveals and 288 KB of logs, with no dangling policy targets and no egress opened when providers are unused.

Two **pre-existing** defects were found — neither introduced by 1.1.0, both now confirmed rather than suspected:

- **A ROLLING RESTART PERMANENTLY SPLITS A REPLICA OUT OF THE CLUSTER.** One `force-redeployment` left `test-wv-weaviate-0` a leaderless `Candidate` (`leaderId=''`, `lastContact=never`, `commitIndex=0` against `lastLogIndex=8` — raft log on disk, nothing applied). Replicas 1 and 2 elected a leader without it and it **never rejoined**: still broken 31 minutes later, with a 60-sample probe measuring `200: 42 (70%) / 404: 18 (30%)` — exactly one node in three. **Control Plane reports all three replicas `ready`, so the broken node stays in service-DNS rotation.** Cause: the start script sets `CLUSTER_JOIN` (gossip) but never `RAFT_JOIN`/`RAFT_BOOTSTRAP_EXPECT`, and treats replica-0 as bootstrap on *every* boot. Note the restart of replicas 1 and 2 was seamless (270/270 OK) — the rollout pacing is fine; **rejoin** is what is broken. So the shipped `replicas: 3` default is not safe across an upgrade, and `helm upgrade` is how every user will hit it.
- **`modules.enabled` does not gate anything.** With `modules.enabled: []`, `text2vec-openai` still loads and a vector-less insert generated a real embedding through a stub. The risk is the inverse of what the values comment claims: supplying a provider key "just to configure it" yields a **live, billable** integration. An `ENABLE_MODULES` allow-list was proposed and then **disproven** — with it genuinely in force, `/v1/meta` still reports all 41 modules.

Also unverified: **backup was NOT tested** (needs an S3 bucket and IAM policy outside the test blast radius) — renders and validation negatives pass, and the cron job's URL derivation was live-checked, but `status.aws.usable` is exactly the surface CLAUDE.md warns can report false success. And with `internalAccess.type: workload-list` the backup cron is not on the allow-list, so its calls would be denied.
