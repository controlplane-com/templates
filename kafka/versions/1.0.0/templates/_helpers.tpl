{{/*
Name
*/}}
{{- define "kafka.name" -}}
{{- printf "%s" .Release.Name -}}
{{- end }}

{{/*
Cluster Workload Name
*/}}
{{- define "kafka.clusterName" -}}
{{- printf "%s-%s" (include "kafka.name" .) .Values.kafka.name -}}
{{- end }}

{{/*
Convert .Values.kafka.memory to appropriate JVM heap size settings.
*/}}
{{- define "kafka.heap.opts" -}}
{{- $memory := default "512Mi" .Values.kafka.memory }}
{{- $memoryInMi := 0 }}
{{- if hasSuffix "Gi" $memory }}
  {{- $value := trimSuffix "Gi" $memory | float64 }}
  {{- $memoryInMi = mul $value 1024 | int }}
{{- else if hasSuffix "Mi" $memory }}
  {{- $memoryInMi = trimSuffix "Mi" $memory | int }}
{{- else }}
  {{- $memoryInMi = 512 }} # Default to 512Mi if no suffix
{{- end }}
-Xmx{{ $memoryInMi }}m -Xms{{ $memoryInMi }}m
{{- end }}
