{{/* Resource Naming */}}

{{/*
Advisor Web Workload Name (the dashboard)
*/}}
{{- define "cpln-advisor.web.name" -}}
{{- printf "%s-web" .Release.Name }}
{{- end }}

{{/*
Advisor API Workload Name
*/}}
{{- define "cpln-advisor.api.name" -}}
{{- printf "%s-api" .Release.Name }}
{{- end }}

{{/*
Advisor Worker Workload Name
*/}}
{{- define "cpln-advisor.worker.name" -}}
{{- printf "%s-worker" .Release.Name }}
{{- end }}

{{/*
Advisor Scheduler Workload Name
*/}}
{{- define "cpln-advisor.scheduler.name" -}}
{{- printf "%s-scheduler" .Release.Name }}
{{- end }}

{{/*
Advisor Redis Workload Name
*/}}
{{- define "cpln-advisor.redis.name" -}}
{{- printf "%s-redis" .Release.Name }}
{{- end }}

{{/*
Advisor Identity Name
*/}}
{{- define "cpln-advisor.identity.name" -}}
{{- printf "%s-identity" .Release.Name }}
{{- end }}

{{/*
Advisor Policy Name
*/}}
{{- define "cpln-advisor.policy.name" -}}
{{- printf "%s-policy" .Release.Name }}
{{- end }}

{{/*
Bundled Postgres workload name. The `postgres` subchart names it
`{{ .Release.Name }}-postgres`, and as a subchart that Release.Name is OURS — so
this must track the subchart's own helper. A rename there breaks this silently.
*/}}
{{- define "cpln-advisor.postgres.name" -}}
{{- printf "%s-postgres" .Release.Name }}
{{- end }}

{{/*
Internal address of Redis. Plain redis:// is correct — the sidecar adds mTLS.
*/}}
{{- define "cpln-advisor.redis.url" -}}
{{- printf "redis://%s.%s.cpln.local:6379" (include "cpln-advisor.redis.name" .) .Values.global.cpln.gvc }}
{{- end }}

{{/*
Internal address of the API, on the CONTAINER port (8000), not 443.
*/}}
{{- define "cpln-advisor.api.url" -}}
{{- printf "http://%s.%s.cpln.local:8000" (include "cpln-advisor.api.name" .) .Values.global.cpln.gvc }}
{{- end }}

{{/*
Every credential the advisor reads, by key, out of the ONE prerequisite dictionary
secret. Nothing sensitive passes through values, so nothing sensitive lands in the
Helm release. Key names match the app's own environment variable names.
*/}}
{{- define "cpln-advisor.secretRef" -}}
{{- printf "cpln://secret/%s.%s" .name .key }}
{{- end }}

{{/* Resource ratio guard */}}

{{/*
CPU quantity -> millicores. "250m" -> 250, "1" -> 1000, "0.5" -> 500.
*/}}
{{- define "cpln-advisor.cpu2m" -}}
{{- $v := . | toString -}}
{{- if hasSuffix "m" $v -}}
{{- float64 (trimSuffix "m" $v) -}}
{{- else -}}
{{- mulf (float64 $v) 1000.0 -}}
{{- end -}}
{{- end }}

{{/*
Memory quantity -> Mi. "1Gi" -> 1024, "512Mi" -> 512.
*/}}
{{- define "cpln-advisor.mem2mi" -}}
{{- $v := . | toString -}}
{{- if hasSuffix "Gi" $v -}}
{{- mulf (float64 (trimSuffix "Gi" $v)) 1024.0 -}}
{{- else if hasSuffix "Mi" $v -}}
{{- float64 (trimSuffix "Mi" $v) -}}
{{- else if hasSuffix "G" $v -}}
{{- mulf (float64 (trimSuffix "G" $v)) 1000.0 -}}
{{- else if hasSuffix "M" $v -}}
{{- float64 (trimSuffix "M" $v) -}}
{{- else -}}
{{- float64 $v -}}
{{- end -}}
{{- end }}

{{/*
Guard the two limits Control Plane enforces on containers but publishes in no JSON
schema, so both otherwise surface as a 400 partway through an install:

  1. RATIO. cpu/minCpu must be strictly under 4:1 — that is the API's own wording,
     "The ratio between cpu and minCpu must be less than 4:1". Memory is bounded the
     same way but treated as <= 4:1, because the reference deployment ships the
     dashboard at exactly 128Mi -> 512Mi and it is accepted.
  2. UNITS. `cpu` and `memory` are typed as plain STRINGS with no numeric bound, so
     `512Gi` written for `512Mi` is ACCEPTED and the workload then never schedules.

Only called for workloads that actually set a min; where Capacity AI is off there is
no min and no ratio to check.
Call with (dict "who" "api" "r" .Values.api.resources).
*/}}
{{- define "cpln-advisor.checkResources" -}}
{{- $who := .who -}}
{{- $r := .r -}}
{{- $maxC := float64 (include "cpln-advisor.cpu2m" $r.maxCpu) -}}
{{- $maxM := float64 (include "cpln-advisor.mem2mi" $r.maxMemory) -}}
{{- if gt $maxC 16000.0 -}}
{{- fail (printf "cpln-advisor: %s.resources.maxCpu is %v (%.0f cores) — almost certainly a unit typo. Control Plane types cpu as a bare string with no bound, so it is accepted and the workload then never schedules." $who $r.maxCpu (divf $maxC 1000.0)) -}}
{{- end -}}
{{- if gt $maxM 65536.0 -}}
{{- fail (printf "cpln-advisor: %s.resources.maxMemory is %v (%.0f GiB) — almost certainly a unit typo (Mi written as Gi). Control Plane types memory as a bare string with no bound, so it is accepted and the workload then never schedules." $who $r.maxMemory (divf $maxM 1024.0)) -}}
{{- end -}}
{{- if $r.minCpu -}}
{{- $minC := float64 (include "cpln-advisor.cpu2m" $r.minCpu) -}}
{{- if le $minC 0.0 -}}
{{- fail (printf "cpln-advisor: %s.resources.minCpu must be greater than zero, got %v" $who $r.minCpu) -}}
{{- end -}}
{{- if lt $maxC $minC -}}
{{- fail (printf "cpln-advisor: %s.resources.maxCpu (%v) is below minCpu (%v)" $who $r.maxCpu $r.minCpu) -}}
{{- end -}}
{{- if ge (divf $maxC $minC) 4.0 -}}
{{- fail (printf "cpln-advisor: %s.resources is %v/%v cpu, a %.2f:1 spread. Control Plane requires cpu/minCpu to be UNDER 4:1 and rejects the workload with \"The ratio between cpu and minCpu must be less than 4:1\". Raise minCpu above %.0fm, or lower maxCpu." $who $r.maxCpu $r.minCpu (divf $maxC $minC) (divf $maxC 4.0)) -}}
{{- end -}}
{{- end -}}
{{- if $r.minMemory -}}
{{- $minM := float64 (include "cpln-advisor.mem2mi" $r.minMemory) -}}
{{- if le $minM 0.0 -}}
{{- fail (printf "cpln-advisor: %s.resources.minMemory must be greater than zero, got %v" $who $r.minMemory) -}}
{{- end -}}
{{- if lt $maxM $minM -}}
{{- fail (printf "cpln-advisor: %s.resources.maxMemory (%v) is below minMemory (%v)" $who $r.maxMemory $r.minMemory) -}}
{{- end -}}
{{- if gt (divf $maxM $minM) 4.0 -}}
{{- fail (printf "cpln-advisor: %s.resources is %v/%v memory, a %.2f:1 spread. Control Plane bounds memory/minMemory at 4:1 and rejects the workload. Raise minMemory to at least %.0fMi, or lower maxMemory." $who $r.maxMemory $r.minMemory (divf $maxM $minM) (divf $maxM 4.0)) -}}
{{- end -}}
{{- end -}}
{{- end }}


{{/* Validation */}}{{/* Validation */}}

{{- define "cpln-advisor.validate" -}}
{{- if not .Values.global.cpln.gvc -}}
{{- fail "cpln-advisor: global.cpln.gvc is required — the name of the GVC this chart creates, e.g. 'advisor'. It lives under `global` so cpln-common tags every resource with it, and so a subchart would inherit it." -}}
{{- end -}}
{{- if not .Values.gvc.locations -}}
{{- fail "cpln-advisor: gvc.locations must contain exactly one location, e.g. `locations:` / `  - name: aws-us-east-1`. Run `cpln location get` to list the ones available to your org." -}}
{{- end -}}
{{- if ne (len .Values.gvc.locations) 1 -}}
{{- fail (printf "cpln-advisor: gvc.locations must contain EXACTLY ONE location, got %d. A workload runs in every location of its GVC and minScale/maxScale are per-location, so a second location silently doubles the API, worker and scheduler — a second scheduler would fire every cron twice. The bundled Postgres is a single stateful workload on a read-write-once volume, so a second location would also give it a second, independent database rather than a replica." (len .Values.gvc.locations)) -}}
{{- end -}}
{{- range .Values.gvc.locations -}}
{{- if not .name -}}
{{- fail "cpln-advisor: every entry in gvc.locations needs a `name`, e.g. `- name: aws-us-east-1`" -}}
{{- end -}}
{{- end -}}
{{- if not .Values.auth.secretName -}}
{{- fail "cpln-advisor: auth.secretName is required — the name of a `dictionary` secret that MUST EXIST BEFORE INSTALL, holding the keys ADVISOR_API_TOKEN, ADVISOR_SECRET_KEY, ADVISOR_SESSION_SECRET, ADVISOR_USERNAME, ADVISOR_PASSWORD and DATABASE_URL. This chart creates no secret and accepts no credential as a value. See README Prerequisites." -}}
{{- end -}}
{{- if and .Values.appUrl (not (or (hasPrefix "http://" .Values.appUrl) (hasPrefix "https://" .Values.appUrl))) -}}
{{- fail (printf "cpln-advisor: appUrl must be a full URL including the scheme, e.g. https://advisor.example.com, got '%s'" .Values.appUrl) -}}
{{- end -}}
{{- if eq .Values.appUrl "*" -}}
{{- fail "cpln-advisor: appUrl must not be '*' — it becomes the CORS allowlist, and a wildcard combined with credentials makes the API echo back whichever origin asked" -}}
{{- end -}}
{{- range $who := (list "web" "api" "worker" "scheduler" "redis" "postgres") -}}
{{- include "cpln-advisor.checkResources" (dict "who" $who "r" (get $.Values $who).resources) -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "cpln-advisor.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "cpln-advisor.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}

{{- define "cpln-advisor.selectorLabels" -}}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- end }}
