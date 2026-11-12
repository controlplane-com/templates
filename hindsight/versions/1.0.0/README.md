# Hindsight

This app deploys [Hindsight](https://github.com/vectorize-io/hindsight), an open-source memory server for AI agents. Agents **retain** conversations and documents, an LLM extracts facts, entities and timestamps into a per-bank memory graph on PostgreSQL with pgvector, and agents **recall** (hybrid search, reranked) or **reflect** (the LLM reasons over the bank) through a REST API or the built-in MCP server. A web UI, called Hindsight Control Plane upstream, browses banks, entities and documents.

## Architecture

- **API** (`RELEASE_NAME-hindsight`): standard workload serving REST (`/v1/...`) and MCP (`/mcp/BANK_ID/`) on port 8888, 1 replica by default. Replicas share PostgreSQL, so they are interchangeable. Without dedicated workers each replica also runs retain, consolidation and other background tasks. The default image bundles the local embedding model (`BAAI/bge-small-en-v1.5`) and reranker (`hs-rerank-1`), so recall makes no external call.
- **Web UI** (`RELEASE_NAME-hindsight-ui`, on by default): port 9999, behind an access key you type to log in. It calls the API inside the GVC with the API key.
- **Dedicated workers** (`RELEASE_NAME-hindsight-worker`, optional): stateful workload that takes background tasks off the API. Each replica keeps a stable worker id, so a restarted worker picks up its own unfinished tasks.
- **PostgreSQL (single instance, default)**: the `pgvector` template. Holds every bank, fact, entity and document.
- **PostgreSQL (HA, optional)**: the `postgres-highly-available` template instead: 3 Patroni replicas, 3 etcd replicas and an HAProxy leader endpoint.
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

Read a key back with `cpln secret reveal my-hindsight-api-key`.

**If a secret the release names does not exist, the deployment waits silently**: `cpln logs` returns nothing. The only signal is `status.versions[].message` in `cpln workload get-deployments RELEASE_NAME-hindsight --gvc GVC_NAME -o yaml`. Create the secret and run `cpln workload force-redeployment RELEASE_NAME-hindsight --gvc GVC_NAME`.

**LLM**: a model with JSON-schema (structured) output. Hindsight asks for up to 65k output tokens per retain call; for a model with a smaller limit set `HINDSIGHT_API_RETAIN_MAX_COMPLETION_TOKENS` (above 3000) in `hindsight.extraEnv`.

**Backups (optional)**: a bucket and a Control Plane cloud account (on AWS also a bucket-scoped IAM policy), set up as in the [pgvector](https://docs.controlplane.com/template-catalog/templates/pgvector) or [postgres-highly-available](https://docs.controlplane.com/template-catalog/templates/postgres-highly-available) template.

## Configuration

```yaml
auth:
  apiKeySecretName: my-hindsight-api-key

llm:
  provider: openai              # e.g. openai, anthropic, gemini, groq, ollama, litellm (see README)
  model: gpt-5-mini             # must support JSON-schema output
  baseUrl: ""                   # "" = provider default; e.g. http://my-ollama.my-gvc.cpln.local:11434/v1
  apiKeySecretName: my-hindsight-llm-key

pgvector:
  enabled: true
  config:
    credentialsSecretName: my-hindsight-db-credentials

ui:
  enabled: true                 # browse banks, entities and documents; test recall and reflect
  accessKeySecretName: my-hindsight-ui-access-key

publicAccess:
  api: false                    # true = REST + MCP on a public *.cpln.app URL (API key still required)
  ui: false                     # true = web UI on a public *.cpln.app URL (access key still required)
```

Other LLM providers, with the provider's own key in `llm.apiKeySecretName`:

| Provider | `llm.provider` | `llm.model` (example) | `llm.baseUrl` |
|---|---|---|---|
| Anthropic | `anthropic` | `claude-sonnet-4-5` | `""` |
| Gemini | `gemini` | `gemini-2.5-flash` | `""` |
| Ollama template, no key | `ollama` | `qwen2.5:7b` | `http://OLLAMA_RELEASE-ollama.GVC_NAME.cpln.local:11434/v1` |
| vLLM template | `openai` | the served model name | `http://VLLM_RELEASE-vllm.GVC_NAME.cpln.local:8000/v1` |
| LiteLLM template | `litellm` | a model name LiteLLM routes | `http://LITELLM_RELEASE-litellm.GVC_NAME.cpln.local:4000` |

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

**Availability.** `hindsight.replicas: 2` with `worker.enabled: true` keeps the API up through restarts and upgrades; set `postgresHA.enabled: true` (and `pgvector.enabled: false`) for near-zero-downtime database upgrades and failover. Each API replica and worker opens up to `hindsight.dbPoolMaxSize` (20) connections, and the total must stay at or below 90.

**Extra settings.** Any upstream `HINDSIGHT_API_*` setting goes in `hindsight.extraEnv`; secret ones (a Cohere reranker key, per-operation LLM keys) go in a dictionary secret listed in `hindsight.extraSecrets`.

## Connecting

From a workload in the same GVC, with the API key from the secret:

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

A bank is created on first use. Without the key every `/v1` and `/mcp` call returns `401`; `/health` needs none.

**From your machine**, while the API is private:

```bash
cpln port-forward RELEASE_NAME-hindsight 8888:8888 --gvc GVC_NAME
```

**MCP clients** connect to one bank at `/mcp/BANK_ID/` (streamable HTTP). With `publicAccess.api: true`, read the URL from `status.canonicalEndpoint` in `cpln workload get RELEASE_NAME-hindsight --gvc GVC_NAME -o yaml`, then for Claude Code:

```bash
claude mcp add --transport http hindsight https://CANONICAL_ENDPOINT/mcp/my-agent/ \
  --header "Authorization: Bearer $HINDSIGHT_API_KEY"
```

The tools include `retain`, `recall` and `reflect`.

**Web UI**: forward it and open `http://localhost:9999`, then log in with the access key:

```bash
cpln port-forward RELEASE_NAME-hindsight-ui 9999:9999 --gvc GVC_NAME
```

With `publicAccess.ui: true` it is served on the UI workload's `*.cpln.app` endpoint instead; firewall changes take 30 seconds to a few minutes to take effect.

## Important Notes

- **One API key opens every bank.** Give each agent its own bank id, but anyone holding the key (or the web UI access key) can read and change all of them.
- **Changing the embedding model.** Stored memories keep the vectors of the model they were written with, so changing `embeddings.*` after data exists breaks recall. To switch, run `hindsight-admin reembed` in the API container with the new model set in its environment (`cpln workload exec RELEASE_NAME-hindsight --gvc GVC_NAME --container hindsight -- env HINDSIGHT_API_EMBEDDINGS_PROVIDER=... hindsight-admin reembed`), then `cpln helm upgrade` with the new `embeddings` values, then `hindsight-admin reembed --finish`.
- **Stuck background tasks.** A task claimed by a process that was hard-killed (an out-of-memory kill, a lost node) stays claimed under that process's id. List them with `hindsight-admin worker-status` and hand them back with `hindsight-admin decommission-worker WORKER_ID`, run through `cpln workload exec RELEASE_NAME-hindsight --gvc GVC_NAME --container hindsight -- ...`. A graceful restart releases its own tasks.
- **Rotating a key.** Updating a secret does not restart anything: run `cpln workload force-redeployment` on `RELEASE_NAME-hindsight`, `RELEASE_NAME-hindsight-worker` (when on) and `RELEASE_NAME-hindsight-ui`.
- **The database password** is read only when PostgreSQL first initializes. To change it, run `ALTER ROLE` first, then update the secret and force a redeployment.
- **One location.** The bundled database runs in one location, so install into a GVC with a single location.
- **Uninstalling deletes the database volume** and every memory bank with it.
- The full image is about 1 GB compressed, so the first start on a new node takes a few minutes.

## Links

- [Hindsight on GitHub](https://github.com/vectorize-io/hindsight)
- [Hindsight documentation](https://hindsight.vectorize.io)
- [pgvector template](https://docs.controlplane.com/template-catalog/templates/pgvector)
- [postgres-highly-available template](https://docs.controlplane.com/template-catalog/templates/postgres-highly-available)
