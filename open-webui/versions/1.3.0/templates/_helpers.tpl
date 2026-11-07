{{/* Resource Naming */}}

{{/*
Open WebUI Workload Name
*/}}
{{- define "open-webui.name" -}}
{{- printf "%s-open-webui" .Release.Name }}
{{- end }}

{{/*
Open WebUI Volumeset Name
*/}}
{{- define "open-webui.volume.name" -}}
{{- printf "%s-open-webui-data" .Release.Name }}
{{- end }}

{{/*
Start Script Secret Name
*/}}
{{- define "open-webui.secretStart.name" -}}
{{- printf "%s-open-webui-start" .Release.Name }}
{{- end }}

{{/*
Open WebUI Identity Name
*/}}
{{- define "open-webui.identity.name" -}}
{{- printf "%s-open-webui-identity" .Release.Name }}
{{- end }}

{{/*
Open WebUI Policy Name
*/}}
{{- define "open-webui.policy.name" -}}
{{- printf "%s-open-webui-policy" .Release.Name }}
{{- end }}


{{/* Validation */}}

{{- define "open-webui.validate" -}}
{{- include "open-webui.validateResourceKnobs" . -}}
{{- if not (has .Values.internalAccess.type (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "open-webui: internalAccess.type must be 'none', 'same-gvc', 'same-org', or 'workload-list', got '%s'" .Values.internalAccess.type) -}}
{{- end -}}
{{- if lt (int .Values.volumeset.capacity) 10 -}}
{{- fail (printf "open-webui: volumeset.capacity must be at least 10 (GiB, platform minimum), got '%v'" .Values.volumeset.capacity) -}}
{{- end -}}
{{- if .Values.customDomain -}}
{{- if not (or (hasPrefix "https://" .Values.customDomain) (hasPrefix "http://" .Values.customDomain)) -}}
{{- fail (printf "open-webui: customDomain must be a full URL including the scheme, e.g. https://chat.example.com — got '%s'. It sets WEBUI_URL and does not create a cpln domain; create that separately." .Values.customDomain) -}}
{{- end -}}
{{- end -}}
{{- if hasKey .Values.auth "webuiSecretKey" -}}
{{- fail "open-webui: auth.webuiSecretKey was removed in 1.1.0 — the session/JWT signing key is now a prerequisite opaque secret (encoding: plain) you create before install; set auth.secretKeyName to its name instead" -}}
{{- end -}}
{{- if not .Values.auth.secretKeyName -}}
{{- fail "open-webui: auth.secretKeyName is required — it names the prerequisite opaque secret (encoding: plain) holding the session/JWT signing key, which must exist BEFORE install and stay the same forever" -}}
{{- end -}}
{{- if .Values.backup.enabled -}}
{{- /* The platform rejects snapshot schedules more frequent than hourly at apply time only,
       leaving a half-installed release; a single fixed minute runs at most hourly. */ -}}
{{- if not (regexMatch "^[0-5]?[0-9] +[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+$" (trim (toString .Values.backup.schedule))) -}}
{{- fail (printf "open-webui: backup.schedule %q must be a 5-field cron with a single fixed minute (snapshots cannot run more often than hourly), e.g. \"0 3 * * *\"" (toString .Values.backup.schedule)) -}}
{{- end -}}
{{- end -}}
{{- if hasKey .Values.auth "enableSignup" -}}
{{- fail "open-webui: auth.enableSignup was removed in 1.3.0 — the admin account is now created from admin.secretName at first boot and sign-up is turned off then; open self-service sign-up from Settings → Admin → Authentication (New Sign Ups) instead. Remove auth.enableSignup from your values." -}}
{{- end -}}
{{- if not (.Values.admin).secretName -}}
{{- fail "open-webui: admin.secretName is required — it names the prerequisite dictionary secret (keys: email, password) holding the admin account, which must exist BEFORE install" -}}
{{- end -}}
{{- if and .Values.ollama.enabled (not .Values.ollama.workloadName) -}}
{{- fail "open-webui: ollama.workloadName is required when ollama.enabled is true — the in-GVC ollama workload to connect to" -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Common tags
*/}}
{{- define "open-webui.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}

{{/*
Reject the pre-rename bare cpu/memory keys. Left unguarded they are silently
ignored and the chart falls back to its own default limit — wrong resources
with no signal.
*/}}
{{- define "open-webui.validateResourceKnobs" -}}
{{- if (.Values.resources).cpu -}}
{{- fail "open-webui: resources.cpu was RENAMED to resources.maxCpu. A block exposing both a reservation and a limit names the limit maxCpu/maxMemory, so the bare name is no longer read and would be silently ignored. Rename it in your values." -}}
{{- end -}}
{{- if (.Values.resources).memory -}}
{{- fail "open-webui: resources.memory was RENAMED to resources.maxMemory. A block exposing both a reservation and a limit names the limit maxCpu/maxMemory, so the bare name is no longer read and would be silently ignored. Rename it in your values." -}}
{{- end -}}
{{- end -}}

{{/* The Control Plane MCP tool-server connection (Open WebUI v0.11 TOOL_SERVER_CONNECTIONS schema). */}}
{{- define "open-webui.cplnMcpConnection" -}}
{{- $info := dict "id" "cpln" "name" "Control Plane" "description" "Manage your Control Plane org: workloads, GVCs, secrets, logs and more" -}}
{{- dict "type" "mcp" "url" "https://mcp.cpln.io/mcp" "path" "" "auth_type" "oauth_2.1" "key" "" "config" (dict "enable" true) "info" $info | toJson -}}
{{- end }}
