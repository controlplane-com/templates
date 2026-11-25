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
- **PostgreSQL**: the `postgres` template with the pgvector image (default; PostgreSQL 19 with pgvector 0.8.7), or `postgres-highly-available` (PostgreSQL 18 for a new cluster: 3 Patroni replicas, etcd and an HAProxy leader endpoint). It holds apps, users, conversations and knowledge-base vectors. The single instance refuses to start on a data directory from another PostgreSQL major version and leaves it untouched (see [Upgrading from 1.x](#upgrading-from-1x)).
- **Redis**: the `redis` template as one node, password required. It holds the cache, the task queue and plugin state.
- **Firewall**: each Dify tier accepts connections only from the tiers that call it; the sandbox cannot reach the API, web or plugin daemon.
- **Identities + policies**: `reveal` on exactly the secrets you name; the sandbox can read only its own key. The template creates no credentials; the bundled Redis keeps its config in its own secret (`RELEASE_NAME-redis-config`).

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
  image: pgvector/pgvector:0.8.7-pg19   # new installs; keep pgvector/pgvector:0.8.7-pg18 when upgrading a 1.x release (Upgrading from 1.x)
  config:
    credentialsSecretName: my-dify-db-credentials
  backup:
    enabled: false              # scheduled backups to object storage; provider aws, gcp or minio
postgresHA:                     # every knob of the postgres-highly-available template
  enabled: false                # enable exactly one of postgres / postgresHA
  image: controlplanecorporation/patroni-postgres:0.9   # pgvector 0.8.7; new clusters PostgreSQL 18, a 1.x cluster stays on 17
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

## Upgrading from 1.x

The single-instance database of 2.0.0 runs PostgreSQL 19. A 1.x release's data directory is PostgreSQL 18, and a data directory only starts under the major version that created it: on a PostgreSQL 19 image the database container does not start PostgreSQL and changes nothing on the volume. `RELEASE_NAME-postgres` stays not ready, Dify waits for it, and the database logs repeat a `[pg-guard] REFUSING TO START` message:

```bash
cpln logs '{gvc="GVC_NAME", workload="RELEASE_NAME-postgres"} |= "pg-guard"' --since 15m
```

**Stay on PostgreSQL 18.** Pin the pgvector image, and keep the pin in your values file for every later upgrade (`cpln helm upgrade` does not reuse the release's values). Use the pgvector image (the database log names it), because Dify's knowledge bases need the extension:

```yaml
postgres:
  image: pgvector/pgvector:0.8.7-pg18
```

If an upgrade ran without the pin, run the same upgrade again with `--set postgres.image=pgvector/pgvector:0.8.7-pg18`; the database comes back on its data. The Console upgrade wizard keeps the installed image and warns before a change to another major version.

**Move to PostgreSQL 19** (a dump and restore into a new release in the same GVC; Dify gets a new endpoint and cannot write while the copy runs):

1. Install 2.0.0 as a **new release** with the **same** `dify.secretName`, `postgres.config.credentialsSecretName` and `codeExecution.apiKeySecretName`. Wait until `NEW_RELEASE-dify-api` and `NEW_RELEASE-dify-plugin-daemon` are ready (they create empty schemas); do not open its `/install` page.
2. Copy the file storage (uploads and the keys that decrypt saved model credentials) and the installed plugins through your machine while the old release still runs (`./cwd`, the plugins' Python environments, is left out: the plugin daemon rebuilds it):

   ```bash
   mkdir -p ./dify-storage ./dify-plugins
   cpln workload exec OLD_RELEASE-dify-api --gvc GVC_NAME --container api -- \
     sh -c 'cd /app/api/storage && tar czf - --exclude="./.*" . | base64' | base64 -d | tar xzf - -C ./dify-storage
   cpln workload exec OLD_RELEASE-dify-plugin-daemon --gvc GVC_NAME --container plugin-daemon -- \
     sh -c 'cd /app/storage && tar czf - --exclude="./.*" --exclude="./cwd" . | base64' | base64 -d | tar xzf - -C ./dify-plugins
   cpln cp ./dify-storage/. NEW_RELEASE-dify-api:/app/api/storage --gvc GVC_NAME --container api
   cpln cp ./dify-plugins/. NEW_RELEASE-dify-plugin-daemon:/app/storage --gvc GVC_NAME --container plugin-daemon
   ```

   `cpln cp` may end with `Cannot change mode ... Operation not permitted` and exit 2: the volume's root directory belongs to root, so its mode cannot be copied. The files themselves arrive; check with `cpln workload exec NEW_RELEASE-dify-api --gvc GVC_NAME --container api -- ls -la /app/api/storage`.

3. Stop writes on both releases:

   ```bash
   cpln workload stop OLD_RELEASE-dify-api OLD_RELEASE-dify-worker OLD_RELEASE-dify-beat OLD_RELEASE-dify-plugin-daemon \
     NEW_RELEASE-dify-api NEW_RELEASE-dify-worker NEW_RELEASE-dify-beat NEW_RELEASE-dify-plugin-daemon --gvc GVC_NAME
   ```

4. Stream both databases (Dify's own and the plugin daemon's `dify_plugin`) into the new release, inside its database container (`--clean` replaces the empty schemas; nothing binary crosses `cpln workload exec`):

   ```bash
   cpln workload exec NEW_RELEASE-postgres --gvc GVC_NAME --container postgresql -- bash -c \
     'export PGPASSWORD="$POSTGRES_PASSWORD"; for db in "$POSTGRES_DB" dify_plugin; do pg_dump -h OLD_RELEASE-postgres.GVC_NAME.cpln.local -U "$POSTGRES_USER" -d "$db" --clean --if-exists | psql -U "$POSTGRES_USER" -d "$db" -q; done'
   ```

5. Start the new release (for the first few minutes the plugin daemon rebuilds the plugins' environments, and knowledge bases and the plugin list return errors until it finishes), sign in with your existing account, check your apps, knowledge bases and model providers, and point your users at the new URL (or move your custom domain and `dify.publicUrl`):

   ```bash
   cpln workload start NEW_RELEASE-dify-api NEW_RELEASE-dify-worker NEW_RELEASE-dify-beat NEW_RELEASE-dify-plugin-daemon --gvc GVC_NAME
   ```

6. Uninstall the old release.

**Highly available mode (`postgresHA`).** The upgrade is in place: an existing cluster keeps the PostgreSQL major it was created with (17 for a 1.x release) on the new `patroni-postgres:0.9` image, and only a new cluster starts on PostgreSQL 18. To move an existing cluster to 18, follow [Upgrading an existing cluster to PostgreSQL 18](https://github.com/controlplane-com/templates/blob/main/postgres-highly-available/versions/3.0.0/README.md#upgrading-an-existing-cluster-to-postgresql-18) in the postgres-highly-available template, with a new Dify 2.0.0 release (`postgresHA.enabled: true`, the same secrets) as the second release. This chart names its database workloads `RELEASE_NAME-postgres-ha` and `RELEASE_NAME-postgres-ha-proxy`, so those commands apply as written, and `pg_dumpall` copies both of Dify's databases. Copy the file storage and plugins as in step 2, and stop both releases' Dify workloads as in step 3 while the copy runs.

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
- **PostgreSQL 19 for new installs only.** A release upgraded from 1.x keeps PostgreSQL 18 only with `postgres.image: pgvector/pgvector:0.8.7-pg18` in its values; without it the database refuses to start (data untouched). See [Upgrading from 1.x](#upgrading-from-1x).
- Use a single-location GVC: the database, Redis, both volumes and the plugin daemon run in one location. The first `helm upgrade` after an install can restart the bundled database. Uninstalling deletes the database and both volumes, and with them every app, user, knowledge base and installed plugin.

## Links

- [Dify documentation](https://docs.dify.ai)
- [Dify environment variables](https://docs.dify.ai/en/self-host/deploy/configuration/environments)
- [Dify service API](https://docs.dify.ai/en/guides/application-publishing/developing-with-apis)
- [Dify as an MCP server](https://docs.dify.ai/en/cloud/use-dify/publish/publish-mcp)
- [Dify plugins](https://docs.dify.ai/en/plugins/introduction)
- [Dify licence](https://github.com/langgenius/dify/blob/main/LICENSE)
- [Dify on GitHub](https://github.com/langgenius/dify)
