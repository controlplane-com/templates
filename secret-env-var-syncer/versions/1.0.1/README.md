## Secret Env Var Syncer (SEVS)

### Architecture

- **Cron workload** — runs on `schedule`, reads each entry in `sevsConfig`, and writes the resolved values into the target workloads' environment variables.
- **Secret** — the generated syncer configuration.
- **Identity and policy** — permission to read the secrets it syncs from and to edit the workloads it syncs into.

This template does not create a GVC.

### Prerequisites

**The secrets you reference and the workloads you target must already exist.** The syncer resolves them at each run; it does not create either.

### Overview

Creates a cron workload that syncs keys from Control Plane dictionary secrets into environment variables on GVCs or individual workload containers. Runs on a configurable schedule, then exits.

---

### How It Works

SEVS runs as a cron workload on Control Plane. Your sync configuration is stored in a Control Plane secret and mounted into the workload as `config.yaml`. On each execution, SEVS reads the list of entries, fetches the specified dictionary secret, and applies its keys as environment variables to the target GVC or workload container. The job then exits until the next scheduled run.

---

### Configuring `values.yaml`

#### Top-level fields

| Field | Description |
|---|---|
| `image` | The SEVS container image. Do not change unless upgrading. |
| `resources.cpu` / `resources.memory` | Resource limits for the workload container. |
| `schedule` | Cron expression controlling how often the sync runs (default: `*/5 * * * *`). |
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

> **Note:** The `container` field is required for workload targets. The `gvc` field is required for workload targets when the workload is in a different GVC than the one SEVS is deployed in.

---

### Permissions

SEVS requires the following permissions on its identity:

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
- **Env var overwrite:** Existing environment variables on the target with the same key will be overwritten on each run.

---

### Resources

- [Image Source Code](https://github.com/controlplane-com/secret-env-var-syncer)

### Connecting

There is no endpoint to connect to — this template is a scheduled job. Confirm it is working by checking the target workload's environment after a run, or by reading the cron workload's logs:

```bash
cpln logs '{gvc="GVC_NAME", workload="RELEASE_NAME-secret-env-var-syncer"}' --limit 50 --since 30m
```

### Links

- [Control Plane secrets](https://docs.controlplane.com/reference/secret)
- [Control Plane workloads](https://docs.controlplane.com/reference/workload/general)
