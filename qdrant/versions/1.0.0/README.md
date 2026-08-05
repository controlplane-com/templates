# Qdrant

Qdrant is an open-source (Apache-2.0) vector database for similarity search and retrieval-augmented generation. This template deploys a single Qdrant server with persistent storage, REST and gRPC APIs, optional API-key authentication, and scheduled volume snapshots.

## Architecture

- **Qdrant server** — a `stateful` workload (`{release}-qdrant`) serving the REST API + web dashboard on port 6333 and the gRPC API on port 6334.
- **Volumeset** — persistent data at `/qdrant/data`: collections, segments, HNSW indexes, WAL, and Qdrant's own logical snapshots. Platform snapshots run on a schedule; a final snapshot is taken on uninstall.
- **Identity** — the workload identity used to read the API-key secret.
- **Policy** *(only when `auth.secretName` is set)* — `reveal` on exactly that one secret, nothing else.

## Prerequisites

- **None for a default install** — Qdrant needs no database, cache, or object store.
- **Authentication (required before enabling public access):** a **dictionary** secret you create yourself, referenced by name. Create it BEFORE installing:

  ```bash
  cpln secret create-dictionary --name my-qdrant-keys \
    --entry api-key=$(openssl rand -hex 32) \
    --entry read-only-api-key=$(openssl rand -hex 32)
  ```

  `api-key` is required; `read-only-api-key` is only needed when `auth.readOnlyKey: true`.

## Configuration

### Image

```yaml
image: qdrant/qdrant:v1.18.3
```

### Resources

```yaml
# HNSW vector indexes are RAM-resident by default. Rough sizing:
#   memory ≈ vectors × dimensions × 4 bytes × 1.5   (200k × 1536 dims ≈ 1.8 GiB)
resources:
  minCpu: 250m
  maxCpu: 1000m
  minMemory: 1Gi
  maxMemory: 4Gi
```

### Storage

```yaml
volumeset:
  capacity: 20   # GiB (platform minimum 10) — collections, segments, WAL, Qdrant snapshots
```

### Backup

```yaml
# Platform-managed crash-consistent volume snapshots — no cloud account or bucket needed.
backup:
  enabled: true
  schedule: "0 3 * * *"   # cron in UTC — daily 03:00 (hourly is the platform max)
  retention: 7d           # how long each snapshot is kept (e.g. 7d, 720h, 30d)
```

### Authentication

```yaml
auth:
  secretName: ""       # name of your dictionary secret, e.g. my-qdrant-keys ; empty = no authentication
  readOnlyKey: false   # true = also wire `read-only-api-key` from the same secret
```

Empty `secretName` leaves the API unauthenticated and is allowed **only** while `publicAccess.enabled` is `false`. The read-only key can search and read but is rejected (403) on writes.

### Service

```yaml
service:
  dashboard: true          # serve the built-in web UI at /dashboard (its static shell is unauthenticated)
  maxRequestSizeMb: 32     # max POST body in MB — raise for large batch upserts
  telemetryDisabled: true  # true = send no anonymous usage reports upstream
```

### Access

```yaml
publicAccess:
  enabled: false   # true = REST API (+ dashboard) over HTTPS on the auto *.cpln.app endpoint; gRPC stays internal
internalAccess:
  type: same-gvc   # none | same-gvc | same-org | workload-list
  workloads: []    # used only with workload-list
```

## Connecting

| Target | Address | Credentials |
|---|---|---|
| Internal REST (same GVC) | `http://{release}-qdrant.{gvc}.cpln.local:6333` | `api-key` header when `auth.secretName` is set |
| Internal gRPC (same GVC) | `{release}-qdrant.{gvc}.cpln.local:6334` | same API key |
| Public REST + dashboard (if enabled) | `https://<canonical>.cpln.app` (UI at `/dashboard`) | `api-key` header |
| Health | `GET /healthz`, `/livez`, `/readyz` on 6333 | none — exempt from the API key |

The canonical hostname appears under `status.canonicalEndpoint` (`cpln workload get {release}-qdrant -o yaml`). Public traffic is HTTPS at the platform edge; same-GVC traffic is plain HTTP/gRPC over the mesh's own mTLS.

In-GVC Python client — note `https=False`:

```python
from qdrant_client import QdrantClient

client = QdrantClient(
    host="{release}-qdrant.{gvc}.cpln.local",
    port=6333, grpc_port=6334, prefer_grpc=True,
    api_key="<api-key>",
    https=False,   # REQUIRED: qdrant-client turns TLS on automatically when api_key is set
)
```

## Using Qdrant with other catalog templates

Qdrant is the retrieval tier of a RAG stack; every other component reaches it over internal GVC DNS with no public exposure. Deploy them into the same GVC and wire them by hostname:

| Template | Internal address | Role |
|---|---|---|
| `qdrant` | `http://{release}-qdrant.{gvc}.cpln.local:6333` | vector store |
| `ollama` | `http://{release}-ollama.{gvc}.cpln.local:11434` | local embedding + chat models |
| `litellm` | `http://{release}-litellm.{gvc}.cpln.local:4000` | OpenAI-compatible gateway to hosted models |
| `langfuse` | `http://{release}-langfuse-web.{gvc}.cpln.local:3000` | tracing for the retrieval + generation calls |

A retrieval service running in the GVC embeds with Ollama, stores in Qdrant, and generates through LiteLLM:

```python
import httpx
from qdrant_client import QdrantClient
from qdrant_client.models import VectorParams, Distance, PointStruct

GVC = "my-gvc"
qdrant = QdrantClient(host=f"my-qdrant.{GVC}.cpln.local", port=6333, grpc_port=6334,
                      prefer_grpc=True, api_key=API_KEY, https=False)
qdrant.create_collection("docs", vectors_config=VectorParams(size=768, distance=Distance.COSINE))

# embed with the in-GVC ollama workload
vec = httpx.post(f"http://{OLLAMA_RELEASE}-ollama.{GVC}.cpln.local:11434/api/embeddings",
                 json={"model": "nomic-embed-text", "prompt": text}).json()["embedding"]
qdrant.upsert("docs", points=[PointStruct(id=1, vector=vec, payload={"text": text})])

# retrieve, then generate through the in-GVC litellm gateway
hits = qdrant.query_points("docs", query=vec, limit=4).points
httpx.post(f"http://my-litellm.{GVC}.cpln.local:4000/v1/chat/completions", json={...})
```

**Open WebUI** can use Qdrant as its native vector store instead of the bundled Chroma — set `VECTOR_DB=qdrant`, `QDRANT_URI=http://{release}-qdrant.{gvc}.cpln.local:6333` and `QDRANT_API_KEY` on the Open WebUI workload (the `open-webui` template does not expose these knobs yet; set them on the deployed workload).

## Important Notes

- **Public access requires an API key** — installing with `publicAccess.enabled: true` and an empty `auth.secretName` fails at render time. Create the dictionary secret first.
- **In-GVC clients must disable TLS** (`https=False` in `qdrant-client`, plain `http://` URLs) — the client silently switches to TLS when an `api_key` is supplied and then hangs against the internal endpoint (the symptom is a gRPC `DEADLINE_EXCEEDED`).
- **The `/dashboard` shell loads without an API key** (its API calls do not). Set `service.dashboard: false` when Qdrant is publicly exposed.
- **Single replica by design** — data survives restarts and upgrades on the volumeset, but a rolling restart is a brief availability gap. Distributed/raft mode is not in this version.
- **Uninstall deletes the volumeset** (a final snapshot is kept for `backup.retention`); your own API-key secret is left untouched.
- **Memory is the sizing constraint** — vectors and HNSW graphs stay in RAM unless a collection is created with `on_disk` vectors/index. Raise `resources.maxMemory` before loading large collections.

## Links

- [Qdrant documentation](https://qdrant.tech/documentation/)
- [Security / API keys](https://qdrant.tech/documentation/guides/security/)
- [Collections and indexing](https://qdrant.tech/documentation/concepts/collections/)
- [Snapshots](https://qdrant.tech/documentation/concepts/snapshots/)
- [Memory consumption and sizing](https://qdrant.tech/articles/memory-consumption/)
