# SeaweedFS — Maintainer Briefing

## What it is
- Distributed object store with an **S3-compatible API** — self-hosted storage speaking the same protocol as Amazon S3, so existing S3 clients and libraries work unchanged. License: Apache-2.0 (permissive; free to run/modify/redistribute, no registration, key or paid tier).
- Shipped as ONE workload running `weed mini` — the image's own default command — which starts master + volume server + filer + S3 gateway + admin UI in a **single process**. Image `chrislusf/seaweedfs:4.40`.
- Exists to be the catalog's S3 endpoint now that MinIO's community images stopped (Oct 2025) and the repo was archived (2026-04-25). The `minio` template is untouched — deprecate-or-redirect is still an open maintainer decision.

## Common use cases
- **Backup target** for `postgres-highly-available` / `timescaledb-highly-available` (proven live, below) and for `thanos`, `mimir`, `prometheus`.
- **Attachment/file storage** for app templates: `docmost`, `sftpgo`, `n8n`, `metabase`, `keycloak`, `unleash`.
- **Self-hosted S3 for the user's own apps** — data stays in the user's org, no cloud egress bill.
- Cheap object store for dev/staging where a real cloud bucket is overkill.

## Architecture on cpln
| Resource | Purpose |
|---|---|
| `{release}-seaweedfs` (stateful, 1 replica, :8333) | one container, `weed mini`; every port pinned by flag; `timeoutSeconds: 300` for long uploads |
| `{release}-seaweedfs-data` volumeset (20 GiB) | `/data` — objects + filer leveldb + master metadata on one disk; final snapshot retained 7 days |
| `{release}-seaweedfs-identity` / `-policy` | `reveal` on exactly the two user-created secrets (S3 always; admin only when the UI is on) — no cloud access at all, no `aws` or `gcp` block on the identity |
| *(user-created)* S3 prerequisite dictionary secret | `AWS_ACCESS_KEY_ID` + `AWS_SECRET_ACCESS_KEY` |
| *(user-created)* admin prerequisite dictionary secret | `username` + `password` — since **1.1.0**; the template creates NO secrets of its own |

- Ports: **8333 = S3 API**, declared FIRST so the canonical `*.cpln.app` endpoint routes to it; **23646 = admin UI**, in-GVC only (verified: external `GET /login` → 403 from the S3 API). Master 9333 / filer 8888 / volume 9340 listen in-container but are not declared. None of these collide with the platform's reserved container ports. `publicAccess.enabled: true` still exposes only 8333; reach the admin UI with `cpln port-forward {release}-seaweedfs 23646:23646 --gvc {gvc}`.
- No GVC created, no subcharts, no cloud account, no raw-TCP load balancer. `-s3.externalUrl` deliberately NOT set.

## Key knobs
| Knob | Default | Note |
|---|---|---|
| `image` | `chrislusf/seaweedfs:4.40` | matches `appVersion`; pin a released tag, never `latest` |
| `resources.{minCpu,maxCpu,minMemory,maxMemory}` | 250m/1000m · 512Mi/2Gi | 4.00 cpu:minCpu ratio accepted on first apply; raise memory for tens of millions of objects |
| `volumeset.capacity` | `20` | GiB; render-validated minimum 10 |
| `volumeset.autoscaling.{enabled,maxCapacity,minFreePercentage,scalingFactor}` | `false` / `200` / `10` / `1.2` | matters here — object stores fill up; `maxCapacity` must be ≥ `capacity` |
| `s3.credentialsSecretName` | `my-seaweedfs-s3-credentials` | REQUIRED prerequisite dictionary secret — **must exist BEFORE install** |
| `s3.buckets` | `[]` | created at boot if missing; most backup tools need the bucket to pre-exist |
| `adminUI.enabled` / `.credentialsSecretName` | `true` / `my-seaweedfs-admin-credentials` | REQUIRED prerequisite dictionary secret (`username`, `password`) while the UI is on — **must exist BEFORE install** |
| `publicAccess.enabled` | `false` | `true` = S3 API on the auto HTTPS endpoint (path-style) |
| `internalAccess.type` / `.workloads` | `same-gvc` / `[]` | all four enum values verified live, incl. cross-GVC `same-org` and a denied `workload-list` |

Prerequisite secrets (both create BEFORE install; the exact README forms, run live 2026-08-19):
```
cpln secret create-dictionary --name my-seaweedfs-s3-credentials \
  --entry AWS_ACCESS_KEY_ID="$(openssl rand -hex 10)" \
  --entry AWS_SECRET_ACCESS_KEY="$(openssl rand -hex 24)"

cpln secret create-dictionary --name my-seaweedfs-admin-credentials \
  --entry username=admin --entry password="$(openssl rand -hex 24)"
```

## Availability posture
- **Single replica, no `replicas` knob** (`minScale`/`maxScale` pinned to 1). `weed mini` is single-master by design and each replica would hold its own separate copy — more replicas would mean several unrelated object stores behind one name. Multi-node clustering is open-source upstream and a specced follow-up gated on named spikes.
- **A redeploy/upgrade is a FULL S3 outage, measured: 337 consecutive failed requests over an 80.8 s gap** (~5 req/s poll, 738 samples); the outage started 47.3 s after the redeploy was triggered and service was restored 128 s after the trigger. A second independent redeploy bounded the same gap at 65–102 s. SeaweedFS itself boots in ~1.5 s — essentially the whole window is platform teardown/reschedule/volume re-attach.
- Install → ready **57 s**. Data durability held across 3 forced redeploys and 7 `helm upgrade`s: all buckets, a 100 MB object (md5 identical) and every small object intact, volumeset never re-provisioned.

## Troubleshooting / considerations
- **Deployment stuck, never starts** → one of the two prerequisite secrets does not exist. `cpln logs` returns ZERO lines (the container never starts), so it reads as a platform fault; the only diagnostic is `status.versions[].message` from `cpln workload get-deployments {release}-seaweedfs --gvc {gvc} -o yaml` — **`get-deployments`**, not plain `get`. Recovers on its own in ~6 min once the secret exists, or ~90 s with a forced redeployment. This is the deliberate safe failure — see the next bullet. Uninstall leaves the user's secrets intact (verified).
- **1.1.0 removed `adminUI.username` / `adminUI.password`** — the admin UI is a human-facing login form, so per the 2026-08-07 ruling its credentials cannot be values. `change-me-seaweedfs-admin` was used AS-IS by any install that did not override it, i.e. a working password published in our public repo. There is NO compatibility shim: passing either old key fails the render with a message naming `adminUI.credentialsSecretName`. Upgraders must create the secret with their existing username/password to keep logins working.
- **With no credentials, SeaweedFS serves S3 with NO authentication at all** — hence hard prerequisite, not a value. Never let a user install with a blank key, especially with `publicAccess.enabled: true`. Signed requests verified end to end: wrong secret → `SignatureDoesNotMatch`, unsigned → 403, `/healthz` unauthenticated by design.
- **Path-style addressing is required** (`http://host:8333/bucket/key`, not `bucket.host`). Consumers set `forcePathStyle: true` / `addressing_style = path`. Virtual-host style needs a custom domain — follow-up.
- **The region value is never validated** — it is read from the client's signature scope and not compared to any server setting (proven with `AWS_DEFAULT_REGION=eu-west-9`). Leaving consumers at `us-east-1` is fine.
- **Proven drop-in backup target**: `postgres-highly-available` 2.4.1 with `backup.provider: minio` → `backup.minio.endpoint: http://{release}-seaweedfs:8333`, bucket pre-seeded via `s3.buckets`, keys from the prerequisite secret. **No consumer-side change was needed**; artifact verified byte-wise in the bucket and a real restore brought a dropped table's row back. Templates offering only `aws`/`gcp` providers (`ghost`, `clickhouse`) cannot point here.
- **Rotating S3 credentials genuinely works** — the S3 identity is `IsStatic`, rebuilt from env on every boot, so updating the secret + redeploying swaps the keys (old key → `InvalidAccessKeyId`, new key works, seeded data intact). Unusual: most stateful templates bake bootstrap creds into the data dir where a change has no effect.
- **`adminUI.enabled: false` means "UI routes off", not "component not running"** — upstream `weed mini` still starts the admin server in-process (port 23646, `/data/admin/.session_key`); `-admin.ui` only controls route registration, so in-container requests 404. No exposure: the port is undeclared, the env credentials are gone, and the admin policy target is removed (policy narrows to the S3 credentials secret only). Reversible — re-enabling restores both.
- **`s3.buckets` seeds at boot only**: adding a bucket takes effect on the next restart; removing one from the list never deletes it.
- **Volume file size limit is derived from disk capacity at startup** (`Volume Size Limit is 256 MB` at 15 GiB), so growing the volumeset takes effect on the next restart. Harmless — SeaweedFS just creates more volume files.
- **Firewall changes take 60–90 s to propagate**, up to ~2 min if a client cached a negative DNS answer. Do not read a failing probe in the first minute after an `internalAccess`/`publicAccess` flip as a fault.
- **Never set `-s3.externalUrl` / `S3_EXTERNAL_URL`** — upstream makes it the *only* accepted host for signature checking, instantly breaking every in-GVC client connecting on the internal hostname.
- **`-ip=localhost` is load-bearing**: it pins the advertised identity so master raft/sequencer state survives a reschedule onto a new pod IP (`Running in single-master mode (peers=none)`, no raft errors across restarts); `-ip.bind=0.0.0.0` keeps listeners on all interfaces. No `filesystemGroupId` needed — the image entrypoint chowns `/data` on first boot.
- Benign log noise: `W … filer_server.go:215 skipping default store dir in /data/filerldb2` (the only W/E line across the whole run). The admin login form requires a `csrf_token` hidden field — relevant only if someone scripts against the UI.
