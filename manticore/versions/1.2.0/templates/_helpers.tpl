{{/* Resource Naming */}}

{{/*
Manticore Workload Name
*/}}
{{- define "manticore.name" -}}
{{- printf "%s-manticore" .Release.Name }}
{{- end }}

{{/*
Manticore Orchestrator Job Workload Name
*/}}
{{- define "manticore.orchestratorJobName" -}}
{{- printf "%s-orchestrator-job" .Release.Name }}
{{- end }}

{{/*
Manticore Orchestrator API Workload Name
*/}}
{{- define "manticore.orchestratorAPIName" -}}
{{- printf "%s-orchestrator-api" .Release.Name }}
{{- end }}

{{/*
Manticore UI Workload Name
*/}}
{{- define "manticore.UIName" -}}
{{- printf "%s-ui" .Release.Name }}
{{- end }}

{{/*
Manticore Backup Workload Name
*/}}
{{- define "manticore.backupName" -}}
{{- printf "%s-manticore-backup" .Release.Name }}
{{- end }}

{{/*
Manticore Load Test Workload Name
*/}}
{{- define "manticore.loadTestName" -}}
{{- printf "%s-load-test" .Release.Name }}
{{- end }}

{{/*
Manticore Load Test Controller Workload Name
*/}}
{{- define "manticore.loadTestControllerName" -}}
{{- printf "%s-load-test-controller" .Release.Name }}
{{- end }}

{{/*
Manticore Secret Config Name
*/}}
{{- define "manticore.secretConfigName" -}}
{{- printf "%s-manticore-config" .Release.Name }}
{{- end }}

{{/*
Manticore Secret Startup Name
*/}}
{{- define "manticore.secretStartupName" -}}
{{- printf "%s-manticore-startup" .Release.Name }}
{{- end }}

{{/*
Manticore Secret Schema Config Name
*/}}
{{- define "manticore.secretSchemaConfigName" -}}
{{- printf "%s-manticore-schema" .Release.Name }}
{{- end }}

{{/*
Manticore Secret Agent Token Name
*/}}
{{- define "manticore.secretAgentTokenName" -}}
{{- printf "%s-manticore-agent-token" .Release.Name }}
{{- end }}

{{/*
Manticore Secret K6 Script Name
*/}}
{{- define "manticore.secretK6ScriptName" -}}
{{- printf "%s-manticore-k6-script" .Release.Name }}
{{- end }}

{{/*
Manticore Identity Name
*/}}
{{- define "manticore.identityName" -}}
{{- printf "%s-manticore-identity" .Release.Name }}
{{- end }}

{{/*
Manticore Orchestrator Identity Name
*/}}
{{- define "manticore.orchestratorIdentityName" -}}
{{- printf "%s-manticore-orchestrator-identity" .Release.Name }}
{{- end }}

{{/*
Manticore Orchestrator Job Identity Name
*/}}
{{- define "manticore.orchestratorJobIdentityName" -}}
{{- printf "%s-manticore-orchestrator-job-identity" .Release.Name }}
{{- end }}

{{/*
Manticore Load Test Identity Name
*/}}
{{- define "manticore.loadTestIdentityName" -}}
{{- printf "%s-manticore-load-test-identity" .Release.Name }}
{{- end }}

{{/*
Manticore Load Test Controller Identity Name
*/}}
{{- define "manticore.loadTestControllerIdentityName" -}}
{{- printf "%s-manticore-load-test-controller-identity" .Release.Name }}
{{- end }}

{{/*
Manticore Backup Identity Name
*/}}
{{- define "manticore.backupIdentityName" -}}
{{- printf "%s-manticore-backup-identity" .Release.Name }}
{{- end }}

{{/*
Manticore Config Policy Name
*/}}
{{- define "manticore.configPolicyName" -}}
{{- printf "%s-manticore-config-policy" .Release.Name }}
{{- end }}

{{/*
Manticore Exec Policy Name
*/}}
{{- define "manticore.execPolicyName" -}}
{{- printf "%s-manticore-exec-policy" .Release.Name }}
{{- end }}

{{/*
Manticore Orchestrator Policy Name
*/}}
{{- define "manticore.orchestratorPolicyName" -}}
{{- printf "%s-manticore-orchestrator-policy" .Release.Name }}
{{- end }}

{{/*
Manticore Load Test Policy Name
*/}}
{{- define "manticore.loadTestPolicyName" -}}
{{- printf "%s-manticore-load-test-policy" .Release.Name }}
{{- end }}

{{/*
Manticore Load Test Controller Policy Name
*/}}
{{- define "manticore.loadTestControllerPolicyName" -}}
{{- printf "%s-manticore-load-test-controller-policy" .Release.Name }}
{{- end }}

{{/*
Manticore Volume Set Name
*/}}
{{- define "manticore.volumeName" -}}
{{- printf "%s-manticore-vs" .Release.Name }}
{{- end }}

{{/*
Manticore Shared Volume Set Name
*/}}
{{- define "manticore.sharedVolumeName" -}}
{{- printf "%s-manticore-vs-shared" .Release.Name }}
{{- end }}


{{/* Functions */}}

{{/*
Generate JSON mapping of table names to CSV paths for orchestrator.
csvPath accepts a single string or a list for multi-segment tables.
Output (single):  {"addresses":"imports/addresses/data.csv"}
Output (multi):   {"addresses":["imports/addresses/data_1.csv","imports/addresses/data_2.csv"]}
*/}}
{{- define "manticore.tablesConfigJSON" -}}
{{- $config := dict -}}
{{- range . -}}
{{- $_ := set $config .name .csvPath -}}
{{- end -}}
{{- $config | toJson -}}
{{- end }}

{{/*
Validate that each table's csvPath length matches its config.segmentCount.
csvPath may be a single string (segmentCount must be 1) or a list (length must equal segmentCount).
*/}}
{{- define "manticore.validateTables" -}}
{{- range .Values.tables -}}
{{- $tableName := .name -}}
{{- $segmentCount := .config.segmentCount | int -}}
{{- if kindIs "slice" .csvPath -}}
  {{- $csvCount := len .csvPath -}}
  {{- if ne $csvCount $segmentCount -}}
    {{- fail (printf "Table %q: csvPath has %d entries but segmentCount is %d — they must match." $tableName $csvCount $segmentCount) -}}
  {{- end -}}
{{- else -}}
  {{- if ne $segmentCount 1 -}}
    {{- fail (printf "Table %q: csvPath is a single string but segmentCount is %d — it must be 1 when csvPath is a single value." $tableName $segmentCount) -}}
  {{- end -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Calculate total load test duration in seconds (duration + buffer)
Parses duration strings like "5m", "1h", "30s"
*/}}
{{- define "loadTest.totalDurationSeconds" -}}
{{- $duration := .Values.loadTest.duration -}}
{{- $buffer := .Values.loadTest.controller.testDurationBuffer | int -}}
{{- $seconds := 0 -}}
{{- if hasSuffix "s" $duration -}}
  {{- $seconds = trimSuffix "s" $duration | int -}}
{{- else if hasSuffix "m" $duration -}}
  {{- $seconds = mul (trimSuffix "m" $duration | int) 60 -}}
{{- else if hasSuffix "h" $duration -}}
  {{- $seconds = mul (trimSuffix "h" $duration | int) 3600 -}}
{{- end -}}
{{- add $seconds $buffer -}}
{{- end }}


{{/* Labeling */}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "manticore.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "manticore.tags" -}}
helm.sh/chart: {{ include "manticore.chart" . }}
{{ include "manticore.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.cpln.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.cpln.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "manticore.selectorLabels" -}}
app.cpln.io/name: {{ .Release.Name }}
app.cpln.io/instance: {{ .Release.Name }}
{{- end }}