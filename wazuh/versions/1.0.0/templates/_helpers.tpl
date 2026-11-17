{{/* ─── Resource names ─────────────────────────────────────────────────── */}}

{{- define "wazuh.name" -}}
{{- printf "%s-wazuh" .Release.Name }}
{{- end }}

{{- define "wazuh.manager.name" -}}
{{- printf "%s-wazuh-manager" .Release.Name }}
{{- end }}

{{- define "wazuh.worker.name" -}}
{{- printf "%s-wazuh-worker" .Release.Name }}
{{- end }}

{{- define "wazuh.indexer.name" -}}
{{- printf "%s-wazuh-indexer" .Release.Name }}
{{- end }}

{{- define "wazuh.dashboard.name" -}}
{{- printf "%s-wazuh-dashboard" .Release.Name }}
{{- end }}

{{- define "wazuh.demoAgent.name" -}}
{{- printf "%s-wazuh-demo-agent" .Release.Name }}
{{- end }}

{{- define "wazuh.volume.manager.name" -}}
{{- printf "%s-wazuh-manager-data" .Release.Name }}
{{- end }}

{{- define "wazuh.volume.worker.name" -}}
{{- printf "%s-wazuh-worker-data" .Release.Name }}
{{- end }}

{{- define "wazuh.volume.indexer.name" -}}
{{- printf "%s-wazuh-indexer-data" .Release.Name }}
{{- end }}

{{- define "wazuh.volume.pki.name" -}}
{{- printf "%s-wazuh-pki" .Release.Name }}
{{- end }}

{{- define "wazuh.secret.config.name" -}}
{{- printf "%s-wazuh-manager-config" .Release.Name }}
{{- end }}

{{- define "wazuh.identity.name" -}}
{{- printf "%s-wazuh-identity" .Release.Name }}
{{- end }}

{{- define "wazuh.policy.name" -}}
{{- printf "%s-wazuh-policy" .Release.Name }}
{{- end }}

{{/* ─── Internal hostnames ─────────────────────────────────────────────── */}}

{{- define "wazuh.manager.host" -}}
{{- printf "%s.%s.cpln.local" (include "wazuh.manager.name" .) .Values.global.cpln.gvc }}
{{- end }}

{{- define "wazuh.worker.host" -}}
{{- printf "%s.%s.cpln.local" (include "wazuh.worker.name" .) .Values.global.cpln.gvc }}
{{- end }}

{{- define "wazuh.indexer.host" -}}
{{- printf "%s.%s.cpln.local" (include "wazuh.indexer.name" .) .Values.global.cpln.gvc }}
{{- end }}

{{/* Where agents send events: the workers when there are any, else the master. */}}
{{- define "wazuh.agentTarget.name" -}}
{{- if gt (int .Values.manager.workers.replicas) 0 }}{{ include "wazuh.worker.name" . }}{{ else }}{{ include "wazuh.manager.name" . }}{{ end }}
{{- end }}

{{- define "wazuh.workloadLink" -}}
{{- printf "//gvc/%s/workload/%s" .ctx.Values.global.cpln.gvc .name }}
{{- end }}

{{/*
Workloads of this release that call the manager (and workers) internally. Added to the
manager's allow-list when manager.internalAccess.type is workload-list.
*/}}
{{- define "wazuh.manager.callers" -}}
{{- $l := list (include "wazuh.workloadLink" (dict "ctx" . "name" (include "wazuh.dashboard.name" .))) (include "wazuh.workloadLink" (dict "ctx" . "name" (include "wazuh.manager.name" .))) }}
{{- if gt (int .Values.manager.workers.replicas) 0 }}
{{- $l = append $l (include "wazuh.workloadLink" (dict "ctx" . "name" (include "wazuh.worker.name" .))) }}
{{- end }}
{{- if .Values.demoAgent.enabled }}
{{- $l = append $l (include "wazuh.workloadLink" (dict "ctx" . "name" (include "wazuh.demoAgent.name" .))) }}
{{- end }}
{{- toJson $l }}
{{- end }}

{{/* firewallConfig.internal for the manager and the workers (they share manager.internalAccess). */}}
{{- define "wazuh.manager.internalFirewall" -}}
inboundAllowType: {{ .Values.manager.internalAccess.type }}
{{- $allow := .Values.manager.internalAccess.workloads | default list }}
{{- if eq .Values.manager.internalAccess.type "workload-list" }}
{{- $allow = concat $allow (include "wazuh.manager.callers" . | fromJsonArray) }}
{{- end }}
{{- $allow = $allow | uniq | sortAlpha }}
inboundAllowWorkload: {{- if $allow }}{{ $allow | toYaml | nindent 2 }}{{- else }} []{{- end }}
{{- end }}

{{/* firewallConfig.external for the manager and the workers (agent ports on a direct load balancer). */}}
{{- define "wazuh.manager.externalFirewall" -}}
{{- if .Values.manager.publicAccess.enabled }}
inboundAllowCIDR: {{ .Values.manager.publicAccess.allowedCidrs | toYaml | nindent 2 }}
{{- else }}
inboundAllowCIDR: []
{{- end }}
inboundBlockedCIDR: []
outboundAllowCIDR:
  - 0.0.0.0/0
outboundAllowHostname: []
outboundBlockedCIDR: []
{{- end }}

{{- define "wazuh.manager.loadBalancer" -}}
{{- if .Values.manager.publicAccess.enabled }}
direct:
  enabled: true
  ports:
    - containerPort: 1514
      externalPort: 1514
      protocol: TCP
      scheme: tcp
    - containerPort: 1515
      externalPort: 1515
      protocol: TCP
      scheme: tcp
    {{- if .Values.manager.publicAccess.api }}
    - containerPort: 55000
      externalPort: 55000
      protocol: TCP
      scheme: tcp
    {{- end }}
replicaDirect: false
{{- else }}
replicaDirect: false
{{- end }}
{{- end }}

{{/*
Render a shell script as one container arg. The platform expands $(VAR) and collapses $$ in
args, so every $ is doubled; the stored arg reduces back to the script byte for byte.
*/}}
{{- define "wazuh.inlineScript" -}}
{{- . | replace "$" "$$" }}
{{- end }}

{{/*
Shared shell function: validate a credential from the prerequisite secret and stop the
container with a clear message when it breaks the rules (the chart cannot read the secret).
*/}}
{{- define "wazuh.script.validate" -}}
pw_re='^[A-Za-z][A-Za-z0-9.*+?-]*$'
up_re='[A-Z]'; lo_re='[a-z]'; di_re='[0-9]'; sy_re='[.*+?-]'
validate_password() {
  local name="$1" v="$2"
  if [ -z "$v" ]; then
    echo "INVALID $name: the key is missing or empty in secret {{ .Values.credentialsSecretName }}" >&2; exit 1
  fi
  if [ "${#v}" -lt 8 ] || [ "${#v}" -gt 64 ] || ! [[ "$v" =~ $pw_re ]] \
     || ! [[ "$v" =~ $up_re ]] || ! [[ "$v" =~ $lo_re ]] || ! [[ "$v" =~ $di_re ]] || ! [[ "$v" =~ $sy_re ]]; then
    echo "INVALID $name: use 8-64 characters, start with a letter, only A-Z a-z 0-9 . * + ? - and at least one uppercase letter, one lowercase letter, one digit and one of . * + ? -" >&2
    exit 1
  fi
}
{{- end }}

{{/* ─── Validation ─────────────────────────────────────────────────────── */}}

{{- define "wazuh.validate" -}}
{{- if not .Values.credentialsSecretName -}}
  {{- fail "credentialsSecretName is required: it names the prerequisite dictionary secret (indexerAdminPassword, dashboardServerPassword, apiPassword, enrollmentPassword, clusterKey, dashboardCookieSecret). Create it BEFORE installing." -}}
{{- end -}}
{{- $ir := int .Values.indexer.replicas -}}
{{- if not (or (eq $ir 1) (and (ge $ir 3) (eq (mod $ir 2) 1))) -}}
  {{- fail "indexer.replicas must be 1, or an odd number of 3 or more (an even count cannot keep a majority through a node loss)" -}}
{{- end -}}
{{- if lt (int .Values.manager.workers.replicas) 0 -}}
  {{- fail "manager.workers.replicas must be 0 or more" -}}
{{- end -}}
{{- if lt (int .Values.manager.logRetentionDays) 0 -}}
  {{- fail "manager.logRetentionDays must be 0 (keep forever) or more" -}}
{{- end -}}
{{- if lt (int .Values.indexer.retentionDays) 0 -}}
  {{- fail "indexer.retentionDays must be 0 (keep forever) or more" -}}
{{- end -}}
{{- if and .Values.manager.publicAccess.api (not .Values.manager.publicAccess.enabled) -}}
  {{- fail "manager.publicAccess.api needs manager.publicAccess.enabled: the API is exposed on the agents' load balancer" -}}
{{- end -}}
{{- if and .Values.manager.publicAccess.enabled (not .Values.manager.publicAccess.allowedCidrs) -}}
  {{- fail "manager.publicAccess.allowedCidrs must list at least one CIDR when manager.publicAccess.enabled is true (use 0.0.0.0/0 for anywhere)" -}}
{{- end -}}
{{- if and .Values.manager.extraConfig (not (contains "<ossec_config>" .Values.manager.extraConfig)) -}}
  {{- fail "manager.extraConfig must be one or more complete <ossec_config>…</ossec_config> blocks" -}}
{{- end -}}
{{- if not (regexMatch "^[0-9]+[mg]$" (toString .Values.indexer.javaHeap)) -}}
  {{- fail "indexer.javaHeap must be a number followed by m or g, such as 2g or 1536m" -}}
{{- end -}}
{{- $mt := .Values.manager.internalAccess.type -}}
{{- if not (or (eq $mt "same-gvc") (eq $mt "same-org") (eq $mt "workload-list")) -}}
  {{- fail "manager.internalAccess.type must be one of: same-gvc, same-org, workload-list (none would cut the dashboard off from the Wazuh server API)" -}}
{{- end -}}
{{- $dt := .Values.dashboard.internalAccess.type -}}
{{- if not (or (eq $dt "none") (eq $dt "same-gvc") (eq $dt "same-org") (eq $dt "workload-list")) -}}
  {{- fail "dashboard.internalAccess.type must be one of: none, same-gvc, same-org, workload-list" -}}
{{- end -}}
{{- if lt (int .Values.dashboard.replicas) 1 -}}
  {{- fail "dashboard.replicas must be 1 or more" -}}
{{- end -}}
{{- /* The platform rejects snapshot schedules more frequent than hourly, at apply time only (a
       half-installed release): a single fixed minute keeps a schedule at most hourly. */ -}}
{{- range $key, $vs := dict "manager.volumeset" .Values.manager.volumeset "manager.workers.volumeset" .Values.manager.workers.volumeset "indexer.volumeset" .Values.indexer.volumeset -}}
{{- $s := trim (toString $vs.snapshots.schedule) -}}
{{- if and $s (not (regexMatch "^[0-5]?[0-9] +[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+$" $s)) -}}
  {{- fail (printf "%s.snapshots.schedule %q must be a 5-field cron with a single fixed minute (snapshots cannot run more often than hourly), e.g. \"0 3 * * *\"; use \"\" to turn snapshots off" $key $s) -}}
{{- end -}}
{{- if not (regexMatch "^[0-9]+(\\.[0-9]+)?[dhm]$" (toString $vs.snapshots.retentionDuration)) -}}
  {{- fail (printf "%s.snapshots.retentionDuration must be a number followed by d, h or m, such as 7d" $key) -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/* ─── Labeling ───────────────────────────────────────────────────────── */}}

{{- define "wazuh.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
