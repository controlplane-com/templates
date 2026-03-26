{{/*
Otel Collector Workload Name
*/}}
{{- define "oc.name" -}}
{{- printf "%s" .Release.Name }}
{{- end }}

{{/*
Secret Name for OTEL Configuration
*/}}
{{- define "oc.secretName" -}}
{{- printf "%s-conf" (include "oc.name" .) }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "oc.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "oc.tags" -}}
helm.sh/chart: {{ include "oc.chart" . }}
{{ include "oc.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.cpln.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.cpln.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "oc.selectorLabels" -}}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "otel.simpleConfig" -}}
extensions:
  health_check:
  pprof:
    endpoint: 0.0.0.0:8180

receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317

processors:
  batch:
  resource:
    attributes:
      - key: workload
        from_attribute: service.name
        action: insert

{{- if .Values.otelCollector.simple.processors.transform.traceStatements }}
  transform:
    trace_statements:
      - context: span
        statements:
{{ toYaml .Values.otelCollector.simple.processors.transform.traceStatements | indent 10 }}
{{- end }}

connectors:
  spanmetrics:
    dimensions:
      - name: http.url
      - name: http.method
      - name: http.status_code
    histogram:
      explicit:
        buckets: {{ .Values.otelCollector.simple.spanmetrics.histogram.buckets | toJson }}
      unit: {{ .Values.otelCollector.simple.spanmetrics.histogram.unit }}

exporters:
  otlp:
    endpoint: http://tracing.controlplane:80
    tls:
      insecure: true

  prometheus:
    endpoint: 0.0.0.0:8889

service:
  pipelines:
    traces:
      receivers: [otlp]
      processors: [resource{{- if (and .Values.otelCollector.simple.processors.transform (not (empty .Values.otelCollector.simple.processors.transform.traceStatements))) }}, transform{{- end }}, batch]
      exporters: [otlp, spanmetrics]

    metrics:
      receivers: [spanmetrics]
      processors: [batch]
      exporters: [prometheus]

  extensions: [pprof, health_check]

  telemetry:
    logs:
      level: INFO
{{- end }}