# Hindsight

This app deploys [Hindsight](https://github.com/vectorize-io/hindsight), an open-source memory server for AI agents. Agents **retain** conversations and documents, an LLM extracts facts, entities and timestamps into a per-bank memory graph on PostgreSQL with pgvector, and agents **recall** (hybrid search, reranked) or **reflect** (the LLM reasons over the bank) through a REST API or the built-in MCP server.

## Architecture

- **API** (`RELEASE_NAME-hindsight`): standard workload serving REST (`/v1/...`) and MCP (`/mcp/BANK_ID/`) on port 8888, 1 replica by default. Replicas share PostgreSQL, so they are interchangeable. Without dedicated workers each replica also runs retain, consolidation and other background tasks. The default image (about 1 GB compressed) bundles the local embedding model (`BAAI/bge-small-en-v1.5`) and reranker (`hs-rerank-1`), so recall makes no external call.
- **Web UI** (`RELEASE_NAME-hindsight-ui`, on by default): Hindsight's web UI (called Hindsight Control Plane upstream) on port 9999, behind an access key you type to log in. It calls the API inside the GVC with the API key.
- **Dedicated workers** (`RELEASE_NAME-hindsight-worker`, optional): stateful workload that takes background tasks off the API. Each replica keeps a stable worker id, so a restarted worker picks up its own unfinished tasks.
- **PostgreSQL**: the `pgvector` template (single instance, default; PostgreSQL 19 with pgvector 0.8.7) or the `postgres-highly-available` template (PostgreSQL 17: 3 Patroni replicas, 3 etcd replicas and an HAProxy leader endpoint). Holds every bank, fact, entity and document. The single instance refuses to start on a data directory from another PostgreSQL major version and leaves it untouched (see [Upgrading from 1.x](#upgrading-from-1x)).
- **Identities + policies**: `reveal` on exactly the secrets you name. The template creates no secrets.

The API and the web UI are private by default: reach them from the same GVC or with `cpln port-forward`.

## Prerequisites

**Create these secrets BEFORE you install.** Secret names are org-wide, so give each release its own:

```bash
# API key: the Bearer token for REST and MCP. It opens every bank.
printf '%s' "$(openssl rand -hex 32)" | cpln secret create-opaque --name my-hindsight-api-key --encoding plain -f -

# Database credentials: letters and digits only (they go into a connection URL)
cpln secret create-dictionary --name my-hindsight-db-credentials \
  --entry username=hindsight \
  --entry password="$(openssl rand -hex 24)" \
  --entry database=hindsight

# Web UI access key (while ui.enabled is true)
printf '%s' "$(openssl rand -hex 16)" | cpln secret create-opaque --name my-hindsight-ui-access-key --encoding plain -f -

# LLM provider key (not needed for Ollama or a self-hosted server without auth)
printf '%s' "$OPENAI_API_KEY" | cpln secret create-opaque --name my-hindsight-llm-key --encoding plain -f -
```

**If a secret the release names does not exist, the deployment waits silently**: `cpln logs` returns nothing. The only signal is `status.versions[].message` in `cpln workload get-deployments RELEASE_NAME-hindsight --gvc GVC_NAME -o yaml`. Create the secret and run `cpln workload force-redeployment RELEASE_NAME-hindsight --gvc GVC_NAME`.

**LLM**: a model with JSON-schema (structured) output. Hindsight asks for up to 65k output tokens per retain call; for a model with a smaller limit set `HINDSIGHT_API_RETAIN_MAX_COMPLETION_TOKENS` (above 3000) in `hindsight.extraEnv`.

**Backups (optional)**: a bucket and a Control Plane cloud account (on AWS also a bucket-scoped IAM policy), set up as in the [pgvector](https://docs.controlplane.com/template-catalog/templates/pgvector) or [postgres-highly-available](https://docs.controlplane.com/template-catalog/templates/postgres-highly-available) template.

## Configuration

```yaml
auth:
  apiKeySecretName: my-hindsight-api-key

llm:
  provider: openai              # e.g. openai, anthropic, gemini, groq, ollama, litellm
  model: gpt-5-mini             # must support JSON-schema output
  baseUrl: ""                   # "" = provider default; e.g. http://my-ollama.my-gvc.cpln.local:11434/v1
  apiKeySecretName: my-hindsight-llm-key

embeddings:
  provider: local               # local (bundled BAAI/bge-small-en-v1.5, 384 dims) | openai (OpenAI or OpenAI-compatible)
reranker:
  provider: local               # local (bundled hs-rerank-1) | rrf (no model; required with the slim image)

hindsight:
  image: ghcr.io/vectorize-io/hindsight-api:1.2.1
  # set hindsight.replicas: 2, worker.enabled: true and postgresHA.enabled: true for near-zero-downtime upgrades and failover
  replicas: 1                   # 1-10 interchangeable API replicas sharing PostgreSQL
  requestTimeoutSeconds: 300    # longest request (a sync retain or reflect waits on the LLM) before it is cut (1-3600)
  dbPoolMaxSize: 20             # PostgreSQL connections per process; (replicas + worker replicas) x this must be <= 90

worker:
  enabled: false                # true = background tasks move off the API into their own workload
  replicas: 1                   # 1-10

ui:
  enabled: true                 # browse banks, entities and documents; test recall and reflect
  accessKeySecretName: my-hindsight-ui-access-key

publicAccess:
  api: false                    # true = REST + MCP on a public *.cpln.app URL (API key still required)
  ui: false                     # true = web UI on a public *.cpln.app URL (access key still required)
internalAccess:                 # who in Control Plane may call the API
  type: same-gvc                # none | same-gvc | same-org | workload-list (none needs ui.enabled: false)
  workloads: []                 # used with workload-list

pgvector:                       # PostgreSQL 19; a release upgraded from 1.x keeps 18 (Upgrading from 1.x)
  enabled: true
  config:
    credentialsSecretName: my-hindsight-db-credentials
# set postgresHA.enabled: true (and pgvector.enabled: false) for near-zero-downtime upgrades and failover
postgresHA:
  enabled: false
  config:
    credentialsSecretName: my-hindsight-db-credentials
```

Other LLM providers, with the provider's own key in `llm.apiKeySecretName` (empty for a server without auth):

| Provider | `llm.provider` | `llm.model` (example) | `llm.baseUrl` |
|---|---|---|---|
| Anthropic | `anthropic` | `claude-sonnet-4-5` | `""` |
| Gemini | `gemini` | `gemini-2.5-flash` | `""` |
| Ollama template | `ollama` | `qwen2.5:7b` | `http://OLLAMA_RELEASE-ollama.GVC_NAME.cpln.local:11434/v1` |
| vLLM template | `openai` | the served model name | `http://VLLM_RELEASE-vllm.GVC_NAME.cpln.local:8000/v1` |
| LiteLLM template | `openai` | a model name LiteLLM routes | `http://LITELLM_RELEASE-litellm.GVC_NAME.cpln.local:4000/v1` |

A small local model on CPU can need minutes for one reflect; raise `hindsight.requestTimeoutSeconds` (up to 3600) or give Ollama a GPU.

**Self-hosted embeddings and the slim image.** The `-slim` image is less than half the size but has no local models: set `embeddings.provider: openai` with an OpenAI-compatible server and `reranker.provider: rrf` (rank fusion, no model):

```yaml
hindsight:
  image: ghcr.io/vectorize-io/hindsight-api:1.2.1-slim
embeddings:
  provider: openai
  model: nomic-embed-text
  baseUrl: http://my-ollama.my-gvc.cpln.local:11434/v1
  apiKeySecretName: ""          # openai only; opaque secret. "" = use the LLM key
reranker:
  provider: rrf
```

**Extra settings.** Any upstream `HINDSIGHT_API_*` setting goes in `hindsight.extraEnv`; secret ones (a Cohere reranker key, per-operation LLM keys) go in a dictionary secret listed in `hindsight.extraSecrets`. The chart refuses the settings it owns, including every `HINDSIGHT_API_TENANT_*` setting.

### Backup retention

The backup job only uploads; it never deletes old backups. To keep a fixed window, add a lifecycle rule on the bucket that expires objects under the backup prefix. Each backup is a complete, standalone copy, so expiring old ones never affects restoring a newer one. Set the window to at least your retention plus one backup interval, and note that an age rule keeps no minimum: if backups stop running, the last ones expire too.

In `wal-g` mode (`postgresHA.backup.mode: wal-g`), a restore needs the newest full base backup plus the WAL files written after it, all under the same prefix and never rewritten. Older base backups and the WAL before them are not needed, so the same rule is safe as long as the window is longer than two base-backup intervals (`postgresHA.backup.walg.intervalSeconds`). If base backups stop while WAL archiving continues, the rule eventually expires the last base backup, so check that new `basebackups_005/` entries keep appearing.

The rules below cover both default prefixes, `pgvector/backups/` (`pgvector.backup.<provider>.prefix`) and `postgres/backups/` (`postgresHA.backup.<provider>.prefix`); change them if you changed those values.

**AWS S3.** `put-bucket-lifecycle-configuration` **replaces every existing rule on the bucket**, so check for existing rules first and add them to the file:

```bash
aws s3api get-bucket-lifecycle-configuration --bucket BUCKET_NAME
cat > lifecycle.json <<'EOF'
{"Rules":[{"ID":"expire-db-backups","Filter":{"Prefix":"pgvector/backups/"},"Status":"Enabled",
  "Expiration":{"Days":30},"NoncurrentVersionExpiration":{"NoncurrentDays":1}},
 {"ID":"expire-db-backups-2","Filter":{"Prefix":"postgres/backups/"},"Status":"Enabled",
  "Expiration":{"Days":30},"NoncurrentVersionExpiration":{"NoncurrentDays":1}}]}
EOF
aws s3api put-bucket-lifecycle-configuration --bucket BUCKET_NAME --lifecycle-configuration file://lifecycle.json
```

**Google Cloud Storage.** `--lifecycle-file` also **replaces the bucket's existing rules**; check with `gcloud storage buckets describe gs://BUCKET_NAME --format='json(lifecycle_config)'` first:

```bash
cat > lifecycle.json <<'EOF'
{"rule":[
  {"action":{"type":"Delete"},"condition":{"age":30,"matchesPrefix":["pgvector/backups/","postgres/backups/"]}},
  {"action":{"type":"Delete"},"condition":{"daysSinceNoncurrentTime":1,"isLive":false,"matchesPrefix":["pgvector/backups/","postgres/backups/"]}}]}
EOF
gcloud storage buckets update gs://BUCKET_NAME --lifecycle-file=lifecycle.json
```

**MinIO** (adds a rule alongside existing ones; the access key needs `s3:PutLifecycleConfiguration`, which the built-in `readwrite` policy grants):

```bash
mc ilm rule add --expire-days 30 --noncurrent-expire-days 1 --prefix "pgvector/backups/" ALIAS/BUCKET_NAME
mc ilm rule add --expire-days 30 --noncurrent-expire-days 1 --prefix "postgres/backups/" ALIAS/BUCKET_NAME
mc ilm rule ls ALIAS/BUCKET_NAME
```

Lifecycle rules run in the background; objects are removed within about a day of reaching the age. The `Noncurrent` parts matter only on a versioned bucket, where expiry otherwise just adds a delete marker.

## Connecting

| Endpoint | Address | Auth |
|---|---|---|
| REST API, same GVC | `http://RELEASE_NAME-hindsight.GVC_NAME.cpln.local:8888/v1/default/banks/BANK_ID/...` | `Authorization: Bearer API_KEY` |
| MCP, same GVC | `http://RELEASE_NAME-hindsight.GVC_NAME.cpln.local:8888/mcp/BANK_ID/` | `Authorization: Bearer API_KEY` |
| API, public (`publicAccess.api: true`) | `status.canonicalEndpoint` of `RELEASE_NAME-hindsight` | `Authorization: Bearer API_KEY` |
| Web UI, public (`publicAccess.ui: true`) | `status.canonicalEndpoint` of `RELEASE_NAME-hindsight-ui` | access key |
| Health, no auth | `/health` on port 8888 | none |

From a workload in the same GVC:

```bash
H="Authorization: Bearer $HINDSIGHT_API_KEY"
URL=http://RELEASE_NAME-hindsight.GVC_NAME.cpln.local:8888

curl -s -X POST "$URL/v1/default/banks/my-agent/memories" -H "$H" -H 'content-type: application/json' \
  -d '{"items":[{"content":"Alice prefers oolong tea and works on the billing team."}]}'
curl -s -X POST "$URL/v1/default/banks/my-agent/memories/recall" -H "$H" -H 'content-type: application/json' \
  -d '{"query":"What does Alice drink?"}'
curl -s -X POST "$URL/v1/default/banks/my-agent/reflect" -H "$H" -H 'content-type: application/json' \
  -d '{"query":"What do we know about Alice?"}'
```

A bank is created on first use. Without the key every `/v1` and `/mcp` call returns `401`. Read a canonical endpoint with `cpln workload get RELEASE_NAME-hindsight --gvc GVC_NAME -o yaml`.

**MCP clients** connect to one bank at `/mcp/BANK_ID/` (streamable HTTP); the tools include `retain`, `recall` and `reflect`. For Claude Code, with the public API:

```bash
claude mcp add --transport http hindsight https://CANONICAL_ENDPOINT/mcp/my-agent/ \
  --header "Authorization: Bearer $HINDSIGHT_API_KEY"
```

With `--scope project`, Claude Code lists the server as pending until you approve it the next time you start `claude`.

**From your machine**, while private, forward the API or the web UI (then open `http://localhost:9999` and log in with the access key):

```bash
cpln port-forward RELEASE_NAME-hindsight 8888:8888 --gvc GVC_NAME
cpln port-forward RELEASE_NAME-hindsight-ui 9999:9999 --gvc GVC_NAME
```
A forwarded web UI can stop responding in a browser after a while; restart the forward (or fully quit the browser), or use `publicAccess.ui: true` for regular use. Firewall changes take 30 seconds to a few minutes to take effect.

## Upgrading from 1.x

The single-instance database of 2.0.0 runs PostgreSQL 19. A 1.x release's data directory is PostgreSQL 18, and a data directory only starts under the major version that created it: on a PostgreSQL 19 image the database container does not start PostgreSQL and changes nothing on the volume. `RELEASE_NAME-pgvector` stays not ready, Hindsight waits for it, and the database logs repeat a `[pg-guard] REFUSING TO START` message. That message names the key `image`; in this chart the key is `pgvector.image`. A release on `postgresHA` is not affected: the highly available database keeps its own image.

**Stay on PostgreSQL 18.** Pin the image, and keep the pin in your values file for every later upgrade (`cpln helm upgrade` does not reuse the release's values):

```yaml
pgvector:
  image: pgvector/pgvector:0.8.7-pg18
```

If an upgrade ran without the pin, run the same upgrade again with `--set pgvector.image=pgvector/pgvector:0.8.7-pg18`; the database comes back on its data. The Console wizard keeps the installed image on upgrade and warns before a change to another major version.

**Move to PostgreSQL 19** (dump and restore into a new release in the same GVC):

1. Install 2.0.0 as a **new release** with the **same database credentials secret** (and the same API key, LLM key and UI access key secrets). Wait until `NEW_RELEASE-hindsight` is ready: it creates an empty schema.
2. Stop writes on both releases (add the `-worker` workloads if `worker.enabled`):

   ```bash
   cpln workload stop OLD_RELEASE-hindsight NEW_RELEASE-hindsight --gvc GVC_NAME
   ```

3. Stream the old database into the new one, inside the new database container (`--clean` replaces the empty schema; nothing binary crosses `cpln workload exec`):

   ```bash
   cpln workload exec NEW_RELEASE-pgvector --gvc GVC_NAME --container pgvector -- bash -c \
     'export PGPASSWORD="$POSTGRES_PASSWORD"; pg_dump -h OLD_RELEASE-pgvector.GVC_NAME.cpln.local -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists | psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -q'
   ```

4. Compare `SELECT count(*) FROM memory_units;` on both databases, then start the new API and point your agents at `NEW_RELEASE-hindsight`:

   ```bash
   cpln workload start NEW_RELEASE-hindsight --gvc GVC_NAME
   ```

5. Uninstall the old release.

## Important Notes

- **One API key opens every bank.** Give each agent its own bank id, but anyone holding the key (or the web UI access key) can read and change all of them. Updating a secret restarts nothing: run `cpln workload force-redeployment` on the API, the workers and the web UI. The database password is read only when PostgreSQL first initializes; run `ALTER ROLE` before updating its secret.
- **Changing the embedding model.** Stored vectors belong to the model that wrote them, so changing `embeddings.*` after data exists breaks recall until every memory is re-embedded. With the release still on the old model, run the re-embed with the new model's settings, then upgrade, then finish:
  ```bash
  cpln workload exec RELEASE_NAME-hindsight --gvc GVC_NAME --container hindsight -- env \
    HINDSIGHT_API_EMBEDDINGS_PROVIDER=openai HINDSIGHT_API_EMBEDDINGS_OPENAI_BASE_URL=NEW_URL \
    HINDSIGHT_API_EMBEDDINGS_OPENAI_MODEL=NEW_MODEL HINDSIGHT_API_EMBEDDINGS_OPENAI_API_KEY=KEY_OR_unused \
    hindsight-admin reembed --all-schemas
  cpln helm upgrade RELEASE_NAME CHART --gvc GVC_NAME -f my-values.yaml   # with the new embeddings.* values
  cpln workload exec RELEASE_NAME-hindsight --gvc GVC_NAME --container hindsight -- hindsight-admin reembed --all-schemas --finish
  ```
  Between the first and second command, retains to the old servers return `503`; recall keeps working. The install wizard refuses this change, so make it with the CLI.
- **Webhooks and mental models.** Webhooks deliver only to public addresses by default; to reach a receiver inside Control Plane (`*.cpln.local`), list its exact hostname (comma-separated, no wildcards, e.g. `my-receiver.my-gvc.cpln.local`) in `HINDSIGHT_API_WEBHOOK_ALLOWED_HOSTS` through `hindsight.extraEnv`. Mental models and pages are written by an agentic reflect loop that needs a capable LLM: a small local model on CPU may not finish before `HINDSIGHT_API_REFLECT_WALL_TIMEOUT` (300 s), so use a hosted or GPU-served model, or raise that timeout through `hindsight.extraEnv`.
- **Stuck background tasks.** A task claimed by a process that was hard-killed (an out-of-memory kill, a lost node) stays claimed under that process's id. List them with `hindsight-admin worker-status` and hand them back with `hindsight-admin decommission-worker WORKER_ID`, through `cpln workload exec RELEASE_NAME-hindsight --gvc GVC_NAME --container hindsight -- ...`.
- **PostgreSQL 19 for new installs only.** A release upgraded from 1.x keeps PostgreSQL 18 only with `pgvector.image: pgvector/pgvector:0.8.7-pg18` in its values; without it the database refuses to start (data untouched). See [Upgrading from 1.x](#upgrading-from-1x).
- **One location; uninstall deletes the data.** The bundled database runs in one location, so install into a GVC with a single location. Uninstalling deletes the database volume and every memory bank with it.

## Links

- [Hindsight on GitHub](https://github.com/vectorize-io/hindsight)
- [Hindsight documentation](https://hindsight.vectorize.io)
- [pgvector template](https://docs.controlplane.com/template-catalog/templates/pgvector)
- [postgres-highly-available template](https://docs.controlplane.com/template-catalog/templates/postgres-highly-available)
