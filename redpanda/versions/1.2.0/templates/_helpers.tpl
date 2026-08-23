{{/*
Release name
*/}}
{{- define "redpanda.name" -}}
{{- printf "%s" .Release.Name -}}
{{- end }}

{{/*
Broker cluster workload name
*/}}
{{- define "redpanda.clusterName" -}}
{{- printf "%s-%s" (include "redpanda.name" .) .Values.redpanda.name -}}
{{- end }}

{{/*
Console workload name
*/}}
{{- define "redpanda.consoleName" -}}
{{- printf "%s-%s" (include "redpanda.name" .) .Values.redpanda_console.name -}}
{{- end }}

{{/*
Default replication factor: min(3, replicas). Redpanda rejects a replication factor greater
than the number of brokers, so we clamp to the cluster size.
*/}}
{{- define "redpanda.defaultReplicationFactor" -}}
{{- $replicas := .Values.redpanda.replicas | int -}}
{{- if lt $replicas 3 -}}{{ $replicas }}{{- else -}}3{{- end -}}
{{- end }}

{{/*
Console startup-script secret name. The console config file carries SASL credentials,
so it is assembled inside the container from injected secrets rather than rendered by
Helm — see secret-console-init.yaml.
*/}}
{{- define "redpanda.secret.consoleInit.name" -}}
{{- printf "%s-console-init" (include "redpanda.name" .) -}}
{{- end }}

{{/*
Top-level validation — included by identity.yaml, which always renders.
*/}}
{{- define "redpanda.validate" -}}
{{- include "redpanda.validateResourceKnobs" . -}}
{{- include "redpanda.validateReplicas" . -}}
{{- include "redpanda.validateAuth" . -}}
{{- end }}

{{/*
Validate replica count — Raft consensus requires an odd number for quorum.
*/}}
{{- define "redpanda.validateReplicas" -}}
{{- $replicas := .Values.redpanda.replicas | int -}}
{{- if or (eq $replicas 2) (eq $replicas 4) (gt $replicas 5) -}}
  {{- fail "redpanda.replicas must be 1, 3, or 5 — Raft consensus requires an odd number for quorum." -}}
{{- end -}}
{{- end }}

{{/*
Validate the SASL user list. As of 1.1.0 every user's credentials are a user-created
prerequisite secret, never values — a Kafka SASL password is what applications put in
their client config and what a human pastes into rpk, so it is the product, not
internal plumbing.
*/}}
{{- define "redpanda.validateAuth" -}}
{{- if not .Values.redpanda.auth.users -}}
  {{- fail "At least one entry is required in redpanda.auth.users — the first entry is the cluster superuser the console and internal clients authenticate as." -}}
{{- end -}}
{{- range $i, $u := .Values.redpanda.auth.users -}}
  {{- if hasKey $u "password" -}}
    {{- fail (printf "redpanda.auth.users[%d].password was REMOVED in redpanda 1.1.0. SASL credentials are no longer values: create a `dictionary` secret holding the keys `username` and `password`, and set redpanda.auth.users[%d].credentialsSecretName to its name. See Prerequisites in the README." $i $i) -}}
  {{- end -}}
  {{- if hasKey $u "username" -}}
    {{- fail (printf "redpanda.auth.users[%d].username was REMOVED in redpanda 1.1.0. The username now comes from the `username` key of the `dictionary` secret named by redpanda.auth.users[%d].credentialsSecretName, so that it travels with the password it belongs to. See Prerequisites in the README." $i $i) -}}
  {{- end -}}
  {{- if not $u.credentialsSecretName -}}
    {{- fail (printf "redpanda.auth.users[%d].credentialsSecretName is required — it names the `dictionary` secret holding that SASL user's `username` and `password` keys. Create that secret BEFORE installing; see Prerequisites in the README." $i) -}}
  {{- end -}}
{{- end -}}
{{- end }}

{{/*
Common labels
*/}}
{{- define "redpanda.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}

{{/*
Reject the pre-rename bare cpu/memory keys. Left unguarded they are silently
ignored and the chart falls back to its own default limit — wrong resources
with no signal.
*/}}
{{- define "redpanda.validateResourceKnobs" -}}
{{- if (.Values.redpanda).cpu -}}
{{- fail "redpanda: redpanda.cpu was RENAMED to redpanda.maxCpu. A block exposing both a reservation and a limit names the limit maxCpu/maxMemory, so the bare name is no longer read and would be silently ignored. Rename it in your values." -}}
{{- end -}}
{{- if (.Values.redpanda).memory -}}
{{- fail "redpanda: redpanda.memory was RENAMED to redpanda.maxMemory. A block exposing both a reservation and a limit names the limit maxCpu/maxMemory, so the bare name is no longer read and would be silently ignored. Rename it in your values." -}}
{{- end -}}
{{- if (.Values.redpanda_console).cpu -}}
{{- fail "redpanda: redpanda_console.cpu was RENAMED to redpanda_console.maxCpu. A block exposing both a reservation and a limit names the limit maxCpu/maxMemory, so the bare name is no longer read and would be silently ignored. Rename it in your values." -}}
{{- end -}}
{{- if (.Values.redpanda_console).memory -}}
{{- fail "redpanda: redpanda_console.memory was RENAMED to redpanda_console.maxMemory. A block exposing both a reservation and a limit names the limit maxCpu/maxMemory, so the bare name is no longer read and would be silently ignored. Rename it in your values." -}}
{{- end -}}
{{- end -}}
