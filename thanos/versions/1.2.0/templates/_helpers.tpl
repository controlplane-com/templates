{{/* Resource Naming */}}

{{/*
Thanos Query Workload Name
*/}}
{{- define "thanos.name" -}}
{{- printf "%s-thanos" .Release.Name }}
{{- end }}

{{/*
Thanos Store Gateway Workload Name
*/}}
{{- define "thanos.store.name" -}}
{{- printf "%s-thanos-store" .Release.Name }}
{{- end }}

{{/*
Thanos Compactor Workload Name
*/}}
{{- define "thanos.compact.name" -}}
{{- printf "%s-thanos-compact" .Release.Name }}
{{- end }}

{{/*
Thanos Identity Name
*/}}
{{- define "thanos.identity.name" -}}
{{- printf "%s-thanos-identity" .Release.Name }}
{{- end }}

{{/*
Thanos Policy Name
*/}}
{{- define "thanos.policy.name" -}}
{{- printf "%s-thanos-policy" .Release.Name }}
{{- end }}

{{/*
Objstore Config Secret Name
*/}}
{{- define "thanos.secret.objstore.name" -}}
{{- printf "%s-thanos-objstore" .Release.Name }}
{{- end }}

{{/*
Store Gateway Cache Volumeset Name
*/}}
{{- define "thanos.store.volume.name" -}}
{{- printf "%s-thanos-store-vs" .Release.Name }}
{{- end }}

{{/*
Compactor Workspace Volumeset Name
*/}}
{{- define "thanos.compact.volume.name" -}}
{{- printf "%s-thanos-compact-vs" .Release.Name }}
{{- end }}


{{/* Storage tier gate */}}

{{/*
Non-empty when the optional object-storage tier (Store Gateway and/or
Compactor) is enabled — gates the objstore secret, policy, and cloud grants.
*/}}
{{- define "thanos.storageEnabled" -}}
{{- if or .Values.storeGateway.enabled .Values.compactor.enabled -}}true{{- end -}}
{{- end }}


{{/* Rendered objstore.yml */}}

{{/*
Thanos-native object storage configuration (storage.md @v0.42.2).
Keyless posture for aws/gcp is deliberate: `aws_sdk_auth: true` hands auth to
the AWS SDK default chain and GCS falls back to Application Default
Credentials — both satisfied by the workload identity's cloud access on
Control Plane. This rendering is the canonical objstore format shared with the
prometheus template's sidecar: both must address the same bucket identically.
*/}}
{{- define "thanos.objstoreConfig" -}}
{{- if eq .Values.storage.type "aws" -}}
type: S3
config:
  bucket: {{ .Values.storage.aws.bucket | quote }}
  endpoint: {{ printf "s3.%s.amazonaws.com" .Values.storage.aws.region | quote }}
  region: {{ .Values.storage.aws.region | quote }}
  aws_sdk_auth: true
{{- else if eq .Values.storage.type "gcp" -}}
type: GCS
config:
  bucket: {{ .Values.storage.gcp.bucket | quote }}
{{- else -}}
type: S3
config:
  bucket: {{ .Values.storage.minio.bucket | quote }}
  endpoint: {{ .Values.storage.minio.endpoint | quote }}
  region: {{ .Values.storage.minio.region | quote }}
  insecure: {{ .Values.storage.minio.insecure }}
  bucket_lookup_type: path
{{- end -}}
{{- end }}


{{/* Validation */}}

{{- define "thanos.validate" -}}
{{- include "thanos.validateObjstoreCreds" . -}}
{{- if lt (int .Values.replicas) 1 -}}
{{- fail "thanos: replicas must be at least 1" -}}
{{- end -}}
{{- if not (has .Values.internalAccess.type (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "thanos: internalAccess.type must be none, same-gvc, same-org, or workload-list — got '%s'" .Values.internalAccess.type) -}}
{{- end -}}
{{- range .Values.stores -}}
{{- if contains "://" . -}}
{{- fail (printf "thanos: stores entries must be host:port with NO scheme — got '%s'" .) -}}
{{- end -}}
{{- if not (contains ":" .) -}}
{{- fail (printf "thanos: stores entries must be host:port (gRPC Store API, typically :10901) — got '%s'" .) -}}
{{- end -}}
{{- end -}}
{{- range $res, $val := (pick .Values.compactor.retention "raw" "fiveMinutes" "oneHour") -}}
{{- if not (regexMatch "^[0-9]+(ms|s|m|h|d|w|y)$" (printf "%v" $val)) -}}
{{- fail (printf "thanos: compactor.retention.%s must be a duration like 0d, 2w, 1y — got '%v'" $res $val) -}}
{{- end -}}
{{- end -}}
{{- if or .Values.storeGateway.enabled .Values.compactor.enabled -}}
{{- if not (has .Values.storage.type (list "aws" "gcp" "minio")) -}}
{{- fail (printf "thanos: storage.type must be aws, gcp, or minio — got '%s'" .Values.storage.type) -}}
{{- end -}}
{{- if eq .Values.storage.type "aws" -}}
{{- $a := .Values.storage.aws -}}
{{- if not $a.bucket -}}{{- fail "thanos: storage.aws.bucket is required (the bucket must already exist)" -}}{{- end -}}
{{- if not $a.region -}}{{- fail "thanos: storage.aws.region is required" -}}{{- end -}}
{{- if not $a.cloudAccountName -}}{{- fail "thanos: storage.aws.cloudAccountName is required — AWS access is keyless via a Control Plane cloud account" -}}{{- end -}}
{{- if not $a.policyName -}}{{- fail "thanos: storage.aws.policyName is required (a custom IAM policy granting bucket access)" -}}{{- end -}}
{{- else if eq .Values.storage.type "gcp" -}}
{{- $g := .Values.storage.gcp -}}
{{- if not $g.bucket -}}{{- fail "thanos: storage.gcp.bucket is required (the bucket must already exist)" -}}{{- end -}}
{{- if not $g.cloudAccountName -}}{{- fail "thanos: storage.gcp.cloudAccountName is required — GCS access is keyless via a Control Plane cloud account" -}}{{- end -}}
{{- else -}}
{{- $m := .Values.storage.minio -}}
{{- if not $m.endpoint -}}{{- fail "thanos: storage.minio.endpoint is required (host:port, no scheme)" -}}{{- end -}}
{{- if contains "://" $m.endpoint -}}{{- fail (printf "thanos: storage.minio.endpoint must be host:port with NO scheme — got '%s'" $m.endpoint) -}}{{- end -}}
{{- if not $m.bucket -}}{{- fail "thanos: storage.minio.bucket is required" -}}{{- end -}}
{{- if not $m.credentialsSecretName -}}{{- fail "thanos: minio.credentialsSecretName is required — it names the `dictionary` secret holding `accessKey` and `secretKey`. Create it BEFORE installing." -}}{{- end -}}
{{- end -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Common tags
*/}}
{{- define "thanos.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}

{{/*
MinIO object-storage credentials moved to a prerequisite secret. They are passed as
AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY rather than written into the config file,
because a cpln:// reference inside a mounted file is never resolved by the platform.
*/}}
{{- define "thanos.validateObjstoreCreds" -}}
{{- if eq .Values.storage.type "minio" -}}
{{- if or (.Values.storage.minio).accessKey (.Values.storage.minio).accessSecret -}}
{{- fail "thanos: minio.accessKey and minio.accessSecret were REMOVED — they are now a `dictionary` secret you create, named by minio.credentialsSecretName, holding the keys `accessKey` and `secretKey`. Delete them from your values." -}}
{{- end -}}
{{- if not (.Values.storage.minio).credentialsSecretName -}}
{{- fail "thanos: minio.credentialsSecretName is required when the object-storage type is 'minio' — it names the `dictionary` secret holding `accessKey` and `secretKey`. Create it BEFORE installing." -}}
{{- end -}}
{{- end -}}
{{- end -}}
