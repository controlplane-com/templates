{{- define "sequence" -}}
{{- $count := int . -}}
{{- $seq := list -}}
{{- range $i := until $count }}
  {{- $seq = append $seq $i -}}
{{- end }}
{{- $seq -}}
{{- end }}