# Langflow

This app deploys [Langflow](https://www.langflow.org), a visual low-code builder for AI agents, RAG pipelines and MCP servers. You build a flow on a canvas, test it in the editor, then call it through the REST API or as MCP tools. It runs on a bundled PostgreSQL and always requires a login.

## Architecture

- **Langflow** (`RELEASE_NAME-langflow`): standard workload serving the editor, the API and MCP on port 7860, 1 replica by default. Replicas share PostgreSQL, the data volume and Redis, so they are interchangeable.
- **Data volume** (`RELEASE_NAME-langflow-data`): a shared volume at `/app/langflow` that every replica mounts. It holds uploaded files and knowledge bases.
- **PostgreSQL (single instance, default)**: the `postgres` template. It holds users, flows, messages and stored credentials.
- **PostgreSQL (HA, optional)**: the `postgres-highly-available` template instead: 3 Patroni replicas, 3 etcd replicas and an HAProxy leader endpoint.
- **Redis (optional, required above 1 replica)**: the `redis` template as one node. It holds the shared editor build queue and the login rate limits.
- **Identity + policy**: `reveal` on exactly the secrets you name. The template creates no secrets.

## Prerequisites

**Three secrets must exist BEFORE you install.** The first holds the database credentials. They become part of a connection URL, so use only letters, digits, `-`, `_`, `.` and `~`:

```bash
cpln secret create-dictionary --name my-langflow-db-credentials \
  --entry username=langflow \
  --entry password="$(openssl rand -hex 32)" \
  --entry database=langflow
```

The second is the superuser Langflow creates on first start:

```bash
cpln secret create-dictionary --name my-langflow-admin \
  --entry username=admin \
  --entry password="$(openssl rand -base64 24)"
```

The third is the encryption key, a 44-character Fernet key. It encrypts every API key saved in Langflow and signs logins:

```bash
printf '%s' "$(openssl rand -base64 32 | tr '+/' '-_')" | \
  cpln secret create-opaque --name my-langflow-secret-key --encoding plain -f -
```

Secret names are org-wide, so give each release its own secrets. Langflow refuses to start with a key that is not a valid Fernet key, and logs why.

**If a secret the release names does not exist at install time, the deployment waits silently**: `cpln logs` returns nothing. The only signal is `status.versions[].message` in `cpln workload get-deployments RELEASE_NAME-langflow --gvc GVC_NAME -o yaml`. Create the secret and the deployment recovers by itself within about 10 minutes. To recover at once, run `cpln workload force-redeployment RELEASE_NAME-langflow --gvc GVC_NAME`.

**Optional prerequisites**:

- Provider keys: a dictionary secret whose keys (such as `OPENAI_API_KEY`) you list in `variableSecrets.keys`.
- A Redis password: a dictionary secret with a URL-safe `password` key.
- Backups: a bucket and a Control Plane cloud account, set up as in the [postgres](https://docs.controlplane.com/template-catalog/templates/postgres) template. On AWS you also need a bucket-scoped IAM policy.

## Configuration

### Langflow

```yaml
langflow:
  image: langflowai/langflow:1.13.1   # build FROM it to add custom components
  # set langflow.replicas: 2, redis.enabled: true and postgresHA.enabled: true for near-zero-downtime upgrades and failover
  replicas: 1                   # 1-4; above 1 requires redis.enabled: true
  resources:
    minCpu: 500m
    maxCpu: 2000m
    minMemory: 1Gi
    maxMemory: 3Gi
  requestTimeoutSeconds: 600    # longest request on the public URL (flow runs, editor builds) before it is cut (1-3600)
  volumeset:
    capacity: 10                # GiB (minimum 10), shared by all replicas
  extraEnv: []                  # plain settings, e.g. [{name: LANGFLOW_SSRF_ALLOWED_HOSTS, value: "*.cpln.local"}]
```

### Login, encryption key and provider keys

```yaml
admin:
  secretName: my-langflow-admin          # REQUIRED dictionary: username, password (used on first start only)
secretKey:
  secretName: my-langflow-secret-key     # REQUIRED opaque: 44-character Fernet key; never rotate it
variableSecrets:
  secretName: ""                # dictionary; each listed key becomes an env var and a Langflow global variable
  keys: []                      # e.g. [OPENAI_API_KEY, ANTHROPIC_API_KEY]
```

### Access

```yaml
publicAccess:
  enabled: true                 # public *.cpln.app URL; login is always required
internalAccess:
  type: same-gvc                # none | same-gvc | same-org | workload-list
  workloads: []                 # used only with workload-list
```

### Database

```yaml
postgres:                       # every knob of the postgres template
  enabled: true
  image: postgres:18
  config:
    credentialsSecretName: my-langflow-db-credentials   # REQUIRED, create before install
  resources:
    minCpu: 250m
    maxCpu: 1000m
    minMemory: 512Mi
    maxMemory: 1Gi
  volumeset:
    capacity: 10                # GiB (minimum 10)
  backup:
    enabled: false              # scheduled backups to object storage; provider aws, gcp or minio (postgres template)

postgresHA:                     # every knob of the postgres-highly-available template
  enabled: false                # enable exactly one of postgres / postgresHA
  config:
    credentialsSecretName: my-langflow-db-credentials
  replicas: 3
  resources:                    # per Patroni replica
    minCpu: 250m
    maxCpu: 1000m
    minMemory: 512Mi
    maxMemory: 2Gi
  volumeset:
    capacity: 10                # GiB per replica (minimum 10)
  backup:
    enabled: false              # logical or wal-g backups (postgres-highly-available template)
```

The full backup keys and their defaults are in `values.yaml`.

### Redis

```yaml
redis:
  enabled: false                # required for langflow.replicas above 1
  mode: dev                     # required: one node; Langflow cannot use Sentinel
  redis:
    image: redis:8
    resources:
      maxCpu: 200m
      maxMemory: 256Mi
      minCpu: 80m
      minMemory: 128Mi
    auth:
      fromSecret:
        enabled: false          # true = Redis requires the password in the secret below
        name: ""                # e.g. my-langflow-redis
        passwordKey: password
```

## Connecting

| What | Where |
|---|---|
| Editor and API (public) | `status.canonicalEndpoint` of `cpln workload get RELEASE_NAME-langflow --gvc GVC_NAME -o yaml`; log in with the superuser secret |
| From your machine (private install) | `cpln port-forward RELEASE_NAME-langflow 7860:7860 --gvc GVC_NAME`, then `http://localhost:7860` |
| Internal API | `http://RELEASE_NAME-langflow.GVC_NAME.cpln.local:7860` |
| Run a flow | `POST /api/v1/run/FLOW_ID` with the header `x-api-key: API_KEY` (create API keys under Settings) |
| MCP server | `/api/v1/mcp/project/PROJECT_ID/streamable` (Streamable HTTP); the project's MCP Server tab shows the full URL |
| API docs | `/docs` on any of the above |

Langflow blocks requests to private addresses by default, which includes services in your GVC (`*.cpln.local`). To let flows call one, such as an Ollama or Qdrant release, add this to `langflow.extraEnv`: `{name: LANGFLOW_SSRF_ALLOWED_HOSTS, value: "*.cpln.local"}`.

## Important Notes

- Never rotate or delete the encryption key secret: API keys already saved in Langflow could no longer be decrypted.
- The superuser secret is read on first start only. Change the password in the Langflow UI, since later changes to the secret are ignored.
- Any user who can log in can run Python on the server through custom components. Give accounts only to people you trust.
- With more than one replica, use the Streamable HTTP MCP URL. The legacy SSE URL (`/sse`) works with one replica only.
- Rotating a provider-keys secret does not restart Langflow; run `cpln workload force-redeployment RELEASE_NAME-langflow --gvc GVC_NAME` afterwards.
- The first `helm upgrade` after an install can restart the bundled database, which briefly interrupts the editor and the API.
- Use a single-location GVC: the database, the data volume and Redis run in one location.
- Uninstalling deletes the database and the data volume, and with them every flow, user and uploaded file.

## Links

- [Langflow documentation](https://docs.langflow.org)
- [Langflow environment variables](https://docs.langflow.org/environment-variables)
- [Langflow as an MCP server](https://docs.langflow.org/mcp-server)
- [Langflow API keys and authentication](https://docs.langflow.org/api-keys-and-authentication)
- [Langflow on GitHub](https://github.com/langflow-ai/langflow)
