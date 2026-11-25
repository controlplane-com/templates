{{/* Resource Naming */}}

{{/*
Ghost Workload Name
*/}}
{{- define "ghost.name" -}}
{{- printf "%s-ghost" .Release.Name }}
{{- end }}

{{/*
Ghost Content Volume Set Name
*/}}
{{- define "ghost.volume.name" -}}
{{- printf "%s-ghost-vs" .Release.Name }}
{{- end }}

{{/*
Ghost Startup-Script Secret Name (opaque, plain; derives `url`, execs the entrypoint)
*/}}
{{- define "ghost.secretStart.name" -}}
{{- printf "%s-ghost-start" .Release.Name }}
{{- end }}

{{/*
Ghost Identity Name
*/}}
{{- define "ghost.identity.name" -}}
{{- printf "%s-ghost-identity" .Release.Name }}
{{- end }}

{{/*
Ghost Policy Name
*/}}
{{- define "ghost.policy.name" -}}
{{- printf "%s-ghost-policy" .Release.Name }}
{{- end }}

{{/*
Database credentials: the prerequisite dictionary secret (username, password, database)
that the `mysql` subchart initializes MySQL with. Ghost connects with the same keys.
*/}}
{{- define "ghost.mysql.credentialsSecretName" -}}
{{- .Values.mysql.credentialsSecretName }}
{{- end }}

{{/*
The secret ghost 1.2.0 (mysql subchart 1.4.3) CREATED itself. Upgrading to 1.3.0
deletes it, so neither prerequisite secret may carry this name.
*/}}
{{- define "ghost.mysql.legacySecretName" -}}
{{- printf "%s-mysql-config" .Release.Name }}
{{- end }}

{{/*
Internal DNS host of the MySQL workload created by the `mysql` subchart.
Must match the subchart's own `mysql.name` helper.
*/}}
{{- define "ghost.mysql.host" -}}
{{- printf "%s-mysql.%s.cpln.local" .Release.Name .Values.global.cpln.gvc }}
{{- end }}


{{/* Validation */}}

{{- define "ghost.validate" -}}
{{- include "ghost.validateResourceKnobs" . -}}
{{- include "ghost.validateRemovedKeys" . -}}
{{- include "ghost.validateDatabaseSecrets" . -}}
{{- if .Values.mail.secretName -}}
{{- if not .Values.mail.host -}}
{{- fail "ghost: mail.host must be set when mail.secretName is provided" -}}
{{- end -}}
{{- if not .Values.mail.from -}}
{{- fail "ghost: mail.from must be set when mail.secretName is provided" -}}
{{- end -}}
{{- end -}}
{{- if and .Values.staffDeviceVerification (not .Values.mail.secretName) -}}
{{- fail "ghost: staffDeviceVerification requires SMTP — set mail.secretName (Ghost emails the 2FA code) or leave staffDeviceVerification: false" -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Common tags
*/}}
{{- define "ghost.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}

{{/*
Reject the pre-rename bare cpu/memory keys. Left unguarded they are silently
ignored and the chart falls back to its own default limit — wrong resources
with no signal.
*/}}
{{- define "ghost.validateResourceKnobs" -}}
{{- if (.Values.resources).cpu -}}
{{- fail "ghost: resources.cpu was RENAMED to resources.maxCpu. A block exposing both a reservation and a limit names the limit maxCpu/maxMemory, so the bare name is no longer read and would be silently ignored. Rename it in your values." -}}
{{- end -}}
{{- if (.Values.resources).memory -}}
{{- fail "ghost: resources.memory was RENAMED to resources.maxMemory. A block exposing both a reservation and a limit names the limit maxCpu/maxMemory, so the bare name is no longer read and would be silently ignored. Rename it in your values." -}}
{{- end -}}
{{- end -}}

{{/*
Keys removed in 1.3.0. An upgrade still carrying them is refused at render, before
any resource is touched — there are no compatibility fallbacks.
*/}}
{{- define "ghost.validateRemovedKeys" -}}
{{- if hasKey .Values.mysql "config" -}}
{{- fail "ghost: mysql.config was removed in 1.3.0 — the database passwords are no longer values. Create a `dictionary` secret with keys username, password and database, and an `opaque` secret with the root password, set mysql.credentialsSecretName and mysql.rootPasswordSecretName to their names, and remove mysql.config. Upgrading from 1.2.0: put the values your database was initialized with into NEW secrets — see \"Upgrading from 1.2.0\" in the README." -}}
{{- end -}}
{{- if hasKey .Values.mysql "enablePhpMyAdmin" -}}
{{- fail "ghost: mysql.enablePhpMyAdmin was removed in 1.3.0 (the mysql template renamed it). Remove it; set mysql.phpMyAdmin.enabled: true only if you want the phpMyAdmin console." -}}
{{- end -}}
{{- end -}}

{{/*
Both prerequisite database secrets must be named, and neither may reuse the name
of the secret 1.2.0 created (the upgrade deletes that one).
*/}}
{{- define "ghost.validateDatabaseSecrets" -}}
{{- if not .Values.mysql.credentialsSecretName -}}
{{- fail "ghost: mysql.credentialsSecretName is required — it names a `dictionary` secret with keys username, password and database, which must EXIST BEFORE INSTALL. Create it with: cpln secret create-dictionary --name my-ghost-db-credentials --entry username=ghost --entry password='YOUR-STRONG-PASSWORD' --entry database=ghost" -}}
{{- end -}}
{{- if not .Values.mysql.rootPasswordSecretName -}}
{{- fail "ghost: mysql.rootPasswordSecretName is required — it names an `opaque` secret (encoding: plain) holding the MySQL root password, which must EXIST BEFORE INSTALL. Create it with: printf '%s' 'YOUR-STRONG-ROOT-PASSWORD' | cpln secret create-opaque --name my-ghost-mysql-root-password --encoding plain -f -" -}}
{{- end -}}
{{- $legacy := include "ghost.mysql.legacySecretName" . -}}
{{- if or (eq .Values.mysql.credentialsSecretName $legacy) (eq .Values.mysql.rootPasswordSecretName $legacy) -}}
{{- fail (printf "ghost: %s is the secret ghost 1.2.0 created itself, and upgrading to 1.3.0 deletes it. Create the database secrets under NEW names and set mysql.credentialsSecretName and mysql.rootPasswordSecretName to them." $legacy) -}}
{{- end -}}
{{- if eq .Values.mysql.credentialsSecretName .Values.mysql.rootPasswordSecretName -}}
{{- fail "ghost: mysql.credentialsSecretName and mysql.rootPasswordSecretName must name two different secrets — a `dictionary` with username, password and database, and an `opaque` secret with the root password." -}}
{{- end -}}
{{- end -}}
