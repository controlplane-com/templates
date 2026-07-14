{{/* Resource Naming */}}

{{/*
SFTPGo Workload Name
*/}}
{{- define "sftpgo.name" -}}
{{- printf "%s-sftpgo" .Release.Name }}
{{- end }}

{{/*
Scale-to-zero Proxy Workload Name
*/}}
{{- define "sftpgo.proxy.name" -}}
{{- printf "%s-sftpgo-proxy" .Release.Name }}
{{- end }}

{{/*
SFTPGo Volumeset Name
*/}}
{{- define "sftpgo.volume.name" -}}
{{- printf "%s-sftpgo-vs" .Release.Name }}
{{- end }}

{{/*
Admin Bootstrap Secret Name
*/}}
{{- define "sftpgo.secretAdmin.name" -}}
{{- printf "%s-sftpgo-admin" .Release.Name }}
{{- end }}

{{/*
Users LOADDATA Secret Name
*/}}
{{- define "sftpgo.secretUsers.name" -}}
{{- printf "%s-sftpgo-users" .Release.Name }}
{{- end }}

{{/*
SFTPGo Identity Name
*/}}
{{- define "sftpgo.identity.name" -}}
{{- printf "%s-sftpgo-identity" .Release.Name }}
{{- end }}

{{/*
Proxy Identity Name
*/}}
{{- define "sftpgo.proxy.identity.name" -}}
{{- printf "%s-sftpgo-proxy-identity" .Release.Name }}
{{- end }}

{{/*
SFTPGo Policy Name
*/}}
{{- define "sftpgo.policy.name" -}}
{{- printf "%s-sftpgo-policy" .Release.Name }}
{{- end }}

{{/*
Proxy Policy Name
*/}}
{{- define "sftpgo.proxy.policy.name" -}}
{{- printf "%s-sftpgo-proxy-policy" .Release.Name }}
{{- end }}


{{/* Storage resolution */}}

{{/*
The active storage block as a normalized dict — isolates every "which backend"
decision here. `provider` is SFTPGo's filesystem provider (1 = S3, 2 = GCS).
AWS and GCP are always keyless (cloud identity); minio is static-keys.
*/}}
{{- define "sftpgo.storage" -}}
{{- $t := .Values.storage.type -}}
{{- if eq $t "aws" -}}
{{- $a := .Values.storage.aws -}}
{{- dict "provider" 1 "bucket" $a.bucket "region" $a.region "keyPrefix" ($a.keyPrefix | default "")
      "endpoint" "" "forcePathStyle" false "accessKey" "" "accessSecret" "" "keyless" true | toJson -}}
{{- else if eq $t "gcp" -}}
{{- $g := .Values.storage.gcp -}}
{{- dict "provider" 2 "bucket" $g.bucket "keyPrefix" ($g.keyPrefix | default "") "keyless" true | toJson -}}
{{- else -}}
{{- $m := .Values.storage.minio -}}
{{- dict "provider" 1 "bucket" $m.bucket "region" $m.region "keyPrefix" ($m.keyPrefix | default "")
      "endpoint" $m.endpoint "forcePathStyle" true
      "accessKey" ($m.accessKey | default "") "accessSecret" ($m.accessSecret | default "")
      "keyless" false | toJson -}}
{{- end -}}
{{- end }}


{{/* Users LOADDATA JSON (SFTPGo dump format) */}}

{{/*
Renders the SFTPGO_LOADDATA_FROM file: declared users with per-user S3
filesystems. Plain passwords are bcrypt-hashed by SFTPGo on load. For static
credentials the access secret uses the {"status":"Plain","payload":...} form
(encrypted by SFTPGo's local KMS on load); for keyless (UCI) auth the
access_key/access_secret are OMITTED so SFTPGo's AWS SDK uses the vended
credentials from the workload identity.
*/}}
{{- define "sftpgo.usersFile" -}}
{{- $s := include "sftpgo.storage" . | fromJson -}}
{{- $globalPrefix := $s.keyPrefix -}}
{{- if and $globalPrefix (not (hasSuffix "/" $globalPrefix)) -}}
{{- $globalPrefix = printf "%s/" $globalPrefix -}}
{{- end -}}
{{- $users := list -}}
{{- range .Values.users -}}
{{- $kp := printf "%s%s/" $globalPrefix .username -}}
{{- if hasKey . "keyPrefix" -}}
{{- $kp = .keyPrefix -}}
{{- end -}}
{{- $fs := dict "provider" $s.provider -}}
{{- if eq (int $s.provider) 2 -}}
{{- $_ := set $fs "gcsconfig" (dict "bucket" $s.bucket "key_prefix" $kp "automatic_credentials" 1) -}}
{{- else -}}
{{- $s3config := dict
      "bucket" $s.bucket
      "region" $s.region
      "endpoint" $s.endpoint
      "force_path_style" $s.forcePathStyle
      "key_prefix" $kp
-}}
{{- if not $s.keyless -}}
{{- $_ := set $s3config "access_key" $s.accessKey -}}
{{- $_ := set $s3config "access_secret" (dict "status" "Plain" "payload" $s.accessSecret) -}}
{{- end -}}
{{- $_ := set $fs "s3config" $s3config -}}
{{- end -}}
{{- $user := dict
      "username" .username
      "status" 1
      "home_dir" (printf "/srv/sftpgo/data/%s" .username)
      "permissions" (dict "/" (list "*"))
      "filesystem" $fs
-}}
{{- if .password -}}
{{- $_ := set $user "password" .password -}}
{{- end -}}
{{- if .publicKeys -}}
{{- $_ := set $user "public_keys" .publicKeys -}}
{{- end -}}
{{- $users = append $users $user -}}
{{- end -}}
{{- dict "users" $users | toJson -}}
{{- end }}


{{/* Validation */}}

{{- define "sftpgo.validate" -}}
{{- if not (or (eq .Values.mode "scale_to_zero") (eq .Values.mode "always_warm")) -}}
{{- fail (printf "sftpgo: mode must be 'scale_to_zero' or 'always_warm', got '%s'" .Values.mode) -}}
{{- end -}}
{{- if and (eq .Values.mode "scale_to_zero") (eq .Values.internalAccess.type "none") -}}
{{- fail "sftpgo: mode 'scale_to_zero' requires internalAccess.type other than 'none' — the proxy must be able to reach the SFTPGo workload" -}}
{{- end -}}
{{- if and (eq .Values.mode "scale_to_zero") (not (regexMatch "^[0-9]+(ms|s|m|h)$" (printf "%v" .Values.scaleToZero.idleHold))) -}}
{{- fail (printf "sftpgo: scaleToZero.idleHold must be a duration like 90s, 5m, or 1h, got '%v'" .Values.scaleToZero.idleHold) -}}
{{- end -}}
{{- if not (has .Values.storage.type (list "aws" "gcp" "minio")) -}}
{{- fail (printf "sftpgo: storage.type must be 'aws', 'gcp', or 'minio', got '%s'" .Values.storage.type) -}}
{{- end -}}
{{- if eq .Values.storage.type "aws" -}}
{{- $a := .Values.storage.aws -}}
{{- if not $a.bucket -}}{{- fail "sftpgo: storage.aws.bucket is required (the bucket must already exist)" -}}{{- end -}}
{{- if not $a.region -}}{{- fail "sftpgo: storage.aws.region is required" -}}{{- end -}}
{{- if not $a.cloudAccountName -}}{{- fail "sftpgo: storage.aws.cloudAccountName is required — AWS access is keyless via a Control Plane cloud account" -}}{{- end -}}
{{- if not $a.policyName -}}{{- fail "sftpgo: storage.aws.policyName is required (a custom IAM policy granting bucket access)" -}}{{- end -}}
{{- else if eq .Values.storage.type "gcp" -}}
{{- $g := .Values.storage.gcp -}}
{{- if not $g.bucket -}}{{- fail "sftpgo: storage.gcp.bucket is required (the bucket must already exist)" -}}{{- end -}}
{{- if not $g.cloudAccountName -}}{{- fail "sftpgo: storage.gcp.cloudAccountName is required — GCS access is keyless via a Control Plane cloud account" -}}{{- end -}}
{{- else -}}
{{- $m := .Values.storage.minio -}}
{{- if not $m.endpoint -}}{{- fail "sftpgo: storage.minio.endpoint is required (e.g. http://my-minio-workload:9000)" -}}{{- end -}}
{{- if not $m.bucket -}}{{- fail "sftpgo: storage.minio.bucket is required" -}}{{- end -}}
{{- if not $m.accessKey -}}{{- fail "sftpgo: storage.minio.accessKey is required" -}}{{- end -}}
{{- if not $m.accessSecret -}}{{- fail "sftpgo: storage.minio.accessSecret is required" -}}{{- end -}}
{{- end -}}
{{- if not .Values.users -}}
{{- fail "sftpgo: at least one entry in 'users' is required" -}}
{{- end -}}
{{- $seen := dict -}}
{{- range .Values.users -}}
{{- if not .username -}}
{{- fail "sftpgo: every users[] entry requires a username" -}}
{{- end -}}
{{- if hasKey $seen .username -}}
{{- fail (printf "sftpgo: duplicate username '%s' in users" .username) -}}
{{- end -}}
{{- $_ := set $seen .username true -}}
{{- if and (not .password) (not .publicKeys) -}}
{{- fail (printf "sftpgo: user '%s' needs a password or at least one entry in publicKeys" .username) -}}
{{- end -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Common tags
*/}}
{{- define "sftpgo.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
