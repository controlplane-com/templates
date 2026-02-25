{{- define "calculateWorkloadCounts" -}}
{{- $quorumCount := int .Values.sentinel.quorum }}
{{- $workloadCount := 0 }}
{{- if eq $quorumCount 1 }}
  {{- $workloadCount = 1 }}
{{- else }}
  {{- $workloadCount = int (add $quorumCount 1) }}
{{- end }}
{{- $locations := default (list) .Values.locations }}
{{- if and $locations (gt (len $locations) 0) }}
  {{- $locationCount := (len $locations) }}
  {{- $baseCount := int (div $workloadCount $locationCount) }}
  {{- $remainderCount := int (mod $workloadCount $locationCount) }}
  {{- if not .Values.global }}
    {{- $ := set .Values "global" (dict) }}
  {{- end }}
  {{- $ := set .Values.global "baseCount" $baseCount }}
  {{- $ := set .Values.global "remainderCount" $remainderCount }}
  {{- $ := set .Values.global "locationCount" $locationCount }}
  {{- $ := set .Values.global "workloadCount" $workloadCount }}
{{- end }}
{{- end }}


{{ include "redis.auth" (dict "auth" .Values.redis.auth) }}

redis:
  image: redis/redis-stack:7.4.0-v3
  resources:
    cpu: 200m
    memory: 256Mi
    minCpu: 80m
    minMemory: 128Mi
  replicas: 3
  timeoutSeconds: 15
  auth:
    fromSecret:
      enabled: false
      name: example-redis-auth-password
      passwordKey: password
    password:
      enabled: true
      value: fu3h4f9834f8

{{/*
Validate auth configuration block
*/}}
{{- define "validateAuth" -}}
{{- $auth := .auth -}}

{{- /* Check if auth block exists */ -}}
{{- if $auth -}}
  {{- /* Count enabled auth methods */ -}}
  {{- $enabledCount := 0 -}}
  
  {{- /* Check fromSecret */ -}}
  {{- if and (hasKey $auth "fromSecret") $auth.fromSecret.enabled -}}
    {{- $enabledCount = add1 $enabledCount -}}
  {{- end -}}
  
  {{- /* Check password */ -}}
  {{- if and (hasKey $auth "password") $auth.password.enabled -}}
    {{- $enabledCount = add1 $enabledCount -}}
  {{- end -}}
  
  {{- /* Validate that at most one method is enabled */ -}}
  {{- if gt $enabledCount 1 -}}
    {{- fail "Only one authentication method can be enabled at a time" -}}
  {{- end -}}
  
  {{- /* If fromSecret is enabled, validate its configuration */ -}}
  {{- if and (hasKey $auth "fromSecret") $auth.fromSecret.enabled -}}
    {{- if not (hasKey $auth.fromSecret "name") -}}
      {{- fail "fromSecret authentication requires a name" -}}
    {{- end -}}
    {{- if not (hasKey $auth.fromSecret "passwordKey") -}}
      {{- fail "fromSecret authentication requires a passwordKey" -}}
    {{- end -}}
  {{- end -}}
  
  {{- /* If password is enabled, validate its configuration */ -}}
  {{- if and (hasKey $auth "password") $auth.password.enabled -}}
    {{- if not (hasKey $auth.password "value") -}}
      {{- fail "password authentication requires a value" -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- end -}}