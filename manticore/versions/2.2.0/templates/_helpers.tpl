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
Manticore Agent Token Secret Name (USER-SUPPLIED prerequisite secret, not created by this chart)
*/}}
{{- define "manticore.agentTokenSecretName" -}}
{{- required "orchestrator.agent.tokenSecretName is required — it names an opaque secret that must exist BEFORE install" .Values.orchestrator.agent.tokenSecretName }}
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
Chart-level validation: removed-key guards plus table validation.
The guards exist because 2.1.0 is a clean break — a user carrying 2.0.x values
forward would otherwise silently ship a public admin UI or an ignored token.
*/}}
{{- define "manticore.validate" -}}
{{- include "manticore.validateResourceKnobs" . -}}
{{- if hasKey .Values.orchestrator.agent "token" -}}
{{- fail "orchestrator.agent.token was REMOVED in manticore 2.1.0. The bearer token is now a prerequisite opaque secret you create before install; set orchestrator.agent.tokenSecretName to its name instead. See the README Prerequisites section." -}}
{{- end -}}
{{- if hasKey .Values.orchestrator.ui "allowExternalAccess" -}}
{{- fail "orchestrator.ui.allowExternalAccess was REMOVED in manticore 2.1.0. Use orchestrator.ui.publicAccess.enabled instead — note it now defaults to false, because the UI has no authentication of its own and publishing it exposes full cluster admin." -}}
{{- end -}}
{{- include "manticore.validateTables" . -}}
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
Common labels - delegated to cpln-common
*/}}
{{- define "manticore.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}

{{/*
Reject the pre-rename bare cpu/memory keys. Left unguarded they are silently
ignored and the chart falls back to its own default limit — wrong resources
with no signal.
*/}}
{{- define "manticore.validateResourceKnobs" -}}
{{- if (.Values.orchestrator.agent.resources).cpu -}}
{{- fail "manticore: orchestrator.agent.resources.cpu was RENAMED to orchestrator.agent.resources.maxCpu. A block exposing both a reservation and a limit names the limit maxCpu/maxMemory, so the bare name is no longer read and would be silently ignored. Rename it in your values." -}}
{{- end -}}
{{- if (.Values.orchestrator.agent.resources).memory -}}
{{- fail "manticore: orchestrator.agent.resources.memory was RENAMED to orchestrator.agent.resources.maxMemory. A block exposing both a reservation and a limit names the limit maxCpu/maxMemory, so the bare name is no longer read and would be silently ignored. Rename it in your values." -}}
{{- end -}}
{{- end -}}
