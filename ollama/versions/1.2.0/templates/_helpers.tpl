{{/* Resource Naming */}}

{{/*
Ollama Workload Name
*/}}
{{- define "ollama.name" -}}
{{- printf "%s-ollama" .Release.Name }}
{{- end }}

{{/*
Ollama Secret Entrypoint Name
*/}}
{{- define "ollama.secret.name" -}}
{{- printf "%s-ollama-secret" .Release.Name }}
{{- end }}

{{/*
Ollama Identity Name
*/}}
{{- define "ollama.identity.name" -}}
{{- printf "%s-ollama-identity" .Release.Name }}
{{- end }}

{{/*
Ollama Policy Name
*/}}
{{- define "ollama.policy.name" -}}
{{- printf "%s-ollama-policy" .Release.Name }}
{{- end }}

{{/*
Ollama Volume Set Name
*/}}
{{- define "ollama.volume.name" -}}
{{- printf "%s-ollama-vs" .Release.Name }}
{{- end }}


{{/* Labeling */}}

{{/*
Common labels
*/}}
{{- define "ollama.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}

{{/* Validation */}}

{{/*
Validate values - included once from workload.yaml.
*/}}
{{- define "ollama.validate" -}}
{{- include "ollama.validateImage" . -}}
{{- end }}

{{/*
Validate the Open WebUI image - refuse an official Open WebUI tag older than
v0.12.4, whose images carry Critical CVEs. Values stored by an earlier install
(the wizard stores the image) would otherwise keep the vulnerable image through
a helm upgrade -f. Matches ghcr.io/open-webui/open-webui and its Docker Hub
mirror openwebui/open-webui; a minor-only tag (0.11) counts as that minor's
latest patch. Other registries, digests and non-version tags (main) pass.
*/}}
{{- define "ollama.validateImage" -}}
{{- $raw := .Values.workload.containers.ui.image | default "" | toString -}}
{{- $image := trimPrefix "docker.io/" $raw -}}
{{- if not (contains "@" $image) -}}
{{- $parts := splitn ":" 2 $image -}}
{{- if and (has $parts._0 (list "ghcr.io/open-webui/open-webui" "openwebui/open-webui")) $parts._1 -}}
{{- $ver := trimPrefix "v" (regexFind "^v?[0-9]+\\.[0-9]+(\\.[0-9]+)?" $parts._1) -}}
{{- if regexMatch "^[0-9]+\\.[0-9]+$" $ver -}}
{{- $ver = printf "%s.9999" $ver -}}
{{- end -}}
{{- if and $ver (semverCompare "<0.12.4" $ver) -}}
{{- fail (printf "ollama: workload.containers.ui.image %s runs Open WebUI older than v0.12.4, whose images carry Critical CVEs. Set workload.containers.ui.image to ghcr.io/open-webui/open-webui:v0.12.4 or a newer tag, or remove it from your values to use the chart default." $raw) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end }}
