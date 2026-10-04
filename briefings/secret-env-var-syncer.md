# Secret Env Var Syncer (SEVS) — maintainer briefing

**What it is.** A scheduled job that lists the keys of a Control Plane dictionary secret and adds one
environment variable per key — each a `cpln://secret/SECRET.KEY` reference, never the value — to a GVC or a
workload container. Companion to `ess`, which syncs *into* Control Plane secrets from external stores.

**Common use cases.** Keeping a target's environment in step with the key set of a dictionary secret, so a
key added to the secret appears as an env var without hand-editing every workload.

## Architecture

| Resource | Notes |
|---|---|
| workload `-sevs` (cron, `concurrencyPolicy: Forbid`) | runs on `schedule`, resolves each entry, patches the targets |
| secret `-sevs-config` | the generated syncer configuration |
| identity + 3 policies | `reveal` on every secret, `edit` on every GVC, `edit` on every workload — all `target: all`, whatever the entries say |

Does not create a GVC. Creates no secrets of its own beyond its configuration.

## Key knobs (shipped defaults)

| Knob | Default | Notes |
|---|---|---|
| `schedule` | `*/5 * * * *` | standard cron; every five minutes |
| `timeoutSeconds` | `300` | raise it for a large entry list |
| `sevsConfig.entries[]` | one example entry | each maps a source secret to a target |
| `image` | `secret-env-var-syncer:v1.3.1` | pinned |

Each entry names a `target` (by `type` and `name` — a GVC or a specific workload) and the `secret` to read.
Workload targets require both `gvc` and `container`; the image rejects the entry otherwise.

## Troubleshooting traps

- **The secrets and the target workloads must already exist.** The syncer resolves both at each run and
  creates neither; a typo in either name fails that entry (and the rest of the run), visible only in
  the job's logs.
- **The grants are org-wide, not per target.** The chart renders `target: all` on all three policies, so
  the syncer can reveal every secret and edit every GVC and workload in the org however narrow the entries
  are. Scoping them needs a new chart version (open maintainer ruling).
- **It writes references, so rotation does not propagate.** A rotated value leaves the reference unchanged;
  the syncer sees no diff and does not patch, and a running replica keeps the old value until the target is
  force-redeployed. Only a changed KEY SET patches the target (which then redeploys).
- **The target's own identity must have `reveal` on the source secret**, or the reference cannot resolve.
  GVC-level env vars reach only containers with `inheritEnv: true`.
- **There is no endpoint to check.** It is a cron job, so confirm it works from the target workload's
  environment after a run, or from the job's own logs — not by connecting to anything.
- **Runs never overlap.** `concurrencyPolicy: Forbid` skips a tick while a run is active; a run is killed at
  `timeoutSeconds`.
- **One bad entry stops the run.** Entries run in order and the first error ends the job, so every later
  entry goes unsynced until it is fixed. Read `cpln logs '{gvc="GVC_NAME", workload="RELEASE_NAME-sevs"}'`.
