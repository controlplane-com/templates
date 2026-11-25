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
Users-template Secret Name (chart-owned; holds no credential since 1.2.0)
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
No backend puts a credential in the users file: AWS and GCP are keyless (cloud
identity), and the S3-compatible backend's static keys reach SFTPGo's AWS SDK as
AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY env vars from the prerequisite secret.
*/}}
{{- define "sftpgo.storage" -}}
{{- $t := .Values.storage.type -}}
{{- if eq $t "aws" -}}
{{- $a := .Values.storage.aws -}}
{{- dict "provider" 1 "bucket" $a.bucket "region" $a.region "keyPrefix" ($a.keyPrefix | default "")
      "endpoint" "" "forcePathStyle" false | toJson -}}
{{- else if eq $t "gcp" -}}
{{- $g := .Values.storage.gcp -}}
{{- dict "provider" 2 "bucket" $g.bucket "keyPrefix" ($g.keyPrefix | default "") | toJson -}}
{{- else -}}
{{- $m := .Values.storage.minio -}}
{{- dict "provider" 1 "bucket" $m.bucket "region" $m.region "keyPrefix" ($m.keyPrefix | default "")
      "endpoint" $m.endpoint "forcePathStyle" true | toJson -}}
{{- end -}}
{{- end }}


{{/* User passwords */}}

{{/*
Whether a users[] entry logs in with a password. Explicit `passwordLogin` wins;
otherwise a user with no publicKeys uses a password. Call with the user dict.
*/}}
{{- define "sftpgo.userWantsPassword" -}}
{{- if hasKey . "passwordLogin" -}}
{{- if .passwordLogin }}true{{ end -}}
{{- else if not .publicKeys -}}
true
{{- end -}}
{{- end }}

{{/*
"true" when any declared user logs in with a password, i.e. when the
userPasswords secret is read (env refs + policy target).
*/}}
{{- define "sftpgo.anyPasswordUser" -}}
{{- $any := false -}}
{{- range .Values.users -}}
{{- if include "sftpgo.userWantsPassword" . -}}{{- $any = true -}}{{- end -}}
{{- end -}}
{{- if $any }}true{{ end -}}
{{- end }}


{{/* Users LOADDATA JSON (SFTPGo dump format) */}}

{{/*
Renders the users TEMPLATE (SFTPGo dump format): declared users with per-user
S3/GCS filesystems. It holds NO credential: each password is the token
@@USERPW_<index>@@, which the start script replaces with the JSON-escaped value of
env var USERPW_<index> (a cpln://secret reference into userPasswords.secretName)
and writes to /tmp. SFTPGo hashes the plain password when it loads the file.
Storage credentials are never in the file (see sftpgo.storage).
*/}}
{{- define "sftpgo.usersFile" -}}
{{- $s := include "sftpgo.storage" . | fromJson -}}
{{- $globalPrefix := $s.keyPrefix -}}
{{- if and $globalPrefix (not (hasSuffix "/" $globalPrefix)) -}}
{{- $globalPrefix = printf "%s/" $globalPrefix -}}
{{- end -}}
{{- $users := list -}}
{{- range $i, $u := .Values.users -}}
{{- $kp := printf "%s%s/" $globalPrefix $u.username -}}
{{- if hasKey $u "keyPrefix" -}}
{{- $kp = $u.keyPrefix -}}
{{- end -}}
{{- $fs := dict "provider" $s.provider -}}
{{- if eq (int $s.provider) 2 -}}
{{- $_ := set $fs "gcsconfig" (dict "bucket" $s.bucket "key_prefix" $kp "automatic_credentials" 1) -}}
{{- else -}}
{{- $_ := set $fs "s3config" (dict
      "bucket" $s.bucket
      "region" $s.region
      "endpoint" $s.endpoint
      "force_path_style" $s.forcePathStyle
      "key_prefix" $kp) -}}
{{- end -}}
{{- $user := dict
      "username" $u.username
      "status" 1
      "home_dir" (printf "/srv/sftpgo/data/%s" $u.username)
      "permissions" (dict "/" (list "*"))
      "filesystem" $fs
-}}
{{- if include "sftpgo.userWantsPassword" $u -}}
{{- $_ := set $user "password" (printf "@@USERPW_%d@@" $i) -}}
{{- end -}}
{{- if $u.publicKeys -}}
{{- $_ := set $user "public_keys" $u.publicKeys -}}
{{- end -}}
{{- $users = append $users $user -}}
{{- end -}}
{{- dict "users" $users | toJson -}}
{{- end }}


{{/* Start script */}}

{{/*
SFTPGo start script, run by /bin/sh (the alpine-slim image's busybox). Holds no
credential, so it is inline in args rather than in a secret. It copies the users
template to /tmp (mode 0600), replacing each @@USERPW_<n>@@ token with the
JSON-escaped value of env var USERPW_<n>, then execs SFTPGo, which loads the file,
hashes the passwords, and deletes it (SFTPGO_LOADDATA_CLEAN).
*/}}
{{- define "sftpgo.script.start" -}}
set -eu
umask 077
awk '
function esc(s,   out, i, c) {
  out = ""
  for (i = 1; i <= length(s); i++) {
    c = substr(s, i, 1)
    if (c == "\\") out = out "\\\\"
    else if (c == "\"") out = out "\\\""
    else if (c == "\n") out = out "\\n"
    else if (c == "\r") out = out "\\r"
    else if (c == "\t") out = out "\\t"
    else out = out c
  }
  return out
}
{
  line = $0
  res = ""
  while (match(line, /@@USERPW_[0-9]+@@/)) {
    name = substr(line, RSTART + 2, RLENGTH - 4)
    val = ENVIRON[name]
    if (val == "") {
      printf "sftpgo: %s is empty. Every users[] entry that logs in with a password needs its username as a key in the userPasswords secret.\n", name > "/dev/stderr"
      exit 1
    }
    res = res substr(line, 1, RSTART - 1) esc(val)
    line = substr(line, RSTART + RLENGTH)
  }
  print res line
}' /etc/sftpgo/users.json > /tmp/sftpgo-users.json
exec sftpgo serve
{{- end }}

{{/*
Renders a script as a YAML block scalar for container args. The platform expands
$(VAR) and collapses $$ to $ in args, so every $ is doubled (pgedge.inlineScript).
*/}}
{{- define "sftpgo.inlineScript" -}}
|-
{{ . | replace "$" "$$" | indent 2 }}
{{- end -}}


{{/* Validation */}}

{{- define "sftpgo.validate" -}}
{{- include "sftpgo.validateRemovedKeys" . -}}
{{- if not .Values.admin.secretName -}}
{{- fail "sftpgo: admin.secretName is required — the name of a pre-created dictionary secret holding 'username' and 'password'. Create the secret BEFORE installing; see the README." -}}
{{- end -}}
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
{{- if not $m.credentialsSecretName -}}{{- fail "sftpgo: storage.minio.credentialsSecretName is required — the name of a pre-created dictionary secret holding 'accessKey' and 'secretKey'. Create the secret BEFORE installing; see the README." -}}{{- end -}}
{{- if eq $m.credentialsSecretName (include "sftpgo.secretUsers.name" .) -}}{{- fail (printf "sftpgo: storage.minio.credentialsSecretName must not be '%s' — the chart creates and owns that secret. Name your prerequisite secret something else." (include "sftpgo.secretUsers.name" .)) -}}{{- end -}}
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
{{- if and (not (include "sftpgo.userWantsPassword" .)) (not .publicKeys) -}}
{{- fail (printf "sftpgo: user '%s' has passwordLogin: false and no publicKeys, so it could never log in. Add a public key or remove passwordLogin." .username) -}}
{{- end -}}
{{- end -}}
{{- if include "sftpgo.anyPasswordUser" . -}}
{{- $pw := .Values.userPasswords.secretName -}}
{{- if not $pw -}}
{{- fail "sftpgo: userPasswords.secretName is required while any users[] entry logs in with a password — the name of a pre-created dictionary secret with one key per such username, holding its password. Create the secret BEFORE installing; see the README." -}}
{{- end -}}
{{- if eq $pw (include "sftpgo.secretUsers.name" .) -}}
{{- fail (printf "sftpgo: userPasswords.secretName must not be '%s' — the chart creates and owns that secret. Name your prerequisite secret something else." (include "sftpgo.secretUsers.name" .)) -}}
{{- end -}}
{{- end -}}
{{- end }}


{{/*
Keys removed in 1.1.0 (admin.*) and 1.2.0 (users[].password, storage.minio
accessKey/accessSecret). An upgrader carrying a 1.0.0 values file forward is told
exactly what to do instead of silently getting a default. There are deliberately
NO compatibility fallbacks — the version bump IS the migration path.
*/}}
{{- define "sftpgo.validateRemovedKeys" -}}
{{- if dig "username" "" .Values.admin -}}
{{- fail "sftpgo: admin.username was removed in 1.1.0. Put it in the prerequisite dictionary secret named by admin.secretName (key: username) — see the README." -}}
{{- end -}}
{{- if dig "password" "" .Values.admin -}}
{{- fail "sftpgo: admin.password was removed in 1.1.0. Put it in the prerequisite dictionary secret named by admin.secretName (key: password) — see the README. An install that already booted keeps the admin it created; the secret only seeds a fresh data provider." -}}
{{- end -}}
{{- range .Values.users -}}
{{- if hasKey . "password" -}}
{{- fail (printf "sftpgo: users[].password was removed in 1.2.0 (user '%v'). Put each password in the prerequisite dictionary secret named by userPasswords.secretName, keyed by username, and delete the password key from users[] — see the README. To keep the current login, store the password the user has today." .username) -}}
{{- end -}}
{{- end -}}
{{- if hasKey .Values.storage.minio "accessKey" -}}
{{- fail "sftpgo: storage.minio.accessKey was removed in 1.2.0. Put it in the prerequisite dictionary secret named by storage.minio.credentialsSecretName (key: accessKey) and delete it from the values — see the README." -}}
{{- end -}}
{{- if hasKey .Values.storage.minio "accessSecret" -}}
{{- fail "sftpgo: storage.minio.accessSecret was removed in 1.2.0. Put it in the prerequisite dictionary secret named by storage.minio.credentialsSecretName (key: secretKey) and delete it from the values — see the README." -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Common tags
*/}}
{{- define "sftpgo.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
