# Redis — Maintainer Briefing

## What it is
- Runs **Redis (default) or Valkey** — one `engine` knob, chosen at install. Valkey is the BSD-3-Clause (permissive: use, modify, redistribute, no strings) fork of Redis 7.2 stewarded by the Linux Foundation; no paid edition exists, so nothing in it is feature-gated.
- Master-replica Redis with a Redis Sentinel quorum in front: automatic leader election, automatic failover, and Sentinel-based master discovery for clients. Optional persistence, metrics exporter, scheduled S3/GCS backups, and public TCP exposure.
- License: the shipped `redis:8` image is tri-licensed **RSALv2 / SSPLv1 / AGPLv3** — Redis 8 added the AGPLv3 option, which is why 3.5.0 moved the default off 7.4 (dual RSALv2/SSPL, neither OSI-approved). Free to self-host either way; no registration, no paid edition.
- Doubles as catalog infrastructure: seven other templates take this chart as a dependency, so a change here has blast radius beyond its own installs (see the dependent-pin note below).

## Common use cases
- Application cache / session store with automatic failover rather than a single-node cache.
- Job queues and pub/sub (BullMQ, Sidekiq, Celery) that need a stable master address.
- The HA Redis backing dependency for other catalog templates (litellm, infisical, glitchtip, grafana, tooljet, tyk, cpln-task-runner).
- Rate-limiting / leaderboard / ephemeral-state workloads that can tolerate async replication.

## Architecture on cpln
| Resource | Purpose |
|---|---|
| `{release}-redis` (stateful, 3 replicas, :6379) | `redis:8` (or `valkeyImage` under `engine: valkey`); boot script asks Sentinel who the master is, then boots as master or `--replicaof`; replication-aware readiness probe |
| `{release}-sentinel` (stateful, 3 replicas, :26379) | `redis:8` (or `valkeyImage`) in sentinel mode; quorum `(replicas/2)+1`; `down-after-milliseconds 5000`, `failover-timeout 10000` |
| `{release}-redis-config` / `{release}-sentinel-config` (opaque, `encoding: plain`) | file-mounted `redis.conf` / `sentinel.conf` |
| `{release}-redis-auth-password` / `{release}-sentinel-auth-password` (dictionary) | only when inline `auth.password.enabled` |
| `{release}-redis-vs` / `{release}-sentinel-vs` volumesets | opt-in; AOF+RDB data at `redis.dataDir`, sentinel `CONFIG REWRITE` state at `/etc/sentinel` |
| `{release}-redis-identity` / `-sentinel-identity` + matching policies | `reveal` on exactly the config + both tiers' password secrets; the redis identity also carries the backup cloud binding |
| `{release}-redis-backup` (cron) + `-backup-config` secret + `-backup-policy` | opt-in scheduled RDB dump to S3/GCS via `redis-backup:1.0.0` |
| `kind: domain` ×2 + `{release}-redis-dashboard` | opt-in: public TCP exposure (one port per replica) and a `GrafanaDashboard` CRD |

- Both workloads carry `cpln/publishNotReadyAddresses: "true"` and `rolloutOptions.scalingPolicy: Parallel` — peers must resolve each other during a simultaneous cold start or the cluster cannot form. Do not remove either.
- No GVC created, no chart dependencies beyond `cpln-common`. `redis.exporter` adds a `redis_exporter` sidecar on `:9121` scraped by the platform.

## Key knobs
| Knob | Default | Meaning |
|---|---|---|
| `engine` | `redis` | `redis` \| `valkey`. Selects the server image for **both** tiers at once; validated at render with a named `fail`. Install-time only |
| `valkeyImage` | `valkey/valkey:8.1.9` | used for BOTH tiers when `engine: valkey`, at which point `redis.image`/`sentinel.image` are ignored. Debian tags only — `-alpine` has no bash |
| `redis.image` / `sentinel.image` | `redis:8` (both) | live tag resolves to 8.10.0; `redis:7.4` still renders if you must pin back |
| `redis.replicas` / `sentinel.replicas` | `3` / `3` | sentinel must be odd; `1`+`1` proven for dev shapes |
| `redis.resources.*` / `sentinel.resources.*` | `maxCpu: 200m` `minCpu: 80m` · `maxMemory: 256Mi` `minMemory: 128Mi` | **renamed in 3.6.0**: the limit is `maxCpu`/`maxMemory`. A values file still carrying bare `cpu`/`memory` is refused at render with a named `fail` |
| `redis.auth.password.{enabled,value}` | `false` / `change-me-redis-password` | template-created secret; sentinel side is `change-me-sentinel-password` |
| `redis.auth.fromSecret.{enabled,name,passwordKey}` | `false` / `example-redis-auth-password` / `password` | user-supplied dictionary secret; only one auth method may be enabled per tier |
| `redis.persistence.enabled` / `sentinel.persistence.enabled` | `false` / `false` | redis = AOF+RDB durability at `redis.dataDir` (`/data`); sentinel = post-failover master survives restart (**recommended on in prod**) |
| `redis.replication.{backlogSize,timeout,slaveOutputBufferLimit}` | `1gb` / `300` / `"2gb 512mb 300"` | tuned well above Redis defaults so a brief disconnect does not escalate to a full resync |
| `redis.probes.readiness.*` / `.liveness.*` | failureThreshold `10`/`5`, initialDelay `10`/`30`, period `5`/`10`, timeout `4`/`5` | startup window = `initialDelaySeconds + 30 × periodSeconds` (160 s); raise `periodSeconds` for large AOF loads |
| `redis.exporter.enabled` / `.image` / `.dropMetrics` | `false` / `oliver006/redis_exporter:v1.67.0-alpine` / `[]` | 435 series, zero scrape errors against Redis 8, works through `requirepass` |
| `sentinel.quorumAutoCalculation` / `quorumOverride` | `true` / `null` | override only with auto-calculation off |
| `*.firewall.internal_inboundAllowType` | `same-gvc` | `same-org` / `workload-list` (+ `inboundAllowWorkload`) both proven |
| `*.publicAccess.enabled` / `.address` | `false` / `redis-test.example-cpln.com`, `redis-sentinel-test.example-cpln.com` | render-verified only — see notes |
| `backup.enabled` / `.schedule` / `.provider` | `false` / `"0 2 * * *"` / `aws` | AWS and GCS both verified end to end against real buckets |
| `backup.aws.*` / `backup.gcp.*` | `my-backup-bucket`, `us-east-1`, `my-backup-cloudaccount`, `my-backup-policy`, `redis/backups` | keyless via cloud account; every field render-validated with a named `fail` |
| `backup.image` / `backup.resources` | `…/backup-images/redis-backup:1.0.0` / `cpu: 100m` `memory: 128Mi` | version-agnostic; produced a valid `redis-ver8.10.0` RDB |
| `grafana.dashboard.enabled` / `folder` / `datasource` | `false` / `Redis` / `metrics` | K8s + Grafana Operator only; not a cpln kind |

Optional prerequisite secret for `auth.fromSecret` (dictionary; the README's example name is `my-redis-secret`, one secret per tier):
`cpln secret create-dictionary --name my-redis-secret --entry password=$(openssl rand -hex 24)`
(the entry key must match `passwordKey`, default `password`)

## Availability posture
- The HA shape is **identical on both engines** — 3 data + 3 sentinels, quorum 2. Valkey gates nothing (BSD-3, no paid edition), and the Valkey render differs from the Redis render only in the image string.
- **HA is the default shape**: 3 data nodes + 3 sentinels, quorum 2. Clients discover the master via `SENTINEL get-master-addr-by-name mymaster`, never by pinning pod-0.
- **Measured failover (hung master):** `+sdown` at ~5.2 s (matches `down-after-milliseconds 5000`), `+switch-master` at 6.7 s, `+failover-end` at 7.7 s. On the pure-default no-auth cluster, ~8.4 s end to end. Old master rejoins cleanly as a replica; no split brain observed.
- A **fast crash** (container back in ~1 s) correctly does *not* trigger failover — sentinel logs `+reboot master`. That is what most "kill the master" attempts actually produce here.
- **Rolling replacement of all 3 data nodes: ~173 s** (~90 s/pod, dominated by volume detach/attach), with two automatic ~1.5 s failovers along the way and zero key loss. Cold start ~38 s (persistent/auth shape) to ~201 s (3+3 pure defaults).
- The replication-aware readiness probe holds a resyncing pod NotReady while the deliberately permissive TCP liveness probe leaves it alive — that split is the design and is why the roll never kills a mid-resync replica.

## Troubleshooting / considerations
- **The 7.4 → 8 upgrade is ONE-WAY.** Redis 8 reads 7.4 AOF/RDB directly (proven: 206 mixed-type keys, identical keyset MD5, TTLs still counting down after a real `helm upgrade`), but once a node writes under 8 a 7.4 image can no longer load it. Snapshot the volumeset first if you want a rollback path.
- **Never rotate the password in place — it deadlocks the rollout.** The first restarted node cannot AUTH to the not-yet-restarted master (`Unable to AUTH to MASTER: -WRONGPASS`), readiness never passes, and the roll stalls indefinitely (observed stuck at 1 of 3 for 17+ minutes). **Recovery: `helm upgrade` back to the previous password** — full health restored in 282 s. Otherwise uninstall/reinstall. With `sentinel.persistence: true` sentinel also keeps the stale `auth-pass`, compounding it.
- **Switching `backup.provider` leaves a STALE cloud binding on the identity.** The rendered manifest is correct (gcp-only), but the platform deep-merges identity updates and never removes absent keys, so the live identity keeps both `aws:` and `gcp:` blocks — a least-privilege leak invisible to any render inspection. Reinstall, or hand-edit the identity, after a provider switch.
- **`backup.schedule` starting with `*` renders correctly as of 3.5.0.** On 3.4.3 and earlier `schedule: {{ .Values.backup.schedule }}` was unquoted, so YAML parsed `*/5 * * * *` as an alias node and the chart would not render at all. Anyone on ≤3.4.3 who "can't use `*/N` schedules" needs this version.
- **The seven dependent templates still pin redis 3.4.x** (`cpln-task-runner`/`tyk` on 3.4.2; glitchtip, grafana, infisical, litellm, tooljet on 3.4.3) — they are all still on Redis 7.4 until each is bumped individually. The default no-auth/no-persistence shape they consume was installed and failed over cleanly on Redis 8, so the bump is safe whenever they take it.
- **`publicAccess` is render-verified only** — a live test needs a maintainer-owned DNS zone (blocked at test time). It also requires a Dedicated Load Balancer on the GVC and the TXT + CNAME records created *before* first deploy, or the domain resource is rejected. Ports are one per replica: redis `6380+i`, sentinel `26380+i`.
- **Firewall changes take ~150 s to propagate** — an unlisted client kept getting `PONG` for five polls after a `workload-list` upgrade returned before flipping to denied. Wait ~2.5 min before concluding a rule doesn't work.
- **The AWS backup identity still carries `aws::ReadOnlyAccess`** in `policyRefs` alongside the user's scoped policy — broader than needed; docmost trimmed exactly this. Open item, pre-existing, not 3.5.0-specific.
- `redis.exporter.dropMetrics`, `persistence.volumes.data.customEncryption`, and the whole `grafana.dashboard.*` block are config/render-verified only — no CLI path to the org metrics store, no KMS key in the test org, no Grafana Operator on the managed platform.
- Redis 8 refuses `DEBUG` subcommands unless `enable-debug-command` is set (same on 7.4.10) — affects operator muscle memory (`DEBUG SLEEP`), not the chart. Use `CLIENT PAUSE` to simulate a hung master.
- Benign cold-start noise, self-clearing within ~8 s: `delayed_connect_error:_Connection_refused` from `_accesslog`, `Failed to read response from the server: Success` on replicas' first handshake, `detected child with unmatched pid` during the initial AOF rewrite. Steady state logs zero error/warn lines.
- **`aws::ReadOnlyAccess` was removed from the backup identity in 3.5.1.** It granted read access to every bucket in the AWS account and contains no write actions, so it was never carrying the backup — what it did carry was account-wide read. The identity is now `cpln-connector` plus the user's bucket-scoped policy only. The documented IAM policy was widened to ten actions at the same time, because `ReadOnlyAccess` had been silently supplying any read action a user's policy omitted; **an upgrading user must update their IAM policy first**.

### Valkey engine (3.7.0)
- **The engine cannot be changed on an existing install.** Measured locally at the pinned tags: `redis:8` (8.10.1) writes **RDB 15**, and Valkey 8 refuses anything in its foreign range — the container exits 1 with `# Can't handle RDB format version 15` / `# Error reading the RDB base file appendonly.aof.1.base.rdb, AOF loading aborted`, i.e. a crash loop. With persistence off it silently starts empty instead, which is worse. Migrate by dump/restore or replication, never by flipping the knob.
- **The reverse direction happens to work but is still unsupported here:** Valkey 8 writes RDB 11, and `redis:8` loaded a Valkey-written AOF cleanly (20/20 keys) in the same local probe. Untested on the platform, so do not document it as a migration path.
- **`redis-server` / `redis-cli` / `redis-sentinel` work unchanged under Valkey** because the image ships compatibility symlinks (Valkey's own `make install` default, `USE_REDIS_SYMLINKS?=yes`). All six were confirmed present at `valkey/valkey:8.1.9`. That is why no script, probe or config directive changed — and why `valkeyImage` is pinned to an exact tag rather than a floating one: the symlinks are an upstream default a future release could flip.
- **`masterauth` and `client-output-buffer-limit slave` are still accepted at 8.1.9** — verified by starting `valkey-server`/`valkey-sentinel` on this chart's real rendered config payloads (zero `Bad directive` lines, `Ready to accept connections`, `CONFIG GET` echoes both back). Valkey's docs prefer `primaryauth`/`replica`; the aliases are retained.
- **Valkey reports `redis_version:7.2.4`** in `INFO` for client compatibility. To tell what is actually running read `server_name:valkey` and `valkey_version`. Anything that version-gates on `redis_version` will believe it is talking to Redis 7.2.
- **`appVersion` still shows the Redis version** on the marketplace card even for a Valkey install — a chart's appVersion is a constant and cannot follow a values knob. Deliberate: it describes what a default install runs.
- **Only the Debian-based Valkey tags work here.** `valkey/valkey:8.1.9` has `bash 5.2.37` (confirmed), which the readiness probe and the `publicAccess` liveness probe (`exec 3<>/dev/tcp/...`) both require; the `-alpine` tags do not.
- **Do not set `dual-channel-replication-enabled yes` via `extraArgs` on Valkey** — [valkey-io/valkey#2338](https://github.com/valkey-io/valkey/issues/2338) makes Sentinel see duplicate replicas. It defaults to `no` and the chart never sets it.
- The image runs as **root** with the entrypoint bypassed (`uid=0`, confirmed), same as `redis:*`, so the volumesets need no `securityOptions.filesystemGroupId`. `io-threads` defaults to `1`, so the 200m CPU floor is unchanged.
- The backup image is engine-agnostic: it drives `redis-cli --rdb`, `INFO replication` and `CLUSTER INFO`, all of which behave identically on Valkey (`CLUSTER INFO` errors the same way on a standalone server, so the script's standalone branch is taken).
- **`persistence` is an INSTALL-TIME choice, like `engine`.** Enabling it on an already-running release stalls the rollout indefinitely: replicas sit on `Replica N will be restarted shortly`, the volume set's volumes stay `unbound`, `/data` stays on the container overlay, and a forced redeployment does not clear it. Measured at 27 minutes with no progress (2026-08-26). Controls that isolate it: a fresh install with persistence works in 53 s, and an image-only upgrade on a workload that already owns its volume rolls fine — so the problem is specifically ADDING a volume to a live release. Engine-independent; reproduced under `engine: redis`. Pre-existing, not introduced by the Valkey work, and awaiting a maintainer ruling.
- **A hung exec readiness probe does not show up in per-replica `ready`.** Reproduced on both engines (2:15 Valkey, 2:30 Redis) while the pod refused every command. The chart's probe body is correct — it exits 0 on a healthy master and a synced replica and hangs on a paused one — so do not read `ready` as proof a Redis node is serving; ask the node.
