## Secret Env Var Syncer (SEVS)

### Architecture

- **Cron workload** (`RELEASE_NAME-sevs`) — runs on `schedule`, reads each entry in `sevsConfig`, and writes one `cpln://secret/SECRET.KEY` reference per secret key into the target's environment variables.
- **Secret** (`RELEASE_NAME-sevs-config`) — the generated syncer configuration.
- **Identity and three policies** — `reveal` on every secret, `edit` on every GVC and `edit` on every workload in the org (`target: all`), regardless of which entries you configure.

This template does not create a GVC.

### Prerequisites

**The secrets you reference and the workloads you target must already exist.** The syncer resolves them at each run; it does not create either.

The syncer writes references, not values, so each target workload's own identity needs `reveal` on the source secret for the reference to resolve. For a GVC target, only containers with `inheritEnv: true` receive GVC environment variables.

### Overview

Creates a cron workload that adds an environment variable for each key of a Control Plane dictionary secret to a GVC or an individual workload container, as a `cpln://secret/SECRET.KEY` reference. Runs on a configurable schedule, then exits.

---

### How It Works

SEVS runs as a cron workload on Control Plane. Your sync configuration is stored in a Control Plane secret and mounted into the workload as `config.yaml`. On each execution, SEVS reads the list of entries, lists the keys of the specified dictionary secret, and sets one environment variable per key on the target GVC or workload container, each holding a `cpln://secret/SECRET.KEY` reference. It updates the target only when that set of variables changes. Entries run in order, and an error on one entry ends the run, so later entries are not synced until it is fixed. The job then exits until the next scheduled run.

---

### Configuring `values.yaml`

#### Top-level fields

| Field | Description |
|---|---|
| `image` | The SEVS container image. Do not change unless upgrading. |
| `resources.cpu` / `resources.memory` | Resource limits for the workload container. |
| `schedule` | Cron expression controlling how often the sync runs (default: `*/5 * * * *`). |
| `timeoutSeconds` | Maximum time for a single run (default: `300`). |
| `sevsConfig` | The full sync configuration — a list of entries (see below). |

---

#### `sevsConfig.entries`

Each entry syncs the keys of one Control Plane dictionary secret into the environment variables of one target.

| Field | Description |
|---|---|
| `target` | The resource to apply env vars to (see target types below). |
| `secret` | The name of the Control Plane dictionary secret to read from. |

---

#### Target Types

**GVC** — applies the secret keys as env vars to the entire GVC:
```yaml
- target:
    type: gvc
    name: my-gvc
  secret: my-dictionary-secret
```

**Workload** — applies the secret keys as env vars to a specific container within a workload:
```yaml
- target:
    type: workload
    name: my-workload
    gvc: my-gvc
    container: app
  secret: my-dictionary-secret
```

> **Note:** The `gvc` and `container` fields are both required for workload targets, even when the workload is in the same GVC as SEVS. An entry without them fails the run.

---

### Permissions

The template grants its identity these permissions on **every** resource of each kind in the org (`target: all`), not only the ones named in your entries:

| Resource Kind | Permission | Reason |
|---|---|---|
| `secret` | `reveal` | Read the source dictionary secrets listed in each entry |
| `gvc` | `edit` | Set environment variables on GVC targets |
| `workload` | `edit` | Set environment variables on workload targets |

These are automatically created by the template via three policy resources.

---

### Important Notes

- **One-shot execution:** SEVS runs once per schedule tick and exits. It is not a long-running daemon.
- **Concurrency:** The job is configured with `concurrencyPolicy: Forbid`, so if a previous run is still active when the next schedule fires, the new run is skipped.
- **Dictionary secrets only:** Source secrets must be of type `dictionary`. Opaque secrets are not supported as sync sources.
- **Env var overwrite:** An existing environment variable on the target with the same name as a secret key is replaced by the reference.
- **Rotating a secret value does not reach the target on its own.** The reference does not change, so the syncer does not update the target. Force a redeployment of the target workload after a rotation: `cpln workload force-redeployment WORKLOAD_NAME --gvc GVC_NAME`.
- **Adding a key updates the target**, which redeploys the workloads that receive it.

---

### Resources

- [Image Source Code](https://github.com/controlplane-com/secret-env-var-syncer)

### Connecting

There is no endpoint to connect to — this template is a scheduled job. Confirm it is working by checking the target workload's environment after a run, or by reading the cron workload's logs:

```bash
cpln logs '{gvc="GVC_NAME", workload="RELEASE_NAME-sevs"}' --limit 50 --since 30m
```

### Links

- [Control Plane secrets](https://docs.controlplane.com/reference/secret)
- [Control Plane workloads](https://docs.controlplane.com/reference/workload/general)
