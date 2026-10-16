# vLLM — Maintainer Briefing

## What it is
- vLLM: high-throughput LLM inference server (PagedAttention, continuous batching) with an OpenAI-compatible API. **Apache-2.0** (permissive open-source license; nothing for us or users to do).
- Official image `vllm/vllm-openai:v0.31.0` (CUDA 13, needs NVIDIA driver ≥ 580). Measured 2026-10-07: built-in A10G and T4 in aws-us-west-2 run driver 580.159.03; the MK8s DLAMI node 595.91.07. **Do NOT use `-cu129`:** at v0.31.0 it bundles a CUDA-13 torchcodec and crashes on import (`libnvrtc.so.13`, upstream vllm#60406) — every install crash-loops. The image runs as root, so no `filesystemGroupId`.
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
- Availability: `replicas: 1` (default, per the simple-shape ruling; GPU cost dominates) = the API is down for every restart/upgrade boot (~2.5 min measured). `replicas: 2` measured zero failed requests on built-in A10G×2 through scale-up (401/401), a rolling restart (376/376) and one replica stopped (325/325). No clustering needed.
- `gvc` limited to exactly one location (wizard): N locations = N copies × N GPUs, and a BYOK GVC with a Control Plane location runs a GPU-less copy that crash-loops.

## Key knobs (shipped defaults)
`model.name` Qwen/Qwen2.5-1.5B-Instruct · `model.maxModelLen` 8192 · `model.gpuMemoryUtilization` 0.90 · `model.dtype` auto · `model.toolCallParser` hermes · `model.extraArgs` [] · `gpu.type`/`model`/`quantity` builtin/a10g/1 · `resources.cpu`/`memory` 6000m/16Gi · `replicas` 1 · `startupTimeoutSeconds` 900 · `volumeset.capacity` 50 · `apiKey.secretName` my-vllm-api-key (required) · `huggingFace.tokenSecretName` "" · `publicAccess.enabled` false · `internalAccess.type` same-gvc

## Probe design
- Startup window ≈ `initialDelaySeconds + 30 × periodSeconds`; `failureThreshold` does not count. The chart derives `periodSeconds = ceil((startupTimeoutSeconds − 30) / 30)` (29 at the default, 300-1830 allowed → 9-60) with `failureThreshold: 3`, so a hung server leaves rotation after ~90 s. Liveness uses the same numbers; the platform's derived startup probe holds it off during boot — measured: 164 s and 340 s boots with zero restarts, and `startupTimeoutSeconds: 300` with a cold 7B was killed at ~338 s.
- **There is no vLLM boot gate inside the window.** `VLLM_ENGINE_READY_TIMEOUT_S` only bounds the engine's post-load ZMQ handshake at v0.31.0 (`wait_for_engine_startup` has no timeout), so a slow download is bounded only by the platform restart. The env var is not set.

## Validation the API enforces (probed 2026-10-07, mirrored in `vllm.validateGpu`)
- a10g: quantity 1, cpu 6000-8000m, memory ≥ 8Gi. t4: quantity 1-4, cpu ≥ 2000m per GPU, **4000m per GPU when quantity > 1 or memory ≥ 14Gi** (14Gi itself needs 4000m, not "above 14Gi" as the docs say), memory 7-31Gi per GPU. byok quantity 1-8.
- Every workload: memory (MiB) < 8 × cpu (millicores). A byok `1000m/16Gi` is rejected.
- The API's "at most" messages print wrong numbers (t4 9000m → "at most 4000"); trust the limits above. The per-GPU scaling of the t4 maxima (16000m / 62Gi for 2 GPUs) is unproven: the test org's quota (15000m, 32768 MiB per workload) rejects first.

## Troubleshooting / traps
- Deployment waiting with zero logs → API key (or HF token) secret missing; `cpln workload get-deployments … -o yaml` → `status.versions[].message`.
- Crash-loop "Connection reset by peer" at start → egress blocked; the chart always opens outbound (huggingface.co + CDNs).
- Gated model crash-loops (exit 1; deployment message says nothing about HF) → `cpln logs` shows `GatedRepoError`: 401 = no token, 403 "not in the authorized list" = the license was not accepted by the account that owns the token. Proven 2026-10-08 with gemma-2-2b-it on built-in A10G (43 s download, ready ~5 min from container start).
- BYOK replica Pending → `resources.cpu` still 6000m; a g5/g6.xlarge has 4 vCPU. Use ~2000m/8Gi.
- BYOK cluster requirements: NVIDIA add-on `taintGPUNodes: false`; GPU pool label `cpln.io/gpuUsageAutoDrain: ignore` (else BYOK drains a GPU node idle 5 min, even one whose GPU pod just landed); x86 driver AMI + label `mk8s.cpln.io/accelerator: nvidia` while the `+nvidia` images resolve to arm64; GPU boot disk ≥ 200 GB (a 100 GB disk hit 91% and the kubelet evicted vLLM); one instance type per GPU pool; on AWS `awsWorkloadIdentity` + `awsELB` and core nodes ≥ 4 vCPU/16 GB. Working spec: `mk8s-clusters/vllm-gpu.yaml`.
- **BYOK portability (spikes 2026-10-15/16, stock 1.0.0 with `gpu.type: byok`, all passed chat/401/public-endpoint checks):** the hardcoded `runtimeClass: nvidia` is the main portability cost — its handler is `nvidia` on EKS, `runc` on GKE, `nvidia-container-runtime` on AKS, built in on MK8s (AWS, GCP). **vllm 1.1 candidate: make `runtimeClass` a knob.** Per cluster:
  - MK8s GCP (g2-standard-4 L4): no workarounds; DLVM `common-cu129-ubuntu-2404-nvidia-580` via `overrideImage.family`; GCP pools have no accelerator field, so built-in-GPU machine types only (no T4).
  - EKS (g5.xlarge): RuntimeClass + AWS Load Balancer Controller (BYOK ingress asks for an `external` NLB); Helm needed `--disable-openapi-validation` after BYOK.
  - GKE (n1 + T4): RuntimeClass → `runc` + actuator restart (it caches RuntimeClasses); BYOK classes are Hyperdisk-only, which N1 cannot attach → `byok.noDefaultStorageClasses: true` + own pd-balanced class; first BYOK install deadlocked (Istio Telemetry before its CRD) → restart `cpln-byok-agent`.
  - AKS (NC4as_T4_v3): driver 580 via `--gpu-driver Install` but no device plugin (install nvdp + label `nvidia.com/gpu.present=true`); BYOK classes are PremiumV2_LRS → GPU pool must be zonal; ready 766 s.
  - MK8s Azure: FAILED on platform bugs (custom-image GPU pool silently never created; stock image has no driver; kubectl forbidden for superusers). Write-up for the platform team kept outside the repo.
- **Open WebUI (and agent clients) need tool calling.** Open WebUI sends `tool_choice: auto` on every chat; without `--enable-auto-tool-choice --tool-call-parser` vLLM rejects each message (`"auto" tool choice requires --enable-auto-tool-choice and --tool-call-parser to be set`). Found 2026-10-13 by the maintainer pairing it with open-webui 1.2.0; hence `model.toolCallParser` (default `hermes`, matching the default Qwen). The parser is model-family specific (`llama3_json`, `mistral`, …); only `hermes` with Qwen2.5 1.5B/7B is measured.
- **Longer context with YaRN (Qwen2.5-7B to 64k, 2026-10-15)**: open-webui's Control Plane tools need ~56k tokens. `model.maxModelLen: 65536` plus `extraArgs: [--hf-overrides, '{"max_position_embeddings":65536,"rope_parameters":{"rope_type":"yarn","factor":2.0,"original_max_position_embeddings":32768,"rope_theta":1000000.0}}']`. At v0.31.0 the old `rope_scaling` key is ignored and `rope_parameters` alone still derives 32768 (`User-specified max_model_len (65536) is greater than the derived max_model_len`); `max_position_embeddings` is what clears it. Never `VLLM_ALLOW_LONG_MAX_MODEL_LEN`, which skips the check without scaling. On an A10G at 0.90 the KV cache held 76,592 tokens (1.17x concurrency at 64k).
- The API stores container `env` sorted by name, so the chart renders it sorted (rendered == stored).
- API key rotation needs a restart; the platform does not re-resolve `cpln://` on a running replica. `cpln workload force-redeployment` DOES restart the stateful GPU pod (T19): old container gone after 60-90 s, new key live ~4 min after the call, API down ~2.5 min at 1 replica. (The 2026-10-07 spike's 40 s observation was just too short.) `cpln workload replica stop` also works.
- The API key guards `/v1` only; `/health`, `/metrics`, `/tokenize`, `/detokenize` are open upstream at v0.31.0.
- T4: no bfloat16, no FlashAttention; `dtype: auto` falls back to fp16 with a warning (read in source); the chart refuses `bfloat16` with t4.
- `gpu.quantity > 1` (tensor parallel) needs more than the 64 MiB `/dev/shm` every tested location gives; the chart mounts `scratch://shm` at `/dev/shm` only then. TP=2 on 2× T4 served (aws-us-east-1 — no 2-GPU T4 node came up in aws-us-west-2 in 23 min); throughput under load not measured.
- A single T4 at 4000m/16Gi never scheduled in aws-us-west-2 although the API accepts it; 3000m/12Gi was ready in ~8 min. The README and wizard (info rule) say so; the chart does not block it (capacity, not a validated limit).
- `volumeset.capacity` only sizes NEW volumes; a live volume is grown online with `cpln volumeset expand {release}-vllm-models --location L --volume-index N --new-size X` (no restart, weights kept).
- Freeing an old model: `hf cache rm model/ORG/NAME -y` (freed 15.2 G); `rm -rf .../hub/models--ORG--NAME` frees nothing because the weights live in the shared `hub/blobs/` store.
- BYOK only: `cpln port-forward` returns `502 Unable to connect to upstream workload` with `internalAccess: none` (works with `same-gvc`, and on built-in with `none`). Unexplained; README tells users.
- Public access works on both targets; on BYOK the traffic goes through the cluster's own Istio ingress load balancer.
