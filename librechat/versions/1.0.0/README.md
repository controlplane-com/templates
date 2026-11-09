# LibreChat

This app deploys [LibreChat](https://github.com/danny-avila/LibreChat), an open-source (MIT) ChatGPT-style chat UI that talks to OpenAI, Anthropic, Google and any OpenAI-compatible server (Ollama, vLLM, LiteLLM, OpenRouter) from one place, with per-user accounts, agents, presets and conversation search. The admin account comes from a secret you create first, so the UI is ready to sign in to on its public URL from the first start. Chat over uploaded files and 2-4 replicas are optional.

## Architecture

- **LibreChat** (`{release}-librechat`): standard workload serving the web UI and API on port 3080. The start script writes `librechat.yaml` from your values, creates the admin account on first start, then starts the server.
- **Uploaded files** (`{release}-librechat-files`): shared volume set at `/app/storage` for uploads, images and avatars, seen by every replica.
- **MongoDB** (`{release}-mongo`, the `mongodb` template): every chat, user, preset and setting.
- **Meilisearch** (`{release}-meilisearch`, the `meilisearch` template, on by default): the conversation search index.
- **Document search** (opt-in, `rag.enabled`): `{release}-librechat-rag` runs the LibreChat rag-api on port 8000, internal only, storing embeddings in `{release}-pgvector` (the `pgvector` template).
- **Redis** (opt-in, `redis.enabled`): `{release}-redis` (the `redis` template, single node) for shared sessions, rate limits and resumable answers; required for more than one replica.
- **Identities + policies**: each workload reveals exactly the secrets it reads.

The GVC must have exactly one location: the datastores are single-instance and the files volume is per location.

## Prerequisites

Create these secrets **before** you install; a missing one leaves the deployment waiting with no logs (see Important Notes).

1. **Encryption and signing keys** (`keys.secretName`). `CREDS_KEY`/`CREDS_IV` encrypt every API key users save, so never change them; a new JWT secret signs everyone out:

   ```bash
   cpln secret create-dictionary --name my-librechat-keys \
     --entry CREDS_KEY=$(openssl rand -hex 32) --entry CREDS_IV=$(openssl rand -hex 16) \
     --entry JWT_SECRET=$(openssl rand -hex 32) --entry JWT_REFRESH_SECRET=$(openssl rand -hex 32)
   ```

2. **Admin account** (`admin.secretName`), password of 8 or more characters:

   ```bash
   cpln secret create-dictionary --name my-librechat-admin --entry email=you@example.com --entry 'password=YOUR-STRONG-PASSWORD'
   ```

3. **MongoDB credentials** (`mongodb.config.credentialsSecretName`). URL-safe values only; they go into the connection string:

   ```bash
   cpln secret create-dictionary --name my-librechat-mongodb-credentials \
     --entry username=librechat --entry password=$(openssl rand -hex 32) --entry database=LibreChat
   ```

4. **Meilisearch master key** (`meilisearch.auth.secretName`, while `search.enabled: true`):

   ```bash
   printf '%s' "$(openssl rand -hex 32)" | cpln secret create-opaque --name my-librechat-meili-key --encoding plain -f -
   ```

Optional, each an **opaque** secret holding one API key (same `create-opaque` form as above):

- **Provider keys** shared by every user: `providers.openai.apiKeySecretName`, `providers.anthropic.apiKeySecretName`, `providers.google.apiKeySecretName`.
- **Custom endpoint keys**: one per keyed endpoint, named in its `apiKeySecretName`. Local servers such as Ollama need none.
- **Document search** (`rag.enabled: true`): a dictionary secret `pgvector.config.credentialsSecretName` (`username`, `password`, `database`) and, for OpenAI embeddings, the key in `rag.embeddings.apiKeySecretName`.
- **Redis** (`redis.enabled: true`): a dictionary secret `redis.redis.auth.fromSecret.name` with key `password` (`openssl rand -hex 32`, URL-safe).

## Configuration

### Image, replicas, files and sign-up

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

auth:
  allowRegistration: false # true = anyone who reaches the URL can create an account (role USER)
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

customEndpoints: []
  # - name: ollama
  #   baseURL: http://my-ollama-ollama.GVC_NAME.cpln.local:11434/v1
  #   apiKeySecretName: ""   # opaque secret; "" = no key (local servers)
  #   models: [llama3.2]
  #   fetchModels: false     # true = also list the server's /models

config: {} # extra librechat.yaml settings merged over the generated file, e.g. interface.customWelcome
```

Custom endpoint names must be unique and must not be a built-in endpoint (`openAI`, `anthropic`, `google`, `agents`, `assistants`, `azureOpenAI`, `bedrock`, `custom`).

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

### Access

```yaml
publicAccess:
  enabled: true # chat UI on the canonical *.cpln.app URL; false = reach it with cpln port-forward
customDomain: "" # full URL, e.g. https://chat.example.com; sets the app's URL only
internalAccess:
  type: none # none | same-gvc | same-org | workload-list
  workloads: []
```

## Connecting

| What | Value |
|---|---|
| Web UI | `status.canonicalEndpoint` of `{release}-librechat` (`cpln workload get {release}-librechat --gvc {gvc} -o yaml`), when `publicAccess.enabled: true` |
| Sign in | The `email` and `password` in your admin secret |
| Internal API | `http://{release}-librechat.{gvc}.cpln.local:3080`, when `internalAccess.type` allows the caller |
| From your machine | `cpln port-forward {release}-librechat 3080:3080 --gvc {gvc}`, then `http://localhost:3080` |
| Custom endpoint in this GVC | `http://{workload}.{gvc}.cpln.local:{port}/v1`; always use the full `.cpln.local` name |

## Important Notes

- **Create the secrets before installing.** A missing secret leaves the deployment waiting with no logs; `cpln workload get-deployments {release}-librechat --gvc {gvc} -o yaml` names it under `status.versions[].message`, and the install recovers once the secret exists.
- **The admin secret is read on first start only.** LibreChat creates the account while the database has no users; the first user is the admin. Later changes to the secret change nothing, so change the password in the UI.
- **Never change `CREDS_KEY` or `CREDS_IV`.** Saved user API keys become unreadable. Changing `JWT_*` signs everyone out.
- **Uploaded files are not backed up.** The shared files volume takes no snapshots. Chats, users and settings live in MongoDB; turn on `mongodb.backup` to back them up to object storage.
- **Private custom endpoints are allowed automatically.** LibreChat refuses private addresses (`*.cpln.local`, `localhost`, `10.x`) unless their `host:port` is listed under `endpoints.allowedAddresses`; the chart adds each private custom endpoint's `host:port` for you. Add other addresses under `config.endpoints.allowedAddresses`.
- **Never put an API key in `config`.** The generated `librechat.yaml` is part of the workload spec; reference a key with `${VAR}` instead.
- **Answers are capped at 10 minutes** per request by the platform; with Redis on, an interrupted answer resumes after a reconnect.
- **The datastores are single-instance.** More LibreChat replicas keep the chat tier up, but a MongoDB restart is a short outage.
- **Uninstall deletes the data.** The MongoDB, Meilisearch, pgvector and files volumes go with the release.

## Links

- [LibreChat on GitHub](https://github.com/danny-avila/LibreChat)
- [LibreChat documentation](https://www.librechat.ai/docs)
- [librechat.yaml reference](https://www.librechat.ai/docs/configuration/librechat_yaml)
- [Custom endpoints](https://www.librechat.ai/docs/configuration/librechat_yaml/object_structure/custom_endpoint)
- [rag-api](https://github.com/danny-avila/rag_api)
