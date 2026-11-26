# Aegra

This app deploys [Aegra](https://github.com/aegra/aegra), an open-source agent server compatible with the LangGraph Agent Server API: assistants, threads, background runs, streaming, the store and crons for the LangGraph agents in your image. It runs on a bundled PostgreSQL with pgvector and a bundled Redis, and works with the LangGraph SDK and frontends such as Agent Chat UI.

## Architecture

- **Aegra** (`RELEASE_NAME-aegra`): standard workload serving the API on port 2026, 1 replica by default. Replicas share PostgreSQL and Redis, so they are interchangeable; a run on a lost replica is picked up by another.
- **PostgreSQL (single instance, default)**: the `postgres` template running a pgvector image (PostgreSQL 19 with pgvector 0.8.7). Holds threads, runs, checkpoints and the store. It refuses to start on a data directory from another PostgreSQL major version and leaves it untouched (see [Upgrading from 1.x](#upgrading-from-1x)).
- **PostgreSQL (HA, optional)**: the `postgres-highly-available` template instead (PostgreSQL 18 for a new cluster): 3 Patroni replicas, 3 etcd replicas and an HAProxy leader endpoint.
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

Build and push it to your org's private registry, then set `aegra.image` to the printed `image` value:

```bash
cpln image build --name my-agent:1 --dockerfile Dockerfile --push   # builds linux/amd64
```

Only your graphs are served; the example agents of the default image are not registered. Each graph appears in `/assistants/search` under an id generated from its name (the `graph_id` is the name you listed in `aegra.json`); call it with `"assistant_id": "my_agent"`.

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
  image: pgvector/pgvector:0.8.7-pg19   # a release upgraded from 1.x keeps -pg18 (Upgrading from 1.x)
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
    image: ghcr.io/controlplane-com/backup-images/postgres-backup:19.1.0   # also backs up a server pinned to -pg18
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
  image: controlplanecorporation/patroni-postgres:0.9   # PostgreSQL 18 for new clusters; an existing cluster keeps 17
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
      image: ghcr.io/controlplane-com/backup-images/postgres-backup:18.2.0   # backs up PostgreSQL 17 and 18 clusters
      schedule: "0 2 * * *"     # daily at 2am UTC
    walg:
      intervalSeconds: 21600    # every 6 hours
```

### Backup retention

The backup job only uploads; it never deletes old backups. To keep a fixed window, add a lifecycle rule on the bucket that expires objects under the backup prefix. Each backup is a complete, standalone copy, so expiring old ones never affects restoring a newer one. Set the window to at least your retention plus one backup interval, and note that an age rule keeps no minimum: if backups stop running, the last ones expire too.

In `wal-g` mode (`postgresHA.backup.mode: wal-g`), a restore needs the newest full base backup plus the WAL files written after it, all under the same prefix and never rewritten. Older base backups and the WAL before them are not needed, so the same rule is safe as long as the window is longer than two base-backup intervals (`postgresHA.backup.walg.intervalSeconds`). If base backups stop while WAL archiving continues, the rule eventually expires the last base backup, so check that new `basebackups_005/` entries keep appearing.

The rules below use the default prefix `postgres/backups/`; change it if you changed `postgres.backup.<provider>.prefix` (or `postgresHA.backup.<provider>.prefix` in HA mode).

**AWS S3.** `put-bucket-lifecycle-configuration` **replaces every existing rule on the bucket**, so check for existing rules first and add them to the file:

```bash
aws s3api get-bucket-lifecycle-configuration --bucket BUCKET_NAME
cat > lifecycle.json <<'EOF'
{"Rules":[{"ID":"expire-db-backups","Filter":{"Prefix":"postgres/backups/"},"Status":"Enabled",
  "Expiration":{"Days":30},"NoncurrentVersionExpiration":{"NoncurrentDays":1}}]}
EOF
aws s3api put-bucket-lifecycle-configuration --bucket BUCKET_NAME --lifecycle-configuration file://lifecycle.json
```

**Google Cloud Storage.** `--lifecycle-file` also **replaces the bucket's existing rules**; check with `gcloud storage buckets describe gs://BUCKET_NAME --format='json(lifecycle_config)'` first:

```bash
cat > lifecycle.json <<'EOF'
{"rule":[
  {"action":{"type":"Delete"},"condition":{"age":30,"matchesPrefix":["postgres/backups/"]}},
  {"action":{"type":"Delete"},"condition":{"daysSinceNoncurrentTime":1,"isLive":false,"matchesPrefix":["postgres/backups/"]}}]}
EOF
gcloud storage buckets update gs://BUCKET_NAME --lifecycle-file=lifecycle.json
```

**MinIO** (adds a rule alongside existing ones; the access key needs `s3:PutLifecycleConfiguration`, which the built-in `readwrite` policy grants):

```bash
mc ilm rule add --expire-days 30 --noncurrent-expire-days 1 --prefix "postgres/backups/" ALIAS/BUCKET_NAME
mc ilm rule ls ALIAS/BUCKET_NAME
```

Lifecycle rules run in the background; objects are removed within about a day of reaching the age. The `Noncurrent` parts matter only on a versioned bucket, where expiry otherwise just adds a delete marker.

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

## Upgrading from 1.x

**Single-instance database (`postgres.enabled: true`, the default):** new installs run PostgreSQL 19 (`pgvector/pgvector:0.8.7-pg19`). A 1.x release's data directory was created by PostgreSQL 18, and a data directory only opens with its own major. The chart never converts data in place: before PostgreSQL starts, a guard compares the two majors, and on a mismatch it does not start the server and changes nothing on the volume. `RELEASE_NAME-postgres` then stays not ready, Aegra restarts until its database is back, and the logs repeat `[pg-guard] REFUSING TO START`.

```bash
cpln logs '{gvc="GVC_NAME", workload="RELEASE_NAME-postgres"} |= "pg-guard"' --since 15m
```

**Stay on PostgreSQL 18:** run the upgrade with the pgvector image pinned to 18, and keep it in your values file for every later upgrade (`cpln helm upgrade` does not reuse the installed values). Pin the pgvector image (the guard's log names it): Aegra needs the pgvector extension. The Console upgrade wizard keeps the installed image for you and warns before a change to another major.

```yaml
postgres:
  image: pgvector/pgvector:0.8.7-pg18
```

```bash
cpln helm upgrade RELEASE_NAME CHART --gvc GVC_NAME -f my-values.yaml --set postgres.image=pgvector/pgvector:0.8.7-pg18
```

**Move to PostgreSQL 19** (dump and restore into a new release in the same GVC; runs pause during the copy):

1. Install 2.0.0 as a **new release** with the **same** database credentials secret (and the same agent, Langfuse and Redis secrets). Wait until `NEW_RELEASE-aegra` is ready: it creates an empty schema.
2. Stop Aegra on both releases (the databases keep running):

   ```bash
   cpln workload stop OLD_RELEASE-aegra NEW_RELEASE-aegra --gvc GVC_NAME
   ```

3. Stream the old database into the new one, from inside the new database container. The PostgreSQL 19 `pg_dump` reads the old server, and `--clean --if-exists` first drops what the new Aegra created:

   ```bash
   cpln workload exec NEW_RELEASE-postgres --gvc GVC_NAME --container postgresql -- bash -c \
     'PGPASSWORD="$POSTGRES_PASSWORD" pg_dump -h OLD_RELEASE-postgres.GVC_NAME.cpln.local -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists | psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -q'
   ```

4. Start the new Aegra, check that your threads are there (`POST /threads/search`), and point your clients at `NEW_RELEASE-aegra`:

   ```bash
   cpln workload start NEW_RELEASE-aegra --gvc GVC_NAME
   ```

5. Uninstall the old release.

**Highly available database (`postgresHA.enabled: true`):** a plain upgrade works, and the cluster stays on PostgreSQL 17, the major it was created with, on the new `patroni-postgres:0.9` image; new HA releases start on PostgreSQL 18. To move an existing cluster to 18, follow [Upgrading an existing cluster to PostgreSQL 18](https://github.com/controlplane-com/templates/blob/main/postgres-highly-available/versions/3.0.0/README.md#upgrading-an-existing-cluster-to-postgresql-18) in the postgres-highly-available template. The second release there is a new Aegra 2.0.0 release with `postgresHA.enabled: true`, `postgres.enabled: false` and the same secrets; this chart names its database workloads `RELEASE_NAME-postgres-ha` and `RELEASE_NAME-postgres-ha-proxy`, so the commands apply as written. Stop both releases' `-aegra` workloads while the copy runs.

## Important Notes

- Aegra has no authentication unless your image configures an auth handler in `aegra.json`. Keep `publicAccess` off without one: anyone with the URL could run your agents and read every thread.
- Langfuse in another GVC: set that Langfuse release's `internalAccess` to `same-org`, or Aegra cannot reach it.
- Rotating a secret does not restart Aegra; run `cpln workload force-redeployment RELEASE_NAME-aegra --gvc GVC_NAME` afterwards.
- A run whose database stays unreachable for more than 30 seconds ends in `error`; submit it again. Aegra itself restarts until the database is back.
- Aegra does not drain runs on shutdown: a run on a replica that stops is picked up again by a live replica once its lease expires, and retried.
- The first `helm upgrade` after an install can restart the bundled database and Redis, which briefly interrupts the API.
- Firewall changes (`publicAccess`, `internalAccess`) take from 30 seconds to several minutes to take effect.
- **PostgreSQL 19 for new installs only.** A release upgraded from 1.x keeps PostgreSQL 18 only with `postgres.image: pgvector/pgvector:0.8.7-pg18` in its values; without it the database refuses to start (data untouched). See [Upgrading from 1.x](#upgrading-from-1x).
- Use a single-location GVC: the bundled database and Redis run in one location.
- Uninstalling deletes the database volume, and with it every thread, run and checkpoint.

## Links

- [Aegra documentation](https://docs.aegra.dev)
- [Aegra deployment guide](https://docs.aegra.dev/guides/deployment)
- [Aegra authentication](https://docs.aegra.dev/guides/authentication)
- [Aegra observability](https://docs.aegra.dev/guides/observability)
- [Aegra on GitHub](https://github.com/aegra/aegra)
- [Agent Chat UI](https://github.com/langchain-ai/agent-chat-ui)
