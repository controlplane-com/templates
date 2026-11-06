# Aegra

This app deploys [Aegra](https://github.com/aegra/aegra), an open-source agent server compatible with the LangGraph Agent Server API: assistants, threads, background runs, streaming, the store and crons for the LangGraph agents in your image. It runs on a bundled PostgreSQL with pgvector and a bundled Redis, and works with the LangGraph SDK and frontends such as Agent Chat UI.

## Architecture

- **Aegra** (`RELEASE_NAME-aegra`): standard workload serving the API on port 2026, 1 replica by default. Replicas share PostgreSQL and Redis, so they are interchangeable; a run on a lost replica is picked up by another.
- **PostgreSQL (single instance, default)**: the `postgres` template with pgvector. Holds threads, runs, checkpoints and the store.
- **PostgreSQL (HA, optional)**: the `postgres-highly-available` template instead: 3 Patroni replicas, 3 etcd replicas and an HAProxy leader endpoint.
- **Redis**: the `redis` template as one node, the job queue and run event streams. Runs are recovered from PostgreSQL if it restarts.
- **Identity + policy**: `reveal` on exactly the secrets you name (database credentials, and the optional agent, Langfuse and Redis secrets). The template creates no secrets.

## Prerequisites

**The database credentials secret must exist BEFORE you install**. The bundled PostgreSQL initializes with it and Aegra connects with it:

```bash
cpln secret create-dictionary --name my-aegra-db-credentials \
  --entry username=aegra \
  --entry password="$(openssl rand -hex 32)" \
  --entry database=aegra
```

Secret names are org-wide, so give each release its own secret.

**If a secret the release names does not exist at install time, the deployment waits silently**: `cpln logs` returns nothing. The only signal is `status.versions[].message` in `cpln workload get-deployments RELEASE_NAME-aegra --gvc GVC_NAME -o yaml`. Create the secret and it recovers on its own within about 10 minutes, or right away with `cpln workload force-redeployment RELEASE_NAME-aegra --gvc GVC_NAME`.

**Backups (optional)**: a bucket and a Control Plane cloud account (on AWS also a bucket-scoped IAM policy), set up as in the [postgres](https://docs.controlplane.com/template-catalog/templates/postgres) or [postgres-highly-available](https://docs.controlplane.com/template-catalog/templates/postgres-highly-available) template; MinIO needs a dictionary secret with `accessKey` and `secretKey`.

**Optional secrets**, each a dictionary created the same way: agent secrets (any keys your agent reads, such as `OPENAI_API_KEY`), Langfuse keys (`publicKey`, `secretKey`), and a Redis password (`password`, URL-safe: letters, digits, `-`, `_`, `.`).

## Bring your own agent

The default image is a community build of Aegra 0.11.0 with Aegra's example agents: `stress_test` runs with no model key, and `agent` needs `OPENAI_API_KEY` in the agent secrets. To serve your own graphs, build an image from it with your code and an `aegra.json`:

```dockerfile
FROM upstreamyard/aegra:0.11.0
USER root
COPY requirements.txt /app/agents/requirements.txt
RUN pip install --no-cache-dir -r /app/agents/requirements.txt
COPY . /app/agents
USER 10001
ENV AEGRA_CONFIG=/app/agents/aegra.json
```

```json
{
  "dependencies": ["."],
  "graphs": { "my_agent": "./my_agent/graph.py:graph" }
}
```

Push it to a registry the GVC can pull from and set `aegra.image`. Each graph is registered as an assistant whose id is the graph name.

## Configuration

### Aegra

```yaml
aegra:
  image: upstreamyard/aegra:0.11.0   # your agent image (see Bring your own agent)
  # set aegra.replicas: 2 and postgresHA.enabled: true for near-zero-downtime upgrades and failover
  replicas: 1                   # 1-10
  resources:
    minCpu: 250m
    maxCpu: 1000m
    minMemory: 512Mi
    maxMemory: 1Gi
  requestTimeoutSeconds: 600    # longest /runs/wait or /runs/stream request on the public URL before it is cut (1-3600)
  extraEnv: []                  # plain settings, e.g. [{name: LOG_LEVEL, value: DEBUG}]
```

### Agent secrets

```yaml
agentSecrets:
  secretName: ""                # e.g. my-aegra-agent-secrets
  keys: []                      # each listed key becomes an env var, e.g. [OPENAI_API_KEY]
```

### Access

```yaml
publicAccess:
  enabled: false                # true = public *.cpln.app URL. Aegra has NO auth unless your image adds a handler
internalAccess:
  type: same-gvc                # none | same-gvc | same-org | workload-list
  workloads: []                 # used only with workload-list
```

### Langfuse tracing

```yaml
langfuse:
  secretName: ""                # dictionary with publicKey and secretKey; "" = tracing off
  baseUrl: http://my-langfuse-langfuse-web.my-gvc.cpln.local:3000   # or https://cloud.langfuse.com
```

### Database

```yaml
postgres:                       # every knob of the postgres template
  enabled: true
  image: pgvector/pgvector:0.8.7-pg18
  config:
    credentialsSecretName: my-aegra-db-credentials   # REQUIRED, create before install
  resources:
    minCpu: 250m
    maxCpu: 1000m
    minMemory: 512Mi
    maxMemory: 1Gi
  volumeset:
    capacity: 10                # GiB (minimum 10)
  backup:                       # scheduled backups to object storage (postgres template)
    enabled: false
    image: ghcr.io/controlplane-com/backup-images/postgres-backup:18.1.0
    schedule: "0 2 * * *"       # daily at 2am UTC
    resources:
      cpu: 100m
      memory: 128Mi
    provider: aws               # aws, gcp or minio
    aws:
      bucket: my-aegra-backup-bucket
      region: us-east-1
      cloudAccountName: my-aegra-backup-cloudaccount
      policyName: my-aegra-backup-policy
      prefix: postgres/backups
    gcp:
      bucket: my-aegra-backup-bucket
      cloudAccountName: my-aegra-backup-cloudaccount
      prefix: postgres/backups
    minio:                      # any S3-compatible endpoint
      endpoint: http://my-minio-workload:9000
      bucket: my-aegra-backup-bucket
      credentialsSecretName: my-aegra-minio-credentials   # dictionary: accessKey, secretKey
      prefix: postgres/backups

postgresHA:                     # every knob of the postgres-highly-available template
  enabled: false                # enable exactly one of postgres / postgresHA
  image: controlplanecorporation/patroni-postgres:0.8
  config:
    credentialsSecretName: my-aegra-db-credentials
  replicas: 3
  resources:                    # per Patroni replica
    minCpu: 250m
    maxCpu: 1000m
    minMemory: 512Mi
    maxMemory: 2Gi
  volumeset:
    capacity: 10                # GiB per replica (minimum 10)
  backup:                       # provider, aws, gcp, minio: same keys and defaults as postgres.backup
    enabled: false
    mode: logical               # logical or wal-g
    resources:
      cpu: 100m
      memory: 512Mi             # 128Mi OOM-kills wal-g mid-backup
    logical:
      image: ghcr.io/controlplane-com/backup-images/postgres-backup:17.1.0
      schedule: "0 2 * * *"     # daily at 2am UTC
    walg:
      intervalSeconds: 21600    # every 6 hours
```

### Redis

```yaml
redis:
  mode: dev                     # required: one node; Aegra cannot use Sentinel
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
        name: ""                # e.g. my-aegra-redis
        passwordKey: password
```

## Connecting

| What | Where |
|---|---|
| Internal API | `http://RELEASE_NAME-aegra.GVC_NAME.cpln.local:2026` |
| From your machine | `cpln port-forward RELEASE_NAME-aegra 2026:2026 --gvc GVC_NAME`, then `http://localhost:2026` |
| Public URL (`publicAccess.enabled`) | `status.canonicalEndpoint` of `cpln workload get RELEASE_NAME-aegra --gvc GVC_NAME -o yaml` |
| API docs | `/docs` on any of the above |

Point the LangGraph SDK (`langgraph_sdk.get_client(url=...)`) or Agent Chat UI at the URL and use the graph name as the assistant id.

Aegra has no UI of its own. To chat with an agent in a browser, open the hosted [Agent Chat UI](https://agentchat.vercel.app) with your public URL and a graph name, for example `https://agentchat.vercel.app/?apiUrl=PUBLIC_URL&assistantId=stress_test`. The browser calls Aegra directly, so it needs the public URL, and anyone with that URL can call your agents unless your image adds an auth handler.

## Important Notes

- Aegra has no authentication unless your image configures an auth handler in `aegra.json`. Keep `publicAccess` off without one: anyone with the URL could run your agents and read every thread.
- Langfuse in another GVC: set that Langfuse release's `internalAccess` to `same-org`, or Aegra cannot reach it.
- Rotating a secret does not restart Aegra; run `cpln workload force-redeployment RELEASE_NAME-aegra --gvc GVC_NAME` afterwards.
- A run whose database stays unreachable for more than 30 seconds ends in `error`; submit it again. Aegra itself restarts until the database is back.
- Aegra does not drain runs on shutdown: a run on a replica that stops is picked up again by a live replica once its lease expires, and retried.
- The first `helm upgrade` after an install can restart the bundled database and Redis, which briefly interrupts the API.
- Firewall changes (`publicAccess`, `internalAccess`) take from 30 seconds to several minutes to take effect.
- Use a single-location GVC: the bundled database and Redis run in one location.
- Uninstalling deletes the database volume, and with it every thread, run and checkpoint.

## Links

- [Aegra documentation](https://docs.aegra.dev)
- [Aegra deployment guide](https://docs.aegra.dev/guides/deployment)
- [Aegra authentication](https://docs.aegra.dev/guides/authentication)
- [Aegra observability](https://docs.aegra.dev/guides/observability)
- [Aegra on GitHub](https://github.com/aegra/aegra)
- [Agent Chat UI](https://github.com/langchain-ai/agent-chat-ui)
