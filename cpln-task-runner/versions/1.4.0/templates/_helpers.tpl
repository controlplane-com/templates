{{/* Resource Naming */}}

{{/*
Task Runner Worker Workload Name
*/}}
{{- define "task-runner-worker.name" -}}
{{- printf "%s-task-runner-worker" .Release.Name }}
{{- end }}

{{/*
Task Runner API Workload Name
*/}}
{{- define "task-runner-api.name" -}}
{{- printf "%s-task-runner-api" .Release.Name }}
{{- end }}

{{/*
Task Runner Sentinel Workload Name
*/}}
{{- define "task-runner-sentinel.name" -}}
{{- printf "%s-sentinel" .Release.Name }}
{{- end }}

{{/*
Task Runner Identity Name
*/}}
{{- define "task-runner.identity.name" -}}
{{- printf "%s-task-runner-identity" .Release.Name }}
{{- end }}

{{/*
Task Runner Policy Name
*/}}
{{- define "task-runner.policy.name" -}}
{{- printf "%s-task-runner-policy" .Release.Name }}
{{- end }}


{{/*
Redis / Sentinel credentials: one user-created prerequisite dictionary secret
(the redis subchart reads the same names through redis.*.auth.fromSecret).
*/}}
{{- define "task-runner.redis.secret.name" -}}
{{- .Values.redis.redis.auth.fromSecret.name -}}
{{- end }}

{{- define "task-runner.redis.secret.key" -}}
{{- .Values.redis.redis.auth.fromSecret.passwordKey -}}
{{- end }}

{{- define "task-runner.sentinel.secret.name" -}}
{{- .Values.redis.sentinel.auth.fromSecret.name -}}
{{- end }}

{{- define "task-runner.sentinel.secret.key" -}}
{{- .Values.redis.sentinel.auth.fromSecret.passwordKey -}}
{{- end }}


{{/* Validation */}}

{{/*
Top-level validation — included by templates/validate/redis/auth.yaml, which
always renders and renders before the redis subchart.
*/}}
{{- define "cpln-task-runner.validate" -}}
{{- include "cpln-task-runner.validateAdmin" . -}}
{{- include "cpln-task-runner.validateRedisCredentials" . -}}
{{- end }}

{{/*
Validate the Redis / Sentinel credentials. Until 1.3.0 the chart created a
secret (createSecret / secretName, default `task-runner-secrets`) from the plain
values redis.redisPassword and redis.sentinelPassword. As of 1.4.0 no credential
is a Helm value: both passwords live in a user-created prerequisite dictionary
secret named by redis.redis.auth.fromSecret.name / redis.sentinel.auth.fromSecret.name.

The old chart-created name is refused: an upgrade from 1.3.0 deletes the secret
the release created, so a new secret under that same name would be deleted by
the very upgrade that starts reading it.
*/}}
{{- define "cpln-task-runner.validateRedisCredentials" -}}
{{- $removed := list -}}
{{- if hasKey .Values "createSecret" -}}{{- $removed = append $removed "createSecret" -}}{{- end -}}
{{- if hasKey .Values "secretName" -}}{{- $removed = append $removed "secretName" -}}{{- end -}}
{{- if hasKey .Values.redis "redisPassword" -}}{{- $removed = append $removed "redis.redisPassword" -}}{{- end -}}
{{- if hasKey .Values.redis "sentinelPassword" -}}{{- $removed = append $removed "redis.sentinelPassword" -}}{{- end -}}
{{- if $removed -}}
  {{- fail (printf "Removed in cpln-task-runner 1.4.0: %s. The Redis and Sentinel passwords are no longer values, and the chart no longer creates a secret for them. Create a dictionary secret with the keys `password` and `sentinelPassword` holding the passwords your release runs with TODAY, set redis.redis.auth.fromSecret.name and redis.sentinel.auth.fromSecret.name to its name, and remove %s from the values. See \"Upgrading from 1.3.0\" in the README." (join ", " $removed) (join ", " $removed)) -}}
{{- end -}}
{{- if not (and .Values.redis.redis.auth.fromSecret.enabled .Values.redis.sentinel.auth.fromSecret.enabled) -}}
  {{- fail "redis.redis.auth.fromSecret.enabled and redis.sentinel.auth.fromSecret.enabled must both stay true: the API and Worker always authenticate to Redis and Sentinel with the passwords from the prerequisite credentials secret." -}}
{{- end -}}
{{- range $name := list (include "task-runner.redis.secret.name" .) (include "task-runner.sentinel.secret.name" .) -}}
  {{- if not $name -}}
    {{- fail "redis.redis.auth.fromSecret.name and redis.sentinel.auth.fromSecret.name are required: the name of a prerequisite dictionary secret holding the Redis password (key `password`) and the Sentinel password (key `sentinelPassword`). Create it BEFORE you install; see Prerequisites in the README." -}}
  {{- end -}}
  {{- if eq $name "task-runner-secrets" -}}
    {{- fail "The Redis credentials secret cannot be named `task-runner-secrets`: that is the secret cpln-task-runner 1.3.0 and earlier created itself, and upgrading deletes it. Create the prerequisite dictionary secret under a NEW name (e.g. my-cpln-task-runner-redis-credentials) holding the same passwords, and set redis.redis.auth.fromSecret.name and redis.sentinel.auth.fromSecret.name to it." -}}
  {{- end -}}
{{- end -}}
{{- if not (and (include "task-runner.redis.secret.key" .) (include "task-runner.sentinel.secret.key" .)) -}}
  {{- fail "redis.redis.auth.fromSecret.passwordKey and redis.sentinel.auth.fromSecret.passwordKey must not be empty." -}}
{{- end -}}
{{- end }}

{{/*
Validate the admin API key. The key guards /admin/* — creating, editing and deleting
clients and rate-limit tiers — on an API that is public by default, so as of 1.3.0 it
is a user-created prerequisite secret rather than a value sitting in the Helm release.

An EMPTY apiKeySecretName leaves the admin endpoints unauthenticated (the app logs
"Admin API key not configured - admin endpoints are unprotected"). That is allowed
only for an internal-only deployment: combined with public access it publishes an
unauthenticated control plane for the queue, so it is rejected here rather than
silently changing what public.enabled means.
*/}}
{{- define "cpln-task-runner.validateAdmin" -}}
{{- if hasKey .Values.api.env "adminApiKey" -}}
  {{- fail "api.env.adminApiKey was REMOVED in cpln-task-runner 1.3.0. The admin API key is no longer a value: create an `opaque` secret (encoding: plain) whose payload is the key, and set api.admin.apiKeySecretName to its name. See Prerequisites in the README." -}}
{{- end -}}
{{- if hasKey .Values.redis "admin" -}}
  {{- fail "redis.admin.fromSecret was REMOVED in cpln-task-runner 1.3.0. The admin API key now comes from its own `opaque` secret named by api.admin.apiKeySecretName, whichever value createSecret has. See Prerequisites in the README." -}}
{{- end -}}
{{- if not .Values.api.admin.apiKeySecretName -}}
  {{- if .Values.api.public.enabled -}}
    {{- fail "api.admin.apiKeySecretName is empty while api.public.enabled is true. An empty key disables admin authentication entirely, which would publish /admin/* — create, edit and delete clients and rate-limit tiers — to the internet. Set api.admin.apiKeySecretName to the name of an `opaque` secret holding the key (see Prerequisites in the README), or set api.public.enabled to false." -}}
  {{- end -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "cpln-task-runner.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "cpln-task-runner.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}

{{- define "cpln-task-runner.selectorLabels" -}}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- end }}
