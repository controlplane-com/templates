# vLLM

This template deploys [vLLM](https://github.com/vllm-project/vllm), a high-throughput LLM inference server, serving one Hugging Face model through an OpenAI-compatible API (`/v1/chat/completions`, `/v1/completions`, `/v1/models`, …) on an NVIDIA GPU. The GPU is either one of Control Plane's built-in A10G or T4 cards, or your own GPU cluster registered as a BYOK location. The API is protected by an API key you create first, and the model is cached on a persistent volume so restarts do not re-download it.

## Architecture

- **vLLM server**: stateful workload on port 8000, one GPU set per replica (`replicas: 1` by default); replicas are independent servers behind the workload's load-balanced endpoint and are replaced one at a time.
- **Model cache volume set**: one volume per replica at `/models` holding the downloaded weights and vLLM's compile cache. It is a re-downloadable cache, so no snapshots are kept.
- **Identity + policy**: `reveal` on exactly your API key secret, plus your Hugging Face token secret when set.
- **Metrics**: vLLM's `/metrics` (queue depth, KV-cache usage, token throughput) is scraped into the platform's built-in metrics.

## Prerequisites

1. **API key secret — must exist BEFORE you install.** An opaque secret clients send as a Bearer token. If it is missing the deployment waits silently and `cpln logs` shows nothing:

   ```bash
   printf '%s' "$(openssl rand -hex 32)" | cpln secret create-opaque --name my-vllm-api-key --encoding plain -f -
   ```

2. **A GPU.** With `gpu.type: builtin` (default): GPU quota for your org (one NVIDIA A10G by default, with 6 vCPU and 16 GiB) in a location that offers it — ask Control Plane support. With `gpu.type: byok`: a BYOK location backed by NVIDIA GPU nodes (see below).
3. **Optional — Hugging Face token** for gated models such as Llama or Gemma. Accept the model's license on its huggingface.co page **with the account that owns the token**, and wait until the page shows access granted (some, like Llama, are reviewed by hand). Create a read token (a fine-grained one needs read access to public gated repos), store it, and set `huggingFace.tokenSecretName: my-vllm-hf-token`:

   ```bash
   printf '%s' "$HF_TOKEN" | cpln secret create-opaque --name my-vllm-hf-token --encoding plain -f -
   ```

   Without access the replica restarts with exit code 1; `cpln logs` shows `GatedRepoError` (401 with no token, 403 "not in the authorized list" without license access).
4. **A GVC with exactly one location.** Every location of the GVC runs its own copy, with its own GPUs.

## Configuration

### Image

```yaml
image: vllm/vllm-openai:v0.31.0 # CUDA 13 build; needs NVIDIA driver 580 or newer (Control Plane GPUs run 580)
```

### Model

```yaml
model:
  name: Qwen/Qwen2.5-1.5B-Instruct # Hugging Face model id; downloaded into the volume on first start
  servedModelName: "" # name clients send as "model"; empty = the model id
  maxModelLen: 8192 # max tokens per request (prompt + output)
  gpuMemoryUtilization: 0.90 # share of GPU memory vLLM may use for weights and KV cache
  dtype: auto # options: auto, half, bfloat16, float32 (bfloat16 is not supported on t4)
  toolCallParser: hermes # tool calling, which Open WebUI and agents need; must match the model: hermes (Qwen), llama3_json (Llama 3), mistral; "" = off
  extraArgs: [] # extra `vllm serve` flags, e.g. ["--max-num-seqs", "32"]
```

### Credentials

```yaml
apiKey:
  secretName: my-vllm-api-key # REQUIRED opaque secret (encoding: plain); must EXIST BEFORE INSTALL
huggingFace:
  tokenSecretName: "" # opaque secret with a Hugging Face token, needed for gated models (e.g. my-vllm-hf-token); empty = anonymous
```

### GPU

```yaml
gpu:
  type: builtin # options: builtin (Control Plane GPU locations), byok (your own GPU cluster on a BYOK location)
  model: a10g # builtin only. options: a10g (24 GB), t4 (16 GB)
  quantity: 1 # GPUs per replica. a10g: 1, t4: 1-4, byok: 1-8; more than 1 enables tensor parallelism
```

### Resources and Scaling

```yaml
# builtin a10g: cpu 6000m-8000m, memory 8Gi-62Gi. t4: cpu 2000m-8000m and memory 7Gi-31Gi per GPU (4000m per GPU with 2+ GPUs or from 14Gi).
# Any type: memory below 8 MiB per millicore of cpu (e.g. under 16Gi at 2000m).
# byok: fit your GPU node, e.g. cpu 2000m / memory 8Gi on a 4-vCPU g5.xlarge or g6.xlarge.
resources:
  cpu: 6000m
  memory: 16Gi

replicas: 1 # each replica runs its own GPU(s) and model cache; 2+ keeps serving through restarts and upgrades
startupTimeoutSeconds: 900 # seconds from container start to ready (download + load) before the platform restarts it; 300-1830
```

### Model Cache

```yaml
volumeset:
  capacity: 50 # GiB per replica for new volumes; at least 2x the model's weights plus 5 (minimum 10)
```

### Access

```yaml
publicAccess:
  enabled: false # true = the API is reachable from the internet (the API key still applies to /v1)

internalAccess:
  type: same-gvc # options: none, same-gvc, same-org, workload-list
  workloads: [] # used with workload-list, e.g. //gvc/GVC_NAME/workload/WORKLOAD_NAME
```

## Bring Your Own GPU Cluster (BYOK)

Set `gpu.type: byok` to run on your own NVIDIA nodes. This works on any Kubernetes cluster registered as a Control Plane [BYOK location](https://docs.controlplane.com/byok/overview) — an MK8s cluster with the [BYOK add-on](https://docs.controlplane.com/mk8s/add-ons/byok) enabled, or a cluster you already run (EKS, GKE, AKS, on-premises). A cluster that is not registered as a location cannot run this template. The chart requests `nvidia.com/gpu` with runtime class `nvidia`; the built-in form cannot target BYOK nodes.

Every cluster needs:

- **NVIDIA GPU nodes with driver 580 or newer** (the CUDA 13 image requires it) and a device plugin that exposes `nvidia.com/gpu`.
- **A RuntimeClass named `nvidia`** — the chart always requests it, and its handler differs per cluster (below). Without it the install fails with `The GPU runtime class nvidia is not supported in this cluster`. If you add it after installing BYOK, restart BYOK's actuator (`kubectl rollout restart deploy/actuator -n controlplane`); it does not see new runtime classes until then.
- **No taint on the GPU nodes** — Control Plane workloads do not tolerate it.
- **GPU node label `cpln.io/gpuUsageAutoDrain: ignore`** — otherwise BYOK drains a GPU node that has had no GPU pod for 5 minutes, including one where vLLM is still starting.
- **A GPU node boot disk of at least 200 GB** — the ~10 GB image and the model otherwise fill the disk and the node evicts vLLM.
- **`resources` sized to the node** — a 4-vCPU GPU node (g5.xlarge, g6.xlarge, g2-standard-4, NC4as_T4_v3) cannot fit the built-in default of 6 CPU and the replica stays pending; use about `cpu: 2000m`, `memory: 8Gi`.
- **A GVC whose only location is the BYOK location** — on a Control Plane location the GPU request is ignored and vLLM cannot start.

```yaml
# kubectl apply -f runtimeclass.yaml (not needed on MK8s)
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: nvidia
handler: nvidia # EKS: nvidia, GKE: runc, AKS: nvidia-container-runtime
```

Tested per cluster type (each passed internal and public API checks):

- **MK8s on AWS:** NVIDIA add-on with `taintGPUNodes: false`; an x86 NVIDIA-driver node image (DLAMI) plus the label `mk8s.cpln.io/accelerator: nvidia` — the recommended `+nvidia` images resolve to arm64, and with a custom image the device plugin only runs on nodes carrying that label; one instance type per GPU pool. The `nvidia` RuntimeClass is built in.
- **MK8s on GCP:** NVIDIA add-on with `taintGPUNodes: false`; GPU pool `overrideImage.family` `deeplearning-platform-release/common-cu129-ubuntu-2404-nvidia-580` plus the label `mk8s.cpln.io/accelerator: nvidia`. Only machine types with a built-in GPU work (G2/L4, A2, A3) — GCP node pools have no accelerator field, so T4/V100 on N1 is not possible. The `nvidia` RuntimeClass is built in.
- **EKS:** the AL2023 NVIDIA AMI (eksctl installs the device plugin); RuntimeClass `nvidia` with handler `nvidia`; the [AWS Load Balancer Controller](https://kubernetes-sigs.github.io/aws-load-balancer-controller/) — BYOK's ingress service requests an `external` NLB and gets no address without it (Helm needs `--disable-openapi-validation` once BYOK is installed).
- **GKE:** GPU pool with `gpu-driver-version=latest`; RuntimeClass `nvidia` with handler **`runc`** (GKE has no `nvidia` handler and injects the driver itself). BYOK's storage classes are Hyperdisk-only, which N1 machines (the only T4 family) cannot attach — on N1 set `byok.noDefaultStorageClasses: true` in `cluster.json` of ConfigMap `kube-system/cpln-byok-current`, restart `cpln-byok-agent`, and create your own `general-purpose-ssd-ext4` class on `pd-balanced`. If BYOK's install stalls with `istiod` never created, restart `deploy/cpln-byok-agent -n kube-system`.
- **AKS:** GPU pool with the default `--gpu-driver Install` (driver 580) **in an availability zone** (`--zones 1`) — BYOK's storage classes are Premium SSD v2, which Azure attaches only to zonal VMs; the [NVIDIA device plugin](https://github.com/NVIDIA/k8s-device-plugin) (AKS does not install it), with the pool label `nvidia.com/gpu.present=true` so its chart schedules there; RuntimeClass `nvidia` with handler **`nvidia-container-runtime`**.
- **MK8s on Azure:** not working yet — a GPU pool with a custom NVIDIA-driver image is never created, and the stock image has no driver.

## Connecting

| What | Value |
|---|---|
| Internal API | `http://{release}-vllm.{gvc}.cpln.local:8000/v1` — from workloads `internalAccess.type` allows |
| Public API | `https://<canonical>/v1` — only with `publicAccess.enabled: true`; read it from `status.canonicalEndpoint` of `{release}-vllm` |
| From your machine | `cpln port-forward {release}-vllm 8000:8000 --gvc {gvc}`, then `http://localhost:8000/v1` |
| API key | The payload of your `apiKey.secretName` secret: `cpln secret reveal my-vllm-api-key` |
| Model name | `model.servedModelName`, or the model id when it is empty |

```bash
curl http://localhost:8000/v1/chat/completions \
  -H "Authorization: Bearer $VLLM_API_KEY" -H 'Content-Type: application/json' \
  -d '{"model":"Qwen/Qwen2.5-1.5B-Instruct","messages":[{"role":"user","content":"Hello"}]}'
```

Any OpenAI SDK works with `base_url` set to the `/v1` address and `api_key` set to the key. The `open-webui` and `litellm` templates can use it as an OpenAI-compatible backend; for a chat UI, install `open-webui` 1.3.0 or later in the same GVC with the values in its README's "Pairing with vLLM" section. Open WebUI offers tools on every chat, so keep `model.toolCallParser` set and matched to your model, or each message fails with `"auto" tool choice requires --enable-auto-tool-choice`. Open WebUI's Control Plane tools need a context of at least 64k tokens, more than the default `model.maxModelLen: 8192`; its README section "Connecting Control Plane tools (MCP)" gives `model` values that reach 64k on an A10G.

## Important Notes

- **The API key protects only `/v1`.** vLLM leaves `/health`, `/metrics`, `/tokenize` and `/detokenize` unauthenticated, so with public access on anyone can read metrics and use the tokenizer.
- **A missing secret stalls the install with no logs.** Run `cpln workload get-deployments {release}-vllm --gvc {gvc} -o yaml` and read `status.versions[].message`, which names the missing secret; once the secret exists the deployment recovers by itself, which can take up to ~10 minutes; keep polling.
- **The first start is slow:** a ~12 GB image pull, then the model download and load (3-5 minutes for the default model). A replica not ready within `startupTimeoutSeconds` is restarted, so raise it (up to 1830) for large models and keep it for slow first downloads.
- **With one replica the API is down while it restarts** (any upgrade or setting change); set `replicas: 2` for zero-downtime restarts and upgrades — each replica needs its own GPU.
- **Rotating the API key:** update the secret's payload, then run `cpln workload force-redeployment {release}-vllm --gvc {gvc}`; the running server keeps the old key until it restarts (about 4 minutes, with the API down for ~2.5 of them at one replica).
- **On a T4, size the replica at about `cpu: 3000m` / `memory: 12Gi`.** Larger requests the chart accepts (e.g. the 6000m / 16Gi default) did not schedule on Control Plane's T4 nodes in testing.
- **On a BYOK location, `cpln port-forward` needs `internalAccess` other than `none`**; with `none` it returns `502 Unable to connect to upstream workload` there.
- **Switching models leaves the old weights on the volume.** Delete them with `cpln workload exec {release}-vllm --gvc {gvc} --container vllm -- hf cache rm model/ORG/NAME -y` (deleting the model's folder frees nothing: the weights live in a shared blob store).
- **Changing `volumeset.capacity` does not resize an existing volume** — it only sizes new ones. Grow a live volume with `cpln volumeset expand {release}-vllm-models --gvc {gvc} --location LOCATION --volume-index 0 --new-size 100` (online, no restart; one index per replica).

## Links

- [vLLM on GitHub](https://github.com/vllm-project/vllm)
- [OpenAI-compatible server](https://docs.vllm.ai/en/latest/serving/openai_compatible_server.html)
- [Engine arguments (`extraArgs`)](https://docs.vllm.ai/en/latest/configuration/engine_args.html)
- [Using Docker](https://docs.vllm.ai/en/latest/deployment/docker.html)
- [Supported models](https://docs.vllm.ai/en/latest/models/supported_models.html)
