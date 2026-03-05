## Ollama

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
      image: ghcr.io/open-webui/open-webui:main
      resources:
        cpu: 500m
        memory: 1Gi
```

**API container** — configure the Ollama image, resources, and GPU:
```yaml
workload:
  containers:
    api:
      image: ollama/ollama
      resources:
        cpu: 6
        memory: 7Gi
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
