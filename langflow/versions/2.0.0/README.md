# Langflow

This app deploys [Langflow](https://www.langflow.org), a visual low-code builder for AI agents, RAG pipelines and MCP servers. You build a flow on a canvas, test it in the editor, then call it through the REST API or as MCP tools. It runs on a bundled PostgreSQL and always requires a login.

## Architecture

- **Langflow** (`RELEASE_NAME-langflow`): standard workload serving the editor, the API and MCP on port 7860, 1 replica by default. Replicas share PostgreSQL, the data volume and Redis, so they are interchangeable.
- **Data volume** (`RELEASE_NAME-langflow-data`): a shared volume at `/app/langflow` that every replica mounts. It holds uploaded files and knowledge bases.
- **PostgreSQL (single instance, default)**: the `postgres` template, PostgreSQL 19. It holds users, flows, messages and stored credentials. A boot guard refuses to start the server on a data directory of another PostgreSQL major and leaves it untouched (see **Upgrading from 1.x**).
- **PostgreSQL (HA, optional)**: the `postgres-highly-available` template instead: 3 Patroni replicas, 3 etcd replicas and an HAProxy leader endpoint. New clusters run PostgreSQL 18; a cluster created by a 1.x release stays on PostgreSQL 17.
- **Redis (optional, required above 1 replica)**: the `redis` template as one node. It holds the shared editor build queue and the login rate limits.
- **Control Plane MCP server (optional)**: with `cplnMcp.keySecretName` set, Langflow registers `https://mcp.cpln.io/mcp?toolsets=readonly` (read-only tools) as the superuser's MCP server `cpln` at boot, authenticated with a service-account key.
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
- The Control Plane MCP server: an opaque secret holding a service-account key, named in `cplnMcp.keySecretName`. Langflow's MCP client cannot sign in with OAuth, so every flow that uses the server acts as this service account. Give it only what your flows need. This example lets it view one GVC:

```bash
cpln serviceaccount create --name my-langflow-mcp
cpln policy create --name my-langflow-mcp-view --target-kind gvc --resource GVC_NAME
cpln policy add-binding my-langflow-mcp-view --permission view --serviceaccount my-langflow-mcp
cpln serviceaccount add-key my-langflow-mcp --description langflow -o json | jq -j .key | \
  cpln secret create-opaque --name my-langflow-cpln-mcp-key --encoding plain -f -
```

Add a policy for each further resource kind the flows should see or change, such as `workload` with `view`.

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
cplnMcp:
  keySecretName: ""             # opaque: a service-account key; "" = no Control Plane MCP server
  url: https://mcp.cpln.io/mcp?toolsets=readonly  # read-only tools (no create, update or delete); https://mcp.cpln.io/mcp = every tool
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
  image: postgres:19            # new installs; keep postgres:18 when upgrading a 1.x release (Upgrading from 1.x)
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
  replicas: 3                   # new clusters PostgreSQL 18; a 1.x cluster stays on 17
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

## Upgrading from 1.x

**Highly available database (`postgresHA.enabled: true`):** a plain upgrade works, and the cluster stays on PostgreSQL 17, the major it was created with; new HA releases start on PostgreSQL 18. Moving an existing cluster to 18 is a copy into a new release: see [Upgrading an existing cluster to PostgreSQL 18](https://github.com/controlplane-com/templates/blob/main/postgres-highly-available/versions/3.0.0/README.md#upgrading-an-existing-cluster-to-postgresql-18) in the postgres-highly-available template.

**Single-instance database (`postgres.enabled: true`, the default):** new installs run PostgreSQL 19. A 1.x release's data directory was created by PostgreSQL 18 (or the major of the `postgres.image` it ran), and a data directory only opens with its own major. The chart never converts data in place: before PostgreSQL starts, a guard compares the two majors, and on a mismatch it does not start the server and changes nothing on the volume. `RELEASE_NAME-postgres` then stays not ready, Langflow cannot reach its database, and the logs repeat `[pg-guard] REFUSING TO START` with the exact `--set postgres.image=...` to run.

```bash
cpln logs '{gvc="GVC_NAME", workload="RELEASE_NAME-postgres"} |= "pg-guard"' --since 15m
```

**Stay on PostgreSQL 18:** run the upgrade with the image pinned, and keep `postgres.image: postgres:18` in your values file for every later upgrade (`cpln helm upgrade` does not reuse the installed values). The Console upgrade wizard keeps the installed image for you.

```bash
cpln helm upgrade RELEASE_NAME CHART --gvc GVC_NAME -f my-values.yaml --set postgres.image=postgres:18
```

**Move to PostgreSQL 19, side by side** (Langflow gets a new endpoint; writes pause during the copy):

1. Install this version as a NEW release in the same GVC with the **same** `admin.secretName`, `secretKey.secretName` and `postgres.config.credentialsSecretName` (and the same `variableSecrets` and `cplnMcp` settings). The encryption key must be the same one, or the API keys stored in the copied database cannot be decrypted. Langflow initializes an empty database in it.
2. Copy the data volume (uploaded files and knowledge bases) through your machine while the old Langflow is still running (do this in a quiet window: a file uploaded after this step is not copied):

   ```bash
   mkdir -p ./langflow-data
   cpln workload exec OLD_RELEASE-langflow --gvc GVC_NAME --container langflow -- \
     sh -c 'cd /app/langflow && tar czf - --exclude="./.*" . | base64' | base64 -d | tar xzf - -C ./langflow-data
   cpln cp ./langflow-data/. NEW_RELEASE-langflow:/app/langflow --gvc GVC_NAME --container langflow
   ```

3. Stop writes to the old release by stopping its Langflow workload (`cpln workload stop OLD_RELEASE-langflow --gvc GVC_NAME`; the database keeps running).
4. Replace the new release's database with the old one, from inside the new database container. The PostgreSQL 19 `pg_dump` reads the old server, and `--clean --if-exists` first drops what the new Langflow created:

   ```bash
   cpln workload exec NEW_RELEASE-postgres --gvc GVC_NAME --container postgresql -- bash -c \
     'PGPASSWORD="$POSTGRES_PASSWORD" pg_dump -h OLD_RELEASE-postgres.GVC_NAME.cpln.local -U "$POSTGRES_USER" -d "$POSTGRES_DB" --clean --if-exists | psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -q'
   ```

5. Run `cpln workload force-redeployment NEW_RELEASE-langflow --gvc GVC_NAME` so Langflow reloads the copied data, log in to check your flows and files, point your clients at the new endpoint (or move your custom domain), then uninstall the old release.

## Connecting

| What | Where |
|---|---|
| Editor and API (public) | `status.canonicalEndpoint` of `cpln workload get RELEASE_NAME-langflow --gvc GVC_NAME -o yaml`; log in with the superuser secret |
| From your machine (private install) | `cpln port-forward RELEASE_NAME-langflow 7860:7860 --gvc GVC_NAME`, then `http://localhost:7860` |
| Internal API | `http://RELEASE_NAME-langflow.GVC_NAME.cpln.local:7860` |
| Run a flow | `POST /api/v1/run/FLOW_ID` with the header `x-api-key: API_KEY` (create API keys under Settings) |
| MCP server | `/api/v1/mcp/project/PROJECT_ID/streamable` (Streamable HTTP); the project's MCP Server tab shows the full URL |
| Control Plane MCP server | Log in as the superuser, add an MCP Tools component to a flow and pick the `cpln` server; its tools act as the service account in `cplnMcp.keySecretName` |
| API docs | `/docs` on any of the above |

Langflow blocks requests to private addresses by default, which includes services in your GVC (`*.cpln.local`). To let flows call one, such as an Ollama or Qdrant release, add this to `langflow.extraEnv`: `{name: LANGFLOW_SSRF_ALLOWED_HOSTS, value: "*.cpln.local"}`.

## Important Notes

- Never rotate or delete the encryption key secret: API keys already saved in Langflow could no longer be decrypted.
- The superuser secret is read on first start only. Change the password in the Langflow UI, since later changes to the secret are ignored.
- Anyone who reaches the public URL can sign up, but new accounts stay inactive until an admin activates them in Langflow; to turn sign-up off, add `{name: LANGFLOW_ENABLE_SIGNUP, value: "false"}` to `langflow.extraEnv`.
- Any user who can log in can run Python on the server through custom components. Give accounts only to people you trust.
- With more than one replica, use the Streamable HTTP MCP URL. The legacy SSE URL (`/sse`) works with one replica only.
- MCP clients authenticate with a Langflow API key in the `x-api-key` header (create one under Settings → API Keys), even when the MCP Server tab shows no auth.
- After turning on `redis.enabled` or Redis auth on a running release, run `cpln workload force-redeployment RELEASE_NAME-langflow --gvc GVC_NAME` so every replica picks up the change.
- The Control Plane MCP server is registered for the superuser only; other users add their own under Settings → MCP Servers. Registration runs in the background and never delays startup: the log line starting `cpln-mcp:` says whether it worked, and a key the server refuses is reported there and not registered.
- Any logged-in user can read the service-account key through Python, so grant that service account only what flows need.
- Rotating the service-account key does not update a server that is already registered: edit its `Authorization` header under Settings → MCP Servers, or delete the `cpln` server there and run `cpln workload force-redeployment RELEASE_NAME-langflow --gvc GVC_NAME`.
- Rotating a provider-keys secret does not restart Langflow; run `cpln workload force-redeployment RELEASE_NAME-langflow --gvc GVC_NAME` afterwards.
- Upgrading a 1.x release with the single-instance database needs `postgres.image: postgres:18` in your values on that and every later upgrade, or the database refuses to start (data untouched); moving the data to PostgreSQL 19 is a dump and restore into a new release. See **Upgrading from 1.x**.
- The first `helm upgrade` after an install can restart the bundled database, which briefly interrupts the editor and the API.
- Use a single-location GVC: the database, the data volume and Redis run in one location.
- Uninstalling deletes the database and the data volume, and with them every flow, user and uploaded file.

## Links

- [Langflow documentation](https://docs.langflow.org)
- [Langflow environment variables](https://docs.langflow.org/environment-variables)
- [Langflow as an MCP server](https://docs.langflow.org/mcp-server)
- [Langflow API keys and authentication](https://docs.langflow.org/api-keys-and-authentication)
- [Langflow on GitHub](https://github.com/langflow-ai/langflow)
