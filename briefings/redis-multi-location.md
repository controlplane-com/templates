# Redis Multi-Location — Maintainer Briefing

## What it is

- **One** Redis master-replica cluster stretched across locations, with **Redis Sentinel** running one instance per location to monitor the master and vote a replacement when it is lost. Not a sharded Redis Cluster, and not one independent Redis per region.
- Runs **Redis (default) or Valkey** — one `engine` knob, chosen at install (new in 2.2.0). Redis is **BSD-3 / RSALv2+SSPLv1** depending on version; the shipped `redis:7.4` image is free to self-host with nothing to buy or register. Valkey is **BSD-3-Clause** under the Linux Foundation with **no paid edition at all**, so nothing in it is feature-gated.
- `redis.serverCommand` stays `redis-server` on **both** engines — the Valkey image ships a `redis-server` symlink, so deriving the command from `engine` would only create a second way to get a broken combination.
- The single-location `redis` template is untouched and remains the right choice for one location. This chart **requires ≥2 locations** and says so in the validation message.
- **3.0.0 no longer creates a GVC** (`createsGvc: false`). It deploys into `global.cpln.gvc`, and the location roster moved from `global.gvc.locations` to `global.locations`. Breaking; see the migration note below.

## Common use cases

- A cache or session store that must survive losing a whole region.
- The Redis dependency of a multi-location app — from 2.1.0 it is consumable **as a subchart**, which is why the version exists (`grafana-multi-location` will consume it).
- A cross-region pub/sub or queue backend where a few seconds of failover is acceptable.

## Architecture on cpln

| Resource | Purpose |
|---|---|
| _(no `gvc`)_ | 3.0.0 deploys into `.Values.global.cpln.gvc`. `global.locations` must name locations that GVC already has |
| `workload` (stateful) `{release}-redis` | `redis.replicasPerLocation` instances in every DECLARED location, `replicaDirect: true`. `defaultOptions.minScale/maxScale: 0` + full `localOptions` |
| `workload` (stateful) `{release}-sentinel` | Exactly 1 per location — the count is not a knob |
| `workload` (cron) `{release}-redis-backup` | Nightly RDB → S3/GCS, suspended everywhere except the FIRST location. Optional |
| `volumeset` ×2 | `/data` (20 GiB, autoscalable) and `/etc/sentinel` (10 GiB — Sentinel's own rewritten config) |
| `domain` ×2 | One TCP port per replica (`6380+i`, `26380+i`). Optional, needs a dedicated LB on the GVC |
| `identity` + `policy` ×2 | `reveal` on exactly the config secret plus whichever password secrets are in use |
| `policy` `{release}-redis-gvc-policy` | `view` on the ONE install GVC, for the Redis tier's boot-time location check. Never `target: all` |

- No probes on either tier, deliberately — a readiness probe failing during an election would withdraw the instance from discovery exactly when Sentinel needs it. Nothing to declare for probe drift as a result.
- Master election is resolved at container start: each Redis instance asks **any** Sentinel for the current master, and boots as master if that address is its own, else as `--replicaof`. Sentinel persists the elected master via `CONFIG REWRITE`, which is what the Sentinel volume set is for.

## Key knobs (defaults as shipped in 3.0.0)

| Knob | Default | Meaning |
|---|---|---|
| `global.locations[]` | 3 AWS locations, `name` only | ≥2 required; **`replicas` here is rejected at render (standalone only)**. Every name must already exist in the install GVC; the FIRST one seeds the master and hosts the backup cron |
| `redis.replicasPerLocation` | `2` | Redis instances in every location; total = this × locations |
| `engine` | `redis` | `redis` \| `valkey`. Binds **both** tiers at once — you cannot get a Valkey server behind a Redis Sentinel by accident |
| `valkeyImage` | `valkey/valkey:8.1.9` | Used for BOTH tiers when `engine: valkey`, at which point `redis.image`/`sentinel.image` are inert. As a subchart the parent sets `redis-multi-location.engine` / `.valkeyImage` (ordinary subchart values, not `global`) |
| `redis.image` / `sentinel.image` | `redis:7.4` | Ignored when `engine: valkey` |
| `redis.resources.cpu` / `.memory` | `200m` / `256Mi` | Limits only — bare names are correct per the 2026-08-06 ruling |
| `redis.passwordSecretName` | `""` | OPTIONAL prerequisite **opaque** secret; payload IS the password |
| `sentinel.passwordSecretName` | `""` | Same, independent — guards Sentinel itself |
| `redis.publicAccess.enabled` / `.address` | `false` / `redis.my-domain.com` | Raw TCP per replica through a `domain`; needs a **dedicated LB** (paid) which **3.0.0 can no longer enable** — the user must turn it on for their GVC first |
| `firewall.internalAllowType` | `same-gvc` | Applies to both tiers |
| `backup.*` | disabled, `aws` | Bucket + cloud account + bucket-scoped IAM policy; see the README's Storage setup |

- `global.locations` sits under `global` **on purpose**: it is the only channel that reaches an aliased subchart, so this list and a parent's can never be edited apart. `.Chart.IsRoot` survives, but now gates ONLY the `replicas` guard below — there is no `gvc.yaml` any more, so the "Helm without IsRoot renders no GVC" trap is gone with it.
- **Redis deliberately does NOT read `global.locations[].replicas`.** That shared field already means "Patroni members per location" to `postgres-multi-location`; letting Redis read it too would give one field two meanings in a single release. Standalone, setting it fails at render with that explanation; **nested, it is silently ignored** — `global` is release-wide, so a parent that also ships `postgres-multi-location` cannot scope a different locations list to one subchart, and failing there would abort the parent over a field its database tier requires. The guard is gated on `.Chart.IsRoot`, exactly as etcd's `replicas != 1` guard is.
- **Helper names are prefixed `redis-ml.`, not `redis.`** — Helm's template namespace is release-global and the single-location `redis` chart defines `redis.name`, `redis.tags` and friends with different bodies. A release containing both would resolve to whichever parsed last.

## Troubleshooting / considerations

- **Passwords are prerequisite secrets, not values (new in 2.1.0).** They are appended to the config at container start from `cpln://secret/{name}.payload`, never written into the chart's own config secret — a password in `values.yaml` would sit in the Helm release, and this chart can put Redis on the public internet. **Changing OR removing one takes effect only on restart**; restart Sentinel first, then Redis. Sentinel's `apply_auth()` runs unconditionally and strips the old `requirepass` / `sentinel auth-pass` lines before re-adding: `sentinel.conf` sits on a retained volume set, so a gated version would leave a stale credential in force after the password was turned off and Sentinel could no longer reach the master.
- **Two locations give NO automatic failover.** The Sentinel vote needs a majority of one-per-location instances, so 2 survives 0 losses, 3 survives 1, 5 survives 2. "Why didn't it fail over" usually has an arithmetic answer.
- **Never use `localOptions[].suspend` to simulate a location outage.** It permanently withdraws that location's endpoints from the other locations' service discovery while every status surface reads healthy, and only deleting and recreating the workload fixes it. Genuine crashes and replica reschedules recover in ~15–23 s.
- **A `helm upgrade` restarts every replica in every location at once** — the API drops `rolloutOptions.maxUnavailableReplicas` on a stateful workload, so nothing limits the rollout. Treat an upgrade as a planned write outage.
- **Allow ~2 minutes of cross-region convergence** after a cold deploy before believing a replica is unreachable; firewall changes take a further 30–150 s.
- **`--set global.locations[0].name=…` replaces the list wholesale.** Test list-shaped values with a `-f` values file, or you will trip the ≥2-locations guard instead of the guard you meant to test.
- **Uninstall deletes the volume sets**, so data does not survive a reinstall under a new release name.
- **`engine` cannot be changed on an existing install**, and the failure is a crash-loop rather than an error message anyone will read. Measured locally on the shipped pair (2026-08-26): `redis:7.4.11` writes its AOF base file as **RDB 12** (`REDIS0012`); `valkey/valkey:8.1.9` refuses it with `# Can't handle RDB format version 12` / `# Error reading the RDB base file appendonly.aof.N.base.rdb, AOF loading aborted` and exits 1. Because the chart ships `appendonly yes`, the block surfaces through **AOF** loading, not `dump.rdb`. Setting `engine` back to `redis` recovers all 100 test keys untouched.
- **The block is ASYMMETRIC, and this is a briefing note only — the README's rule stays uniform.** Valkey 8.1.9 writes **RDB 11**, and `redis:7.4` loaded a Valkey-written data directory cleanly (100/100 keys) in the same local measurement. Valkey → Redis is therefore *technically* loadable at this pin, but it is **untested on-platform** and unsupported; do not soften the documented rule on the strength of it. (Valkey 9 writes RDB 80, which no Redis can read — that direction is a genuine one-way door, which is why 8.1.9 is pinned.)
- **`valkeyImage` must be a DEBIAN-based tag.** Both start scripts build their config with `echo "\n..."` and rely on `/bin/sh` expanding it; `/bin/sh` is `dash` on the Debian tags and `busybox` on `-alpine`, which does **not** expand it. Measured: an `-alpine` tag appends a literal `\nreplica-announce-ip …` line and the server exits 1 with `Bad directive or wrong number of arguments`. **This is not a Valkey property** — `redis:7.4-alpine` fails identically on the same script, so the pre-existing `redis.image`/`sentinel.image` knobs carry the same trap.
- **`INFO` reports `redis_version:7.2.4` on Valkey** for client compatibility. Read `server_name:valkey` and `valkey_version:8.1.9` to see what is actually running; anything that version-gates on `redis_version` will believe it is talking to Redis 7.2.
- **`appVersion` still shows `7.4`** on the marketplace card even for a Valkey install — a chart's `appVersion` is a constant and cannot follow a values knob.
- **Do not enable `dual-channel-replication-enabled yes` via `extraArgs` on Valkey** — a known upstream defect (valkey-io/valkey#2338) makes Sentinel see duplicate replicas. It defaults to `no` and no chart sets it, but `extraArgs` reaches it.
- **The `user default` ACL trap below applies identically on Valkey.** Confirmed locally: Valkey's `CONFIG REWRITE` writes the same `user default on sanitize-payload #<hash> ~* &* +@all` line, so `apply_auth()`'s three-line strip is load-bearing on both engines.
- **Valkey is not new to THIS chart — but the precedent is one version, not three.** 1.0.0 hardcoded `valkey/valkey:8` in both workloads (container literally named `valkey`) while calling `redis-server`/`redis-sentinel` through the compat symlinks. 1.0.1 introduced `values.yaml` with `image: redis:7.4`-style knobs defaulting to `redis:7.2`; because a values entry always beats the template's inline `| default "valkey/valkey:8"`, **1.0.1 already ran Redis** and its Valkey fallback was dead code, which 1.0.2 then cleaned up. There is **no recorded defect or decision** behind the move — RELEASES.md frames 1.0.1 purely as "Configurable Images", so Valkey was dropped as a side effect of making the image a knob, not because anything went wrong with it.

## The GVC conversion (3.0.0) — what a maintainer needs to know

**Never `helm upgrade` a 2.x release onto 3.0.0.** The upgrade drops `kind: gvc` from the manifest and Helm prunes what a chart no longer declares — deleting the GVC and every workload, volume set and identity in it, in seconds, while printing `upgraded successfully`. Migrate to a NEW release against an existing GVC, copy the keyspace, then uninstall the old one. Both the README and the values comments say so.

The **three-layer defence**, all present:

1. **Render-time `fail`** on `hasKey .Values.global "gvc"`. Verified two ways: `helm template 3.0.0 -f 2.2.0/values.yaml` (the real upgrade path) and `--set global.gvc.name=…`. **One hole is not closable at render** — an upgrade run with NO values at all sees 3.0.0's own defaults, the key is absent, and the guard cannot fire. That is why the prose matters.
2. **`defaultOptions.minScale/maxScale: 0` on both tiers**, with full per-location `localOptions`. An undeclared GVC location therefore starts nothing and reads `deactivated because maxScale is set to 0`.
3. **A boot-time GVC read on the REDIS tier**, the direction the platform does not validate at all: it accepts, stores and ignores a `localOptions` location the GVC lacks. Policy is `targetKind: gvc` + `targetLinks` to that one GVC — never `target: all`.

**Checks the Redis start script runs, in order** (all measured against a fake GVC API in both pinned images, 2026-08-28):

| Check | Trigger | Fresh `/data` | Initialised `/data` |
|---|---|---|---|
| A — running in an undeclared location | `CPLN_LOCATION` not in `global.locations` | FATAL | FATAL (unconditional) |
| B — bootstrap master's location missing | first entry of `global.locations` absent from the GVC | FATAL | WARN |
| C — Sentinel quorum unreachable | present locations < `floor(N/2)+1` | FATAL | WARN |
| D — any declared location missing | anything else missing | FATAL | WARN |

Check B is redis-specific and worth understanding: every Sentinel is seeded with `sentinel monitor mymaster replica-0.<redis>.<FIRST location>…`, so if that location is not in the GVC the address never resolves, every instance boots as a replica, and **no master ever forms**. Check C alone does not catch it (3 locations, first missing → 2 present, quorum 2, passes). Sentinel runs check A only — it needs no API and therefore no GVC-read grant.

**Why perl and not curl — do not re-litigate this.** Neither pinned image has curl OR wget (probed on `redis:7.4` and `valkey/valkey:8.1.9`; both Debian, both ship `perl` with `IO::Socket::INET` and `bash`, neither ships an HTTP client). The alternative considered was a **curl sidecar** writing a verdict to a shared `scratch://` volume (the `guacamole` pattern). Rejected: it needs a SECOND pinned image to maintain, it costs an extra container on every replica in every location (9 by default), and it would not remove the logic from the main container anyway — the fatal/warn split keys off data-directory freshness, which only that container can see. So the sidecar moves the HTTP call and adds a handshake that can hang.

**The call is bounded twice, measured against genuinely slow failures** — `IO::Socket::INET` `Timeout => 5` bounds a hanging `connect()`, `alarm 8` bounds a server that accepts and never answers, and `timeout 12` is the outer backstop; 3 attempts with 2 s sleeps. Measured end to end in the rendered script: **22 s** against a blackholed address (`10.255.255.1`), **30 s** against an accept-never-respond server, identical on Valkey. An NXDOMAIN control returned in **1 s** and proves neither — which is exactly why it was not used. A failed read WARNS and continues; a control-plane hiccup must never stop a cache from starting.

**Freshness marker is `appendonlydir/`, not `dump.rdb`.** The chart ships `appendonly yes`. Both are tested so the check stays right if `extraArgs` turns AOF off, and `lost+found` is excluded because an ext4 volume set always has one.

**`publicAccess` lost its automatic dedicated load balancer.** 2.x set `spec.loadBalancer.dedicated: true` on the GVC it created. 3.0.0 creates no GVC, so **the user must enable the dedicated LB on their own GVC before installing with public access on**, or the `domain` is created and never serves. Documented in Prerequisites and Public access. `[UNPROVEN]` — nobody has watched a `domain` fail this way on a non-dedicated GVC; it is a named test row.

**Other fixes that rode along** (defect classes found in every clustered template this batch):

- **`workload-list` self-inclusion.** 2.2.0 passed `firewall.workloads` through verbatim, so a user listing only their clients would have cut Redis off from Sentinel, Redis off from Redis, and the backup cron off from everything — while every replica still reported `ready: true`. Now a single `redis-ml.ownWorkloadLinks` helper supplies both tiers, the backup member gated on `backup.enabled`, user duplicates de-duplicated. There is exactly ONE `inboundAllowWorkload` key per workload (tidb shipped a duplicate that silently discarded the user's whole list).
- **`firewall.internalAllowType` had no enum validation at all** in 2.2.0 — a typo rendered fine and produced a workload the API rejects. Added.
- **Duplicate locations** are now refused at render.

## Status

**3.0.0 (this version)** is the GVC conversion described above, plus the firewall and validation fixes. **Not deployed** — every on-platform row is pending, and it inherits 2.2.0's and 2.1.0's untested backlog below.

**2.2.0** adds the `engine: redis|valkey` knob and `valkeyImage`, and changes nothing else: a default install renders **byte-identically** to 2.1.0 across six values profiles (default, backup-aws, backup-gcp, publicAccess, passwords, two-location) once the chart-version tag text is normalised, and `--set engine=valkey` changes exactly **two lines** in the whole render — the two `image:` fields. Build-stage probes against `valkey/valkey:8.1.9` cleared the config-vocabulary risks locally: `masterauth`, `client-output-buffer-limit slave`, `replica-announce-ip/-port`, `sentinel auth-pass`, `sentinel announce-ip/-port/-hostnames`, `resolve-hostnames` and `sentinel monitor` all parse and take effect, a replica reached `master_link_status:up` against a `requirepass`-protected Valkey master, and Sentinel discovered that replica **by hostname** — the exact mechanism cross-location discovery depends on. **Not yet deployed to Control Plane**; every on-platform row (failover, cross-region replication, backups, public access, drift) is still pending, and 2.2.0's test round is also 2.1.0's first.

2.1.0 is a conventions + subchart-consumability release: `global.gvc` (clean break from `.Values.gvc`, no fallback shim), the `.Chart.IsRoot` GVC gate, prerequisite password secrets, sorted `locationLinks`, `terminationGracePeriodSeconds: 90`, `aws::ReadOnlyAccess` dropped from the backup identity, service-scoped placeholders, and a rewritten README. **Not yet deployed** — the failover, backup, public-access and drift rows all come from the pending test round, so treat the measured-behaviour numbers above as inherited from sibling multi-location templates rather than measured here.

## The sentinel `user default` ACL trap (found and fixed 2026-08-13, in place in 2.1.0)

**The single most important thing to know before touching `apply_auth()` in
`templates/workload-sentinel.yaml`.**

Sentinel materialises its current auth state into an ACL line via `CONFIG REWRITE`:

```
user default on nopass sanitize-payload ~* &* +@all
```

**An ACL entry for `default` OVERRIDES `requirepass`.** `sentinel.conf` lives on a retained volume set,
so a line written during an authless period survives every later boot — and the tier keeps answering
unauthenticated no matter what `requirepass` says, while every status surface reports success.

- **Symptom:** enabling `sentinel.passwordSecretName` on a running authless install leaves all sentinels
  answering `PONG` to unauthenticated clients. Nothing anywhere reports a problem.
- **It broke in BOTH directions**, which is what makes it more than an edge case: with the stale line
  present, *removing* the password still demanded the old one, and *rotating* kept the OLD password
  working while rejecting the new one. Sentinel's auth state was effectively frozen at first boot.
- **Fix:** `apply_auth()` strips three lines, not two — `^sentinel auth-pass mymaster `, `^requirepass `
  **and `^user default `**. The block's comment already claimed stripping made rotation and removal work;
  before this it was aspirational.
- **Redis was never affected** because `workload-redis.yaml` re-copies its whole config from the secret
  every boot. Sentinel deliberately preserves its file to keep `myid`, epochs and the elected master —
  which is exactly why the stale line rode along, and why the fix must not simply re-copy like Redis does.
- **Verified the right way:** post-fix the ACL line *reappears* (sentinel rewrites it, as designed) but
  now carries a password hash matching `sha256(env password)` rather than `nopass` — confirmed
  in-container on all three replicas. Deleting the line is not the goal; the correct state being
  persisted is. `sentinel myid` stayed byte-identical across 4 upgrades, a force-redeployment and 2
  no-op upgrades, with no `+switch-master`.

**Operational note that came out of the same round:** changing the **Redis** password restarts every
Redis instance in every location at once, dropping the master out of quorum and starting a failover
(`+odown` → `+try-failover`). It resolved harmlessly only because no replica was promotable. Changing
the **Sentinel** password alone is safe — no vote at all. Documented in the README.
- **Rotating a password needs a forced redeployment.** Both tiers read the secret at container start, and updating it in place does NOT trigger a restart: measured at 5 minutes with the version unchanged and the old password still returning `PONG`. Healthy status throughout, so it looks like it worked. Redeploy Sentinel first, then Redis.
- **The 2.1.0 ACL trap is closed under Valkey.** The persisted `sentinel.conf` carried a password HASH rather than `user default … nopass`, verified on an authless→auth upgrade, which is the harder direction.
- **Open, pre-existing:** the backup cron sets `REDIS_HOST` to the load-balanced service name, so a snapshot lands on a non-deterministic replica rather than the master. Untested (no bucket in the round) and unresolved.
- **Restore is documented as UNVERIFIED, deliberately.** The chart ships `appendonly yes`, so Redis loads `appendonlydir/` and ignores `dump.rdb` — the restore this template documented before 2.2.0 silently did nothing. The README now says the RDB path needs AOF disabled for the load and re-enabled after, and states plainly that the sequence has not been verified against this template. Do not replace that with a plausible-looking procedure; verify it or leave it flagged.
