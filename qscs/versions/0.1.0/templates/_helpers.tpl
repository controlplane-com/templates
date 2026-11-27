{{- define "qscs.node" -}}{{ printf "%s-qscs" .Release.Name }}{{- end -}}
{{- define "qscs.volume" -}}{{ printf "%s-state" .Release.Name }}{{- end -}}
{{- define "qscs.gvc" -}}
{{- $catalog := dig "global" "cpln" "gvc" "" .Values.AsMap -}}
{{- $cli := dig "cpln" "gvc" "" .Values.AsMap -}}
{{- if and $catalog $cli (ne $catalog $cli) }}{{ fail "The selected GVC and global.cpln.gvc disagree" }}{{ end -}}
{{- default $cli $catalog -}}
{{- end -}}
{{- define "qscs.tags" -}}
cpln/marketplace: "true"
cpln/marketplace-template: {{ .Chart.Name | quote }}
cpln/marketplace-template-version: {{ .Chart.Version | quote }}
cpln/marketplace-gvc: {{ include "qscs.gvc" . | quote }}
{{- end -}}
{{- define "qscs.validate" -}}
{{- if gt (len (include "qscs.node" .)) 49 }}{{ fail "Release names must be at most 44 characters" }}{{ end -}}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?$" (include "qscs.gvc" .)) }}{{ fail "Select a GVC or pass --gvc to cpln helm" }}{{ end -}}
{{- $authority := "(\\[[0-9A-Fa-f:]+\\]|[A-Za-z0-9.-]+)(:[0-9]{1,5})?" -}}
{{- if not (regexMatch (printf "^(https?://%s/?|%s)$" $authority $authority) .Values.origin) }}{{ fail "origin must be an HTTP(S) URL or a bare hostname/IP with an optional port, without credentials, path prefix, query or fragment" }}{{ end -}}
{{- end -}}
