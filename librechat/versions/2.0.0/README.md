# LibreChat

This app deploys [LibreChat](https://github.com/LibreChat-AI/LibreChat), an open-source (MIT) ChatGPT-style chat UI that talks to OpenAI, Anthropic, Google and any OpenAI-compatible server (Ollama, vLLM, LiteLLM, OpenRouter) from one place, with per-user accounts, agents, presets and conversation search. The admin account comes from a secret you create first, so the UI is ready to sign in to on its public URL from the first start. Chat over uploaded files and 2-4 replicas are optional.

## Architecture

- **LibreChat** (`{release}-librechat`): standard workload serving the web UI and API on port 3080. The start script writes `librechat.yaml` from your values, creates the admin account on first start, then starts the server.
- **Uploaded files** (`{release}-librechat-files`): shared volume set at `/app/storage` for uploads, images and avatars, seen by every replica.
- **MongoDB** (`{release}-mongo`, the `mongodb` template): every chat, user, preset and setting.
- **Meilisearch** (`{release}-meilisearch`, the `meilisearch` template, on by default): the conversation search index.
- **Document search** (opt-in, `rag.enabled`): `{release}-librechat-rag` runs the LibreChat rag-api on port 8000, internal only, storing embeddings in `{release}-pgvector` (the `pgvector` template, PostgreSQL 19).
- **Redis** (opt-in, `redis.enabled`): `{release}-redis` (the `redis` template, single node) for shared sessions, rate limits and resumable answers; required for more than one replica.
- **One location**: the GVC must have exactly one, since the datastores are single-instance and the files volume is per location.

## Prerequisites

Create these secrets **before** you install; a missing one leaves the deployment waiting with no logs. URL-safe values only for the MongoDB and Redis passwords: they go into connection strings.

```bash
# keys.secretName: CREDS_* encrypt every API key users save (never change them); a new JWT secret signs everyone out
cpln secret create-dictionary --name my-librechat-keys \
  --entry CREDS_KEY=$(openssl rand -hex 32) --entry CREDS_IV=$(openssl rand -hex 16) \
  --entry JWT_SECRET=$(openssl rand -hex 32) --entry JWT_REFRESH_SECRET=$(openssl rand -hex 32)
# admin.secretName: the first account, created on first start (password of 8 or more characters)
cpln secret create-dictionary --name my-librechat-admin --entry email=you@example.com --entry 'password=YOUR-STRONG-PASSWORD'
# mongodb.config.credentialsSecretName
cpln secret create-dictionary --name my-librechat-mongodb-credentials \
  --entry username=librechat --entry password=$(openssl rand -hex 32) --entry database=LibreChat
# meilisearch.auth.secretName (while search.enabled: true)
printf '%s' "$(openssl rand -hex 32)" | cpln secret create-opaque --name my-librechat-meili-key --encoding plain -f -
```

Optional:

- **API keys**, each an **opaque** secret (the `create-opaque` form above): `providers.openai`, `providers.anthropic` and `providers.google` `.apiKeySecretName` (shared by every user), one per keyed custom endpoint (its `apiKeySecretName`; Ollama needs none), and `rag.embeddings.apiKeySecretName` for OpenAI embeddings.
- **Document search** (`rag.enabled: true`): a **dictionary** secret `pgvector.config.credentialsSecretName` with `username`, `password`, `database`.
- **Redis** (`redis.enabled: true`): a **dictionary** secret `redis.redis.auth.fromSecret.name` with key `password` (`openssl rand -hex 32`).

## Configuration

### Image, replicas, accounts and database

```yaml
image: ghcr.io/librechat-ai/librechat:v0.8.8
resources:
  minCpu: 250m
  maxCpu: 1000m
  minMemory: 512Mi
  maxMemory: 2Gi
replicas: 1 # 2-4 keep chat up through restarts and upgrades; requires redis.enabled: true
files:
  volumeset:
    capacity: 10 # GiB (platform minimum 10); can be expanded later, never shrunk
keys:
  secretName: my-librechat-keys
admin:
  secretName: my-librechat-admin # read on first start only; later changes do nothing
auth:
  allowRegistration: false # true = anyone who reaches the URL can create an account (role USER)
mongodb:
  config:
    credentialsSecretName: my-librechat-mongodb-credentials
  resources:
    minCpu: 250m
    maxCpu: 1000m
    minMemory: 512Mi
    maxMemory: 1Gi # the chart's override of the mongodb template default
  volumeset:
    capacity: 10 # GiB
```

### Model providers

```yaml
providers:
  openai:
    apiKeySecretName: "" # "" = that provider is off
  anthropic:
    apiKeySecretName: ""
  google:
    apiKeySecretName: ""
  userProvidedKeys: false # true = providers with no secret ask each user for their own key
customEndpoints: [] # names unique, not a built-in: openAI, azureOpenAI, google, anthropic, assistants,
  # azureAssistants, agents, custom, bedrock, gptPlugins, chatGPTBrowser (any case). Private hosts
  # (*.cpln.local, localhost, 10.x) work; their host:port also goes in endpoints.allowedAddresses,
  # which LibreChat checks for URLs users add themselves (actions, MCP).
  # - name: ollama
  #   baseURL: http://my-ollama-ollama.GVC_NAME.cpln.local:11434/v1
  #   apiKeySecretName: ""   # opaque secret; "" = no key (local servers)
  #   models: [llama3.2]
  #   fetchModels: false     # true = also list the server's /models
config: {} # extra librechat.yaml settings merged over the generated file, e.g. interface.customWelcome
```

### MCP servers (Control Plane example)

MCP servers go in `config.mcpServers`. This connects the Control Plane MCP server; each user clicks **Connect** on it in the chat's MCP menu and signs in to Control Plane (OAuth), so no token is stored in the chart:

```yaml
config:
  mcpServers:
    cpln:
      title: Control Plane
      type: streamable-http
      url: https://mcp.cpln.io/mcp?toolsets=full   # toolsets: readonly, core, mk8s or full
      requiresOAuth: true
      timeout: 60000
```

Every tool's description is sent with each message, and `full` has about 95 tools. If LibreChat reports the context is exceeded, raise **Max Context Tokens** in the model's parameters (up to the model's limit).

### Search, document search and Redis

```yaml
search:
  enabled: true
meilisearch:
  auth:
    secretName: my-librechat-meili-key
rag:
  enabled: false
  embeddings:
    model: text-embedding-3-small # changing it after files are indexed breaks their search
    baseUrl: "" # "" = OpenAI; or any OpenAI-compatible embeddings URL
    apiKeySecretName: "" # required unless baseUrl is set
pgvector:
  config:
    credentialsSecretName: my-librechat-pgvector-credentials
redis:
  enabled: false
  mode: dev # one Redis node; the chart refuses production (Sentinel)
  redis:
    auth:
      fromSecret:
        enabled: true
        name: my-librechat-redis-password
        passwordKey: password
```

Every other `mongodb`, `meilisearch`, `pgvector` and `redis` template value works under its key too, for example `mongodb.backup` for scheduled database backups.

New installs of document search run PostgreSQL 19 (`pgvector.image` defaults to the pgvector template's `pgvector/pgvector:0.8.7-pg19`). A release upgraded from 1.x keeps PostgreSQL 18; see [Upgrading from 1.x](#upgrading-from-1x).

### Access

```yaml
publicAccess:
  enabled: true # chat UI on the canonical *.cpln.app URL; false = reach it with cpln port-forward
customDomain: "" # full URL, e.g. https://chat.example.com; sets the app's URL only
internalAccess:
  type: none # none | same-gvc | same-org | workload-list
  workloads: []
```

## Upgrading from 1.x

2.0.0 moves the bundled pgvector (document search) to PostgreSQL 19. With `rag.enabled: false` there is no pgvector and the upgrade needs nothing. With document search on, the 1.x data directory is PostgreSQL 18, and PostgreSQL only starts under the major version that created it: a PostgreSQL 19 image does not start on it and changes nothing on the volume. `{release}-pgvector` stays not ready and its logs repeat `[pg-guard] REFUSING TO START`.

### Stay on PostgreSQL 18

Pin the image, and keep the pin in your values file for every later upgrade (`cpln helm upgrade` does not reuse the release's values):

```yaml
pgvector:
  image: pgvector/pgvector:0.8.7-pg18
```

If an upgrade ran without the pin, run the same upgrade again with `--set pgvector.image=pgvector/pgvector:0.8.7-pg18`; the server comes back on its data. The guard's log line names the pgvector chart's own key, `image`; in this chart it is `pgvector.image`. The Console wizard keeps the installed image on upgrade and warns on a change to another major.

### Move document search to PostgreSQL 19

The embeddings are copied through a temporary pgvector release in the same GVC, so MongoDB and the rest of LibreChat stay as they are. File uploads to document search fail while the copy runs.

1. Upgrade to 2.0.0 with the PostgreSQL 18 pin above.
2. Install a temporary pgvector 2.0.0 release with the **same credentials secret** (the copy carries the role's password hash):

   ```bash
   cpln helm install TEMP_RELEASE oci://ghcr.io/controlplane-com/templates/pgvector \
     --version 2.0.0 --gvc GVC_NAME --set config.credentialsSecretName=my-librechat-pgvector-credentials
   ```

3. Copy the database into it (the PostgreSQL 19 `pg_dump` reads the 18 server):

   ```bash
   cpln workload exec TEMP_RELEASE-pgvector --gvc GVC_NAME --container pgvector -- bash -c \
     'PGPASSWORD="$POSTGRES_PASSWORD" pg_dump --clean --if-exists -h RELEASE_NAME-pgvector.GVC_NAME.cpln.local -U "$POSTGRES_USER" -d "$POSTGRES_DB" | psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -q'
   ```

4. Compare row counts on both servers (`select count(*) from langchain_pg_embedding;`).
5. Upgrade the LibreChat release with `--set rag.enabled=false` and without the pin. This **deletes** `RELEASE_NAME-pgvector` and its volume set; the copy from step 3 is now the only one.
6. Upgrade again with `rag.enabled: true` and without the pin: `RELEASE_NAME-pgvector` starts empty on PostgreSQL 19.
7. Copy the data back, then compare row counts again:

   ```bash
   cpln workload exec RELEASE_NAME-pgvector --gvc GVC_NAME --container pgvector -- bash -c \
     'PGPASSWORD="$POSTGRES_PASSWORD" pg_dump --clean --if-exists -h TEMP_RELEASE-pgvector.GVC_NAME.cpln.local -U "$POSTGRES_USER" -d "$POSTGRES_DB" | psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -q'
   ```

8. Remove the pin from your values file and uninstall the temporary release: `cpln helm uninstall TEMP_RELEASE --gvc GVC_NAME`.

## Connecting

| What | Value |
|---|---|
| Web UI | `status.canonicalEndpoint` of `{release}-librechat` (`cpln workload get {release}-librechat --gvc {gvc} -o yaml`), when `publicAccess.enabled: true` |
| Sign in | The `email` and `password` in your admin secret |
| Internal API | `http://{release}-librechat.{gvc}.cpln.local:3080`, when `internalAccess.type` allows the caller |
| From your machine | `cpln port-forward {release}-librechat 3080:3080 --gvc {gvc}`, then `http://localhost:3080` |
| Custom endpoint in this GVC | `http://{workload}.{gvc}.cpln.local:{port}/v1`; always use the full `.cpln.local` name |

## Important Notes

- **A missing secret stalls the install silently.** `cpln workload get-deployments {release}-librechat --gvc {gvc} -o yaml` names it under `status.versions[].message`; the install recovers once the secret exists.
- **The admin secret is read on first start only.** LibreChat creates the account while the database has no users (the first user is the admin); afterwards change the password in the UI. Never change `CREDS_KEY` or `CREDS_IV`: saved user API keys become unreadable.
- **Uploaded files are not backed up.** The shared files volume takes no snapshots; chats, users and settings live in MongoDB, which `mongodb.backup` backs up to object storage. Uninstall deletes every volume.
- **Never put an API key in `config`.** The generated `librechat.yaml` is part of the workload spec; reference a key with `${VAR}`.
- **Answers are capped at 10 minutes** per request by the platform; with Redis on, a browser that reconnects mid-answer picks it up on any replica, but an answer is lost if the replica generating it crashes.
- **Document search's PostgreSQL major is fixed once its volume holds data.** A release created before 2.0.0 keeps `pgvector.image: pgvector/pgvector:0.8.7-pg18` in its values for every upgrade; see [Upgrading from 1.x](#upgrading-from-1x).
- **The datastores are single-instance.** More LibreChat replicas keep the chat tier up, but a MongoDB restart is a short outage.

## Links

- [LibreChat on GitHub](https://github.com/LibreChat-AI/LibreChat)
- [LibreChat documentation](https://www.librechat.ai/docs)
- [librechat.yaml reference](https://www.librechat.ai/docs/configuration/librechat_yaml)
- [Custom endpoints](https://www.librechat.ai/docs/configuration/librechat_yaml/object_structure/custom_endpoint)
- [MCP servers in librechat.yaml](https://www.librechat.ai/docs/configuration/librechat_yaml/object_structure/mcp_servers)
- [Control Plane MCP server](https://docs.controlplane.com/ai/mcp)
- [rag-api](https://github.com/LibreChat-AI/rag-api)
