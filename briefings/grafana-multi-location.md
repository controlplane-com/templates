# grafana-multi-location

## What it is

- Grafana OSS **13.1.3** running in every location of a chart-created multi-location GVC, behind one
  georouted `*.cpln.app` endpoint, with all app state in a **stretched Patroni cluster**
  (`postgres-multi-location` subchart, which itself consumes `etcd-multi-location` — three levels).
- **Two alerting shapes, one knob: `alerting.highAvailability.enabled`, default `false`.**
  - **OFF (default, 1.0.0 behaviour).** Two workloads from one image: the UI tier scales freely per
    location with alert execution OFF; a separate **single-replica** workload in one location has it
    ON. Exactly-once evaluation is a property of the topology — nothing is elected, and no value of
    `replicas` can create a second evaluator.
  - **ON (added in 1.1.0).** The separate workload is **not created at all**; every UI instance
    evaluates and a stretched Redis (`redis-multi-location` subchart) coordinates exactly-once
    *notification* delivery. Alert evaluation then survives losing a location. **Requires 3+
    locations, hard-failed below that.**
- Grafana is **stateless** here (no volumeset, no sticky sessions). AGPL-3.0, free to self-host,
  nothing enterprise-gated in what we ship.
- For a single location, `grafana` 1.2.0 is the template; 1.1.0 here uses exactly that template's
  proven Redis mechanism, stretched across locations.

## Common use cases

- One dashboarding surface for teams in several regions, each served locally.
- Grafana that keeps serving when a region is lost, with the database failing over automatically.
- A regional-redundancy requirement met without running and reconciling several Grafanas.

## Architecture on cpln

| Resource | Purpose |
|---|---|
| `gvc` | **Always created**, gated only by `{{ if .Chart.IsRoot }}`. There is no `createGvc` knob — the GVC is what pins the locations. Both subcharts suppress theirs, so a release renders exactly one |
| `workload` (standard) `{release}-grafana` | UI/API tier, `replicas` per location, `execute_alerts=false`, public by default |
| `workload` (standard) `{release}-grafana-alerting` | The dedicated evaluator: 1 replica, `alerting.location` only, `execute_alerts=true`, **never public**. Suppressed entirely when `alerting.enabled: false` **or when `alerting.highAvailability.enabled` is true** |
| `identity` + `policy` | **One** identity shared by every Grafana workload; `reveal` on exactly the secrets they mount. No cloud bindings — this chart touches no object storage. **The rendered policy is byte-identical in both alerting modes** (verified) |
| `secret` `{release}-grafana-datasources` | Datasource provisioning file, mounted by every Grafana workload. Only when `datasources.definitions` is set |
| subchart `postgres-multi-location` (aliased `postgresML`) | The app database: HAProxy leader endpoint per location, one Patroni primary, async replicas |
| subchart `redis-multi-location` (aliased `redisML`) | **Only with alerting HA on.** `{release}-redis` + `{release}-sentinel`, 1 each per location, plus 2 volumesets, 2 identities, 2 policies, 2 config secrets |

- Document count: **17** with HA off (identical to 1.0.0), **26** with HA on at 3 locations.
- Four charts in the release, three of them `.Chart.IsRoot`-gated — still **exactly one `kind: gvc`**
  (verified by render). Chart *depth* is unchanged at 3 (grafana → postgres → etcd); Redis sits beside
  postgres at depth 2.

## Key knobs

| Knob | Default | Meaning |
|---|---|---|
| `global.gvc.name` / `.locations[]` | `grafana-multi-location-gvc`, 3 AWS locations × 1 | **≥2 required, ≥3 with alerting HA**; `replicas` here is DATABASE members per location, ignored by the Redis tier. The GVC **must not already exist** |
| `image` | `grafana/grafana:13.1.3` | Alpine variant required — the boot wrapper needs a shell |
| `replicas` | `1` | Grafana UI instances **per location**. No alerting-related restriction of any kind |
| `database.maxOpenConn` | `10` | Per instance, enforced at render time against an 80 ceiling. HA off: `(replicas × locations + 1) × this`, the `+1` being the evaluator. **HA on: the `+1` is dropped** because that workload does not exist |
| `alerting.highAvailability.enabled` | `false` | `false` = dedicated evaluator (1.0.0 behaviour); `true` = every instance evaluates, Redis coordinates. **Needs 3+ locations** |
| `alerting.enabled` | `true` | `false` = no evaluator workload and `EXECUTE_ALERTS=false` everywhere; rules stay creatable, nothing evaluates them. `false` + HA `true` fails at render |
| `alerting.location` / `.resources.*` | `aws-us-east-1` / 500m–1000m, 512Mi–1Gi | The one location the dedicated evaluator runs in — **required** in that mode. **Both are IGNORED when HA is on** |
| `redisML.redis.replicasPerLocation` | `1` | Redis members per location. One is plenty — the data is a few KB of coordination keys |
| `redisML.redis.volumeset.initialCapacity` | `10` GiB | Platform minimum, deliberately below the dependency's own 20 |
| `redisML.{redis,sentinel}.{image,resources}` | `redis:7.4`, `200m` / `256Mi` | Pass-through. Limits only, so no `cpu:minCpu` ratio applies |
| `redisML.{redis,sentinel}.passwordSecretName` | `""` / `""` | **Opt-in as of 1.1.1** — authless by default. If set, the secrets must exist before install, and Grafana reads them too, so a wrong name stops the UI tier as well |
| `admin.passwordSecretName` / `.secretKeySecretName` / `.applyPassword` / `.user` | `my-grafana-admin-password` / `my-grafana-secret-key` / `true` / `admin` | **Required prerequisite opaque secrets** (`encoding: plain`). Both workloads carry the admin env |
| `datasources.definitions` / `.credentialSecrets` | `[]` / `[]` | Datasources as code; `$KEY` interpolation from prerequisite dictionary secrets |
| `smtp.*` | off | Whichever instance evaluates is what sends — the dedicated evaluator, or the coordinating UI instance with HA on |
| `publicAccess.enabled` / `internalAccess.type` | `true` / `same-gvc` | Public applies to the UI tier only |
| `postgresML.primaryLocation` | `aws-us-east-1` | Deviates from the subchart's `""` on purpose — Grafana has no read/write splitting |

## The `-ml` infix was dropped, and the DB gate was raised (2026-08-12, edited into 1.0.0 in place)

- Rendered resources are now `{release}-grafana`, `-alerting`, `-datasources`, `-identity`,
  `-policy`, and the database tier renamed the same way (`{release}-postgres-proxy`, `-vs`, …). The
  Helm helper namespace is still `grafana-ml.*` — internal, deliberately unchanged.
- **BREAKING, fresh-install-only**, because the subchart's **volume set** renamed too: a `helm upgrade`
  over an install created before this change binds a NEW, EMPTY volume set and orphans the old one
  holding every dashboard, user and alert rule. Back up, uninstall, reinstall, restore.
- **The cross-chart invariant is the thing to not break.** `grafana-ml.postgres.host` duplicates the
  subchart's derived proxy name (`{release}-postgres-proxy`) because a parent cannot call a
  subchart's helper. Both helpers carry a comment saying so. Change one side only and the chart still
  renders and installs — it just never reaches a database.
- **`grafana-ml.dbGate` 180 s → 300 s, and `livenessProbe.initialDelaySeconds` 240 → 360 on BOTH
  workloads. These are COUPLED.** Cold installs still showed containers exiting 1 because the gate
  gave up while the database tier was legitimately still coming up. Raise the gate without raising
  liveness and the container restart-loops instead of waiting. The gate is still *bounded* and then
  CONTINUES regardless, so a genuine misconfiguration surfaces as Grafana's own error, not a hang.
- **The readiness probe was deliberately NOT changed** (10 s + 20 × 10 s = 210 s, shorter than the
  gate). It is the fast unhealthy signal: an instance still waiting on the database must read
  not-ready rather than look fine. Only liveness needs to outlast the gate.
- `postgresML` stays pinned at **1.0.2**, which was edited in place with the same rename.

## Troubleshooting traps

- **A wedged install is almost always a missing prerequisite secret.** Three must exist before
  install: admin password, encryption key, database credentials. The defaults are placeholders.
- **Never rotate `admin.secretKeySecretName`.** It decrypts datasource credentials stored in the
  shared database. Rotate it and every saved credential becomes unreadable in every location — and
  the evaluator then fails every rule that queries them, silently.
- **Both workloads carry the admin bootstrap env deliberately.** Grafana's built-in default password
  is the literal string `admin`; an evaluator without the env that won the empty-database race would
  create `admin`/`admin` on a publicly exposed UI.
- **Losing `alerting.location` stops alert evaluation and the UI does not show it.** A replica
  failure self-heals; a whole-location loss needs `helm upgrade --set alerting.location=<other>`.
  Dashboards look perfectly healthy the whole time.
- **Silences do not propagate.** With no gossip, a silence created against the UI tier is not
  guaranteed to reach the evaluator. Create them against
  `{release}-grafana-alerting.{gvc}.cpln.local:3000` — the evaluator is a named single-replica
  workload, so that instruction is exact at any value of `replicas`.
- **Do not promise rolling upgrades.** Any `helm upgrade` restarts the bundled database in every
  location at once (**~117 s** of failed writes, measured on the dependency) because the API does not
  retain `maxUnavailableReplicas`. Inherited and platform-level; the chart cannot fix it.
- **A cold start logs `Failed to lock database` and restarts an instance — that is expected.**
  Grafana's Postgres migration lock is `pg_try_advisory_lock`: non-blocking, no retry. Verified
  locally at 13.1.3 — the loser exits 1 and succeeds on restart. `locking_attempt_timeout_sec` is
  **not read by the Postgres dialect at all**, so setting it would be a no-op.
- **Alerting HA via gossip is architecturally unavailable**, not merely unconfigured: it needs UDP
  9094 between workloads and container ports accept only grpc/http/http2/tcp. The Redis path
  (`ha_redis_address`) needs no peer port at all and **shipped in 1.1.0** — see the 1.1.0 section.
- **Non-primary locations pay a cross-region round trip per query.** Grafana has no read/write
  splitting, so every dashboard load hits the one primary (96 ms us-east ↔ eu-central measured on the
  dependency, 236 ms worst case).
- **Never suspend a location**, and the evaluator's other locations are **scaled to 0/0**, not
  suspended. Verified on a live workload 2026-08-11: `localOptions` autoscaling `minScale: 0 /
  maxScale: 0` is accepted, stored verbatim, and yields 0 replicas there and 1 in the selected
  location. Note those zero-scaled locations report `ready: false` on their deployment — that is
  normal and not a failure to wait on.
- **The GVC is created unconditionally and Helm will adopt one that already exists — then delete it
  on uninstall**, taking unrelated workloads with it. Always a fresh name.

## Measured behaviour (test rounds 1-2, 2026-08-11)
| Event | Result |
|---|---|
| Cold install, 3 locations | **4 m 44 s** (was 22 m 13 s before the readiness-gate and primary-placement fixes) |
| Schema migrations | **713 in 5.79 s** with the primary local; ~15 min when it bootstrapped cross-region |
| Exactly-one evaluator at `replicas: 3` | 9 replicas `false`, 1 `true`, 0 elsewhere; 8 deliveries, 8 distinct `x-request-id`, all into the evaluator's location |
| Moving `alerting.location` | **no** two-evaluator window — 57 s between the old evaluator's last notification and the new one's readiness |
| Grafana-only upgrade (`replicas: 1→3`) | 1160 probe samples, **0** failures |
| Public endpoint | proximity-routed — 100/100 requests served by one location, not spread |

## Troubleshooting traps
- **The readiness gate must probe HAProxy's `/healthz` (8404), never a TCP connect to 5432.** HAProxy accepts the socket with no healthy backend, so a TCP gate passes ~24 s into a cold install and Grafana then crash-loops on `connection reset by peer`. `/healthz` is backed by `monitor fail if nbsrv(patroni_primary) lt 1`, so 200 means a real primary is serving.
- **Pin `postgresML` at 1.0.2 or later.** 1.0.0 places the primary by race, which sends every schema migration cross-region; 1.0.1 and earlier also OOM GCP backups at 128Mi.
- **An upgrade adding a secret reference pauses the rollout ~9-10 minutes while Helm reports success**, then self-heals with no action. Platform-side propagation — do not re-run the upgrade or edit policies.
- **The evaluator answers only from inside `alerting.location`.** The name resolves to the GVC VIP everywhere, but the other locations have no local upstream and return 503. Matters for the silence workaround.
- **A `helm upgrade` can report `Updated` without any spec drift** — the difference is platform-computed `health` fields, and it is non-deterministic across installs. Diff the stored specs before treating an `Updated` label as a chart defect.

## Cross-location shared state — PROVEN (round 3, 2026-08-12)
The template's central promise, tested rather than reasoned about. 3 locations x `replicas: 2` (6 UI instances + 1 evaluator), every result attributed to a named instance two independent ways (loopback `curl` inside a chosen replica, and a unique marker in the request PATH traced through `cpln logs` replica/location labels).

| Row | Result |
|---|---|
| Dashboard created in us-east-1 | read back **byte-identical** (same md5, same internal id) from all 6 UI instances and the evaluator |
| Edit made in eu-central-1 | authoritative everywhere, including its birthplace — not one-directional |
| User + org created in one location | logs in against every other instance (wrong-password 401 as control) |
| Session cookie issued in us-east-1 | accepted by every other instance, correct identity returned |
| Same-location sibling replica | sees its peer's write |
| **Datasource credentials** | decrypt on every instance — `Database Connection OK` vs `failed SASL auth` for a deliberate wrong-password control; ciphertext confirmed in the DB; identical key fingerprint on all instances checked |

- **Why it is structural, not luck:** the primary carries all 28 application connections and both standbys carry zero. There is no replication hop between a write and a remote read, so visibility is immediate (measured ≤1-3 s, bounded by 1-second container clocks rather than by the system).
- **The addressing trap for anyone re-testing this:** one service-DNS name probed from three locations is served by three DIFFERENT replicas, each local to the caller. An unattributed 200 proves nothing — attribute every response to an instance or the test is meaningless.

## Round 4 — the two previously-untested knobs (2026-08-12)
Both **proven and shipping**; neither was a removal candidate under the test-every-knob rule.
- **`smtp.*` end to end.** Email retrieved from an in-GVC Mailpit sink, not inferred from logs. `fromName`/`fromAddress` correct; 36 s from rule creation to delivery. Three independent discriminators agree the **evaluator is the only sender** (`Received:` header, mesh access-log source IP matching its `hostname -i`, and zero messages in the other location's sink). The link in the email resolves to the **UI tier** and returns 200 — the evaluator's own endpoint is a 403 and never public, so the chatwoot/twenty dead-link defect is not present.
- **`datasources.definitions` + `credentialSecrets`.** Provisioned at INSTALL time (round 1 only covered upgrade): healthy in every instance including the evaluator, exactly one `data_source` row despite three concurrent appliers, and a negative control with a wrong password failing `SQLSTATE 28P01` — so the pass proves correct `$KEY` interpolation rather than a permissive server.

### The one real limitation
**Authenticated SMTP needs a relay offering STARTTLS/TLS.** Go's `net/smtp.PlainAuth` refuses to send credentials over cleartext, so against a plain relay every notification is lost with `failed to send email: unencrypted connection` — and the only signal is a log line in the alerting workload, which is deliberately not publicly reachable. Hosted relays (SES, SendGrid, Mailgun, M365, Gmail) are unaffected; a plain in-GVC relay is not. The chart exposes neither `skipVerify` nor `startTLSPolicy`, so the remedy is to leave `smtp.user` empty for such relays. Documented in values.yaml and the README rather than fixed with a knob.

## Round 5 — rename + gate verification (2026-08-12)
- **The 300 s gate was necessary, and 180 s was genuinely too short.** Two of three UI instances held the gate **190-198 s on a perfectly healthy install** — both would have timed out under the old bound. ~100 s of headroom remains.
- **The gate released ~126 ms too EARLY, not too late.** `/healthz` returns 200 the moment Patroni answers `/primary`, but Postgres then reloads bootstrap parameters and resets connections opened in that window, so two instances still exited 1 on `connection reset by peer`. Fixed by requiring **3 consecutive** healthy polls (~6 s) before proceeding.
- Grafana's own migration-lock race (`Failed to lock database`, exit 1, self-heals) is upstream and remains — 5 of the 7 restarts. Count it separately from database-connection failures or the gate looks broken when it is not.
- `livenessProbe.initialDelaySeconds: 360` confirmed in the **stored** spec; every exit was `exitCode: 1`, no `137`, so nothing was killed by liveness during the longer wait.
- **Drift after the rename: clean.** Upgrade #1 labelled 9 of 17 `Updated` but **0 of 17 had any spec difference** (only `version`, `cpln/release`, `lastModified` and status); upgrade #2 was all `Unchanged` with 34/34 HTTP 200 throughout.
- First install measured 5 m 30 s here vs 4 m 44 s in round 2 — run-to-run variance in the database tier (3 m 23 s vs 2 m 33 s), not a regression. Every Grafana instance released its gate within 9 s of the last Patroni member in both runs.

## Rounds 6-7 — startup noise, and where it actually comes from (2026-08-12)
Cold-install exits went **7 → 2** once the gate required 3 consecutive healthy polls (killing the `connection reset by peer` class outright) and the UI tier staggered behind the single-replica evaluator.

Two design errors found by testing, both mine:
- The stagger's first offset was **0**, which collided with the evaluator — `alerting.location` defaults to the first location in the list, so both released on the same signal at the same millisecond and raced. Offsets now start at 15 s. **Do not "optimise" the first one back to zero.**
- The stagger's premise is "the migration run fits inside 15 s". That holds **only when the Patroni primary is co-located with the evaluator.**

**The dominant variable is where the primary lands, not anything in this chart.** `postgresML.primaryLocation` is a preference with a 90 s bound (necessarily — an unbounded wait could deadlock the install). When the fallback fires, migrations run cross-region at ~215 ms/statement instead of ~4.7 ms, the 713-migration run stretches from ~5 s to minutes, and every instance restarts while it finishes:

| | Primary as configured | Primary elsewhere |
|---|---|---|
| Migrations | **713 in 5.22 s** | minutes |
| Cold install | 4 m 19 s | 11 m 41 s |
| Exits | 2 | 15 |

Both converge and self-heal. Before treating a noisy install as a defect, **check where the Patroni leader actually bootstrapped** — the fallback logs `no leader in <location> after 90s — bootstrapping here instead`.

Remaining exits are Grafana's own migration lock (`pg_try_advisory_lock`, non-blocking, one attempt, and `locking_attempt_timeout_sec` is never read by the Postgres dialect). There is no configuration that removes them; only not arriving together helps.

## 1.1.0 — optional Redis-backed alerting HA (2026-08-13)

**One knob, `alerting.highAvailability.enabled`, default `false`. Default installs are unchanged from
1.0.0 and that is enforced mechanically:** the OFF render was diffed against 1.0.0's and differs in
exactly 20 lines, all of them `helm.sh/chart` / `cpln/marketplace-template-version` tags. Requires
`redis-multi-location` **2.1.0** — 2.0.2 rendered its own GVC unconditionally and read `.Values.gvc`,
so it could not be a subchart.

**The single strongest reason to leave it off: HA multiplies DATA-SOURCE QUERY LOAD by
(locations × replicas).** Every instance evaluates every rule; Redis dedupes the **notification**, not
the **query**. At the default 3 locations that is 3× the queries against the user's Prometheus, Mimir
or SQL server, permanently. For someone whose data source is already the bottleneck that is a worse
trade than losing alert evaluation when a region dies. Say this before recommending HA. (Grafana
13.1.3 does have `ha_single_node_evaluation`, which would cut it back to 1× — deliberately out of
scope for 1.1.0 and staged for a later version, because it is untested and its own docs disagree with
the tagged source on a key name.)

### Traps specific to the ON path

- **"We're getting every alert twice" almost always means Redis is unhealthy.** With Redis
  unreachable each member list expires after 1 minute, every peer falls back to **position 0** and the
  shared notification log stops propagating, so each instance sends its own copy. Grafana logs
  `Failed to look up position, falling back to position 0`. **It never goes silent** — check the
  `{release}-redis` / `{release}-sentinel` workloads first, not the alert rules. Grafana also boots
  fine with Redis down (`newRedisPeer` logs and continues; it does not return an error).
- **Blocked below 3 locations, on purpose.** Sentinel elects a master by a majority of locations (one
  Sentinel each), so at 2 locations losing either — the exact event the knob exists for — leaves no
  quorum. The render-time message names both remedies.
- **The Sentinel address is the EXPLICIT per-location list, not the VIP.** Same-GVC service DNS is
  served location-locally and does not fail over (round 1 measured 200 locally, 503 from the other two
  locations). A single VIP would give each Grafana instance exactly one Sentinel — its local one —
  with no fallback, which is the opposite of the point. Grafana splits the value on commas and hands
  the result to go-redis as `Addrs`.
- **The peer name is `$(hostname)` and that is correct.** A standard workload has no deterministic
  replica identity (`{workload}-{replicaset}-{random}`); the HA peer name needs **uniqueness, not
  order**, since positions come from sorting the member list. **Do not "fix" it into an index — there
  is no index to be had.**
- **No port 9094, no `ha_advertise_address`, ever.** Grafana's docs tell you to set them even with
  Redis; that is not load-bearing (measured on `grafana` 1.2.0), and UDP between workloads does not
  exist here, so adding them would only make Grafana try to bind a listener we cannot express.
- **Notification links come from the UI tier's own `CPLN_GLOBAL_ENDPOINT` in HA mode.** The
  evaluator's endpoint-rewriting wrapper exists **only** on the OFF path, because there the sender has
  no inbound access and would otherwise emit a dead link. **Do not copy that rewrite onto the UI
  tier** — it would rewrite a correct URL into a wrong one.
- **Rule evaluation runs on the UI tier in HA mode**, which was sized for serving dashboards. A large
  rule set may need `resources.maxCpu` raised; `alerting.resources` is unused in that mode.
- **Silences behave differently between the modes.** HA off: they do not reliably reach the evaluator,
  and the evaluator only answers in-GVC from its own location. HA on: they propagate through the
  shared peer, and the 1.0.0 silence workaround is unnecessary.
- **The cross-chart invariants are the things not to break:** `{release}-sentinel` must match
  `redis-multi-location`'s `redis-ml.sentinel.name`, and the master name `mymaster` must match its
  `sentinel monitor` line. Break either and the chart still renders, installs and boots — Grafana just
  never finds a Redis, and alerting quietly duplicates.
- **Redis/Sentinel auth is OPT-IN as of 1.1.1** — both `passwordSecretName` knobs default to `""`, so
  enabling alerting HA needs no extra secrets. 1.1.0 shipped placeholders (auth on by default) and it
  was reversed: forgetting a secret is far likelier than an attacker already running inside the GVC
  this chart creates, and the penalty was severe (below). Auth itself is wired and deploy-proven.
- **If you DO set them, the secrets gate the Grafana UI tier, not just alerting.** Grafana reads the
  same secrets to authenticate as a client, so a misspelt name stops the **UI** at 0 replicas too.
  `helm install` still reports SUCCESS — the message is on `status.versions[].message`, and it
  self-heals ~5-6 min after the secret is created. These are 2.1.0's prerequisite-secret knobs;
  2.0.2's plain `password` values no longer exist.
- **The migration stagger is re-based in HA mode.** HA off: the evaluator goes first, UI locations at
  15/30/45 s (unchanged). HA on: the location matching `postgresML.primaryLocation` goes first at
  offset 0, the rest at 15/30. An empty `primaryLocation` falls back to plain list order — it is a
  latency optimisation, not a correctness dependency.
- **The first `helm upgrade` after install bounces the bundled subcharts** — with HA on that now
  includes Redis, so expect a brief duplicate-notification window on that one upgrade.

### Verified at build time (renders, not deploys)

| Check | Result |
|---|---|
| OFF render vs 1.0.0 | 17 documents both sides; 20 differing lines, **all** chart-version tags |
| ON render | 26 documents, **exactly one `kind: gvc`**, no `-grafana-alerting`, all 15 gvc-bearing docs on `global.gvc.name` |
| `kind: policy` in both modes | **byte-identical** (identity too) |
| Validation | HA+`location:""`, HA+2 locations, and both password-secret knobs each fail with their named message; 2 locations with HA off still renders |
| Connection budget | `replicas:3`, `maxOpenConn:9` → 90 fails HA-off / 81 fails HA-on; `maxOpenConn:8` → 80 and 72 both pass |
| Platform limits | `cpu:minCpu` ≤ 2:1 everywhere, no reserved ports, probe `failureThreshold` ≤ 20, all container port protocols lowercase |
| Drift fields | `locationLinks` sorted, no `maxUnavailableReplicas`, `terminationGracePeriodSeconds: 90` and probe `initialDelaySeconds` declared, `direct.ports: []`, secret volumes `recoveryPolicy: retain` |
| `bash -n` | every rendered boot wrapper in both modes |
| Lint | clean |

**Not yet verified — the test round settles these:** exactly-once delivery measured from a sink with
the Redis master in another region; surviving the loss of the location that would have been
`alerting.location`; the no-op-upgrade drift gate in both modes; Redis-down duplicate degradation;
notification-link correctness in HA mode; and `redisML.redis.replicasPerLocation` live.

### Round 1 — Redis-backed alerting HA, proven on real infrastructure (2026-08-13)
`alerting.highAvailability.enabled`, default **false**. OFF is byte-identical to 1.0.0 apart from version tags (diffed, not inspected).

| Row | Result |
|---|---|
| **Exactly-once with HA on** | **18 deliveries / 18 cycles, 18 distinct `x-request-id`, vs 108 if uncoordinated** — 3 locations x `replicas: 2`, all six instances confirmed `EXECUTE_ALERTS=true` and firing |
| **Losing the would-be `alerting.location`** | 25 min of continuous replica destruction: no drop, no duplicate; west later carried alerting **alone, exactly once, for 5 min** |
| Redis unavailable | degrades to 6x duplicates, **never silent** (longest gap 15 s), re-converges ~40 s |
| Notification links | `externalURL`/`generatorURL`/`silenceURL` all the UI canonical endpoint, 200 |
| HA OFF | 3 UI `false` / 1 evaluator `true`, 41/41 deliveries from the evaluator |
| Install | HA ON 6 m 11 s / 3 exits; HA OFF 5 m 07 s / **0 exits** (primary in `aws-us-east-1` both) |
| Drift | clean in BOTH modes on the second no-op upgrade |

**Traps worth knowing:**
- **Redis peer keys carry a 5-minute TTL.** A dead location's peers hold their positions until expiry, so post-outage hand-off is not instant. Alerting continues from survivors; only the sender changes.
- **The sender is chosen by sorted peer name and moves across rollouts.** "The notification comes from `alerting.location`" is NOT true in HA mode — do not route or filter on it.
- **A no-op upgrade costs ~80 s of duplicate notifications** with HA on, because the Redis tier is patched.
- **With HA OFF, restarting the evaluator re-notifies** everything currently firing. The old wording said a replica failure "self-heals", which was true but omitted the duplicate.
- The API does **not** backfill `loadBalancer.direct` — Redis/Sentinel store exactly `{"replicaDirect": true}`. Declaring it explicitly (as etcd/postgres do) is also stored verbatim, so **both styles are drift-free** and neither needs changing.

### Round 2 — `alerting.enabled` and Redis auth, deploy-proven (2026-08-13)

Two maintainer findings on the values surface, both then tested on real infrastructure (**7 PASS / 0 FAIL**).

**`alerting.enabled` (default `true`) is now the off switch.** Previously the only way to disable
alerting was `alerting.location: ""`, which was undiscoverable *and* not an off switch at all in HA
mode (validation rejected that combination). `location` now means only "where the evaluator runs" and
is **required** when alerting is on and HA is off. `enabled: false` + `highAvailability.enabled: true`
fails at render. The evaluator-renders condition lives in ONE helper (`grafana-ml.evaluatorRenders`) —
it had been hand-written in the workload, the connection budget and validation.

**Redis/Sentinel auth is wired and enforced.** Grafana 13.1.3 has `ha_redis_password` /
`ha_redis_sentinel_password` (checked against `conf/defaults.ini` at the tag). Measured: `NOAUTH`
unauthenticated on both `:6379` and `:26379`, `PONG` authenticated, `WRONGPASS` on a bad password; all
6 instances registered peer keys **inside** the authenticated keyspace; in-container SHA-256 of both
password envs matched the created secrets.

| Row | Result |
|---|---|
| **Exactly-once, auth ON** | **21 deliveries / 21 cycles / 21 distinct `x-request-id` over 9 m 59 s, vs 126 if uncoordinated** |
| `alerting.enabled: false` | no evaluator workload, Redis tier gone, 6/6 `EXECUTE_ALERTS=false`, rules creatable but `lastEvaluation=0001-01-01`, **0 deliveries in 6 m 24 s** |
| Missing password secret | `helm install` **exits 0 and reports success**; redis + sentinel + **the Grafana UI tier** then sit at 0 replicas with no containers and no logs |
| Drift | zero spec drift; second no-op upgrade fully `Unchanged` |
| Teardown | no orphans, no rollback needed |

- **The no-op upgrade duplicate window is 80-95 s, and it fires on an upgrade that changes nothing** —
  the platform stamps a release tag on every resource it touches, so the chart cannot render its way
  out of it. 4 extra notifications over a 93 s window; never silent.
- **Which location sends is unpinnable.** The elected sender moved `us-east-1` → `us-west-2` between
  two installs of the same chart: sorted peer name, and a standard workload's name carries a
  ReplicaSet hash that changes every rollout. Matters most for egress-IP allowlisting.
- Placeholder defaults were kept over `""` deliberately: the failure is precise, actionable, visible
  in the plain CLI table and self-healing, whereas `""` would ship an unauthenticated coordination bus
  by default.

### 1.1.1 — auth reversed to opt-in, two placeholder traps closed (2026-08-13)

- **`redisML.{redis,sentinel}.passwordSecretName` → `""`.** The decision was made on FAILURE
  LIKELIHOOD, not on threat severity, and that reasoning is the part worth keeping: forgetting a
  prerequisite secret is a common typo, while exploiting an authless Redis requires an attacker
  already running inside the GVC this chart creates. The penalty for the typo is also disproportionate
  — `helm install` exits 0 and reports success while three tiers, including the **UI**, sit at 0
  replicas with no containers and therefore no logs. Auth stays wired, deploy-proven and one values
  line away.
- **`GVC` was not a legible placeholder.** The datasource example read
  `http://RELEASE-prometheus.GVC.cpln.local:9095`; in a live install the workload name was substituted
  and `GVC` was left literal. It resolves to nothing, so Envoy times out rather than failing fast, and
  the user sees `upstream connect error ... connection timeout` — an error that points at the network
  when the cause is a string. Now `YOUR_WORKLOAD.YOUR_GVC`. **The otel-collector template has the
  identical trap with `my-gvc` in its `prometheus_remote_write` endpoint, and it silently dropped every
  metric while reporting success at every other layer** — worth fixing there too.
- **Per-location endpoints serve the UI but not panel data.** `root_url` is the canonical endpoint, so
  a per-location hostname loads the dashboard layout over GET while the POST that fetches panel data is
  rejected: empty panels, no error anywhere in the UI. Recorded as observed behaviour — the CSRF origin
  check is the best explanation but was never confirmed with a 403, which is why **no
  `csrf_trusted_origins` knob ships**. Confirm the status code before adding one.
- **Cross-region service DNS to a single-location GVC WORKS.** Worth writing down because it was got
  wrong mid-investigation: the "service DNS is location-local and does not fail over" finding applies
  to a workload present in SEVERAL locations, where each caller prefers its local replica. A target
  living in exactly one location holds the only endpoints, and callers elsewhere reach it — the same
  shape as the proven Thanos east → Prometheus west path. Do not cite the failover caveat to claim a
  single-location dependency is unreachable.
