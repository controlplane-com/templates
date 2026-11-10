# Dify

This app deploys [Dify](https://dify.ai), an open-source builder for LLM applications: chatbots, agents and visual workflows with RAG knowledge bases. You build an app in the browser, then publish it as a web page, call it through the REST service API or expose it as an MCP server. It runs on a bundled PostgreSQL with pgvector and a bundled Redis, and every page requires a login.

## Architecture

- **Gateway** (`RELEASE_NAME-dify`): nginx on port 8080, the only public workload. It routes `/console/api`, `/api`, `/v1`, `/files`, `/mcp` and `/triggers` to the API, `/e/` to the plugin daemon and everything else to the web tier.
- **Web** (`RELEASE_NAME-dify-web`): the console and published web apps on port 3000.
- **API** (`RELEASE_NAME-dify-api`): console API, service API and MCP server on port 5001. It applies database migrations at start; when several replicas start together, one takes a lock and migrates, and the others skip it.
- **Worker** (`RELEASE_NAME-dify-worker`) and **scheduler** (`RELEASE_NAME-dify-beat`): Celery processes that index documents and run asynchronous and periodic tasks. The scheduler always runs exactly one replica.
- **Plugin daemon** (`RELEASE_NAME-dify-plugin-daemon`): installs and runs model-provider and tool plugins, one stateful replica with its own volume (`RELEASE_NAME-dify-plugins`) and its own `dify_plugin` database.
- **Code sandbox** (`RELEASE_NAME-dify-sandbox`): runs the Python and JavaScript of Code and Template nodes. Omitted when `codeExecution.endpoint` points at your own executor.
- **SSRF proxy** (`RELEASE_NAME-dify-ssrf-proxy`): squid on port 3128. HTTP Request nodes, tools and Python HTTP calls in Code nodes go through it, and it refuses private, link-local and in-GVC addresses.
- **File storage** (`RELEASE_NAME-dify-storage`): a shared volume that the API and worker mount at `/app/api/storage`.
- **PostgreSQL**: the `postgres` template with the pgvector image (default), or `postgres-highly-available` (3 Patroni replicas, etcd and an HAProxy leader endpoint). It holds apps, users, conversations and knowledge-base vectors.
- **Redis**: the `redis` template as one node, password required. It holds the cache, the task queue and plugin state.
- **Firewall**: each Dify tier accepts connections only from the tiers that call it; the sandbox cannot reach the API, web or plugin daemon.
- **Identities + policies**: `reveal` on exactly the secrets you name; the sandbox can read only its own key. The template creates no secrets.

## Prerequisites

**Four secrets must exist BEFORE you install.** Use only letters and digits in every value: the plugin daemon and the Redis URL cannot carry other characters. The first holds Dify's own keys. `initPassword` is at most 30 characters:

```bash
cpln secret create-dictionary --name my-dify-secrets \
  --entry secretKey="$(openssl rand -hex 32)" \
  --entry initPassword="$(openssl rand -hex 12)" \
  --entry pluginDaemonKey="$(openssl rand -hex 32)" \
  --entry pluginInnerApiKey="$(openssl rand -hex 32)"
```

The second is the key Dify and the code sandbox share:

```bash
printf '%s' "$(openssl rand -hex 32)" | \
  cpln secret create-opaque --name my-dify-sandbox-key --encoding plain -f -
```

The third holds the database credentials, and the fourth the Redis password:

```bash
cpln secret create-dictionary --name my-dify-db-credentials \
  --entry username=dify \
  --entry password="$(openssl rand -hex 32)" \
  --entry database=dify

cpln secret create-dictionary --name my-dify-redis \
  --entry password="$(openssl rand -hex 32)"
```

Secret names are org-wide, so give each release its own secrets. A value with other characters stops the API, worker and scheduler at start with a log line naming the key.

**If a secret the release names does not exist at install time, the deployment waits silently**: `cpln logs` returns nothing. The only signal is `status.versions[].message` in `cpln workload get-deployments RELEASE_NAME-dify-api --gvc GVC_NAME -o yaml`. Create the secret and the deployment recovers by itself within about 10 minutes. To recover at once, run `cpln workload force-redeployment` on each Dify workload.

**Optional**: backups need a bucket and a Control Plane cloud account, set up as in the [postgres](https://docs.controlplane.com/template-catalog/templates/postgres) template; on AWS also a bucket-scoped IAM policy. A custom domain needs a domain routed to the `RELEASE_NAME-dify` workload.

## Configuration

### Dify

```yaml
dify:
  apiImage: langgenius/dify-api:1.19.0
  webImage: langgenius/dify-web:1.19.0
  # set dify.replicas: 2, worker.replicas: 2 and postgresHA.enabled: true for near-zero-downtime upgrades and failover
  replicas: 1                   # 1-3: gateway, web, API, code sandbox and SSRF proxy
  secretName: my-dify-secrets   # REQUIRED dictionary: secretKey, initPassword, pluginDaemonKey, pluginInnerApiKey
  publicUrl: ""                 # "" = the gateway's *.cpln.app endpoint; or https://dify.example.com (no trailing /)
  requestTimeoutSeconds: 600    # longest request or stream on the public URL before it is cut (1-3600)
  volumeset:
    capacity: 10                # GiB (minimum 10): uploads and the keys that decrypt stored provider credentials
  extraEnv: []                  # plain settings for api, worker and beat, e.g. [{name: UPLOAD_FILE_SIZE_LIMIT, value: "50"}]
worker:
  replicas: 1                   # 1-3
pluginDaemon:
  volumeset:
    capacity: 20                # GiB (minimum 10): installed plugins and their Python environments
```

Each API and worker process holds up to 8 database connections (`SQLALCHEMY_POOL_SIZE` 5 + `SQLALCHEMY_MAX_OVERFLOW` 3), about 8 concurrent runs per API replica; raise both through `extraEnv` for more, within PostgreSQL's 100 connections.

Each tier's resources are under `dify.resources`, `worker.resources`, `pluginDaemon.resources`, `codeExecution.sandbox.resources` and `ssrfProxy.resources` in `values.yaml`.

### Code execution and network

```yaml
codeExecution:
  endpoint: ""                  # "" = the bundled dify-sandbox workload; or the URL of your own sandbox-compatible executor
  apiKeySecretName: my-dify-sandbox-key   # REQUIRED opaque secret
ssrfProxy:
  enabled: true                 # false lets HTTP Request nodes, tools and code call any service in this GVC
publicAccess:
  enabled: true                 # public *.cpln.app URL; /install is guarded by initPassword, every page needs a login
internalAccess:                 # who in Control Plane may reach the gateway (the other tiers admit only each other)
  type: same-gvc                # none | same-gvc | same-org | workload-list
  workloads: []                 # used only with workload-list
```

### Database and Redis

```yaml
postgres:                       # every knob of the postgres template
  enabled: true
  image: pgvector/pgvector:0.8.7-pg18
  config:
    credentialsSecretName: my-dify-db-credentials
  backup:
    enabled: false              # scheduled backups to object storage; provider aws, gcp or minio
postgresHA:                     # every knob of the postgres-highly-available template
  enabled: false                # enable exactly one of postgres / postgresHA
  image: controlplanecorporation/patroni-postgres:0.8   # includes pgvector 0.8.7
  config:
    credentialsSecretName: my-dify-db-credentials
redis:
  enabled: true                 # required
  mode: dev                     # required: one node; the chart refuses production (Sentinel) mode
  redis:
    auth:
      fromSecret:
        enabled: true
        name: my-dify-redis
        passwordKey: password
```

The full backup keys and their defaults are in `values.yaml`.

## Connecting

| What | Where |
|---|---|
| First start | Open the URL below. Dify asks for the `initPassword`, then creates the admin account on `/install` |
| Console (public) | `status.canonicalEndpoint` of `cpln workload get RELEASE_NAME-dify --gvc GVC_NAME -o yaml` |
| From your machine (private install) | Set `dify.publicUrl: http://localhost:8080`, then `cpln port-forward RELEASE_NAME-dify 8080:8080 --gvc GVC_NAME` and open `http://localhost:8080` |
| Service API | `POST PUBLIC_URL/v1/chat-messages` (or `/v1/workflows/run`) with `Authorization: Bearer APP_API_KEY`; create the key on the app's API Access page |
| Internal service API | `http://RELEASE_NAME-dify.GVC_NAME.cpln.local:8080/v1` |
| MCP server | Turn on MCP Server for an app; the app shows its `PUBLIC_URL/mcp/server/.../mcp` URL |
| Control Plane MCP server | Tools → MCP → add `https://mcp.cpln.io/mcp?toolsets=readonly` and sign in with your Control Plane account |
| Models | Install a model-provider plugin from Settings → Model Provider, then enter its API key there |

Dify builds every link, cookie and webhook from the public URL, and the login works only on that exact address. Behind a custom domain, set `dify.publicUrl` to it.

## Important Notes

- The Dify licence allows one workspace per install, not a multi-tenant service, and forbids removing or changing the Dify logo and copyright in the console. The chart turns off self sign-up and creating more workspaces; invite members from Settings → Members.
- Never rotate `secretKey` (it signs every login and shared link) and never delete the file storage volume (it holds the keys that decrypt the model provider credentials saved in Dify).
- Anyone who can edit an app can run Python and JavaScript in the code sandbox, and that code can open direct connections to the internet. The Dify API, web and plugin daemon refuse the sandbox; other services in this GVC, including the bundled PostgreSQL and Redis, are guarded only by their passwords. Give accounts only to people you trust.
- With the SSRF proxy on, HTTP Request nodes, tools and Python HTTP calls in Code nodes (`requests`) go through it and cannot call services inside the GVC (`*.cpln.local`). JavaScript code gets no proxy. Model-provider plugins run in the plugin daemon, not through the proxy, so the Ollama, vLLM and LiteLLM providers can use in-GVC URLs.
- Plugins install from the Dify marketplace or an uploaded package, and only signed plugins are accepted.
- Six failed logins lock an email out for 24 hours. To clear it: `cpln workload exec RELEASE_NAME-redis --gvc GVC_NAME --container redis -- sh -c 'REDISCLI_AUTH="$CUSTOM_REDIS_PASSWORD" redis-cli DEL login_error_rate_limit:USER_EMAIL'`.
- Use a single-location GVC: the database, Redis, both volumes and the plugin daemon run in one location. The first `helm upgrade` after an install can restart the bundled database. Uninstalling deletes the database and both volumes, and with them every app, user, knowledge base and installed plugin.

## Links

- [Dify documentation](https://docs.dify.ai)
- [Dify environment variables](https://docs.dify.ai/en/self-host/deploy/configuration/environments)
- [Dify service API](https://docs.dify.ai/en/guides/application-publishing/developing-with-apis)
- [Dify as an MCP server](https://docs.dify.ai/en/cloud/use-dify/publish/publish-mcp)
- [Dify plugins](https://docs.dify.ai/en/plugins/introduction)
- [Dify licence](https://github.com/langgenius/dify/blob/main/LICENSE)
- [Dify on GitHub](https://github.com/langgenius/dify)
