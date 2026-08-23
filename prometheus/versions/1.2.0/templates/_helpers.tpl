{{/* Resource Naming */}}

{{- define "prometheus.name" -}}
{{- printf "%s-prometheus" .Release.Name }}
{{- end }}

{{- define "prometheus.volume.name" -}}
{{- printf "%s-prometheus-vs" .Release.Name }}
{{- end }}

{{- define "prometheus.secret.config.name" -}}
{{- printf "%s-prometheus-config" .Release.Name }}
{{- end }}

{{- define "prometheus.secret.objstore.name" -}}
{{- printf "%s-prometheus-objstore" .Release.Name }}
{{- end }}

{{- define "prometheus.identity.name" -}}
{{- printf "%s-prometheus-identity" .Release.Name }}
{{- end }}

{{- define "prometheus.policy.name" -}}
{{- printf "%s-prometheus-policy" .Release.Name }}
{{- end }}


{{/* Rendered prometheus.yml */}}

{{/*
Retention lives in the config file (storage.tsdb.retention) — the CLI retention
flags are deprecated at v3.13.1. The template always injects a baseline
external label `prometheus: <workload-name>` (unique per install), which
satisfies the Thanos sidecar's "external labels required and unique" upload
rule out of the box; user-supplied externalLabels keys merge over it and win —
including `prometheus` itself (needed for the HA-pair recipe, see README).
*/}}
{{- define "prometheus.config" -}}
{{- $labels := dict "prometheus" (include "prometheus.name" .) -}}
{{- range $k, $v := .Values.externalLabels }}{{- $_ := set $labels $k $v }}{{- end -}}
global:
  scrape_interval: {{ .Values.scrapeInterval }}
  external_labels:
    {{- toYaml $labels | nindent 4 }}
storage:
  tsdb:
    retention:
      time: {{ .Values.retention.time }}
      {{- with .Values.retention.size }}
      size: {{ . }}
      {{- end }}
scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ["localhost:9095"]
  {{- with .Values.extraScrapeConfigs }}
  {{- . | trim | nindent 2 }}
  {{- end }}
{{- if .Values.remoteWrite }}
remote_write:
  {{- range $i, $rw := .Values.remoteWrite }}
  - url: {{ $rw.url | quote }}
    {{- if $rw.basicAuth }}
    basic_auth:
      username: {{ $rw.basicAuth.username | quote }}
      password_file: /etc/prometheus/remote-write/rw-{{ $i }}/password
    {{- end }}
  {{- end }}
{{- end }}
{{- end }}


{{/* Rendered Thanos objstore.yml */}}

{{/*
Keyless posture for aws/gcp is deliberate: with access_key/secret_key omitted,
the Thanos objstore S3 client falls back to the env/IAM credential chain and
GCS falls back to Application Default Credentials — both are satisfied by the
workload identity's cloud access on Control Plane.
*/}}
{{- define "prometheus.objstore" -}}
{{- $os := .Values.thanos.objectStorage -}}
{{- if eq $os.type "aws" -}}
type: S3
config:
  bucket: {{ $os.aws.bucket | quote }}
  endpoint: {{ printf "s3.%s.amazonaws.com" $os.aws.region | quote }}
  region: {{ $os.aws.region | quote }}
{{- else if eq $os.type "gcp" -}}
type: GCS
config:
  bucket: {{ $os.gcp.bucket | quote }}
{{- else -}}
type: S3
config:
  bucket: {{ $os.minio.bucket | quote }}
  endpoint: {{ $os.minio.endpoint | quote }}
  region: {{ $os.minio.region | quote }}
  insecure: {{ $os.minio.insecure }}
  bucket_lookup_type: path
{{- end }}
{{- end }}


{{/* Validation */}}

{{- define "prometheus.validate" -}}
{{- include "prometheus.validateObjstoreCreds" . -}}
{{- if not (has .Values.internalAccess.type (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "prometheus: internalAccess.type must be none, same-gvc, same-org, or workload-list — got '%s'" .Values.internalAccess.type) -}}
{{- end -}}
{{- if not (regexMatch "^([0-9]+(ms|s|m|h|d|w|y))+$" (printf "%v" .Values.retention.time)) -}}
{{- fail (printf "prometheus: retention.time must be a duration like 15d, 30d, 1y — got '%v'" .Values.retention.time) -}}
{{- end -}}
{{- range $i, $rw := .Values.remoteWrite -}}
{{- if not $rw.url -}}
{{- fail (printf "prometheus: remoteWrite[%d].url is required" $i) -}}
{{- end -}}
{{- if $rw.basicAuth -}}
{{- if not $rw.basicAuth.username -}}
{{- fail (printf "prometheus: remoteWrite[%d].basicAuth.username is required when basicAuth is set" $i) -}}
{{- end -}}
{{- if not $rw.basicAuth.passwordSecretName -}}
{{- fail (printf "prometheus: remoteWrite[%d].basicAuth.passwordSecretName is required when basicAuth is set — an opaque secret that must exist BEFORE install" $i) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- $os := .Values.thanos.objectStorage -}}
{{- if $os.enabled -}}
{{- if not .Values.thanos.sidecar.enabled -}}
{{- fail "prometheus: thanos.objectStorage.enabled requires thanos.sidecar.enabled — the sidecar performs the block uploads" -}}
{{- end -}}
{{- if not (regexMatch "^([0-9]+(ms|s|m|h|d|w|y))+$" (printf "%v" $os.blockDuration)) -}}
{{- fail (printf "prometheus: thanos.objectStorage.blockDuration must be a duration like 2h — got '%v'" $os.blockDuration) -}}
{{- end -}}
{{- if not (has $os.type (list "aws" "gcp" "minio")) -}}
{{- fail (printf "prometheus: thanos.objectStorage.type must be aws, gcp, or minio — got '%s'" $os.type) -}}
{{- end -}}
{{- if eq $os.type "aws" -}}
{{- $a := $os.aws -}}
{{- if not $a.bucket -}}{{- fail "prometheus: thanos.objectStorage.aws.bucket is required (the bucket must already exist)" -}}{{- end -}}
{{- if not $a.region -}}{{- fail "prometheus: thanos.objectStorage.aws.region is required" -}}{{- end -}}
{{- if not $a.cloudAccountName -}}{{- fail "prometheus: thanos.objectStorage.aws.cloudAccountName is required — AWS access is keyless via a Control Plane cloud account" -}}{{- end -}}
{{- if not $a.policyName -}}{{- fail "prometheus: thanos.objectStorage.aws.policyName is required (a custom IAM policy granting bucket access)" -}}{{- end -}}
{{- else if eq $os.type "gcp" -}}
{{- $g := $os.gcp -}}
{{- if not $g.bucket -}}{{- fail "prometheus: thanos.objectStorage.gcp.bucket is required (the bucket must already exist)" -}}{{- end -}}
{{- if not $g.cloudAccountName -}}{{- fail "prometheus: thanos.objectStorage.gcp.cloudAccountName is required — GCS access is keyless via a Control Plane cloud account" -}}{{- end -}}
{{- else -}}
{{- $m := $os.minio -}}
{{- if not $m.endpoint -}}{{- fail "prometheus: thanos.objectStorage.minio.endpoint is required (host:port, no scheme)" -}}{{- end -}}
{{- if contains "://" $m.endpoint -}}{{- fail (printf "prometheus: thanos.objectStorage.minio.endpoint must be host:port with NO scheme — got '%s'" $m.endpoint) -}}{{- end -}}
{{- if not $m.bucket -}}{{- fail "prometheus: thanos.objectStorage.minio.bucket is required" -}}{{- end -}}
{{- if not $m.credentialsSecretName -}}{{- fail "prometheus: minio.credentialsSecretName is required — it names the `dictionary` secret holding `accessKey` and `secretKey`. Create it BEFORE installing." -}}{{- end -}}
{{- end -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{- define "prometheus.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}

{{/*
MinIO object-storage credentials moved to a prerequisite secret. They are passed as
AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY rather than written into the config file,
because a cpln:// reference inside a mounted file is never resolved by the platform.
*/}}
{{- define "prometheus.validateObjstoreCreds" -}}
{{- if eq .Values.thanos.objectStorage.type "minio" -}}
{{- if or (.Values.thanos.objectStorage.minio).accessKey (.Values.thanos.objectStorage.minio).accessSecret -}}
{{- fail "prometheus: minio.accessKey and minio.accessSecret were REMOVED — they are now a `dictionary` secret you create, named by minio.credentialsSecretName, holding the keys `accessKey` and `secretKey`. Delete them from your values." -}}
{{- end -}}
{{- if not (.Values.thanos.objectStorage.minio).credentialsSecretName -}}
{{- fail "prometheus: minio.credentialsSecretName is required when the object-storage type is 'minio' — it names the `dictionary` secret holding `accessKey` and `secretKey`. Create it BEFORE installing." -}}
{{- end -}}
{{- end -}}
{{- end -}}
