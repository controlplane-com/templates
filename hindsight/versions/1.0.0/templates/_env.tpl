{{/*
Environment shared by the API and the worker: database, auth, models and the escape hatches.
The database URL is assembled from $(VAR) placeholders at container start, so the password never
enters a render (it is not percent-encoded: the credentials must be letters and digits).
*/}}
{{- define "hindsight.env.common" -}}
{{- $db := include "hindsight.db.secretName" . -}}
- name: HS_DB_USER
  value: 'cpln://secret/{{ $db }}.username'
- name: HS_DB_PASSWORD
  value: 'cpln://secret/{{ $db }}.password'
- name: HS_DB_NAME
  value: 'cpln://secret/{{ $db }}.database'
- name: HINDSIGHT_API_DATABASE_URL
  value: 'postgresql://$(HS_DB_USER):$(HS_DB_PASSWORD)@{{ include "hindsight.db.host" . }}:5432/$(HS_DB_NAME)'
- name: HINDSIGHT_API_DB_POOL_MIN_SIZE
  value: "2"
- name: HINDSIGHT_API_DB_POOL_MAX_SIZE
  value: {{ .Values.hindsight.dbPoolMaxSize | toString | quote }}
- name: HINDSIGHT_API_TENANT_EXTENSION
  value: hindsight_api.extensions.builtin.tenant:ApiKeyTenantExtension
- name: HINDSIGHT_API_TENANT_API_KEY
  value: 'cpln://secret/{{ .Values.auth.apiKeySecretName }}.payload'
- name: HINDSIGHT_API_MCP_STATELESS
  value: "true"
- name: HINDSIGHT_API_LLM_PROVIDER
  value: {{ .Values.llm.provider | toString | quote }}
{{- with .Values.llm.model }}
- name: HINDSIGHT_API_LLM_MODEL
  value: {{ . | toString | quote }}
{{- end }}
{{- with .Values.llm.baseUrl }}
- name: HINDSIGHT_API_LLM_BASE_URL
  value: {{ . | toString | quote }}
{{- end }}
{{- with .Values.llm.apiKeySecretName }}
- name: HINDSIGHT_API_LLM_API_KEY
  value: 'cpln://secret/{{ . }}.payload'
{{- end }}
- name: HINDSIGHT_API_EMBEDDINGS_PROVIDER
  value: {{ .Values.embeddings.provider | toString | quote }}
{{- if eq (toString .Values.embeddings.provider) "openai" }}
{{- with .Values.embeddings.model }}
- name: HINDSIGHT_API_EMBEDDINGS_OPENAI_MODEL
  value: {{ . | toString | quote }}
{{- end }}
{{- with .Values.embeddings.baseUrl }}
- name: HINDSIGHT_API_EMBEDDINGS_OPENAI_BASE_URL
  value: {{ . | toString | quote }}
{{- end }}
{{- with .Values.embeddings.apiKeySecretName }}
- name: HINDSIGHT_API_EMBEDDINGS_OPENAI_API_KEY
  value: 'cpln://secret/{{ . }}.payload'
{{- end }}
{{- end }}
- name: HINDSIGHT_API_RERANKER_PROVIDER
  value: {{ .Values.reranker.provider | toString | quote }}
{{- if include "hindsight.localModels" . }}
- name: HF_HUB_OFFLINE
  value: "1"
{{- end }}
{{- range .Values.hindsight.extraSecrets.keys }}
- name: {{ . }}
  value: 'cpln://secret/{{ $.Values.hindsight.extraSecrets.secretName }}.{{ . }}'
{{- end }}
{{- range .Values.hindsight.extraEnv }}
- name: {{ .name }}
  value: {{ .value | toString | quote }}
{{- end }}
{{- end }}
