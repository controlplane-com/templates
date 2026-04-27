## Ollama App

### Warning

You will need to request a quota increase for CPU and Memory if your org is at the default quotas.

### Overview

The user interface is the project https://github.com/open-webui/open-webui
It runs on port 8080 as a sidecar to the ollama API. Since 8080 is the first port specified in the workload definition all external traffic is forwarded to it.

The ollama API is the project https://github.com/ollama/ollama
It runs on port 11434 and is accessed by the open-webui sidecar. There is a persistent storage volume of 10Gib (default) that is used to store the models. On startup, a script is used to download a default model (default llama2) if it does not yet exist on the filesystem.

On Control Plane, you can access GPU's from any cloud provider. You can even deploy this example to multiple cloud provider geo locations at the same time and end users will be routed to the closest available location.

### Specification

- NVIDIA T4 GPU

### Access the web-ui using the deployment link, found with [CLI](#CLI) or [UI](#UI)

Documentation and examples of how to use the ollama open-webui are available here:
https://github.com/open-webui/open-webui

#### CLI

1. Run the command below to get the deployment link (replacing gvc and workload as needed)

```bash
cpln workload get {workload-name} --gvc {gvc-name} -o json | jq -r '.status.endpoint'
```

#### UI

1. Navigate to the generated workload and click `Open` next to the workload name