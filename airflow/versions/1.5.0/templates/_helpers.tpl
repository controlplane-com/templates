{{/* Resource Naming */}}

{{/*
Airflow Celery Workload Name
*/}}
{{- define "airflow.celery.name" -}}
{{- printf "%s-airflow-celery-worker" .Release.Name }}
{{- end }}

{{/*
Airflow Webserver Workload Name
*/}}
{{- define "airflow.webserver.name" -}}
{{- printf "%s-airflow-webserver" .Release.Name }}
{{- end }}

{{/*
Airflow Postgres Workload Name
*/}}
{{- define "airflow.postgres.name" -}}
{{- printf "%s-airflow-postgres" .Release.Name }}
{{- end }}

{{/*
Postgres Volume Set Name
*/}}
{{- define "airflow.postgresVolume.name" -}}
{{- printf "%s-airflow-postgres-vs" .Release.Name }}
{{- end }}

{{/*
Airflow Redis Workload Name
*/}}
{{- define "airflow.redis.name" -}}
{{- printf "%s-airflow-redis" .Release.Name }}
{{- end }}

{{/*
Redis Volume Set Name
*/}}
{{- define "airflow.redisVolume.name" -}}
{{- printf "%s-airflow-redis-vs" .Release.Name }}
{{- end }}

{{/*
Airflow Secret Name
*/}}
{{- define "airflow.secret.name" -}}
{{- printf "%s-airflow-config" .Release.Name }}
{{- end }}

{{/*
Airflow Identity Name
*/}}
{{- define "airflow.identity.name" -}}
{{- printf "%s-airflow-identity" .Release.Name }}
{{- end }}

{{/*
Airflow Policy Name
*/}}
{{- define "airflow.policy.name" -}}
{{- printf "%s-airflow-policy" .Release.Name }}
{{- end }}

{{/*
Airflow Volume Set Name
*/}}
{{- define "airflow.volume.name" -}}
{{- printf "%s-airflow-vs" .Release.Name }}
{{- end }}


{{/* Labeling */}}

{{/*
Common labels - delegated to cpln-common
*/}}
{{- define "airflow.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}

{{/* Validation */}}

{{/*
Top-level validation - included by every rendered resource
*/}}
{{- define "airflow.validate" -}}
{{- include "airflow.validateRemovedKeys" . -}}
{{- include "airflow.validateAuth" . -}}
{{- include "airflow.validateGitSync" . -}}
{{- end }}

{{/*
Keys removed in 1.5.0. Each held a credential that the template used AS-IS, so
an install that never overrode it ran on a value published in a public repo.
They are named explicitly so an upgrade carrying a 1.4.x values file fails at
render with the replacement, rather than silently ignoring what it was given.
There are deliberately NO compatibility fallbacks — the version bump IS the
migration path.
*/}}
{{- define "airflow.validateRemovedKeys" -}}
{{- if hasKey .Values.airflow.auth "jwtSecret" -}}
  {{- fail "airflow.auth.jwtSecret was REMOVED in airflow 1.5.0. Put it in the prerequisite `dictionary` secret named by airflow.auth.secretName (key: jwtSecret). See Prerequisites in the README." -}}
{{- end -}}
{{- if hasKey .Values.airflow.auth "fernetKey" -}}
  {{- fail "airflow.auth.fernetKey was REMOVED in airflow 1.5.0. Put it in the prerequisite `dictionary` secret named by airflow.auth.secretName (key: fernetKey). NOTE: the fernet key cannot be changed without making every already-stored Connection and Variable unreadable — see Upgrading in the README." -}}
{{- end -}}
{{- if hasKey .Values.airflow.admin "password" -}}
  {{- fail "airflow.admin.password was REMOVED in airflow 1.5.0. Put it in the prerequisite `dictionary` secret named by airflow.auth.secretName (key: adminPassword). See Prerequisites in the README." -}}
{{- end -}}
{{- if hasKey .Values.gitSync.auth "token" -}}
  {{- fail "gitSync.auth.token was REMOVED in airflow 1.5.0. Create an `opaque` secret (encoding `plain`) whose payload is the token, and set gitSync.auth.secretName to its name. See Prerequisites in the README." -}}
{{- end -}}
{{- end }}

{{/*
The auth secret is REQUIRED - the webserver cannot sign tokens, decrypt
connections or serve a login without it.
*/}}
{{- define "airflow.validateAuth" -}}
{{- if not .Values.airflow.auth.secretName -}}
  {{- fail "airflow.auth.secretName is required — it names the `dictionary` secret holding the `jwtSecret`, `fernetKey` and `adminPassword` keys. Create that secret BEFORE installing; see Prerequisites in the README." -}}
{{- end -}}
{{- if not .Values.airflow.admin.username -}}
  {{- fail "airflow.admin.username is required — it is the login paired with the `adminPassword` key in the auth secret." -}}
{{- end -}}
{{- end }}

{{/*
git-sync is optional; when it is on, a repo is mandatory. The token secret stays
optional so a public repo needs no credentials at all.
*/}}
{{- define "airflow.validateGitSync" -}}
{{- if .Values.gitSync.enabled -}}
  {{- if not .Values.gitSync.repo -}}
    {{- fail "gitSync.repo is required when gitSync.enabled is true." -}}
  {{- end -}}
  {{- if not .Values.gitSync.branch -}}
    {{- fail "gitSync.branch is required when gitSync.enabled is true." -}}
  {{- end -}}
{{- end -}}
{{- if and .Values.gitSync.auth.secretName (not .Values.gitSync.enabled) -}}
  {{- fail "gitSync.auth.secretName may only be set when gitSync.enabled is true." -}}
{{- end -}}
{{- end }}
