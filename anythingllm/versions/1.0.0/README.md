# AnythingLLM

This app deploys [AnythingLLM](https://anythingllm.com), an AI app built around workspaces: each workspace holds a set of documents and a chat that answers from them, with citations. Retrieval is built in (a CPU embedding model and an embedded LanceDB vector store), so no extra services are needed. It also serves a website chat widget, a developer API and AI agents that call MCP tools. The admin account comes from a secret, so AnythingLLM requires a sign-in from its first start.

## Architecture

- **AnythingLLM** (`RELEASE_NAME-anythingllm`): one stateful workload with one replica, serving the UI, the API and the chat widget on port 3001. A second process in the same container (the collector) parses uploaded files and scraped web pages. A restart or upgrade makes it unavailable for a few minutes. Use a single-location GVC.
- **Volume** (`RELEASE_NAME-anythingllm-storage`): 10 GiB at `/app/server/storage`. It holds the SQLite database, the LanceDB vectors, the documents, the downloaded embedding model, the MCP config and the settings saved in the UI. Snapshots are taken daily by default.
- **First start**: the start script creates the admin from `admin.secretName` and turns on multi-user mode before anyone can sign in. If it cannot, or a key in `keys.secretName` is empty, the container exits and restarts, so the release never runs without a login.
- **Control Plane MCP server (optional)**: with `cplnMcp.keySecretName` set, the MCP server `cpln` (`https://mcp.cpln.io/mcp?toolsets=readonly`, read-only tools) is added for agents, authenticated with a service-account key.
- **Identity + policy**: `reveal` on exactly the secrets you name. The template creates no secrets.

## Prerequisites

**Two secrets must exist BEFORE you install.** The first holds the keys that sign sessions and encrypt stored data. None may be empty:

```bash
cpln secret create-dictionary --name my-anythingllm-keys \
  --entry JWT_SECRET="$(openssl rand -hex 32)" \
  --entry SIG_KEY="$(openssl rand -hex 32)" \
  --entry SIG_SALT="$(openssl rand -hex 32)" \
  --entry AUTH_TOKEN="$(openssl rand -hex 32)"
```

The second is the admin account. The username is 2-64 lowercase letters, digits, `.`, `_`, `@` or `-`, starting with a letter; the password is 8 characters or more:

```bash
cpln secret create-dictionary --name my-anythingllm-admin \
  --entry username=admin \
  --entry password="$(openssl rand -base64 24)"
```

Secret names are org-wide, so give each release its own secrets.

**If a secret the release names does not exist at install time, the deployment waits silently**: `cpln logs` returns nothing. The only signal is `status.versions[].message` in `cpln workload get-deployments RELEASE_NAME-anythingllm --gvc GVC_NAME -o yaml`. Create the secret and the deployment recovers by itself within about 10 minutes. To recover at once, or after changing any secret the release uses, run `cpln workload force-redeployment RELEASE_NAME-anythingllm --gvc GVC_NAME`.

**Optional prerequisites**, each an opaque secret: a chat model API key (`llm.apiKeySecretName`, required for `openai` and `anthropic`), an embedding API key (`embedding.apiKeySecretName`) and a bearer token per HTTP MCP server (`bearerTokenSecretName`). Create them like this:

```bash
printf '%s' "$OPENAI_API_KEY" | cpln secret create-opaque --name my-anythingllm-openai-key --encoding plain -f -
```

The Control Plane MCP server needs an opaque secret holding a service-account key, named in `cplnMcp.keySecretName`. AnythingLLM's MCP client cannot sign in with OAuth, so every agent run that uses the server acts as this service account. Give it only what your agents need: this example lets it view one GVC, and you add a policy for each further resource kind, such as `workload` with `view`:

```bash
cpln serviceaccount create --name my-anythingllm-mcp
cpln policy create --name my-anythingllm-mcp-view --target-kind gvc --resource GVC_NAME
cpln policy add-binding my-anythingllm-mcp-view --permission view --serviceaccount my-anythingllm-mcp
cpln serviceaccount add-key my-anythingllm-mcp --description anythingllm -o json | jq -j .key | \
  cpln secret create-opaque --name my-anythingllm-cpln-mcp-key --encoding plain -f -
```

## Configuration

### Keys and admin account

```yaml
keys:
  secretName: my-anythingllm-keys     # REQUIRED: JWT_SECRET, SIG_KEY, SIG_SALT, AUTH_TOKEN; never change it
admin:
  secretName: my-anythingllm-admin    # REQUIRED: username, password; read on first start only, then change it in the UI
```

### Chat model

```yaml
llm:
  provider: ""          # "" | openai | anthropic | ollama | generic-openai | litellm
  model: ""             # required when provider is set, e.g. gpt-4.1-mini, llama3.2
  baseUrl: ""           # ollama / generic-openai / litellm, e.g. http://my-ollama-ollama.GVC_NAME.cpln.local:11434
  contextWindow: 8192   # the model's token limit (ollama / generic-openai / litellm)
  apiKeySecretName: ""  # opaque secret with the API key; required for openai and anthropic
```

With `provider: ""`, choose the model in Settings → AI Providers → LLM after signing in; the choice is kept on the volume. Until a model is chosen, chats and the developer API's vector search fail. Use `generic-openai` for vLLM or any other OpenAI-compatible server, with `baseUrl` ending in `/v1`.

### Embedding model

```yaml
embedding:
  engine: native        # native (built in, CPU, no key; slow for large uploads) | ollama | generic-openai
  model: ""             # required unless native, e.g. nomic-embed-text, text-embedding-3-small
  baseUrl: ""           # e.g. http://my-ollama-ollama.GVC_NAME.cpln.local:11434 or https://api.openai.com/v1
  maxChunkLength: 8192  # characters per chunk sent to the embedder (ollama / generic-openai)
  apiKeySecretName: ""  # opaque secret; generic-openai only, optional
```

### MCP tool servers

```yaml
mcp:
  servers: {}
  # time:                       # stdio: runs inside the container
  #   command: uvx
  #   args: [mcp-server-time]
  # my-tools:                   # HTTP
  #   type: streamable          # streamable | sse
  #   url: http://my-mcp.GVC_NAME.cpln.local:8000/mcp
  #   bearerTokenSecretName: "" # opaque secret sent as "Authorization: Bearer <value>"
```

AnythingLLM has no screen for adding an MCP server; Settings → Agent Skills only turns servers on or off and removes them. With the default `servers: {}`, add servers by editing `/app/server/storage/plugins/anythingllm_mcp_servers.json` through `cpln workload exec`; the chart leaves that file alone. With any server listed here, or `cplnMcp.keySecretName` set, the chart writes the whole file on every start.

### Control Plane MCP server

```yaml
cplnMcp:
  keySecretName: ""             # opaque: a service-account key; "" = no Control Plane MCP server
  url: https://mcp.cpln.io/mcp?toolsets=readonly  # read-only tools (no create, update or delete); https://mcp.cpln.io/mcp = every tool
```

The service-account key is sent to `url`, so point it only at the Control Plane MCP server. At each start a log line beginning `cpln-mcp:` says whether the server accepted the key.

### Access

```yaml
publicAccess:
  enabled: true         # UI, chat widget and API on the canonical *.cpln.app URL; a sign-in is always required
internalAccess:
  type: none            # none | same-gvc | same-org | workload-list
  workloads: []         # used only with workload-list
```

### Storage and backup

```yaml
volumeset:
  capacity: 10          # GiB (minimum 10); grow a live volume with cpln volumeset expand (below)
backup:
  enabled: true         # platform volume snapshots, no bucket needed
  schedule: "0 3 * * *" # cron in UTC with a single fixed minute; at most hourly
  retention: 7d
```

Changing `capacity` does not resize an existing volume. To grow it, and to restore a snapshot (`cpln volumeset snapshot get RELEASE_NAME-anythingllm-storage --gvc GVC_NAME` lists them; everything written after it is lost):

```bash
cpln volumeset expand RELEASE_NAME-anythingllm-storage --new-size 20 --location LOCATION --volume-index 0 --gvc GVC_NAME
cpln volumeset snapshot restore RELEASE_NAME-anythingllm-storage --snapshot-name SNAPSHOT_NAME --location LOCATION --volume-index 0 --gvc GVC_NAME
```

### Server

```yaml
image: mintplexlabs/anythingllm:1.19.0
resources:
  minCpu: 500m
  maxCpu: 2000m
  minMemory: 1Gi
  maxMemory: 3Gi        # the built-in embedder and document parsing run in this container
telemetry:
  enabled: false        # true = send anonymous usage events to AnythingLLM
```

## Connecting

| What | Where |
|---|---|
| UI and API (public) | `status.canonicalEndpoint` of `cpln workload get RELEASE_NAME-anythingllm --gvc GVC_NAME -o yaml`; sign in with the admin secret |
| From your machine (private install) | `cpln port-forward RELEASE_NAME-anythingllm 3001:3001 --gvc GVC_NAME`, then `http://localhost:3001` |
| Internal API | `http://RELEASE_NAME-anythingllm.GVC_NAME.cpln.local:3001` (allow the caller in `internalAccess`) |
| Developer API | `/api/v1/...` with the header `Authorization: Bearer API_KEY`; create keys in Settings → Developer API; reference at `/api/docs` |
| Chat widget | Settings → Chat Embed: create an embed for a workspace, list the website's address under allowed domains (an embed with none refuses every chat), and paste the script tag it shows into your site |
| Control Plane MCP server | In a workspace chat, start an agent with `@agent`; the `cpln` server's tools act as the service account in `cplnMcp.keySecretName` |

## Important Notes

- Never change or delete the keys secret: `SIG_KEY` and `SIG_SALT` encrypt stored data, and a new `JWT_SECRET` signs everyone out.
- Values set in `llm` and `embedding` win over the UI on every restart; with `llm.provider: ""` the chat model chosen in the UI stays. Changing the embedding engine or model in the UI deletes every workspace's vectors and document links. Changing `embedding` in the values deletes nothing, but documents already embedded stay unsearchable until they are added again.
- The volume and its snapshots hold provider keys entered in the UI in plain text (`.env`), alongside every document. Treat snapshots as sensitive.
- A stdio MCP server runs inside the container with AnythingLLM's environment, which includes the provider keys and `JWT_SECRET`. Add only servers you trust.
- Uninstalling deletes the volume after a final snapshot, and with it every workspace, document and account.

## Links

- [AnythingLLM documentation](https://docs.anythingllm.com)
- [Configuration through environment variables](https://docs.anythingllm.com/configuration)
- [Chat embed widget](https://docs.anythingllm.com/features/chat-widgets)
- [MCP in AnythingLLM](https://docs.anythingllm.com/mcp-compatibility/overview)
- [AnythingLLM on GitHub](https://github.com/Mintplex-Labs/anything-llm)
