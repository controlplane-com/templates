## Ollama

### Architecture

- **Workload** — the Ollama server, with an optional Open WebUI front end.
- **Volume set** — stores pulled models, which are large; size it for the models you intend to run.
- **Secret** — the startup script, which starts the Ollama server.
- **Identity and policy** — `reveal` on the startup secret.

This template does not create a GVC.

### Prerequisites

None.

### Warning

You will need to request a quota increase for CPU and memory if your org is at the default quotas. GPU resources require explicit enablement — contact Control Plane support if you do not have access.

### Overview

Deploys [Ollama](https://github.com/ollama/ollama) as a stateful workload with the [Open WebUI](https://github.com/open-webui/open-webui) as a sidecar. The WebUI runs on port 8080 and is the externally exposed interface. The Ollama API runs on port 11434 and is accessed internally by the WebUI. The template does not download a model: pull the one you want once after install (see Important Notes).

On Control Plane, GPUs are available across multiple cloud provider locations. You can deploy this template to several regions simultaneously and end users will be routed to the closest available instance.

### Configuration

**Default model** — the model Open WebUI preselects. It is not downloaded automatically; pull it once after install. Any model in the [Ollama library](https://ollama.com/library) can be used:
```yaml
defaultModel: llama3
```
Common alternatives: `llava`, `gemma`, `mistral`, `phi3`

**UI container** — configure the Open WebUI image and resources:
```yaml
workload:
  containers:
    ui:
      image: ghcr.io/open-webui/open-webui:v0.12.4 # pinned: `main` is a moving branch build; v0.12.4 or newer is required
      resources:
        cpu: 500m
        memory: 1Gi
```

**API container** — configure the Ollama image, resources, and GPU:
```yaml
workload:
  containers:
    api:
      image: ollama/ollama:0.32.15 # pinned: an untagged image resolves to `latest`
      resources:
        cpu: 6
        memory: 8Gi
      gpu:
        nvidia:
          model: t4
          quantity: 1
```

**Volume** — persistent storage for downloaded models. Default is 10 GiB. Optionally enable autoscaling to expand as models accumulate:
```yaml
volumeset:
  initialCapacity: 10
  autoscaling:
    enabled: true
    maxCapacity: 100
    minFreePercentage: 10
    scalingFactor: 1.2
```

**Firewall** — restrict inbound and outbound access. Defaults to open:
```yaml
firewall:
  external:
    inboundAllowCIDR:
      - 0.0.0.0/0
    outboundAllowCIDR:
      - 0.0.0.0/0
```

**Internal access** — controls which workloads can reach Ollama internally:
```yaml
internal_access:
  type: same-gvc # options: none, same-gvc, same-org, workload-list
  workloads:
    - //gvc/my-gvc/workload/my-app
```

### Connecting

Once deployed, open the Open WebUI at the workload's canonical endpoint — read `status.canonicalEndpoint` from:

```bash
cpln workload get RELEASE_NAME-ollama --gvc GVC_NAME -o yaml
```

The Ollama API is also available internally to other workloads in the same GVC:

```
http://RELEASE_NAME-ollama.GVC_NAME.cpln.local:11434
```

### Supported External Services
- [Ollama Documentation](https://github.com/ollama/ollama)
- [Open WebUI Documentation](https://github.com/open-webui/open-webui)
- [Ollama Model Library](https://ollama.com/library)

### Upgrading from 1.1.2

Version 1.2.0 moves Open WebUI from `v0.11.0` to `v0.12.4`, whose image fixes Critical CVEs. The chart refuses an official Open WebUI tag older than `v0.12.4`, so a `workload.containers.ui.image` in your values that pins one must be changed or removed.

- **Open WebUI migrates its database on the first start, and rolling back to 1.1.2 is not supported**: `v0.11.0` cannot read the migrated database. Take a volume set snapshot first: `cpln volumeset snapshot create RELEASE_NAME-ollama-vs --gvc GVC_NAME --snapshot-name before-upgrade`.
- **Tool servers that users saved under Settings › Integrations stop being used in chats** until an admin turns on Direct Integrations in Admin Settings › Connections.
- **Custom functions and tools that install pip packages need versions that support Python 3.12**, which the image now runs.

### Upgrading from 1.1.1 or earlier

Versions before 1.1.2 ran the moving `open-webui:main` build and an untagged `ollama/ollama`; this version pins `open-webui:v0.12.4` and `ollama/ollama:0.32.15`. A release on `main` may already run a newer Open WebUI than `v0.12.4`, and Open WebUI cannot read a database that a newer version migrated. When upgrading, keep the image the release runs, or pin a tag at least as new as its running version (Open WebUI shows it under Settings › About):

```yaml
workload:
  containers:
    ui:
      image: ghcr.io/open-webui/open-webui:main # or a release tag at least as new as the running one
```

Take a volume set snapshot first: `cpln volumeset snapshot create RELEASE_NAME-ollama-vs --gvc GVC_NAME --snapshot-name before-upgrade`.

### Important Notes

- **Register the Open WebUI admin account right after install.** Open WebUI has no preset account, and the first person to register becomes its administrator; with inbound open to `0.0.0.0/0`, that can be anyone who reaches the endpoint first.
- **Quotas are the usual first blocker.** CPU and memory beyond the org defaults need a quota increase, and GPU access must be enabled explicitly — see the Warning above.
- **Models are large and live on the volume set.** Size it for what you intend to pull; a default-sized volume fills quickly once you add a second model.
- **Pull `defaultModel` once after the first start — the template does not download it.** Run `cpln workload exec RELEASE_NAME-ollama --gvc GVC_NAME --container ollama -- ollama pull llama3` (or use Open WebUI's model settings); models are large, so the first pull is slow. It lands on the volume set and survives restarts.
- **The Open WebUI sidecar on `8080` is the exposed interface**; the Ollama API on `11434` is reached internally by the UI. Exposing `11434` directly gives unauthenticated access to the model server.
- **Uninstalling deletes the volume set**, so every pulled model is downloaded again on the next install.
