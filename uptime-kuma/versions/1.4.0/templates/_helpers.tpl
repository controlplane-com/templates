{{/* Resource Naming */}}

{{/*
Uptime Kuma Workload Name
*/}}
{{- define "uptime-kuma.name" -}}
{{- printf "%s-uptime-kuma" .Release.Name }}
{{- end }}

{{/*
Uptime Kuma Volumeset Name
*/}}
{{- define "uptime-kuma.volume.name" -}}
{{- printf "%s-uptime-kuma-data" .Release.Name }}
{{- end }}

{{/*
Uptime Kuma Identity Name
*/}}
{{- define "uptime-kuma.identity.name" -}}
{{- printf "%s-uptime-kuma-identity" .Release.Name }}
{{- end }}


{{/* Validation */}}

{{- define "uptime-kuma.validate" -}}
{{- include "uptime-kuma.validateResourceKnobs" . -}}
{{- include "uptime-kuma.validateImage" . -}}
{{- if not (has .Values.internalAccess.type (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "uptime-kuma: internalAccess.type must be 'none', 'same-gvc', 'same-org', or 'workload-list', got '%s'" .Values.internalAccess.type) -}}
{{- end -}}
{{- if lt (int .Values.volumeset.capacity) 10 -}}
{{- fail (printf "uptime-kuma: volumeset.capacity must be at least 10 (GiB, platform minimum), got '%v'" .Values.volumeset.capacity) -}}
{{- end -}}
{{- end }}


{{/*
Refuse an official Uptime Kuma tag older than 2.5.8 (every 1.x tag, and 2.x
below 2.5.8). The wizard stores image in the release values, so a helm upgrade
-f with those values would otherwise keep the vulnerable image silently. Other
registries, digests and non-version tags (2, latest, next, nightly) pass. The
suggested tag keeps a -slim / -rootless / -slim-rootless variant.
*/}}
{{- define "uptime-kuma.validateImage" -}}
{{- $raw := .Values.image | default "" | toString -}}
{{- $image := trimPrefix "docker.io/" $raw -}}
{{- $prefix := "louislam/uptime-kuma:" -}}
{{- if hasPrefix $prefix $image -}}
{{- $tag := trimPrefix $prefix $image -}}
{{- $ver := regexFind "^2\\.[0-9]+\\.[0-9]+" $tag -}}
{{- if or (regexMatch "^1([.-]|$)" $tag) (and $ver (semverCompare "<2.5.8" $ver)) -}}
{{- $variant := regexFind "-(slim-rootless|slim|rootless)$" $tag -}}
{{- fail (printf "uptime-kuma: image %s is older than Uptime Kuma 2.5.8, which fixes an admin remote-code-execution flaw (GHSA-v2p3-6f5h-6hhf) and Critical CVEs in the image. Set image to louislam/uptime-kuma:2.5.8%s, or remove `image` from your values to use the chart default." $raw $variant) -}}
{{- end -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Common tags
*/}}
{{- define "uptime-kuma.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}

{{/*
Reject the pre-rename bare cpu/memory keys. Left unguarded they are silently
ignored and the chart falls back to its own default limit — wrong resources
with no signal.
*/}}
{{- define "uptime-kuma.validateResourceKnobs" -}}
{{- if (.Values.resources).cpu -}}
{{- fail "uptime-kuma: resources.cpu was RENAMED to resources.maxCpu. A block exposing both a reservation and a limit names the limit maxCpu/maxMemory, so the bare name is no longer read and would be silently ignored. Rename it in your values." -}}
{{- end -}}
{{- if (.Values.resources).memory -}}
{{- fail "uptime-kuma: resources.memory was RENAMED to resources.maxMemory. A block exposing both a reservation and a limit names the limit maxCpu/maxMemory, so the bare name is no longer read and would be silently ignored. Rename it in your values." -}}
{{- end -}}
{{- end -}}
