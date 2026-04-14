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
