# Meilisearch — Maintainer Briefing

## What it is
- Rust search engine for **instant, typo-tolerant, faceted** search in application front-ends — the self-hosted alternative to Algolia, driven entirely by a REST API on one port.
- License: **MIT** (permissive: use, modify and self-host freely, nothing to register or pay). The shipped image is the Community build, compiled without any Enterprise code.

## Common use cases
- Search-as-you-type over a product catalog, docs site or knowledge base, wired into a front-end with a **search-only** API key.
- Faceted filtering (category, price, tag) plus ranking rules — the Algolia-shaped experience without a per-search bill.
- A search index alongside an existing database: the app writes to Postgres/MySQL and mirrors documents into Meilisearch.
- Internal search for a tool already in the GVC, reached over internal DNS with no public exposure.

## Architecture on cpln
| Resource | Purpose |
|---|---|
| `{release}-meilisearch` (stateful, **1 replica**, :7700) | the engine — one container; REST API, `/metrics` and the search preview all share port 7700 |
| `{release}-meilisearch-data` volumeset | `/meili_data` — the LMDB index (`data.ms`), Meilisearch's own snapshots and dumps; `ext4`, general-purpose SSD (never the `shared`/NFS class — upstream advises against network storage for the memory-mapped index) |
| `{release}-meilisearch-identity` | reads the master-key secret |
| `{release}-meilisearch-policy` | `reveal` on exactly that one secret — verified live: one binding, one permission, one target |

- **No database, no cache, no object store, no second workload, no subchart** beyond `cpln-common`. Simplest shape in the catalog; install → ready measured at **45–60 s** across three installs.
- The master key is a **prerequisite secret the user creates**; the template creates no secrets of its own. Private by default (`publicAccess.enabled: false`); internal endpoint `http://{release}-meilisearch.{gvc}.cpln.local:7700`.

## Key knobs
| Knob | Default | Note |
|---|---|---|
| `image` | `getmeili/meilisearch:v1.52.0` | pinned Community image; matches `appVersion` with no leading `v` |
| `resources.*` | 250m/1000m · 512Mi/2Gi | minCpu:cpu is exactly 4:1, the platform cap (6:1 was live-rejected) |
| `tuning.indexingMemoryPercent` | `50` | percent of `resources.maxMemory` → `MEILI_MAX_INDEXING_MEMORY`; render-validated to 20–80 |
| `volumeset.capacity` | `20` | GiB; index + snapshots + dumps share it; render-validated at the platform minimum of 10 |
| `auth.secretName` | `my-meilisearch-master-key` | **REQUIRED prerequisite opaque secret** (`encoding: plain`, payload = the key); must exist BEFORE install |
| `server.env` | `production` | `development` also serves the search-preview UI at `/` |
| `server.logLevel` | `INFO` | `ERROR`\|`WARN`\|`INFO`\|`DEBUG`\|`TRACE` |
| `server.maxPayloadSize` | `"100 MB"` | larger import → HTTP 413 `payload_too_large` |
| `server.telemetry` | `false` | off is implemented by setting `MEILI_NO_ANALYTICS`; on is implemented by omitting it |
| `server.upgradeDb` | `false` | `true` for exactly ONE deploy when raising the image tag, then back to `false` |
| `metrics.enabled` | `false` | Prometheus `/metrics` on 7700; needs an API key with `metrics.get` |
| `snapshots.enabled` / `intervalSeconds` | `false` / `86400` | Meilisearch's own `.snapshot` files on the volume |
| `backup.enabled` / `schedule` / `retention` | `true` / `0 3 * * *` / `7d` | platform volume snapshots — no cloud account or bucket |
| `publicAccess.enabled` / `internalAccess.type` | `false` / `same-gvc` | `none`, `workload-list` and public verified allow AND deny |

Prerequisite secret (create BEFORE install; the exact README command, run verbatim in testing):
```
printf '%s' "$(openssl rand -base64 32)" | \
  cpln secret create-opaque --name my-meilisearch-master-key --encoding plain -f -
```

## Availability posture
- **Single replica, by design and by edition. There is no `replicas` knob and there will not be one at this edition.** Replication and sharding are Enterprise-only (BSL 1.1, paid for production) and are behind a cargo feature the Community image is **not** built with — the code is not in the binary. There is no raft, gossip or membership to wire up.
- **A restart or upgrade is a real outage: measured 87 s / 68 consecutive failed requests out of 349** at 1 req/s across a `helm upgrade` (67 × HTTP 503, 1 connection failure). Failures begin **~51 s after the upgrade command returns**, so the CLI looks finished before the outage starts, and recovery lands at ~138 s.
- **Abrupt replica loss is cheaper: ~20 s** (`kill -9` → container unreachable ~13–19 s, `/health` 200 at 19 s, data intact).
- Advise callers to have the application fall back to a database query when search is unavailable.

## Troubleshooting / considerations
- **"It won't start and the deployment looks stuck" is almost always the missing master-key secret.** The template references it by name; if it does not exist the workload waits indefinitely with no obvious error. Check `cpln secret get <name>` first, every time.
- **`server.env: production` does not serve the search-preview UI, and `GET /` returns `200 {"status":"Meilisearch is running"}`.** Both look like a broken instance and are not — it is healthy. The suppression is real and causally tied to the knob: the same chart at `server.env: development` serves the full HTML dashboard at `/`.
- **`/metrics` returns HTTP 400, not 404, when metrics are off** — `{"code":"feature_not_enabled"}`. Unauthenticated it is 401 in both states. Enabled it returns real Prometheus output.
- **"Master key must be at least 16 bytes in a production environment"** means exactly that — the secret's payload is too short. `openssl rand -base64 32` is the documented way to make one.
- **Rotating the master key silently breaks every client.** All four API keys are derived from it (`generate_key_as_hexa(uid, master_key)`), so rotation changes every key value. Treat it as write-once; if it must rotate, plan to redistribute all keys.
- **Never hand the master key to a browser.** With a key set, Meilisearch auto-creates four scoped keys at `GET /keys` — Search, Admin, Read-Only Admin, Chat. Verified live: the Search key searches (200) and is refused a write (403 `invalid_api_key`). Front-ends use the Search key.
- **The indexing budget is DERIVED and has no absolute override.** `tuning.indexingMemoryPercent` × `resources.maxMemory` → `MEILI_MAX_INDEXING_MEMORY` (2Gi → `1024MiB`, 1Gi → `512MiB`, verified in-container). This is deliberate: Meilisearch reads the **host's** RAM, not the cgroup limit, and left to itself budgets two thirds of it and OOM-kills itself mid-index. Size indexing by raising `resources.maxMemory`; the two structurally cannot drift. A malformed value is fatal (`exit 2` at boot), which is why the render validates it.
- **Bumping the image tag on a populated volume fails by design.** The newer binary refuses to open an older database; set `server.upgradeDb: true` for exactly one deploy, then set it back. Two timings matter: the platform keeps the **old, working version serving for ~124 s** before the deployment flips to not-ready, so a forgotten `upgradeDb` looks fine for two minutes and then goes down; and the upgrade is **not atomic** — confirm a backup first. A large index can exceed the 300 s readiness budget and restart-loop mid-upgrade.
- **Two different things are called "snapshots."** `backup.*` = platform volume snapshots (whole-disk, on by default, no cloud account; `retention` verified applied — `expires` = `created + retention`). `snapshots.*` = Meilisearch's own `.snapshot` files on the volume (off by default; **only the newest is kept**, rewritten each interval; version-locked — use a **dump** to move across versions). Changing `backup.*` does not restart the workload.
- **There is no object-storage feature in v1.** Upstream's `MEILI_S3_*` snapshot-upload variables are Enterprise-gated. If a user asks, the answer is a future sidecar uploader, not a config flag.
- **Install into a single-location GVC.** A workload runs in every location its GVC has and each location gets its own volume — two locations means two independent indexes diverging silently behind one endpoint (stale results, not a visible outage).
- **Firewall changes take 45–150 s to propagate** (public endpoint went 403 → 503 → 200 over ~130 s; a `workload-list` re-allow took ~2.5 min). Re-poll before concluding an access knob is broken.
- **After an API-REJECTED `helm upgrade`, `cpln helm uninstall` orphans the workload, volumeset and identity** — it aborts with `This volume set is in use by a workload and cannot be deleted`. Reproduced three times here (provoked by the 6:1 cpu-ratio negative test). Fix: `cpln helm rollback {release} {last-good-revision}` first, then uninstall. This is CLI behavior affecting any volumeset-bearing template, **not** a meilisearch defect; healthy releases uninstalled cleanly first time.
- **Uninstall deletes the volumeset** (a final snapshot is retained for `backup.retention`); the user's own master-key secret is left untouched (verified). A new release therefore starts with an empty index.
- **Not settled in testing:** leaving `server.upgradeDb: true` on after a successful upgrade (upstream implies a no-op on an already-current database, but it was not measured).
