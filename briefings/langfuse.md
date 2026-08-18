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
| `{rel}-postgres` | postgres 3.2.1 subchart | Users, projects, API keys, prompts, datasets, eval configs. **The one thing that must be backed up.** |
| `{rel}-langfuse-redis` | workload (`stateful`) + volumeset | BullMQ queue + API-key/prompt cache. Transient. |
| `{rel}-langfuse-clickhouse` | workload (`stateful`) + volumeset | Traces/observations/scores. Data parts go to the object store; the volumeset holds metadata only. |
| `{rel}-langfuse-config` | secret (dictionary) | Bundled datastore credentials only — no key material since 1.1.0. |
| `{rel}-langfuse-clickhouse-startup` / `-storage` | secrets (opaque) | Startup script and the S3/GCS disk XML. |
| identity + policy | | `reveal` on exactly those secrets plus the user's prerequisite secrets. |

Three datastores is not optional — Langfuse requires all of Postgres, Redis and ClickHouse.

## Key knobs (defaults as shipped in 1.1.0)

| Knob | Default | Notes |
|---|---|---|
| `langfuse.auth.secretName` | `my-langfuse-auth` | **Prerequisite dictionary secret, 5 keys.** Must exist before install. |
| `langfuse.auth.disableSignup` | `true` | Closed registration; the owner is provisioned headlessly instead. |
| `langfuse.auth.organizationName` | `Langfuse` | Org created for that owner. |
| `publicAccess.enabled` | `true` | Web UI on the canonical endpoint. |
| `internalAccess.type` | `same-gvc` | Web tier only; the datastores are pinned to `same-gvc`. |
| `objectStore.provider` | `aws` | `aws` = keyless cloud account; `gcp` = HMAC pair in a second prerequisite secret. |
| `langfuse.web.image` | `langfuse/langfuse:3.225.2` | Pinned concrete; 1.0.x floated on `:3`. |
| `postgres/redis/clickhouse.*.password` | `change-me-langfuse-{db,redis,clickhouse}` | Bundled plumbing, used as-is. |

## Troubleshooting traps

- **The auth secret must exist BEFORE install.** Web and worker mount five keys from it (`nextAuthSecret`, `encryptionKey`, `salt`, `adminEmail`, `adminPassword`). A missing secret does not error at install — the workloads sit waiting on a secret reference and read as a platform fault.
- **`encryptionKey` can never be rotated.** It encrypts the LLM provider API keys users store under Settings → LLM Connections. Change it and every stored provider key becomes unreadable, with no recovery path. This is why it is a prerequisite secret rather than a value: its exposure window is the life of the install. It must be exactly 64 hex characters — a base64 value fails validation at startup.
- **Signup is closed, and the way in is headless init, not a form.** Langfuse has no first-user exemption: `AUTH_DISABLE_SIGNUP=true` blocks email/password *and* first-time SSO user creation. The template therefore sets `LANGFUSE_INIT_ORG_ID`/`_ORG_NAME`/`_USER_EMAIL`/`_USER_PASSWORD` on the web tier, which bypasses the block and creates an OWNER. Init runs on **every** boot and is idempotent (upserts; the user is created only if absent), so changing `adminPassword` in the secret afterwards does **not** change the existing login — reset it in the UI. Note `LANGFUSE_ALLOWED_ORGANIZATION_CREATORS` is EE-gated and inert on OSS, so with `disableSignup: false` any registrant can also create their own org.
- **One bucket, three prefixes, two consumers.** ClickHouse writes to `clickhouse/`, Langfuse to `events/` and `media/`. Pointing two installs at the same bucket without changing prefixes will have them share ClickHouse data parts — always give each install its own bucket.
- **ClickHouse holds no durable local data.** Its volumeset is metadata; the parts are in the object store. A restore is a redeploy pointed at the same bucket. Conversely, deleting the bucket loses all trace history regardless of snapshots.
- **On GCS, credentials reach ClickHouse via `from_env`.** `storage.xml` carries `<access_key_id from_env="GCS_ACCESS_KEY_ID"/>` rather than the literal key, with the pair injected from the prerequisite secret. If ClickHouse starts but S3 disk operations fail with an auth error, check those two env vars exist on the container before suspecting the HMAC key.
- **The first `helm upgrade` after install re-applies the bundled postgres subchart** and the app is briefly unreachable while it restarts — catalog-wide behavior, not a Langfuse defect.
- **Web and worker are `stateful` with no volumes.** That is deliberate (the cpu:minCpu ≤ 4:1 cap applies to them, and all four workloads sit at or under it), but it means `rolloutOptions.maxUnavailableReplicas` is dropped by the API, so the template does not send it.
