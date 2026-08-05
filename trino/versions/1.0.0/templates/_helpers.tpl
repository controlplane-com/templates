{{/* Resource Naming */}}

{{- define "trino.name" -}}
{{- printf "%s-trino" .Release.Name }}
{{- end }}

{{- define "trino.worker.name" -}}
{{- printf "%s-trino-worker" .Release.Name }}
{{- end }}

{{- define "trino.secret.coordinatorConfig.name" -}}
{{- printf "%s-trino-coordinator-config" .Release.Name }}
{{- end }}

{{- define "trino.secret.workerConfig.name" -}}
{{- printf "%s-trino-worker-config" .Release.Name }}
{{- end }}

{{- define "trino.secret.jvm.name" -}}
{{- printf "%s-trino-jvm" .Release.Name }}
{{- end }}

{{- define "trino.secret.node.name" -}}
{{- printf "%s-trino-node" .Release.Name }}
{{- end }}

{{/* Per-catalog config secret. Call with (dict "root" $ "catalog" "<name>"). */}}
{{- define "trino.secret.catalog.name" -}}
{{- printf "%s-trino-catalog-%s" .root.Release.Name (.catalog | replace "_" "-") }}
{{- end }}

{{- define "trino.secret.passwordAuthenticator.name" -}}
{{- printf "%s-trino-password-authenticator" .Release.Name }}
{{- end }}

{{- define "trino.identity.name" -}}
{{- printf "%s-trino-identity" .Release.Name }}
{{- end }}

{{- define "trino.policy.name" -}}
{{- printf "%s-trino-policy" .Release.Name }}
{{- end }}


{{/* Unit helpers */}}

{{/* CPU quantity ("500m", "2") → millicores as a plain number. */}}
{{- define "trino.millicores" -}}
{{- $v := printf "%v" . -}}
{{- if hasSuffix "m" $v -}}
{{- trimSuffix "m" $v -}}
{{- else -}}
{{- mulf ($v | float64) 1000 | int64 -}}
{{- end -}}
{{- end -}}

{{/* Memory quantity ("512Mi", "4Gi") → mebibytes as a plain number. */}}
{{- define "trino.mebibytes" -}}
{{- $v := printf "%v" . -}}
{{- if hasSuffix "Gi" $v -}}
{{- mul (trimSuffix "Gi" $v | int) 1024 -}}
{{- else if hasSuffix "Mi" $v -}}
{{- trimSuffix "Mi" $v | int -}}
{{- else -}}
{{- 0 -}}
{{- end -}}
{{- end -}}


{{/* Rendered config files */}}

{{/*
Coordinator config.properties.
- discovery.uri is localhost: the discovery server runs in-process, so this
  removes any dependency on the workload's own DNS record being live at boot.
- node.internal-address pins the coordinator's announced address to its service
  DNS name (it is always single-replica, so the name resolves uniquely) instead
  of the pod IP airlift would compute by default.
- node-scheduler.include-coordinator defaults to true upstream, so the
  distributed shape must set it to false explicitly.
- http-server.process-forwarded is MANDATORY on Control Plane, not just when
  public: the mesh adds X-Forwarded-Proto to every hop, including in-GVC ones,
  and Jetty's default REJECT mode answers such a request with
  "406 Server configuration does not allow processing of the X-Forwarded-Proto
  header" — which silently breaks worker announcements (verified 2026-08-05).
  It also makes edge-terminated requests read as HTTPS when public.
*/}}
{{- define "trino.config.coordinator" -}}
coordinator=true
node-scheduler.include-coordinator={{ if eq (int .Values.workers.replicas) 0 }}true{{ else }}false{{ end }}
http-server.http.port=8080
http-server.process-forwarded=true
discovery.uri=http://localhost:8080
node.internal-address={{ include "trino.name" . }}.{{ .Values.global.cpln.gvc }}.cpln.local
{{- if .Values.auth.enabled }}
http-server.authentication.type=PASSWORD
internal-communication.shared-secret=${ENV:TRINO_SHARED_SECRET}
{{- end }}
{{- end }}

{{/*
Worker config.properties. Workers announce themselves to the coordinator over
plain service DNS; end-user authentication is a coordinator concern, so workers
carry only the shared secret. process-forwarded is required here too — the
coordinator's task requests arrive through the same mesh.
*/}}
{{- define "trino.config.worker" -}}
coordinator=false
http-server.http.port=8080
http-server.process-forwarded=true
discovery.uri=http://{{ include "trino.name" . }}.{{ .Values.global.cpln.gvc }}.cpln.local:8080
{{- if .Values.auth.enabled }}
internal-communication.shared-secret=${ENV:TRINO_SHARED_SECRET}
{{- end }}
{{- end }}

{{/*
jvm.config — the file shipped in trinodb/trino:483 verbatim, with only the two
RAM-percentage lines parameterized. Default 70 (not upstream's 80): at 4Gi that
leaves ~1.2GiB for the 256MiB reserved code cache, metaspace, thread stacks and
NIO buffers. Upstream's 80 is written for 8–64GiB nodes.
*/}}
{{- define "trino.config.jvm" -}}
-server
-agentpath:/usr/lib/trino/bin/libjvmkill.so
-XX:InitialRAMPercentage={{ int .Values.jvm.maxRAMPercentage }}
-XX:MaxRAMPercentage={{ int .Values.jvm.maxRAMPercentage }}
-XX:G1HeapRegionSize=32M
-XX:+ExplicitGCInvokesConcurrent
-XX:+HeapDumpOnOutOfMemoryError
-XX:+ExitOnOutOfMemoryError
-XX:-OmitStackTraceInFastThrow
-XX:ReservedCodeCacheSize=256M
-XX:PerMethodRecompilationCutoff=10000
-XX:PerBytecodeRecompilationCutoff=10000
-Djdk.attach.allowAttachSelf=true
-Djdk.nio.maxCachedBufferSize=2000000
{{- end }}

{{/*
node.properties — identical on both tiers. node.environment must match across
every node and is constrained to [a-z0-9][_a-z0-9]*, so it is a fixed literal
(release names contain hyphens). node.id is deliberately absent: the image's
entrypoint then derives it from $HOSTNAME, which is unique per replica.
*/}}
{{- define "trino.config.node" -}}
node.environment=production
node.data-dir=/data/trino
{{- end }}

{{- define "trino.config.passwordAuthenticator" -}}
password-authenticator.name=file
file.password-file=/etc/trino/password.db
{{- end }}


{{/* Shared workload fragments */}}

{{/* Config-file volume mounts common to both tiers (catalogs included). */}}
{{- define "trino.volumes.common" -}}
- path: /etc/trino/jvm.config
  uri: cpln://secret/{{ include "trino.secret.jvm.name" . }}.payload
- path: /etc/trino/node.properties
  uri: cpln://secret/{{ include "trino.secret.node.name" . }}.payload
{{- range .Values.catalogs }}
- path: /etc/trino/catalog/{{ .name }}.properties
  uri: cpln://secret/{{ include "trino.secret.catalog.name" (dict "root" $ "catalog" .name) }}.payload
{{- end }}
{{- end }}

{{/* Credential env vars common to both tiers. */}}
{{- define "trino.env.common" -}}
{{- if .Values.auth.enabled }}
- name: TRINO_SHARED_SECRET
  value: cpln://secret/{{ .Values.auth.sharedSecretName }}.payload
{{- end }}
{{- range $c := .Values.catalogs }}
{{- range $s := $c.secrets }}
- name: {{ $s.env }}
  value: cpln://secret/{{ $s.secretName }}.{{ $s.secretKey | default "payload" }}
{{- end }}
{{- end }}
{{- end }}


{{/* Validation */}}

{{- define "trino.validate.resources" -}}
{{- $tier := .tier -}}
{{- $r := .resources -}}
{{- $max := printf "%v" $r.maxMemory -}}
{{- if not (regexMatch "^[0-9]+Gi$" $max) -}}
{{- fail (printf "trino: %s.resources.maxMemory must be whole GiB (e.g. 4Gi) — got '%s'" $tier $max) -}}
{{- end -}}
{{- if lt (int (trimSuffix "Gi" $max)) 2 -}}
{{- fail (printf "trino: %s.resources.maxMemory must be at least 2Gi — the JVM heap is a percentage of it, and below 2Gi Trino runs out of heap on the first real query (got %s)" $tier $max) -}}
{{- end -}}
{{- $minMem := int (include "trino.mebibytes" $r.minMemory) -}}
{{- if le $minMem 0 -}}
{{- fail (printf "trino: %s.resources.minMemory must be a Mi or Gi quantity (e.g. 2Gi) — got '%v'" $tier $r.minMemory) -}}
{{- end -}}
{{- if gt $minMem (int (include "trino.mebibytes" $max)) -}}
{{- fail (printf "trino: %s.resources.minMemory (%v) must not exceed maxMemory (%s)" $tier $r.minMemory $max) -}}
{{- end -}}
{{- $maxCpu := int (include "trino.millicores" $r.maxCpu) -}}
{{- $minCpu := int (include "trino.millicores" $r.minCpu) -}}
{{- if or (le $maxCpu 0) (le $minCpu 0) -}}
{{- fail (printf "trino: %s.resources.minCpu and maxCpu must be positive CPU quantities (e.g. 500m, 2000m)" $tier) -}}
{{- end -}}
{{- if gt $minCpu $maxCpu -}}
{{- fail (printf "trino: %s.resources.minCpu (%v) must not exceed maxCpu (%v)" $tier $r.minCpu $r.maxCpu) -}}
{{- end -}}
{{- if gt $maxCpu (mul $minCpu 4) -}}
{{- fail (printf "trino: %s.resources maxCpu:minCpu is %dm:%dm — Control Plane rejects a ratio above 4:1 (raise minCpu or lower maxCpu)" $tier $maxCpu $minCpu) -}}
{{- end -}}
{{- end -}}

{{- define "trino.validate" -}}
{{- $pct := .Values.jvm.maxRAMPercentage -}}
{{- if not (regexMatch "^[0-9]+$" (printf "%v" $pct)) -}}
{{- fail (printf "trino: jvm.maxRAMPercentage must be a whole number between 40 and 80 — got '%v'" $pct) -}}
{{- end -}}
{{- if or (lt (int $pct) 40) (gt (int $pct) 80) -}}
{{- fail (printf "trino: jvm.maxRAMPercentage must be between 40 and 80 — got %v (above 80 leaves no room for the reserved code cache, metaspace and NIO buffers; below 40 wastes the container)" $pct) -}}
{{- end -}}
{{- if lt (int .Values.workers.replicas) 0 -}}
{{- fail (printf "trino: workers.replicas must be 0 or more — got %v" .Values.workers.replicas) -}}
{{- end -}}
{{- include "trino.validate.resources" (dict "tier" "coordinator" "resources" .Values.coordinator.resources) -}}
{{- if gt (int .Values.workers.replicas) 0 -}}
{{- include "trino.validate.resources" (dict "tier" "workers" "resources" .Values.workers.resources) -}}
{{- end -}}
{{- if not (has .Values.internalAccess.type (list "none" "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "trino: internalAccess.type must be none, same-gvc, same-org, or workload-list — got '%s'" .Values.internalAccess.type) -}}
{{- end -}}
{{- if and .Values.publicAccess.enabled (not .Values.auth.enabled) -}}
{{- fail "trino: publicAccess.enabled requires auth.enabled — an unauthenticated Trino on the public internet is an arbitrary-read primitive over every connected data source" -}}
{{- end -}}
{{- if .Values.auth.enabled -}}
{{- if not .Values.auth.passwordFileSecretName -}}
{{- fail "trino: auth.passwordFileSecretName is required when auth.enabled — create the opaque secret holding the bcrypt password file BEFORE install" -}}
{{- end -}}
{{- if not .Values.auth.sharedSecretName -}}
{{- fail "trino: auth.sharedSecretName is required when auth.enabled — Trino requires internal-communication.shared-secret once authentication is on" -}}
{{- end -}}
{{- end -}}
{{- $names := dict -}}
{{- $envs := dict -}}
{{- range $i, $c := .Values.catalogs -}}
{{- if not $c.name -}}
{{- fail (printf "trino: catalogs[%d].name is required" $i) -}}
{{- end -}}
{{- if not (regexMatch "^[a-z][a-z0-9_]*$" $c.name) -}}
{{- fail (printf "trino: catalogs[%d].name '%s' must be lowercase letters, digits and underscores, starting with a letter" $i $c.name) -}}
{{- end -}}
{{- if eq $c.name "system" -}}
{{- fail "trino: catalogs[].name 'system' is reserved by Trino's built-in system connector" -}}
{{- end -}}
{{- if hasKey $names $c.name -}}
{{- fail (printf "trino: catalogs[].name '%s' is used more than once" $c.name) -}}
{{- end -}}
{{- $_ := set $names $c.name true -}}
{{- if not (regexMatch "(^|\n)connector\\.name=" (printf "%v" $c.properties)) -}}
{{- fail (printf "trino: catalogs[%d] ('%s') properties must contain a connector.name= line — copy it from the connector's documentation page" $i $c.name) -}}
{{- end -}}
{{- range $s := $c.secrets -}}
{{- if not (regexMatch "^[A-Z][A-Z0-9_]*$" (printf "%v" $s.env)) -}}
{{- fail (printf "trino: catalogs[].secrets[].env '%v' must be an UPPER_SNAKE_CASE environment variable name" $s.env) -}}
{{- end -}}
{{- if hasKey $envs $s.env -}}
{{- fail (printf "trino: catalogs[].secrets[].env '%s' is used by more than one catalog — env vars are container-scoped, so one catalog would silently get another's credential" $s.env) -}}
{{- end -}}
{{- $_ := set $envs $s.env true -}}
{{- if not $s.secretName -}}
{{- fail (printf "trino: catalogs[].secrets[] entry for env '%s' needs a secretName (the Control Plane secret must exist BEFORE install)" $s.env) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end }}


{{/* Labeling */}}

{{- define "trino.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
