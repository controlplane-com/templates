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
{{- include "cpln-common.tags" . }}
{{- end }}

{{- define "oc.selectorLabels" -}}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Validation — required-field, enum, and mode-compatibility checks.
*/}}
{{- define "oc.validate" -}}
{{- $mode := .Values.otelCollector.mode -}}
{{- if not (has $mode (list "simple" "advanced")) -}}
{{- fail (printf "otel-collector: otelCollector.mode must be simple or advanced — got '%s'" $mode) -}}
{{- end -}}
{{- if lt (int .Values.otelCollector.replicas) 1 -}}
{{- fail "otel-collector: otelCollector.replicas must be >= 1" -}}
{{- end -}}
{{- $auth := .Values.auth.method -}}
{{- if not (has $auth (list "none" "bearer" "mtls")) -}}
{{- fail (printf "otel-collector: auth.method must be none, bearer, or mtls — got '%s'" $auth) -}}
{{- end -}}
{{- if and (eq $mode "advanced") .Values.metrics.enabled -}}
{{- fail "otel-collector: metrics.enabled generates config only in simple mode. In advanced mode, add a prometheus_remote_write exporter and a metrics pipeline to otelCollector.advanced.config yourself and leave metrics.enabled false (see README)." -}}
{{- end -}}
{{- if and (eq $auth "bearer") (not .Values.auth.bearer.secretName) -}}
{{- fail "otel-collector: auth.bearer.secretName is required when auth.method is bearer — create the opaque token secret BEFORE install and reference its name here" -}}
{{- end -}}
{{- if and (eq $auth "mtls") (not .Values.auth.mtls.secretName) -}}
{{- fail "otel-collector: auth.mtls.secretName is required when auth.method is mtls — create a dictionary secret with keys cert, key, ca BEFORE install and reference its name here" -}}
{{- end -}}
{{- if .Values.publicAccess.enabled -}}
{{- if eq $auth "none" -}}
{{- fail "otel-collector: you set publicAccess.enabled: true with auth.method: none.\nThat combination would put an unauthenticated OTLP ingestion endpoint on the public internet — it will be found and abused as an open relay, filling your traces and metrics with anyone's data.\nPick one of these three:\n  1. auth.method: bearer — also set auth.bearer.secretName to an opaque secret holding the token, created BEFORE install.\n  2. auth.method: mtls   — also set auth.mtls.secretName to a dictionary secret with keys cert, key, and ca, created BEFORE install.\n  3. publicAccess.enabled: false — leave the collector internal and send from workloads inside the GVC, where no auth is needed." -}}
{{- end -}}
{{- if empty .Values.publicAccess.allowedCidrs -}}
{{- fail "otel-collector: publicAccess.allowedCidrs must be non-empty when publicAccess.enabled — list your sender CIDRs, or [\"0.0.0.0/0\"] to explicitly allow all" -}}
{{- end -}}
{{- end -}}
{{- if not (has .Values.internalAccess.type (list "none" "same-gvc" "same-org")) -}}
{{- fail (printf "otel-collector: internalAccess.type must be none, same-gvc, or same-org — got '%s'" .Values.internalAccess.type) -}}
{{- end -}}
{{- end }}

{{/*
Generated collector config (simple mode).
Two-receiver auth split: the plain `otlp` receiver serves the unauthenticated
in-GVC trace path (GVC-level tracing pushes tokenless OTLP to gRPC :4317) and is
never exposed publicly. When auth is on, a separate `otlp/ingest` receiver
(HTTP :4318 + gRPC :4319) carries bearer or mTLS auth for external senders;
port 4318 belongs to exactly one receiver at a time.
*/}}
{{- define "otel.simpleConfig" -}}
{{- $auth := .Values.auth.method -}}
extensions:
  health_check:
    endpoint: 0.0.0.0:13133
  pprof:
    endpoint: 0.0.0.0:8180
{{- if eq $auth "bearer" }}
  bearertokenauth:
    scheme: Bearer
    filename: /etc/otel-collector/auth/token
{{- end }}

receivers:
  otlp:
    protocols:
      grpc:
        endpoint: 0.0.0.0:4317
{{- if eq $auth "none" }}
      http:
        endpoint: 0.0.0.0:4318
{{- end }}
{{- if ne $auth "none" }}
  otlp/ingest:
    protocols:
      http:
        endpoint: 0.0.0.0:4318
{{- if eq $auth "bearer" }}
        auth:
          authenticator: bearertokenauth
{{- else }}
        tls:
          cert_file: /etc/otel-collector/tls/server.crt
          key_file: /etc/otel-collector/tls/server.key
          client_ca_file: /etc/otel-collector/tls/ca.crt
{{- end }}
      grpc:
        endpoint: 0.0.0.0:4319
{{- if eq $auth "bearer" }}
        auth:
          authenticator: bearertokenauth
{{- else }}
        tls:
          cert_file: /etc/otel-collector/tls/server.crt
          key_file: /etc/otel-collector/tls/server.key
          client_ca_file: /etc/otel-collector/tls/ca.crt
{{- end }}
{{- end }}

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
{{- if .Values.metrics.enabled }}

  prometheus_remote_write:
    endpoint: {{ .Values.metrics.remoteWrite.endpoint | quote }}
{{- end }}

service:
  pipelines:
    traces:
      receivers: [otlp{{- if ne $auth "none" }}, otlp/ingest{{- end }}]
      processors: [resource{{- if (and .Values.otelCollector.simple.processors.transform (not (empty .Values.otelCollector.simple.processors.transform.traceStatements))) }}, transform{{- end }}, batch]
      exporters: [otlp, spanmetrics]

    metrics:
      receivers: [spanmetrics]
      processors: [batch]
      exporters: [prometheus]
{{- if .Values.metrics.enabled }}

    metrics/otlp:
      receivers: [otlp{{- if ne $auth "none" }}, otlp/ingest{{- end }}]
      processors: [resource, batch]
      exporters: [prometheus_remote_write]
{{- end }}

  extensions: [pprof, health_check{{- if eq $auth "bearer" }}, bearertokenauth{{- end }}]

  telemetry:
    logs:
      level: INFO
{{- end }}
