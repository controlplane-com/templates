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


{{/* Users LOADDATA JSON (SFTPGo dump format) */}}

{{/*
Renders the SFTPGO_LOADDATA_FROM file: declared users with per-user S3
filesystems. Plain passwords are bcrypt-hashed by SFTPGo on load; the
access secret uses the {"status":"Plain","payload":...} form and is
encrypted by SFTPGo's local KMS before persisting.
*/}}
{{- define "sftpgo.usersFile" -}}
{{- $s3 := .Values.storage.s3 -}}
{{- $globalPrefix := $s3.keyPrefix | default "" -}}
{{- if and $globalPrefix (not (hasSuffix "/" $globalPrefix)) -}}
{{- $globalPrefix = printf "%s/" $globalPrefix -}}
{{- end -}}
{{- $users := list -}}
{{- range .Values.users -}}
{{- $kp := printf "%s%s/" $globalPrefix .username -}}
{{- if hasKey . "keyPrefix" -}}
{{- $kp = .keyPrefix -}}
{{- end -}}
{{- $s3config := dict
      "bucket" $s3.bucket
      "region" $s3.region
      "access_key" $s3.accessKey
      "access_secret" (dict "status" "Plain" "payload" $s3.accessSecret)
      "endpoint" ($s3.endpoint | default "")
      "force_path_style" ($s3.forcePathStyle | default false)
      "key_prefix" $kp
-}}
{{- $user := dict
      "username" .username
      "status" 1
      "home_dir" (printf "/srv/sftpgo/data/%s" .username)
      "permissions" (dict "/" (list "*"))
      "filesystem" (dict "provider" 1 "s3config" $s3config)
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
{{- if not .Values.storage.s3.bucket -}}
{{- fail "sftpgo: storage.s3.bucket is required (the bucket must already exist)" -}}
{{- end -}}
{{- if not .Values.storage.s3.region -}}
{{- fail "sftpgo: storage.s3.region is required" -}}
{{- end -}}
{{- if not .Values.storage.s3.accessKey -}}
{{- fail "sftpgo: storage.s3.accessKey is required" -}}
{{- end -}}
{{- if not .Values.storage.s3.accessSecret -}}
{{- fail "sftpgo: storage.s3.accessSecret is required" -}}
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
