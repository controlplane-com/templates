# Secret Env Var Syncer (SEVS) — maintainer briefing

**What it is.** A scheduled job that reads Control Plane secrets and writes their values into other
workloads' environment variables, so a workload that cannot consume a `cpln://` reference still gets the
value. Companion to `ess`, which syncs *into* Control Plane secrets from external stores.

**Common use cases.** Feeding secrets to workloads whose runtime resolves env vars at build or start in a
way `cpln://` cannot serve, and keeping a GVC's workloads in step with a rotating secret without a redeploy
per workload.

## Architecture

| Resource | Notes |
|---|---|
| workload (cron) | runs on `schedule`, resolves each entry, patches the target workloads |
| secret | the generated syncer configuration |
| identity + policy | read the source secrets, and **edit** the workloads it writes into |

Does not create a GVC. Creates no secrets of its own beyond its configuration.

## Key knobs (shipped defaults)

| Knob | Default | Notes |
|---|---|---|
| `schedule` | `*/5 * * * *` | standard cron; every five minutes |
| `timeoutSeconds` | `300` | raise it for a large entry list |
| `sevsConfig.entries[]` | one example entry | each maps a source secret to a target |
| `image` | `secret-env-var-syncer:v1.3.1` | pinned |

Each entry names a `target` (by `type` and `name` — a GVC or a specific workload) and the `secret` to read.

## Troubleshooting traps

- **The secrets and the target workloads must already exist.** The syncer resolves both at each run and
  creates neither; a typo in either name is a no-op that only shows in the job's logs.
- **This grants edit on the workloads it targets.** That is inherent — it rewrites their environment — but
  it means a `type: gvc` target hands the syncer edit rights across that whole GVC. Prefer naming specific
  workloads where you can.
- **Writing an env var redeploys the workload.** Patching a workload's spec rolls its replicas, so a sync
  that changes a value is a restart, and anything that cannot survive one is affected by it.
- **There is no endpoint to check.** It is a cron job, so confirm it works from the target workload's
  environment after a run, or from the job's own logs — not by connecting to anything.
- **A short `schedule` with many entries can overlap.** If a run exceeds `timeoutSeconds` or the interval,
  the next fires anyway; keep the interval comfortably above a full run.
