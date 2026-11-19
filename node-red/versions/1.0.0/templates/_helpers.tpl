{{/* Resource Naming */}}

{{- define "node-red.name" -}}
{{- printf "%s-node-red" .Release.Name }}
{{- end }}

{{- define "node-red.volume.name" -}}
{{- printf "%s-node-red-data" .Release.Name }}
{{- end }}

{{- define "node-red.identity.name" -}}
{{- printf "%s-node-red-identity" .Release.Name }}
{{- end }}

{{- define "node-red.policy.name" -}}
{{- printf "%s-node-red-policy" .Release.Name }}
{{- end }}


{{/* Labeling */}}

{{- define "node-red.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}


{{/*
Render a script for a container arg. The platform, like Kubernetes, expands
$(VAR) and turns $$ into $ inside container args, so every $ is doubled and
bash receives the script byte for byte (copied from directus.inlineScript).
*/}}
{{- define "node-red.inlineScript" -}}
|-
{{ . | replace "$" "$$" | indent 2 }}
{{- end -}}


{{/* Placement */}}

{{/*
`autoscaling` for one options entry. `scale` is 0 for `defaultOptions` and 1 for
the one `localOptions` entry. A workload runs in EVERY location its GVC has, so
`defaultOptions` at 0/0 confines this release to `location` BY CONSTRUCTION: on
a 3-location GVC an unpinned Node-RED would be three independent runtimes, each
firing every cron, MQTT subscription and webhook. Every field is repeated in the
localOptions entry: the API completes a partial entry from its own platform
defaults, not from defaultOptions.
*/}}
{{- define "node-red.autoscaling" -}}
maxConcurrency: 0
maxScale: {{ .scale }}
metric: disabled
minScale: {{ .scale }}
scaleToZeroDelay: 300
target: 100
{{- end -}}

{{- define "node-red.localOptions" -}}
- autoscaling:
    {{- include "node-red.autoscaling" (dict "scale" 1) | nindent 4 }}
  capacityAI: false
  debug: false
  location: //location/{{ .Values.location }}
  suspend: false
  timeoutSeconds: 300
{{- end -}}


{{/*
Env names the chart sets itself (or that Node-RED reads and the chart
controls). Refused in extraEnv and envSecret.keys, with the CPLN_ prefix.
*/}}
{{- define "node-red.reservedEnv" -}}
NR_ADMIN_USERNAME NR_ADMIN_PASSWORD NR_CREDENTIAL_SECRET NR_HTTP_NODE_USERNAME NR_HTTP_NODE_PASSWORD NR_PALETTE_PACKAGES NODE_RED_ENABLE_SAFE_MODE NODE_RED_ENABLE_PROJECTS NODE_RED_HOME NODE_PATH PATH TZ PORT
{{- end }}


{{/* Validation */}}

{{- define "node-red.validate" -}}
{{- include "node-red.validateLocation" . -}}
{{- include "node-red.validateAdmin" . -}}
{{- include "node-red.validateCredentialSecret" . -}}
{{- include "node-red.validateHttpNodeAuth" . -}}
{{- include "node-red.validateContextStorage" . -}}
{{- include "node-red.validateFlags" . -}}
{{- include "node-red.validatePalette" . -}}
{{- include "node-red.validateVolumeset" . -}}
{{- include "node-red.validateBackup" . -}}
{{- include "node-red.validateEnv" . -}}
{{- include "node-red.validateInternalAccess" . -}}
{{- end }}

{{/*
`location` names the ONE GVC location Node-RED runs in. Helm cannot see the live
GVC at render time, so a `location` the GVC does NOT have is not checkable here:
the platform accepts it and the release runs nothing (README names the symptom).
*/}}
{{- define "node-red.validateLocation" -}}
{{- if hasKey .Values "gvc" -}}
{{- fail "node-red: a `gvc` values key is not supported — this chart deploys into the GVC you install it into (global.cpln.gvc) and never creates one" -}}
{{- end -}}
{{- if hasKey .Values "locations" -}}
{{- fail "node-red: `locations` (plural) is not a key of this chart. Node-RED runs in exactly ONE location — use the singular `location`, e.g. `location: aws-us-east-1`." -}}
{{- end -}}
{{- if not .Values.location -}}
{{- fail "node-red: `location` is required — it names the ONE location of your GVC that Node-RED runs in, e.g. `location: aws-us-east-1`. A workload runs in EVERY location its GVC has, so without this pin a multi-location GVC would start one independent Node-RED per location, each running every flow. List your GVC's locations with `cpln gvc get <gvc> -o yaml` (spec.staticPlacement.locationLinks)." -}}
{{- end -}}
{{- if not (kindIs "string" .Values.location) -}}
{{- fail "node-red: `location` must be a single location NAME, e.g. `location: aws-us-east-1`. Node-RED runs in exactly one location — a second location would be a second, independent runtime." -}}
{{- end -}}
{{- if not (regexMatch "^[a-z0-9]+(-[a-z0-9]+)*$" .Values.location) -}}
{{- fail (printf "node-red: `location` must be a bare location NAME like `aws-us-east-1`, got '%s'. A link form (`//location/x`) or a comma-separated list stores a placement that matches no real location, so Node-RED starts NOWHERE and the logs are silent." .Values.location) -}}
{{- end -}}
{{- end }}

{{- define "node-red.validateAdmin" -}}
{{- if not .Values.admin.secretName -}}
{{- fail "node-red: admin.secretName is required — the name of your pre-created `dictionary` secret holding the editor login (`username` and `password`, at least 12 characters). See Prerequisites in the README." -}}
{{- end -}}
{{- end }}

{{- define "node-red.validateCredentialSecret" -}}
{{- if not .Values.credentialSecret.secretName -}}
{{- fail "node-red: credentialSecret.secretName is required — the name of your pre-created `opaque` secret (at least 16 characters) that encrypts the credentials stored in your flows. See Prerequisites in the README." -}}
{{- end -}}
{{- end }}

{{- define "node-red.validateHttpNodeAuth" -}}
{{- if not (kindIs "string" .Values.httpNodeAuth.secretName) -}}
{{- fail "node-red: httpNodeAuth.secretName must be a secret name, or \"\" to leave HTTP In endpoints and the Dashboard without a login" -}}
{{- end -}}
{{- end }}

{{- define "node-red.validateContextStorage" -}}
{{- if not (has .Values.contextStorage (list "localfilesystem" "memory")) -}}
{{- fail (printf "node-red: contextStorage must be 'localfilesystem' or 'memory', got '%v'" .Values.contextStorage) -}}
{{- end -}}
{{- end }}

{{/* Rendered as JavaScript literals into settings.js, so they must be real booleans. */}}
{{- define "node-red.validateFlags" -}}
{{- range $k, $v := dict "projects.enabled" .Values.projects.enabled "safeMode" .Values.safeMode "publicAccess.enabled" .Values.publicAccess.enabled "backup.enabled" .Values.backup.enabled -}}
{{- if not (kindIs "bool" $v) -}}
{{- fail (printf "node-red: %s must be true or false, got '%v'" $k $v) -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Pinned `name@version` only: the list is passed to `npm install` as an env var,
so this regex is also what keeps shell metacharacters and version ranges out.
*/}}
{{- define "node-red.validatePalette" -}}
{{- if not (kindIs "bool" .Values.palette.allowInstall) -}}
{{- fail (printf "node-red: palette.allowInstall must be true or false, got '%v'" .Values.palette.allowInstall) -}}
{{- end -}}
{{- if not (kindIs "slice" .Values.palette.packages) -}}
{{- fail "node-red: palette.packages must be a list of pinned name@version entries, e.g. [\"@flowfuse/node-red-dashboard@1.36.1\"]" -}}
{{- end -}}
{{- range .Values.palette.packages -}}
{{- if not (regexMatch "^(@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]*@[0-9A-Za-z][0-9A-Za-z.+-]*$" (toString .)) -}}
{{- fail (printf "node-red: palette.packages entry '%v' must be a pinned npm package name@version, e.g. node-red-contrib-foo@1.2.3 or @flowfuse/node-red-dashboard@1.36.1 (no ranges, tags or URLs)" .) -}}
{{- end -}}
{{- end -}}
{{- end }}

{{- define "node-red.validateVolumeset" -}}
{{- if lt (int .Values.volumeset.capacity) 10 -}}
{{- fail (printf "node-red: volumeset.capacity must be at least 10 (GiB), got '%v'" .Values.volumeset.capacity) -}}
{{- end -}}
{{- end }}

{{/*
The platform rejects snapshot schedules more frequent than hourly at apply time
only; a schedule runs at most hourly when its minute field is one fixed minute.
retentionDuration: a number then d, h or m (the API's volume set schema).
*/}}
{{- define "node-red.validateBackup" -}}
{{- if not (regexMatch "^[0-9]+(\\.[0-9]+)?[dhm]$" (toString .Values.backup.retention)) -}}
{{- fail (printf "node-red: backup.retention must be a number followed by d, h or m, e.g. 7d — got '%v'. It also sets how long the final snapshot taken at uninstall is kept." .Values.backup.retention) -}}
{{- end -}}
{{- if .Values.backup.enabled -}}
{{- if not (regexMatch "^[0-5]?[0-9] +[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+$" (trim (toString .Values.backup.schedule))) -}}
{{- fail (printf "node-red: backup.schedule %q must be a 5-field cron with a single fixed minute (snapshots cannot run more often than hourly), e.g. \"0 3 * * *\"" (toString .Values.backup.schedule)) -}}
{{- end -}}
{{- end -}}
{{- end }}

{{- define "node-red.validateEnv" -}}
{{- if and .Values.envSecret.secretName (not .Values.envSecret.keys) -}}
{{- fail "node-red: envSecret.keys must list the keys of your envSecret.secretName dictionary secret to load as env vars (for example [API_TOKEN])" -}}
{{- end -}}
{{- if and .Values.envSecret.keys (not .Values.envSecret.secretName) -}}
{{- fail "node-red: envSecret.keys is set but envSecret.secretName is empty — name the `dictionary` secret holding those keys" -}}
{{- end -}}
{{- $reserved := splitList " " (include "node-red.reservedEnv" .) -}}
{{- $names := list -}}
{{- range .Values.envSecret.keys -}}
{{- $names = append $names (toString .) -}}
{{- end -}}
{{- range .Values.extraEnv -}}
{{- if not (and (kindIs "map" .) (hasKey . "name") (hasKey . "value")) -}}
{{- fail "node-red: every extraEnv entry needs a name and a value" -}}
{{- end -}}
{{- $names = append $names (toString .name) -}}
{{- end -}}
{{- $seen := dict -}}
{{- range $names -}}
{{- if not (regexMatch "^[A-Za-z_][A-Za-z0-9_]*$" .) -}}
{{- fail (printf "node-red: %q is not a valid env var name (letters, digits and _, not starting with a digit)" .) -}}
{{- end -}}
{{- if hasPrefix "CPLN_" (upper .) -}}
{{- fail (printf "node-red: env var names starting with CPLN_ are reserved by Control Plane (%s)" .) -}}
{{- end -}}
{{- if has (upper .) $reserved -}}
{{- fail (printf "node-red: env var %s is set by the chart and cannot be overridden in extraEnv or envSecret.keys" .) -}}
{{- end -}}
{{- if hasKey $seen . -}}
{{- fail (printf "node-red: env var %s is defined more than once across extraEnv and envSecret.keys" .) -}}
{{- end -}}
{{- $_ := set $seen . true -}}
{{- end -}}
{{- end }}

{{- define "node-red.validateInternalAccess" -}}
{{- $t := .Values.internalAccess.type -}}
{{- if not (has $t (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "node-red: internalAccess.type must be one of none, same-gvc, same-org, workload-list (got %q)" $t) -}}
{{- end -}}
{{- if and (eq $t "workload-list") (not .Values.internalAccess.workloads) -}}
{{- fail "node-red: internalAccess.workloads must list at least one workload link (//gvc/GVC_NAME/workload/WORKLOAD_NAME) when internalAccess.type is workload-list" -}}
{{- end -}}
{{- end }}
