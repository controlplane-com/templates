{{/* Resource Naming */}}

{{- define "mimir.name" -}}
{{- printf "%s-mimir" .Release.Name }}
{{- end }}

{{- define "mimir.volume.name" -}}
{{- printf "%s-mimir-vs" .Release.Name }}
{{- end }}

{{- define "mimir.secret.config.name" -}}
{{- printf "%s-mimir-config" .Release.Name }}
{{- end }}

{{- define "mimir.identity.name" -}}
{{- printf "%s-mimir-identity" .Release.Name }}
{{- end }}

{{- define "mimir.policy.name" -}}
{{- printf "%s-mimir-policy" .Release.Name }}
{{- end }}


{{/* Rendered mimir.yaml */}}

{{/*
Single-file Mimir config. Keyless posture for aws/gcp is deliberate and spike-
verified (2026-07-20): with keys omitted, Mimir's objstore S3 client falls back
to the env/IAM credential chain and GCS falls back to Application Default
Credentials — both are satisfied by the workload identity's cloud access on
Control Plane. Expect transient "Access Denied" warnings for the first seconds
of a fresh boot while identity credentials are vended; they self-heal.
All state dirs live under /data (the image has no persistent defaults). Blocks
must not share a bucket path with ruler/alertmanager stores, hence the fixed
per-component storage prefixes.
*/}}
{{- define "mimir.config" -}}
target: all
multitenancy_enabled: {{ .Values.multitenancy.enabled }}
server:
  http_listen_port: 8080
  grpc_listen_port: 9095
common:
  storage:
{{- if eq .Values.storage.type "aws" }}
    backend: s3
    s3:
      endpoint: {{ printf "s3.%s.amazonaws.com" .Values.storage.aws.region | quote }}
      region: {{ .Values.storage.aws.region | quote }}
      bucket_name: {{ .Values.storage.aws.bucket | quote }}
{{- else if eq .Values.storage.type "gcp" }}
    backend: gcs
    gcs:
      bucket_name: {{ .Values.storage.gcp.bucket | quote }}
{{- else }}
    backend: s3
    s3:
      endpoint: {{ .Values.storage.minio.endpoint | quote }}
      region: {{ .Values.storage.minio.region | quote }}
      bucket_name: {{ .Values.storage.minio.bucket | quote }}
      access_key_id: {{ .Values.storage.minio.accessKey | quote }}
      secret_access_key: {{ .Values.storage.minio.accessSecret | quote }}
      insecure: {{ .Values.storage.minio.insecure }}
      bucket_lookup_type: path
{{- end }}
blocks_storage:
  storage_prefix: blocks
  tsdb:
    dir: /data/tsdb
  bucket_store:
    sync_dir: /data/tsdb-sync
ruler_storage:
  storage_prefix: ruler
ruler:
  rule_path: /data/ruler
alertmanager_storage:
  storage_prefix: alertmanager
compactor:
  data_dir: /data/compactor
ingester:
  ring:
    replication_factor: {{ ternary 3 1 (gt (int .Values.replicas) 1) }}
store_gateway:
  sharding_ring:
    replication_factor: {{ ternary 3 1 (gt (int .Values.replicas) 1) }}
{{- if gt (int .Values.replicas) 1 }}
memberlist:
  join_members:
    - {{ include "mimir.name" . }}.{{ .Values.global.cpln.gvc }}.cpln.local:7946
  abort_if_cluster_join_fails: false
{{- end }}
activity_tracker:
  filepath: /data/metrics-activity.log
limits:
  compactor_blocks_retention_period: {{ .Values.retention.period }}
{{- end }}


{{/* Validation */}}

{{- define "mimir.validate" -}}
{{- $r := int .Values.replicas -}}
{{- if and (ne $r 1) (lt $r 3) -}}
{{- fail "mimir: replicas must be 1 or >= 3 — a 2-replica cluster has no failure tolerance under 3-way replication" -}}
{{- end -}}
{{- if not (has .Values.storage.type (list "aws" "gcp" "minio")) -}}
{{- fail (printf "mimir: storage.type must be aws, gcp, or minio — got '%s'" .Values.storage.type) -}}
{{- end -}}
{{- if eq .Values.storage.type "aws" -}}
{{- $a := .Values.storage.aws -}}
{{- if not $a.bucket -}}{{- fail "mimir: storage.aws.bucket is required (the bucket must already exist)" -}}{{- end -}}
{{- if not $a.region -}}{{- fail "mimir: storage.aws.region is required" -}}{{- end -}}
{{- if not $a.cloudAccountName -}}{{- fail "mimir: storage.aws.cloudAccountName is required — AWS access is keyless via a Control Plane cloud account" -}}{{- end -}}
{{- if not $a.policyName -}}{{- fail "mimir: storage.aws.policyName is required (a custom IAM policy granting bucket access)" -}}{{- end -}}
{{- else if eq .Values.storage.type "gcp" -}}
{{- $g := .Values.storage.gcp -}}
{{- if not $g.bucket -}}{{- fail "mimir: storage.gcp.bucket is required (the bucket must already exist)" -}}{{- end -}}
{{- if not $g.cloudAccountName -}}{{- fail "mimir: storage.gcp.cloudAccountName is required — GCS access is keyless via a Control Plane cloud account" -}}{{- end -}}
{{- else -}}
{{- $m := .Values.storage.minio -}}
{{- if not $m.endpoint -}}{{- fail "mimir: storage.minio.endpoint is required (host:port, no scheme)" -}}{{- end -}}
{{- if contains "://" $m.endpoint -}}{{- fail (printf "mimir: storage.minio.endpoint must be host:port with NO scheme — got '%s'" $m.endpoint) -}}{{- end -}}
{{- if not $m.bucket -}}{{- fail "mimir: storage.minio.bucket is required" -}}{{- end -}}
{{- if not $m.accessKey -}}{{- fail "mimir: storage.minio.accessKey is required" -}}{{- end -}}
{{- if not $m.accessSecret -}}{{- fail "mimir: storage.minio.accessSecret is required" -}}{{- end -}}
{{- end -}}
{{- if not (has .Values.internalAccess.type (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "mimir: internalAccess.type must be none, same-gvc, same-org, or workload-list — got '%s'" .Values.internalAccess.type) -}}
{{- end -}}
{{- if not (regexMatch "^(0|[0-9]+(ms|s|m|h|d|w|y))$" (printf "%v" .Values.retention.period)) -}}
{{- fail (printf "mimir: retention.period must be 0 (keep forever) or a duration like 30d, 13w, 1y — got '%v'" .Values.retention.period) -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{- define "mimir.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
