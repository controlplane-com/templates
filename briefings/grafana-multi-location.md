# grafana-multi-location

## What it is

- Grafana OSS **13.1.3** running in every location of a chart-created multi-location GVC, behind one
  georouted `*.cpln.app` endpoint, with all app state in a **stretched Patroni cluster**
  (`postgres-multi-location` subchart, which itself consumes `etcd-multi-location` — three levels).
- **Two workloads from one image.** The UI tier scales freely per location with alert execution OFF;
  a separate **single-replica** workload in one location has it ON. Exactly-once evaluation is a
  property of the topology, not of container agreement — nothing is elected, and no value of
  `replicas` can create a second evaluator.
- Grafana is **stateless** here (no volumeset, no sticky sessions). AGPL-3.0, free to self-host,
  nothing enterprise-gated in what we ship.
- For a single location, `grafana` 1.2.0 is the template — it also offers Redis-coordinated alerting
  HA, which this one deliberately does not (see the traps).

## Common use cases

- One dashboarding surface for teams in several regions, each served locally.
- Grafana that keeps serving when a region is lost, with the database failing over automatically.
- A regional-redundancy requirement met without running and reconciling several Grafanas.

## Architecture on cpln

| Resource | Purpose |
|---|---|
| `gvc` | **Always created**, gated only by `{{ if .Chart.IsRoot }}`. There is no `createGvc` knob — the GVC is what pins the locations. Both subcharts suppress theirs, so a release renders exactly one |
| `workload` (standard) `{release}-grafana-ml` | UI/API tier, `replicas` per location, `execute_alerts=false`, public by default |
| `workload` (standard) `{release}-grafana-ml-alerting` | The evaluator: 1 replica, `alerting.location` only, `execute_alerts=true`, **never public**. Suppressed entirely when `alerting.location: ""` |
| `identity` + `policy` | **One** identity shared by both workloads; `reveal` on exactly the secrets they mount. No cloud bindings — this chart touches no object storage |
| `secret` `{release}-grafana-ml-datasources` | Datasource provisioning file, mounted by both. Only when `datasources.definitions` is set |
| subchart `postgres-multi-location` (aliased `postgresML`) | The app database: HAProxy leader endpoint per location, one Patroni primary, async replicas |

## Key knobs

| Knob | Default | Meaning |
|---|---|---|
| `global.gvc.name` / `.locations[]` | `grafana-multi-location-gvc`, 3 AWS locations × 1 | **≥2 required**; `replicas` here is DATABASE members per location. The GVC **must not already exist** |
| `image` | `grafana/grafana:13.1.3` | Alpine variant required — the boot wrapper needs a shell |
| `replicas` | `1` | Grafana UI instances **per location**. No alerting-related restriction of any kind |
| `database.maxOpenConn` | `10` | Per instance. `(replicas × locations + 1) × this` must stay ≤ 80; the `+1` is the evaluator. Enforced at render time |
| `alerting.location` / `.resources.*` | `aws-us-east-1` / 500m–1000m, 512Mi–1Gi | The one location the evaluator runs in. `""` = no evaluator, alerting disabled |
| `admin.passwordSecretName` / `.secretKeySecretName` / `.applyPassword` / `.user` | `my-grafana-ml-admin-password` / `my-grafana-ml-secret-key` / `true` / `admin` | **Required prerequisite opaque secrets** (`encoding: plain`). Both workloads carry the admin env |
| `datasources.definitions` / `.credentialSecrets` | `[]` / `[]` | Datasources as code; `$KEY` interpolation from prerequisite dictionary secrets |
| `smtp.*` | off | The evaluator is what actually sends |
| `publicAccess.enabled` / `internalAccess.type` | `true` / `same-gvc` | Public applies to the UI tier only |
| `postgresML.primaryLocation` | `aws-us-east-1` | Deviates from the subchart's `""` on purpose — Grafana has no read/write splitting |

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
  `{release}-grafana-ml-alerting.{gvc}.cpln.local:3000` — the evaluator is a named single-replica
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
  (`ha_redis_address`, shipped in `grafana` 1.2.0) works but needs a cross-region Redis tier — a
  four-level chart, staged as 1.1.0.
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
