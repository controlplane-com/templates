# langfuse

Self-hosted **Langfuse** — LLM observability and evaluation. Traces, prompt management, evaluations, and a playground for LLM apps. OSS edition (MIT core); the template ships the free self-host build, so the EE-gated features (org-creator allowlists, data-retention policies, per-project RBAC extras) are simply absent.

## Common use cases

- Tracing an LLM app's calls end to end and inspecting cost/latency/token usage per trace.
- Prompt management with versioning, pulled by the SDK at runtime.
- LLM-as-judge evaluations and datasets on captured production traces.
- Keeping trace data (which frequently contains customer prompts) inside the user's own bucket rather than a vendor's.

## Architecture

| Resource | Type | Notes |
|---|---|---|
| `{rel}-langfuse-web` | workload (`stateful`) | Next.js UI + public API on :3000, autoscales 2–5 on CPU. The only tier with public inbound. |
| `{rel}-langfuse-worker` | workload (`stateful`) | Ingestion/eval processor. No inbound. |
| `{rel}-postgres` | postgres **3.4.1** subchart since 1.2.0 (creates no secret of its own) | Users, projects, API keys, prompts, datasets, eval configs. **The one thing that must be backed up.** |
| `{rel}-langfuse-redis` | workload (`stateful`) + volumeset | BullMQ queue + API-key/prompt cache. Transient. |
| `{rel}-langfuse-clickhouse` | workload (`stateful`) + volumeset | Traces/observations/scores. Data parts go to the object store; the volumeset holds metadata only. |
| `{rel}-langfuse-config` | secret (dictionary) | Bundled datastore credentials the APP reads (`postgresUsername`/`postgresPassword`/`redisPassword`/`clickhousePassword`) — no key material since 1.1.0. |
| `my-langfuse-db-credentials` | secret (dictionary), **chart-created**, 1.2.0+ | `username`/`password`/`database` for the bundled DB; built from `postgres.credentials.*` and handed to the postgres subchart by name. **Deliberately separate** from `-langfuse-config`. |
| `{rel}-langfuse-clickhouse-startup` / `-storage` | secrets (opaque) | Startup script and the S3/GCS disk XML. |
| identity + policy | | `reveal` on exactly those secrets plus the user's prerequisite secrets. |

Three datastores is not optional — Langfuse requires all of Postgres, Redis and ClickHouse.

## Key knobs (defaults as shipped in 1.2.0)

| Knob | Default | Notes |
|---|---|---|
| `langfuse.auth.secretName` | `my-langfuse-auth` | **Prerequisite dictionary secret, 5 keys.** Must exist before install. |
| `langfuse.auth.disableSignup` | `true` | Closed registration; the owner is provisioned headlessly instead. |
| `langfuse.auth.organizationName` | `Langfuse` | Org created for that owner. |
| `publicAccess.enabled` | `true` | Web UI on the canonical endpoint. |
| `internalAccess.type` | `same-gvc` | Web tier only; the datastores are pinned to `same-gvc`. |
| `objectStore.provider` | `aws` | `aws` = keyless cloud account; `gcp` = HMAC pair in a second prerequisite secret. |
| `langfuse.web.image` | `langfuse/langfuse:3.225.2` | Pinned concrete; 1.0.x floated on `:3`. |
| `postgres.credentials.{username,password,database}` | `langfuse` / `change-me-langfuse-db` / `langfuse` | **1.2.0** — was `postgres.config.*`; bundled plumbing, still plain values. |
| `postgres.config.credentialsSecretName` | `my-langfuse-db-credentials` | **1.2.0** — name of the dictionary secret the CHART creates and the subchart reads; org-wide, so unique per release. |
| `redis.auth.password` / `clickhouse.config.password` | `change-me-langfuse-{redis,clickhouse}` | Bundled plumbing, used as-is. Unchanged in 1.2.0. |

## Troubleshooting traps

- **The auth secret must exist BEFORE install.** Web and worker mount five keys from it (`nextAuthSecret`, `encryptionKey`, `salt`, `adminEmail`, `adminPassword`). A missing secret does not error at install — the workloads sit waiting on a secret reference and read as a platform fault.
- **`encryptionKey` can never be rotated.** It encrypts the LLM provider API keys users store under Settings → LLM Connections. Change it and every stored provider key becomes unreadable, with no recovery path. This is why it is a prerequisite secret rather than a value: its exposure window is the life of the install. It must be exactly 64 hex characters — a base64 value fails validation at startup.
- **Signup is closed, and the way in is headless init, not a form.** Langfuse has no first-user exemption: `AUTH_DISABLE_SIGNUP=true` blocks email/password *and* first-time SSO user creation. The template therefore sets `LANGFUSE_INIT_ORG_ID`/`_ORG_NAME`/`_USER_EMAIL`/`_USER_PASSWORD` on the web tier, which bypasses the block and creates an OWNER. Init runs on **every** boot and is idempotent (upserts; the user is created only if absent), so changing `adminPassword` in the secret afterwards does **not** change the existing login — reset it in the UI. Note `LANGFUSE_ALLOWED_ORGANIZATION_CREATORS` is EE-gated and inert on OSS, so with `disableSignup: false` any registrant can also create their own org.
- **One bucket, three prefixes, two consumers.** ClickHouse writes to `clickhouse/`, Langfuse to `events/` and `media/`. Pointing two installs at the same bucket without changing prefixes will have them share ClickHouse data parts — always give each install its own bucket.
- **ClickHouse holds no durable local data.** Its volumeset is metadata; the parts are in the object store. A restore is a redeploy pointed at the same bucket. Conversely, deleting the bucket loses all trace history regardless of snapshots.
- **On GCS, credentials reach ClickHouse via `from_env`.** `storage.xml` carries `<access_key_id from_env="GCS_ACCESS_KEY_ID"/>` rather than the literal key, with the pair injected from the prerequisite secret. If ClickHouse starts but S3 disk operations fail with an auth error, check those two env vars exist on the container before suspecting the HMAC key.
- **The first `helm upgrade` after install re-applies the bundled postgres subchart** and the app is briefly unreachable while it restarts — catalog-wide behavior, not a Langfuse defect.
- **1.2.0 adopted postgres 3.4.1, and langfuse absorbed the break rather than passing it on.** 3.4.0 deleted its `{release}-pg-config` secret and now takes only a secret NAME. Because a parent cannot template a subchart value, the name is a plain value (`postgres.config.credentialsSecretName`) that both sides read: langfuse's `secret-db.yaml` renders it, the subchart's env refs and policy consume it. Net user-visible change is one rename (`postgres.config.{username,password,database}` → `postgres.credentials.*`); **no new prerequisite**, because no human ever types this password. The auth/ClickHouse/Redis paths are untouched.
- **The DB secret is a SECOND secret on purpose — do not merge it into `{rel}-langfuse-config`.** The postgres subchart's policy grants its identity `reveal` on the *entire* secret it is handed. `-langfuse-config` also carries `redisPassword` and `clickhousePassword`, so pointing the subchart at it would give the Postgres identity both. The two DB values are therefore rendered into both secrets and read by different identities; that duplication is intended.
- **The secret name is org-wide, not release-scoped** (forced by the Helm limitation above). Two langfuse releases left on the default name: the second is **refused at install** — `cannot be updated because it is being managed by a different release` — and creates nothing. Nothing is shared, overwritten or deleted. No render-time guard for it.
- **A stale 1.1.0 values file fails with the SUBCHART's message, not langfuse's.** Helm renders `charts/…` before `templates/…`, so a parent-side guard would be dead code and was deliberately not added (unlike `langfuse.validateRemovedKeys`, which covers 1.1.0's own removals). The README's "Upgrading from 1.1.0" table carries the rename.
- **Web and worker are `stateful` with no volumes.** That is deliberate (the cpu:minCpu ≤ 4:1 cap applies to them, and all four workloads sit at or under it), but it means `rolloutOptions.maxUnavailableReplicas` is dropped by the API, so the template does not send it.
- **`aws::ReadOnlyAccess` was removed from the backup identity in 1.2.1.** It granted read access to every bucket in the AWS account and contains no write actions, so it was never carrying the backup — what it did carry was account-wide read. The identity is now `cpln-connector` plus the user's bucket-scoped policy only. The documented IAM policy was widened to ten actions at the same time, because `ReadOnlyAccess` had been silently supplying any read action a user's policy omitted; **an upgrading user must update their IAM policy first**.
