{{- define "cassandra.name" -}}
{{- default "cassandra" .Values.global.cpln.workloadName | trunc 63 | trimSuffix "-" }}
{{- end }}

{{- define "cassandra.tags" -}}
{{- if .Values.global.cpln.tags }}
{{- toYaml .Values.global.cpln.tags }}
{{- end }}
{{- end }}
