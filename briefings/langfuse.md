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
| `{rel}-langfuse-config` | secret (dictionary) | `redisPassword`/`clickhousePassword` only since 1.3.0 (the Postgres pair moved out). |
| DB credentials secret | secret (dictionary), **user-created** since 1.3.0 | `username`/`password`/`database`, named by `postgres.config.credentialsSecretName`; the postgres subchart AND both Langfuse workloads read it. 1.2.x had the chart render it from `postgres.credentials.*`. |
| `{rel}-langfuse-clickhouse-startup` / `-storage` | secrets (opaque) | Startup script and the S3/GCS disk XML. |
| identity + policy | | `reveal` on exactly those secrets plus the user's prerequisite secrets. |

Three datastores is not optional — Langfuse requires all of Postgres, Redis and ClickHouse.

## Key knobs (defaults as shipped in 1.3.0)

| Knob | Default | Notes |
|---|---|---|
| `langfuse.auth.secretName` | `my-langfuse-auth` | **Prerequisite dictionary secret, 5 keys.** Must exist before install. |
| `langfuse.auth.disableSignup` | `true` | Closed registration; the owner is provisioned headlessly instead. |
| `langfuse.auth.organizationName` | `Langfuse` | Org created for that owner. |
| `publicAccess.enabled` | `true` | Web UI on the canonical endpoint. |
| `internalAccess.type` | `same-gvc` | Web tier only; the datastores are pinned to `same-gvc`. |
| `objectStore.provider` | `aws` | `aws` = keyless cloud account; `gcp` = HMAC pair in a second prerequisite secret. |
| `langfuse.web.image` | `langfuse/langfuse:3.225.2` | Pinned concrete; 1.0.x floated on `:3`. |
| `postgres.config.credentialsSecretName` | `my-langfuse-db-credentials` | **1.3.0: REQUIRED prerequisite** dictionary secret (`username`, `password`, `database`), must exist before install. `postgres.credentials` fails the render. |
| `redis.auth.password` / `clickhouse.config.password` | `change-me-langfuse-{redis,clickhouse}` | Bundled plumbing, used as-is. Unchanged through 1.3.0 (out of scope of work item 5284). |

## Troubleshooting traps

- **The auth secret must exist BEFORE install.** Web and worker mount five keys from it (`nextAuthSecret`, `encryptionKey`, `salt`, `adminEmail`, `adminPassword`). A missing secret does not error at install — the workloads sit waiting on a secret reference and read as a platform fault.
- **`encryptionKey` can never be rotated.** It encrypts the LLM provider API keys users store under Settings → LLM Connections. Change it and every stored provider key becomes unreadable, with no recovery path. This is why it is a prerequisite secret rather than a value: its exposure window is the life of the install. It must be exactly 64 hex characters — a base64 value fails validation at startup.
- **Signup is closed, and the way in is headless init, not a form.** Langfuse has no first-user exemption: `AUTH_DISABLE_SIGNUP=true` blocks email/password *and* first-time SSO user creation. The template therefore sets `LANGFUSE_INIT_ORG_ID`/`_ORG_NAME`/`_USER_EMAIL`/`_USER_PASSWORD` on the web tier, which bypasses the block and creates an OWNER. Init runs on **every** boot and is idempotent (upserts; the user is created only if absent), so changing `adminPassword` in the secret afterwards does **not** change the existing login — reset it in the UI. Note `LANGFUSE_ALLOWED_ORGANIZATION_CREATORS` is EE-gated and inert on OSS, so with `disableSignup: false` any registrant can also create their own org.
- **One bucket, three prefixes, two consumers.** ClickHouse writes to `clickhouse/`, Langfuse to `events/` and `media/`. Pointing two installs at the same bucket without changing prefixes will have them share ClickHouse data parts — always give each install its own bucket.
- **ClickHouse holds no durable local data.** Its volumeset is metadata; the parts are in the object store. A restore is a redeploy pointed at the same bucket. Conversely, deleting the bucket loses all trace history regardless of snapshots.
- **On GCS, credentials reach ClickHouse via `from_env`.** `storage.xml` carries `<access_key_id from_env="GCS_ACCESS_KEY_ID"/>` rather than the literal key, with the pair injected from the prerequisite secret. If ClickHouse starts but S3 disk operations fail with an auth error, check those two env vars exist on the container before suspecting the HMAC key.
- **The first `helm upgrade` after install re-applies the bundled postgres subchart** and the app is briefly unreachable while it restarts — catalog-wide behavior, not a Langfuse defect.
- **1.3.0: the DB credentials became a prerequisite secret (maintainer ruling 2026-10-14, work item 5284).** Rule: when a dependency takes only a credentials-secret NAME, the parent requires the user to create that secret rather than rebuilding it from plaintext values. 1.2.x kept `postgres.credentials.*` as values under the bundled-plumbing exception, rendered `secret-db.yaml` from them AND duplicated the user/password into `-langfuse-config` — both gone. `postgres.credentials` now fails at render (`langfuse.validateRemovedKeys`, mirrored in the wizard). The Langfuse identity gets `reveal` on the user's secret by name; the postgres subchart's own policy grants its identity the same.
- **`DATABASE_URL` is assembled at container start, not at render.** `POSTGRES_USER`, `POSTGRES_PASSWORD` and (new in 1.3.0) `POSTGRES_DB` are `cpln://secret/<name>.{username,password,database}` env vars, and `DATABASE_URL` is `postgresql://$(POSTGRES_USER):$(POSTGRES_PASSWORD)@…:5432/$(POSTGRES_DB)` — the `$(VAR)` pattern langfuse already used for the password since 1.0.x. So all three values must be URL-safe (no render-time check is possible; README says so).
- **Upgrading 1.2.x → 1.3.0 deletes the chart-created DB secret**, because the new chart no longer renders it. The user must create a secret under a NEW name holding the CURRENT credentials (PostgreSQL keeps the password it was initialized with) and point `postgres.config.credentialsSecretName` at it. The wizard enforces the new name with a `semverCompare(context.fromVersion, '1.3.0') < 0` root rule. From 1.1.0 the old secret was `{release}-pg-config`, so any other name works. Expected (per gitea 1.3.0's live measurement, not yet measured here): the upgrade bounces the bundled postgres, and the new reveal grant can stall new workload versions ~10 min (authorization edge cache) while the old version keeps serving.
- **Two releases pointed at one DB secret share a password** — rotating it for one breaks the other. Secret names are org-wide, so give each release its own.
- **The wizard (new in 1.3.0) lists the DB secret on the Langfuse step**, next to the auth secret: it is excluded from the postgres import so every prerequisite secret is created in one place. `postgres.pgbouncer` is `yamlOnly` (Langfuse connects to `{rel}-postgres` directly).
- **Web and worker are `stateful` with no volumes.** That is deliberate (the cpu:minCpu ≤ 4:1 cap applies to them, and all four workloads sit at or under it), but it means `rolloutOptions.maxUnavailableReplicas` is dropped by the API, so the template does not send it.
- **`aws::ReadOnlyAccess` was removed from the object-store identity (`{release}-langfuse-identity`, `objectStore.provider: aws`) in 1.2.1** — not from a backup identity; the postgres subchart's backup identity never carried it. It granted read access to every bucket in the AWS account and contains no write actions, so it was never carrying the object-store writes — what it did carry was account-wide read. The identity is now `cpln-connector` plus the user's bucket-scoped policy only. The documented IAM policy was widened to ten actions at the same time, because `ReadOnlyAccess` had been silently supplying any read action a user's policy omitted; **an upgrading user must update their IAM policy first**.
