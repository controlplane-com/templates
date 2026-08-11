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

## Build-time verifications (2026-08-11, pre-test)

| Claim | Result |
|---|---|
| `localOptions` 0/0 scale-to-zero, no `suspend` | **Works** — stored verbatim, 0 replicas in the zero-scaled locations |
| Positive `rolloutOptions.maxSurgeReplicas: "1"` | Accepted and stored (catalog had only `0%` before) |
| `CPLN_GLOBAL_ENDPOINT` on a workload with `inboundAllowCIDR: []` | **Injected** — hence the prefix rewrite rather than a fallback |
| Endpoint prefix rewrite → the UI tier's URL | Verified inside `grafana/grafana:13.1.3` against both real endpoint forms, plus the fallback branch |
| bash `/dev/tcp` for the 180 s database gate | Present (bash 5.3.9); so are `curl`, `sed` and `nc` |
| Simultaneous boot against an empty database | Loser exits 1 with `Failed to lock database`, succeeds on restart |
