## Ollama

### Architecture

- **Workload** — the Ollama server, with an optional Open WebUI front end.
- **Volume set** — stores pulled models, which are large; size it for the models you intend to run.
- **Secret** — the startup script, which pulls `defaultModel` on first boot.
- **Identity and policy** — `reveal` on the startup secret.

This template does not create a GVC.

### Prerequisites

None. The model named by `defaultModel` is pulled on first start.

### Warning

You will need to request a quota increase for CPU and memory if your org is at the default quotas. GPU resources require explicit enablement — contact Control Plane support if you do not have access.

### Overview

Deploys [Ollama](https://github.com/ollama/ollama) as a stateful workload with the [Open WebUI](https://github.com/open-webui/open-webui) as a sidecar. The WebUI runs on port 8080 and is the externally exposed interface. The Ollama API runs on port 11434 and is accessed internally by the WebUI. On first startup, a script downloads the configured default model if it is not already present on the volume.

On Control Plane, GPUs are available across multiple cloud provider locations. You can deploy this template to several regions simultaneously and end users will be routed to the closest available instance.

### Configuration

**Default model** — set the model to pull on first startup. Any model available in the [Ollama library](https://ollama.com/library) can be used:
```yaml
defaultModel: llama3
```
Common alternatives: `llava`, `gemma`, `mistral`, `phi3`

**UI container** — configure the Open WebUI image and resources:
```yaml
workload:
  containers:
    ui:
      image: ghcr.io/open-webui/open-webui:v0.11.0 # pinned: `main` is a moving branch build
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

Once deployed, access the Open WebUI through the Control Plane endpoint:

```
https://RELEASE_NAME-ollama.GVC_NAME.cpln.app
```

The Ollama API is also available internally to other workloads in the same GVC:

```
http://RELEASE_NAME-ollama.GVC_NAME.cpln.local:11434
```

### Supported External Services
- [Ollama Documentation](https://github.com/ollama/ollama)
- [Open WebUI Documentation](https://github.com/open-webui/open-webui)
- [Ollama Model Library](https://ollama.com/library)

### Important Notes

- **Quotas are the usual first blocker.** CPU and memory beyond the org defaults need a quota increase, and GPU access must be enabled explicitly — see the Warning above.
- **Models are large and live on the volume set.** Size it for what you intend to pull; a default-sized volume fills quickly once you add a second model.
- **The first start is slow.** `defaultModel` is downloaded before the server is useful, so an install that looks stuck early is usually still pulling.
- **The Open WebUI sidecar on `8080` is the exposed interface**; the Ollama API on `11434` is reached internally by the UI. Exposing `11434` directly gives unauthenticated access to the model server.
- **Uninstalling deletes the volume set**, so every pulled model is downloaded again on the next install.
