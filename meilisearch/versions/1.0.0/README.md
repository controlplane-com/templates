# Meilisearch

Meilisearch is an open-source (MIT) search engine for instant, typo-tolerant, faceted search — the self-hosted alternative to Algolia, driven entirely by a REST API. This template deploys a single Meilisearch server with persistent index storage, mandatory master-key authentication, optional scheduled snapshots, and platform volume backups.

## Architecture

- **Meilisearch server** — a `stateful` workload (`{release}-meilisearch`) serving the REST API on port 7700. Exactly one replica.
- **Volumeset** — persistent data at `/meili_data`: the LMDB index (`data.ms`), Meilisearch's own snapshots, and dumps. Platform snapshots run on a schedule; a final snapshot is taken on uninstall.
- **Identity** — the workload identity used to read the master-key secret.
- **Policy** — `reveal` on exactly that one secret, nothing else.

No database, cache, or object store is involved, and the template creates no secrets of its own.

## Prerequisites

- **A master-key secret you create yourself, BEFORE installing.** This is required — the workload will not start without it, and a deployment referencing a secret that does not exist waits indefinitely with no obvious error. It is an **opaque** secret with `encoding: plain` whose entire payload is the key:

  ```bash
  printf '%s' "$(openssl rand -base64 32)" | \
    cpln secret create-opaque --name my-meilisearch-master-key --encoding plain -f -
  ```

  The key must be **at least 16 bytes** while `server.env` is `production`; a shorter one makes Meilisearch refuse to launch with *"The master key must be at least 16 bytes in a production environment"*. Set `auth.secretName` to the name you used.

- Nothing else — no cloud account, no bucket, no external database.

## Configuration

### Image

```yaml
image: getmeili/meilisearch:v1.52.0
```

### Resources

```yaml
# Searches are served from a memory-mapped index, so steady-state RAM is modest;
# indexing is the hungry phase. Upstream sizing guide: RAM ≈ ⅓ of on-disk index.
resources:
  minCpu: 250m
  maxCpu: 1000m
  minMemory: 512Mi
  maxMemory: 2Gi
```

### Storage

```yaml
volumeset:
  capacity: 20 # GiB (platform minimum 10) — index, snapshots and dumps share it
```

### Master key

```yaml
auth:
  secretName: my-meilisearch-master-key # name of your pre-created opaque secret
```

### Server

```yaml
server:
  env: production            # production | development — development also serves the search-preview UI at /
  logLevel: INFO             # ERROR | WARN | INFO | DEBUG | TRACE
  maxPayloadSize: "100 MB"   # largest accepted request body; a bigger import is rejected with HTTP 413
  maxIndexingMemory: "1 GiB" # keep at ≈½ of resources.maxMemory — unset, Meilisearch budgets from HOST RAM
  telemetry: false           # true = send anonymous usage data upstream
  upgradeDb: false           # true for ONE deploy when moving to a newer image tag, then set back to false
```

### Metrics

```yaml
metrics:
  enabled: false # true = Prometheus /metrics on port 7700 (needs an API key with the metrics.get action)
```

These are index-level metrics (documents indexed, searches per index) that the platform's built-in workload metrics cannot see. With `enabled: false`, `GET /metrics` returns HTTP 400 `feature_not_enabled`.

### Snapshots and backup

Two different things are called "snapshots" — they do different jobs:

| Block | What it is | Default |
|---|---|---|
| `backup` | **Platform** volume snapshots — crash-consistent whole-disk copies. No cloud account or bucket needed. | on |
| `snapshots` | **Meilisearch's own** `.snapshot` files written onto the volume. Only the newest is kept. Required by upstream's upgrade procedure. | off |

```yaml
snapshots:
  enabled: false         # scheduled .snapshot files in /meili_data/snapshots — only the newest is kept
  intervalSeconds: 86400 # seconds between snapshots
```

```yaml
backup:
  enabled: true
  schedule: "0 3 * * *" # cron in UTC — daily 03:00 (hourly is the platform max)
  retention: 7d         # how long each snapshot is kept (e.g. 7d, 720h, 30d)
```

### Access

```yaml
publicAccess:
  enabled: false # true = REST API over HTTPS on the auto *.cpln.app endpoint
internalAccess:
  type: same-gvc # none | same-gvc | same-org | workload-list
  workloads: []  # used only with workload-list
```

## Connecting

| Target | Address | Credentials |
|---|---|---|
| Internal REST (same GVC) | `http://{release}-meilisearch.{gvc}.cpln.local:7700` | `Authorization: Bearer <key>` |
| Public REST (if enabled) | `https://<canonical>.cpln.app` | `Authorization: Bearer <key>` |
| Health | `GET /health` on 7700 | none — the one route the master key does not protect |

The canonical hostname appears under `status.canonicalEndpoint` (`cpln workload get {release}-meilisearch -o yaml`). Public traffic is HTTPS at the platform edge; same-GVC traffic is plain HTTP over the mesh's own mTLS.

**Use a scoped API key, not the master key.** On first boot Meilisearch derives four keys from the master key. Fetch them once and hand the right one to each caller:

```bash
curl -H "Authorization: Bearer <master-key>" http://{release}-meilisearch.{gvc}.cpln.local:7700/keys
```

| Key | Use it for |
|---|---|
| Default Search API Key | front-ends — search only, writes are rejected with 403 |
| Default Admin API Key | your indexing pipeline — everything except key management |
| Default Read-Only Admin API Key | dashboards and monitoring |
| Default Chat API Key | the experimental chat route |

## Important Notes

- **The master-key secret must exist before you install.** If it does not, the deployment hangs waiting on a secret that will never resolve and looks broken. Check `cpln secret get <name>` first.
- **`server.env: production` does not serve the search-preview UI.** `GET /` returns `{"status":"Meilisearch is running"}` — that is a healthy instance, not a failed one. Set `server.env: development` if you want the browser search playground at `/`; the master key still protects every route either way.
- **Rotating the master key changes every API key.** Meilisearch derives all four keys from it, so a rotation silently breaks every deployed client. Treat it as write-once, or plan to redistribute all keys.
- **Raising the image tag on a populated volume fails by design** — Meilisearch refuses to open a database written by an older version. Set `server.upgradeDb: true` for exactly one deploy, then set it back to `false`. The upgrade is **not atomic**: confirm a recent backup exists first.
- **Move `server.maxIndexingMemory` whenever you move `resources.maxMemory`.** Meilisearch sizes its indexing budget from the *host's* RAM, not the container limit, which is why this template sets it explicitly. Too high and indexing gets OOM-killed; too low and it under-uses the container.
- **Single replica, by design and by edition.** Replication and sharding are Meilisearch Enterprise features and are not compiled into the Community image this template ships, so there is no `replicas` knob and no failover. A restart or upgrade is a real outage of the search endpoint — have your application fall back to a database query when search is unavailable.
- **Install into a single-location GVC.** A workload runs in every location its GVC has, and each location gets its own volume — two locations means two independent indexes diverging silently behind one endpoint.
- **Uninstall deletes the volumeset** (a final snapshot is kept for `backup.retention`); your master-key secret is left untouched.

## Links

- [Meilisearch documentation](https://www.meilisearch.com/docs)
- [Configuration reference](https://www.meilisearch.com/docs/resources/self_hosting/configuration/reference)
- [API keys and security](https://www.meilisearch.com/docs/learn/security/basic_security)
- [Snapshots and backups](https://www.meilisearch.com/docs/resources/self_hosting/data_backup/overview)
- [Updating Meilisearch](https://www.meilisearch.com/docs/resources/migration/updating)
