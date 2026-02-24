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
Airflow Redis Workload Name
*/}}
{{- define "airflow.redis.name" -}}
{{- printf "%s-airflow-redis" .Release.Name }}
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

{{/*
Postgres Volume Set Name
*/}}
{{- define "airflow.postgresVolume.name" -}}
{{- printf "%s-airflow-postgres-vs" .Release.Name }}
{{- end }}


{{/* Labeling */}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "airflow.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "airflow.tags" -}}
helm.sh/chart: {{ include "airflow.chart" . }}
{{ include "airflow.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.cpln.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.cpln.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "airflow.selectorLabels" -}}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- end }}
