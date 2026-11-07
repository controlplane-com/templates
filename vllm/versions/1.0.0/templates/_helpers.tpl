{{/* Resource Naming */}}

{{- define "vllm.name" -}}
{{- printf "%s-vllm" .Release.Name }}
{{- end }}

{{- define "vllm.volume.name" -}}
{{- printf "%s-vllm-models" .Release.Name }}
{{- end }}

{{- define "vllm.identity.name" -}}
{{- printf "%s-vllm-identity" .Release.Name }}
{{- end }}

{{- define "vllm.policy.name" -}}
{{- printf "%s-vllm-policy" .Release.Name }}
{{- end }}


{{/* Labeling */}}

{{- define "vllm.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}


{{/*
Probe timing. The platform derives a startup probe from the readiness probe and
restarts a container that has never been ready after about
initialDelaySeconds + 30 x periodSeconds; failureThreshold does not count toward
that window (CLAUDE.md platform-limits table, measured 2026-10-03). So the boot
budget is bought with periodSeconds, and failureThreshold stays small: it is how
long a hung server stays in rotation (3 x periodSeconds).
*/}}
{{- define "vllm.probe.initialDelaySeconds" -}}30{{- end }}

{{- define "vllm.probe.periodSeconds" -}}
{{- $budget := sub (int .Values.startupTimeoutSeconds) 30 -}}
{{- div (add $budget 29) 30 -}}
{{- end }}


{{/* Quantity parsing (for the GPU minimums the API enforces at apply time) */}}

{{- define "vllm.cpuMillicores" -}}
{{- $v := toString . -}}
{{- if hasSuffix "m" $v -}}
{{- trimSuffix "m" $v | int -}}
{{- else -}}
{{- mulf (float64 $v) 1000 | int -}}
{{- end -}}
{{- end }}

{{- define "vllm.memoryMi" -}}
{{- $v := toString . -}}
{{- $num := regexFind "^[0-9]+(\\.[0-9]+)?" $v -}}
{{- $unit := trimPrefix $num $v -}}
{{- $factors := dict "" 0.00000095367431640625 "Ki" 0.0009765625 "Mi" 1.0 "Gi" 1024.0 "Ti" 1048576.0 "K" 0.000953674316 "M" 0.953674316 "G" 953.674316 "T" 953674.316 -}}
{{- if not $num -}}
{{- fail (printf "vllm: resources.memory must be a memory quantity such as 16Gi, got '%s'" $v) -}}
{{- end -}}
{{- if not (hasKey $factors $unit) -}}
{{- fail (printf "vllm: resources.memory must be bytes or use a unit (Ki, Mi, Gi, Ti, K, M, G, T), got '%s'" $v) -}}
{{- end -}}
{{- mulf (float64 $num) (get $factors $unit) | int -}}
{{- end }}


{{/* Validation — every define below is mirrored by a wizard.yaml rule */}}

{{- define "vllm.validate" -}}
{{- include "vllm.validateCredentials" . -}}
{{- include "vllm.validateModel" . -}}
{{- include "vllm.validateGpu" . -}}
{{- include "vllm.validateScale" . -}}
{{- include "vllm.validateStorage" . -}}
{{- include "vllm.validateAccess" . -}}
{{- end }}

{{- define "vllm.validateCredentials" -}}
{{- if not .Values.apiKey.secretName -}}
{{- fail "vllm: apiKey.secretName is required — it names the prerequisite opaque secret (encoding: plain) holding the API key, which must exist BEFORE install" -}}
{{- end -}}
{{- end }}

{{- define "vllm.validateModel" -}}
{{- if not .Values.model.name -}}
{{- fail "vllm: model.name is required — a Hugging Face model id such as Qwen/Qwen2.5-1.5B-Instruct" -}}
{{- end -}}
{{- if lt (int .Values.model.maxModelLen) 256 -}}
{{- fail (printf "vllm: model.maxModelLen must be at least 256, got '%v'" .Values.model.maxModelLen) -}}
{{- end -}}
{{- $util := float64 .Values.model.gpuMemoryUtilization -}}
{{- if or (le $util 0.0) (gt $util 1.0) -}}
{{- fail (printf "vllm: model.gpuMemoryUtilization must be above 0 and at most 1, got '%v'" .Values.model.gpuMemoryUtilization) -}}
{{- end -}}
{{- if not (has .Values.model.dtype (list "auto" "half" "bfloat16" "float32")) -}}
{{- fail (printf "vllm: model.dtype must be 'auto', 'half', 'bfloat16' or 'float32', got '%v'" .Values.model.dtype) -}}
{{- end -}}
{{- if and (eq .Values.gpu.type "builtin") (eq .Values.gpu.model "t4") (eq .Values.model.dtype "bfloat16") -}}
{{- fail "vllm: model.dtype bfloat16 is not supported on a T4 (a pre-Ampere card); use auto or half" -}}
{{- end -}}
{{- $owned := list "--port" "--host" "--model" "--api-key" "--served-model-name" "--max-model-len" "--gpu-memory-utilization" "--dtype" "--tensor-parallel-size" "-tp" "--enable-auto-tool-choice" "--tool-call-parser" -}}
{{- range .Values.model.extraArgs -}}
{{- $arg := toString . -}}
{{- range $owned -}}
{{- if or (eq $arg .) (hasPrefix (printf "%s=" .) $arg) -}}
{{- fail (printf "vllm: model.extraArgs must not set %s — the chart sets it from its own values (model.*, gpu.quantity, the API key secret)" .) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end }}

{{- define "vllm.validateGpu" -}}
{{- $q := int .Values.gpu.quantity -}}
{{- if ge (int (include "vllm.memoryMi" .Values.resources.memory)) (mul 8 (int (include "vllm.cpuMillicores" .Values.resources.cpu))) -}}
{{- fail (printf "vllm: resources.memory must be less than 8 MiB per millicore of resources.cpu (the platform rejects a higher ratio), got cpu '%v' and memory '%v'" .Values.resources.cpu .Values.resources.memory) -}}
{{- end -}}
{{- if not (has .Values.gpu.type (list "builtin" "byok")) -}}
{{- fail (printf "vllm: gpu.type must be 'builtin' or 'byok', got '%v'" .Values.gpu.type) -}}
{{- end -}}
{{- if eq .Values.gpu.type "byok" -}}
{{- if or (lt $q 1) (gt $q 8) -}}
{{- fail (printf "vllm: gpu.quantity must be 1 to 8 with gpu.type byok, got '%v'" .Values.gpu.quantity) -}}
{{- end -}}
{{- else -}}
{{- $cpu := int (include "vllm.cpuMillicores" .Values.resources.cpu) -}}
{{- $mem := int (include "vllm.memoryMi" .Values.resources.memory) -}}
{{- if eq .Values.gpu.model "a10g" -}}
{{- if ne $q 1 -}}
{{- fail (printf "vllm: gpu.quantity must be 1 with gpu.model a10g, got '%v'" .Values.gpu.quantity) -}}
{{- end -}}
{{- if or (lt $cpu 6000) (gt $cpu 8000) -}}
{{- fail (printf "vllm: resources.cpu must be 6000m to 8000m with an A10G, got '%v'" .Values.resources.cpu) -}}
{{- end -}}
{{- if or (lt $mem 8192) (gt $mem 63488) -}}
{{- fail (printf "vllm: resources.memory must be 8Gi to 62Gi with an A10G, got '%v'" .Values.resources.memory) -}}
{{- end -}}
{{- else if eq .Values.gpu.model "t4" -}}
{{- if or (lt $q 1) (gt $q 4) -}}
{{- fail (printf "vllm: gpu.quantity must be 1 to 4 with gpu.model t4, got '%v'" .Values.gpu.quantity) -}}
{{- end -}}
{{- $minCpuPerGpu := 2000 -}}
{{- if or (gt $q 1) (ge $mem 14336) -}}{{- $minCpuPerGpu = 4000 -}}{{- end -}}
{{- if or (lt $cpu (mul $minCpuPerGpu $q)) (gt $cpu (mul 8000 $q)) -}}
{{- fail (printf "vllm: resources.cpu must be %dm to %dm with %d T4 GPU(s) and %v of memory, got '%v'" (mul $minCpuPerGpu $q) (mul 8000 $q) $q .Values.resources.memory .Values.resources.cpu) -}}
{{- end -}}
{{- if or (lt $mem (mul 7168 $q)) (gt $mem (mul 31744 $q)) -}}
{{- fail (printf "vllm: resources.memory must be %dGi to %dGi with %d T4 GPU(s), got '%v'" (mul 7 $q) (mul 31 $q) $q .Values.resources.memory) -}}
{{- end -}}
{{- else -}}
{{- fail (printf "vllm: gpu.model must be 'a10g' or 't4' with gpu.type builtin, got '%v'" .Values.gpu.model) -}}
{{- end -}}
{{- end -}}
{{- end }}

{{- define "vllm.validateScale" -}}
{{- if lt (int .Values.replicas) 1 -}}
{{- fail (printf "vllm: replicas must be at least 1, got '%v'" .Values.replicas) -}}
{{- end -}}
{{- $t := int .Values.startupTimeoutSeconds -}}
{{- if or (lt $t 300) (gt $t 1830) -}}
{{- fail (printf "vllm: startupTimeoutSeconds must be 300 to 1830 (the probe period is capped at 60 s, and the startup window is 30 + 30 x period), got '%v'" .Values.startupTimeoutSeconds) -}}
{{- end -}}
{{- end }}

{{- define "vllm.validateStorage" -}}
{{- if lt (int .Values.volumeset.capacity) 10 -}}
{{- fail (printf "vllm: volumeset.capacity must be at least 10 (GiB, platform minimum), got '%v'" .Values.volumeset.capacity) -}}
{{- end -}}
{{- end }}

{{- define "vllm.validateAccess" -}}
{{- if not (has .Values.internalAccess.type (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "vllm: internalAccess.type must be 'none', 'same-gvc', 'same-org' or 'workload-list', got '%v'" .Values.internalAccess.type) -}}
{{- end -}}
{{- end }}
