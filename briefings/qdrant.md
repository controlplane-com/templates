# Qdrant — Maintainer Briefing

## What it is
- Open-source **vector database** written in Rust (stores embeddings — long lists of numbers that represent meaning — and finds the nearest matches), with REST on 6333 and gRPC on 6334.
- License: **Apache-2.0** — free to self-host, no registration, no key, and **no feature gating**: clustering, sharding, quantization and API-key RBAC are all in the free build.

## Common use cases
- Retrieval tier for **RAG** (retrieval-augmented generation) alongside the catalog's `ollama`, `litellm` and `langfuse` templates.
- Semantic / similarity search over a product catalog, docs site, or support archive.
- Recommendations and deduplication ("find things like this one").
- Filtered vector search — the differentiator vs `weaviate`: fast searches constrained by metadata (tenant, date, category).

## Architecture on cpln
| Resource | Purpose |
|---|---|
| `{release}-qdrant` (stateful, 1 replica, :6333 + :6334) | `qdrant/qdrant:v1.18.3` root image; 6333 MUST stay the first port — the canonical endpoint routes to it |
| `{release}-qdrant-data` volumeset (20 GiB) | single `/qdrant/data` mount: collections, segments, WAL, **and** Qdrant's own logical snapshots (both paths repointed via `QDRANT__STORAGE__*` env) |
| `{release}-qdrant-identity` | always created |
| `{release}-qdrant-policy` | **only when `auth.secretName` is set** — `reveal` on exactly that one secret (verified: one binding, one permission, one target) |

- No bundled database, cache or object store — Qdrant is one self-contained binary. No GVC created.
- Private by default; public access is opt-in and REST-only over the platform's HTTPS edge (gRPC stays inside the GVC). Internal endpoint: `http://{release}-qdrant.{gvc}.cpln.local:6333`.

## Key knobs
| Knob | Default | Meaning |
|---|---|---|
| `image` | `qdrant/qdrant:v1.18.3` | root image, not the `-unprivileged` variant |
| `resources.*` | 250m/1000m · 1Gi/4Gi | minCpu:cpu is exactly 4:1 (the platform cap); sizing ≈ `vectors × dims × 4 bytes × 1.5` |
| `volumeset.capacity` | `20` | GiB; render-validated at the platform minimum of 10 |
| `backup.{enabled,schedule,retention}` | `true` / `0 3 * * *` / `7d` | platform volume snapshots — no cloud account or bucket needed |
| `auth.secretName` | `""` | OPTIONAL prerequisite **dictionary** secret; empty = unauthenticated, allowed only while `publicAccess` is off |
| `auth.readOnlyKey` | `false` | also wires `read-only-api-key` from the same secret; requires `auth.secretName` |
| `service.dashboard` | `true` | built-in web UI at `/dashboard` |
| `service.maxRequestSizeMb` | `32` | max POST body; over-size = HTTP **400**, nothing written |
| `service.telemetryDisabled` | `true` | no upstream phone-home (both states verified in logs) |
| `publicAccess.enabled` / `internalAccess.type` | `false` / `same-gvc` | public **requires** `auth.secretName`; `none`, `same-org`, `workload-list` all verified allow AND deny |

Prerequisite secret (only when using auth; create BEFORE install — exact form from the README):
```
cpln secret create-dictionary --name my-qdrant-keys \
  --entry api-key=$(openssl rand -hex 32) \
  --entry read-only-api-key=$(openssl rand -hex 32)
```

## Availability posture
- **Single replica, pinned (`minScale = maxScale = 1`). There is deliberately NO `replicas` knob.** Volumesets are per-replica, so a second replica would serve a separate, empty store; Qdrant's distributed/raft mode is in the free edition but needs stable per-peer addressing on 6335 that is not proven on this platform yet. A `replicas` knob is a spike-gated follow-up.
- **A rolling restart is a real outage, not a blip: measured 79 s / 313 consecutive failed requests** (311 × HTTP 503 from the mesh, 2 × connection failure) at ~4.4 req/s, beginning ~51 s after the `helm upgrade` command returned. Budget ~2–2.5 min for a config change to fully roll.
- Install → ready: **45 s** (default, no auth), **53 s** (auth + policy + public endpoint). Data, collections and Qdrant snapshots survived every upgrade and `force-redeployment` in testing (20,004 points, identical search scores and snapshot checksum).

## Troubleshooting / considerations
- **The `qdrant-client` Python library SILENTLY enables TLS when `api_key` is set.** In-GVC callers MUST pass `https=False` (and plain `http://` URLs) — otherwise the client hangs against the internal endpoint and the symptom is a gRPC `DEADLINE_EXCEEDED`, which looks like a network or firewall problem and is not.
- **An over-size upsert returns HTTP 400 and writes NOTHING** — `{"status":{"error":"JSON payload (N bytes) is larger than allowed (limit: M bytes)."}}`, sub-second, point count unchanged. (The spec predicted 413; that was wrong and the README never named a code.) Fix by raising `service.maxRequestSizeMb` or batching smaller.
- **`publicAccess.enabled: true` with an empty `auth.secretName` fails the Helm render on purpose** — never expose an unauthenticated vector DB. "The chart won't install" is usually this. Same for `auth.readOnlyKey` without a secret name.
- **The API-key secret must be a `dictionary` secret with the exact key `api-key`** (plus `read-only-api-key` when `auth.readOnlyKey: true`) and must exist BEFORE install — a missing secret wedges the deployment. Uninstall leaves the user's secret intact (verified). Rotating a key needs a redeploy, not just a secret edit: the `cpln://secret/...` reference resolves at container start.
- **Health paths are exempt from the API key by design** (`/healthz`, `/livez`, `/readyz` → 200 with no key, which is what keeps the probes working); `/metrics` is correctly **not** whitelisted and returns 401.
- **The `/dashboard` static shell loads without an API key** (its data calls do not) — confirmed 200 unauthenticated on a public endpoint. Set `service.dashboard: false` for any publicly exposed install.
- **Memory is the thing that bites.** HNSW indexes are RAM-resident; a collection outgrowing `resources.maxMemory` gets the container OOM-killed. Fixes in order: raise memory, or have the client create collections with `vectors.on_disk: true` / `hnsw_config.on_disk: true` — a per-collection client choice, **not** a template knob.
- **Two different things are called "snapshots."** Qdrant's logical snapshots (`POST /collections/{c}/snapshots`) live under `/qdrant/data/snapshots` on the volumeset; the `backup.*` knobs are platform block-level snapshots of the whole volumeset. Users conflate them constantly.
- **`backup.enabled: false` disables only the SCHEDULED snapshot** — `createFinalSnapshot: true` is unconditional, so an uninstall still retains a final snapshot for `backup.retention`. Note: the final snapshot is not observable via any CLI surface once the volumeset is deleted (`cpln volumeset snapshot get` needs a live volumeset) — a platform observability gap, not a template defect.
- **Changing `internalAccess.type` triggers a version transition**, so the first refusals are ambiguous; propagation takes ~30–40 s and presents first as `503 upstream connect error`, then as a connection timeout. Re-test only after `deploying: false` — during a transition `get-deployments` reports a STALE `ready: true` for the outgoing replica (polling on `ready` yields a false "ready in 21 s").
- **The gRPC port must be declared `protocol: grpc`** — the `tcp` fallback fails for in-GVC gRPC over service DNS. Related upstream red herring: `config/production.yaml` shows `grpc_port` commented out with "uncomment to enable gRPC"; gRPC **is** on, inherited from `config/config.yaml`.
- **Uninstall deletes the volumeset**; a reinstall starts empty — collections are not restored automatically.
- Open WebUI can use Qdrant as its vector store (`VECTOR_DB=qdrant`, `QDRANT_URI`, `QDRANT_API_KEY`), but our `open-webui` template does not expose those knobs yet — set them on the deployed workload; wiring them up is a follow-up on that template, not this one.
