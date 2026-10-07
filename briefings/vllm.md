# vLLM — Maintainer Briefing

## What it is
- vLLM: high-throughput LLM inference server (PagedAttention, continuous batching) with an OpenAI-compatible API. **Apache-2.0** (permissive open-source license; nothing for us or users to do).
- Official image `vllm/vllm-openai:v0.31.0-cu129`. The CUDA 12.9 build, not the default CUDA 13 tag, because CUDA 13 needs NVIDIA driver ≥ 580 and the driver on Control Plane's built-in A10G/T4 nodes is not documented (unmeasured; T1 reads it). The image runs as root, so no `filesystemGroupId`.
- API-only: no browser UI. Chat UIs are the `open-webui` template; a key-and-budget gateway is `litellm`.

## Common use cases
- OpenAI-compatible endpoint for internal apps backed by an open-weight model (Qwen, Llama, Mistral).
- Replace a hosted LLM API so prompts stay on the user's infrastructure.
- Serve models on the user's own GPU cluster (MK8s or any Kubernetes registered as a BYOK location).
- Backend for `open-webui` or `litellm`.

## Architecture on cpln

| Resource | Purpose |
|---|---|
| workload `{release}-vllm` (stateful) | `vllm serve <model>` on :8000, one GPU set per replica; `/metrics` scraped into built-in metrics |
| volumeset `{release}-vllm-models` (50 GiB, ext4) | per-replica cache at `/models` (`HF_HOME=/models/hf`, `VLLM_CACHE_ROOT=/models/vllm`); no snapshots, no final snapshot |
| identity + policy | `reveal` on the API key secret (+ HF token secret when set) |

- `gpu.type: builtin` → `gpu.nvidia {a10g|t4}`; `byok` → `gpu.custom {nvidia.com/gpu, runtimeClass nvidia}`. The built-in form CANNOT target BYOK nodes (it needs a `cpln.io/gpu=nvidia-a10g` node label).
- **Why stateful:** the only proven way to mount the block-storage cache, and it replaces replicas one at a time. A `standard` workload deadlocks on one GPU (the new pod waits for the GPU the old one holds) — spike-proven 2026-10-07.
- Availability: `replicas: 1` (default, per the simple-shape ruling; GPU cost dominates) = the API is down for every restart/upgrade boot. `replicas: N` = N independent servers, each with its own GPU and cache, rolled one at a time. No clustering needed.
- `gvc` limited to exactly one location (wizard): N locations = N copies × N GPUs, and a BYOK GVC with a Control Plane location runs a GPU-less copy that crash-loops.

## Key knobs (shipped defaults)
`model.name` Qwen/Qwen2.5-1.5B-Instruct · `model.maxModelLen` 8192 · `model.gpuMemoryUtilization` 0.90 · `model.dtype` auto · `model.extraArgs` [] · `gpu.type`/`model`/`quantity` builtin/a10g/1 · `resources.cpu`/`memory` 6000m/16Gi · `replicas` 1 · `startupTimeoutSeconds` 900 · `volumeset.capacity` 50 · `apiKey.secretName` my-vllm-api-key (required) · `huggingFace.tokenSecretName` "" · `publicAccess.enabled` false · `internalAccess.type` same-gvc

## Probe design
- Startup window ≈ `initialDelaySeconds + 30 × periodSeconds`; `failureThreshold` does not count. The chart derives `periodSeconds = ceil((startupTimeoutSeconds − 30) / 30)` (29 at the default, 300-1830 allowed → 9-60) with `failureThreshold: 3`, so a hung server leaves rotation after ~90 s. Liveness uses the same numbers and relies on the derived startup probe holding it off during boot (default boot 175-280 s > 117 s; T1 proves it).
- **There is no vLLM boot gate inside the window.** `VLLM_ENGINE_READY_TIMEOUT_S` only bounds the engine's post-load ZMQ handshake at v0.31.0 (`wait_for_engine_startup` has no timeout), so a slow download is bounded only by the platform restart. The env var is not set.

## Validation the API enforces (probed 2026-10-07, mirrored in `vllm.validateGpu`)
- a10g: quantity 1, cpu 6000-8000m, memory ≥ 8Gi. t4: quantity 1-4, cpu ≥ 2000m per GPU, **4000m per GPU when quantity > 1 or memory ≥ 14Gi** (14Gi itself needs 4000m, not "above 14Gi" as the docs say), memory 7-31Gi per GPU. byok quantity 1-8.
- Every workload: memory (MiB) < 8 × cpu (millicores). A byok `1000m/16Gi` is rejected.
- The API's "at most" messages print wrong numbers (t4 9000m → "at most 4000"); trust the limits above. The per-GPU scaling of the t4 maxima (16000m / 62Gi for 2 GPUs) is unproven: the test org's quota (15000m, 32768 MiB per workload) rejects first.

## Troubleshooting / traps
- Deployment waiting with zero logs → API key (or HF token) secret missing; `cpln workload get-deployments … -o yaml` → `status.versions[].message`.
- Crash-loop "Connection reset by peer" at start → egress blocked; the chart always opens outbound (huggingface.co + CDNs).
- Gated model never ready → token missing or the license not accepted on huggingface.co.
- BYOK replica Pending → `resources.cpu` still 6000m; a g5/g6.xlarge has 4 vCPU. Use ~2000m/8Gi.
- BYOK cluster requirements: NVIDIA add-on `taintGPUNodes: false`; GPU pool label `cpln.io/gpuUsageAutoDrain: ignore` (else BYOK drains a GPU node idle 5 min, even one whose GPU pod just landed); x86 driver AMI + label `mk8s.cpln.io/accelerator: nvidia` while the `+nvidia` images resolve to arm64; GPU boot disk ≥ 200 GB (a 100 GB disk hit 91% and the kubelet evicted vLLM); one instance type per GPU pool; on AWS `awsWorkloadIdentity` + `awsELB` and core nodes ≥ 4 vCPU/16 GB. Working spec: `mk8s-clusters/vllm-gpu.yaml`.
- The API stores container `env` sorted by name, so the chart renders it sorted (rendered == stored).
- API key rotation needs a restart; the platform does not re-resolve `cpln://` on a running replica. The spike saw `force-redeployment` NOT restart the stateful GPU pod within 40 s; T19 measures it.
- The API key guards `/v1` only; `/health`, `/metrics`, `/tokenize`, `/detokenize` are open upstream at v0.31.0.
- T4: no bfloat16, no FlashAttention; `dtype: auto` falls back to fp16 with a warning (read in source); the chart refuses `bfloat16` with t4.
