{{/*
Name
*/}}
{{- define "kafka.name" -}}
{{- printf "%s" .Release.Name -}}
{{- end }}

{{/*
Cluster Workload Name
*/}}
{{- define "kafka.clusterName" -}}
{{- printf "%s-%s" (include "kafka.name" .) .Values.kafka.name -}}
{{- end }}

{{/*
Log volume set name for a given index. Call with a dict: (dict "root" $root "index" $i).
Defaults to "<release-name>-logs-<index>" (e.g. kafka-logs-0). If
kafka.volumes.logs.externalVolumeSets has a non-empty entry at this index, that name is
used instead — see kafka.volumeSetIsExternal. Both the volume set definitions and the
workload mount URIs resolve names through this helper so they can never drift apart.
*/}}
{{- define "kafka.volumeSetName" -}}
{{- $root := .root -}}
{{- $index := int .index -}}
{{- $external := (($root.Values.kafka.volumes.logs).externalVolumeSets) -}}
{{- if and $external (gt (len $external) $index) (index $external $index) -}}
{{- index $external $index -}}
{{- else -}}
{{- printf "%s-logs-%d" (include "kafka.name" $root) $index -}}
{{- end -}}
{{- end -}}

{{/*
Whether the log volume set at a given index is externally managed (imported) rather than
created by this chart. Call with a dict: (dict "root" $root "index" $i). Returns "true" when
kafka.volumes.logs.externalVolumeSets has a non-empty entry at that index, otherwise "".
An imported volume set is only referenced by the broker workload's mount URI — the chart
does NOT emit a `kind: volumeset` for it, so it never tries to adopt or overwrite a volume
set it didn't create (which would fail the cpln/release ownership tag). Use this for a volume
set that was created/renamed outside the chart (e.g. a "-fresh" volume set from incident
recovery): its data and settings are left exactly as they are and the workload just points at
it.
*/}}
{{- define "kafka.volumeSetIsExternal" -}}
{{- $root := .root -}}
{{- $index := int .index -}}
{{- $external := (($root.Values.kafka.volumes.logs).externalVolumeSets) -}}
{{- if and $external (gt (len $external) $index) (index $external $index) -}}
true
{{- end -}}
{{- end -}}

{{/*
Guard against a partial externalVolumeSets list. If provided, it must have exactly one entry
per kafka.logDirs (entries may be empty strings to keep that log dir chart-managed); a shorter
list would leave a trailing log dir chart-managed under the default name and, on a cluster
whose data lives in imported volume sets, mount a new empty volume set — the exact
data-loss-on-upgrade footgun this feature prevents.
*/}}
{{- define "kafka.validateExternalVolumeSets" -}}
{{- $external := (.Values.kafka.volumes.logs).externalVolumeSets -}}
{{- if $external -}}
  {{- $logDirCount := len (split "," .Values.kafka.logDirs) -}}
  {{- if ne (len $external) $logDirCount -}}
    {{- fail (printf "kafka.volumes.logs.externalVolumeSets has %d entr(y/ies) but kafka.logDirs defines %d log dir(s); provide exactly one entry per log dir (use an empty string to keep a log dir chart-managed), in the same order." (len $external) $logDirCount) -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{/*
Convert .Values.kafka.memory to appropriate JVM heap size settings.
*/}}
{{- define "kafka.heap.opts" -}}
{{- $memory := default "512Mi" .Values.kafka.memory }}
{{- $memoryInMi := 0 }}
{{- if hasSuffix "Gi" $memory }}
  {{- $value := trimSuffix "Gi" $memory | float64 }}
  {{- $memoryInMi = mul $value 1024 | int }}
{{- else if hasSuffix "Mi" $memory }}
  {{- $memoryInMi = trimSuffix "Mi" $memory | int }}
{{- else }}
  {{- $memoryInMi = 512 }} # Default to 512Mi if no suffix
{{- end }}
{{- $heapSize := div (mul $memoryInMi 60) 100 | int }}
-Xmx{{ $heapSize }}m -Xms{{ $heapSize }}m
{{- end }}

{{/*
Recovery threads per data dir. Kafka serializes log recovery within a single thread per
data dir on broker startup, so a high partition count + slow disk = long recovery. We size
this proportionally to the broker's CPU budget: 8 * ceil(cpuCores). Accepts millicore
("1000m") or whole-core ("2") forms; ceils up so half-cores still get a useful pool.
*/}}
{{- define "kafka.recoveryThreads" -}}
{{- $cpu := default "1000m" .Values.kafka.cpu | toString -}}
{{- $millicores := 1000 -}}
{{- if hasSuffix "m" $cpu -}}
  {{- $millicores = trimSuffix "m" $cpu | int -}}
{{- else -}}
  {{- $millicores = mul (atoi $cpu) 1000 -}}
{{- end -}}
{{- $cores := div (add $millicores 999) 1000 -}}
{{- mul 8 $cores -}}
{{- end }}

{{/*
Sensible default for default.replication.factor: min(3, replicaCount). Kafka rejects
default.replication.factor > replicas, so we clamp to the cluster size.
*/}}
{{- define "kafka.defaultReplicationFactor" -}}
{{- $replicas := .Values.kafka.replicas | int -}}
{{- if lt $replicas 3 -}}{{ $replicas }}{{- else -}}3{{- end -}}
{{- end }}

{{/*
Sensible default for min.insync.replicas: max(1, defaultReplicationFactor - 1). With
replication.factor=3 this gives 2 (tolerates one broker loss without unavailability and
without losing acked writes); with replicas=2 it gives 1; with replicas=1 it gives 1.
*/}}
{{- define "kafka.minInsyncReplicas" -}}
{{- $rf := include "kafka.defaultReplicationFactor" . | int -}}
{{- if le $rf 1 -}}1{{- else -}}{{ sub $rf 1 }}{{- end -}}
{{- end }}

{{- define "kafka.validateListenerConfig" -}}
  {{- if not .name -}}
    {{- fail "Error: 'name' must be provided for the listener" -}}
  {{- end -}}
  {{- if not .protocol -}}
    {{- fail "Error: 'protocol' must be provided for the listener" -}}
  {{- end -}}
  {{- $hasValidConfig := or .publicAddress .containerPort (and .directReplicaRouting .directReplicaRouting.enabled .directReplicaRouting.containerPort .directReplicaRouting.publicAddress) -}}
  {{- if not $hasValidConfig -}}
    {{- fail "Error: At least one of 'publicAddress', 'containerPort', or valid 'directReplicaRouting' (with enabled: true, containerPort, and publicAddress) must be provided for the listener" -}}
  {{- end -}}
  {{- if and .publicAddress .containerPort -}}
    {{- fail "Error: When publicAddress is set for the listener, containerPort should not be specified as it will be automatically set to port range 3000-3004" -}}
  {{- end -}}
  {{- if .containerPort -}}
    {{- $port := .containerPort | printf "%s" }}
    {{- if or (eq $port "9091") (eq $port "9093") (eq $port "9094") -}}
      {{- fail "Error: containerPort cannot be 9091, 9093, or 9094 for listener" -}}
    {{- end -}}
  {{- end -}}
  {{- if and .directReplicaRouting .directReplicaRouting.enabled -}}
    {{- if .directReplicaRouting.containerPort -}}
      {{- $port := .directReplicaRouting.containerPort | printf "%s" }}
      {{- if or (eq $port "9091") (eq $port "9093") (eq $port "9094") -}}
        {{- fail "Error: directReplicaRouting.containerPort cannot be 9091, 9093, or 9094 for listener" -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- end -}}

{{- define "kafka.validateAdminExists" -}}
{{- $adminFound := false -}}
{{- $saslPlaintextExists := false -}}
{{- range .Values.kafka.listeners -}}
  {{- if eq .protocol "SASL_PLAINTEXT" -}}
    {{- $saslPlaintextExists = true -}}
    {{- if and .sasl .sasl.admin -}}
      {{- $adminFound = true -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- if and $saslPlaintextExists (not $adminFound) -}}
  {{- fail "Error: At least one SASL_PLAINTEXT listener must have an admin user configured in sasl.admin" -}}
{{- end -}}
{{- end -}}

{{- define "kafka.validateAuthConfig" -}}
{{- if eq .protocol "SASL_PLAINTEXT" -}}
  {{- if not .sasl -}}
    {{- fail (printf "Error: SASL_PLAINTEXT protocol requires sasl configuration to be enabled for listener '%s'" .name) -}}
  {{- else if not .sasl.users -}}
    {{- fail (printf "Error: SASL_PLAINTEXT protocol requires at least one user to be defined in sasl.users for listener '%s'" .name) -}}
  {{- else -}}
    {{- $userCount := len (splitList "," .sasl.users) -}}
    {{- if not .sasl.passwords -}}
      {{- fail (printf "Error: sasl.passwords must be provided when sasl.users is defined for listener '%s'" .name) -}}
    {{- else -}}
      {{- $passwordCount := len (splitList "," .sasl.passwords) -}}
      {{- if ne $userCount $passwordCount -}}
        {{- fail (printf "Error: Number of users (%d) does not match number of passwords (%d) for listener '%s'" $userCount $passwordCount .name) -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{- define "kafka.validateReplicas" -}}
{{- $replicas := .Values.kafka.replicas | int }}
{{- if or (gt $replicas 5) (eq $replicas 2) -}}
  {{- fail "Invalid value for kafka.replicas. It must be less than or equal to 5 and not equal to 2." -}}
{{- end -}}
{{- end -}}

{{- define "kafka.validateOnePublicAddress" -}}
{{- $publicAddressCount := 0 -}}
{{- range .Values.kafka.listeners }}
  {{- if .publicAddress }}
    {{- $publicAddressCount = add $publicAddressCount 1 -}}
  {{- end }}
  {{- if and .directReplicaRouting .directReplicaRouting.enabled .directReplicaRouting.publicAddress }}
    {{- $publicAddressCount = add $publicAddressCount 1 -}}
  {{- end }}
{{- end }}
{{- if gt $publicAddressCount 1 -}}
  {{- fail "There must be at most one listener with a publicAddress set (either listener.publicAddress or listener.directReplicaRouting.publicAddress)." -}}
{{- end }}
{{- end -}}

{{- define "kafka.validatedirectReplicaRoutingConfig" -}}
{{- range $key, $listener := .Values.kafka.listeners }}
  {{- if and $listener.publicAddress $listener.directReplicaRouting }}
    {{- if $listener.directReplicaRouting.enabled }}
      {{- fail (printf "Error in listener '%s': Cannot have both 'publicAddress' at listener level and 'directReplicaRouting.enabled: true'. Use either legacy mode (publicAddress only) or new mode (directReplicaRouting with enabled: true)." $key) -}}
    {{- end }}
  {{- end }}
  {{- if and $listener.directReplicaRouting $listener.directReplicaRouting.enabled }}
    {{- if not $listener.directReplicaRouting.publicAddress }}
      {{- fail (printf "Error in listener '%s': When directReplicaRouting.enabled is true, directReplicaRouting.publicAddress must be specified." $key) -}}
    {{- end }}
    {{- if not $listener.directReplicaRouting.containerPort }}
      {{- fail (printf "Error in listener '%s': When directReplicaRouting.enabled is true, directReplicaRouting.containerPort must be specified." $key) -}}
    {{- end }}
  {{- end }}
{{- end }}
{{- end -}}

{{- define "kafka.validateKafkaImage" -}}
{{- $image := .Values.kafka.image -}}
{{- if contains "bitnami" $image -}}
  {{- fail (printf "Error: This chart does not support Bitnami images, please use Apache Kafka images instead. Current value: %s" $image) -}}
{{- end -}}
{{- end -}}

{{- define "kafka.validateImage" -}}
{{- $image := .image -}}
{{- if contains "bitnami" $image -}}
  {{- fail (printf "Error: This chart does not support Bitnami images, please use Apache Kafka images instead. Current value: %s" $image) -}}
{{- end -}}
{{- end -}}

{{- /* Validates only the plugin-download keys added in 4.3.0; an entry using 4.2.0 keys renders unchanged. */ -}}
{{- define "kafka.validateConnectorDownloads" -}}
{{- $c := . -}}
{{- if and (hasKey $c "plugins_wait_timeout_action") (not (kindIs "invalid" $c.plugins_wait_timeout_action)) -}}
  {{- if not (has (toString $c.plugins_wait_timeout_action) (list "start" "restart")) -}}
    {{- fail (printf "Error in kafka_connectors '%s': plugins_wait_timeout_action must be 'start' or 'restart', got '%v'" (toString $c.name) $c.plugins_wait_timeout_action) -}}
  {{- end -}}
{{- end -}}
{{- if and (hasKey $c "plugins_wait_timeout_seconds") (not (kindIs "invalid" $c.plugins_wait_timeout_seconds)) -}}
  {{- $t := $c.plugins_wait_timeout_seconds -}}
  {{- $ok := false -}}
  {{- if or (kindIs "int" $t) (kindIs "int64" $t) -}}
    {{- $ok = ge (int64 $t) 0 -}}
  {{- else if kindIs "float64" $t -}}
    {{- $ok = and (ge $t 0.0) (eq $t (floor $t)) -}}
  {{- else if kindIs "string" $t -}}
    {{- $ok = regexMatch "^[0-9]+$" $t -}}
  {{- end -}}
  {{- if not $ok -}}
    {{- fail (printf "Error in kafka_connectors '%s': plugins_wait_timeout_seconds must be a whole number of seconds, 0 or more (0 = wait forever), got '%v'" (toString $c.name) $t) -}}
  {{- end -}}
{{- end -}}
{{- range $c.plugins -}}
  {{- $p := . -}}
  {{- range .artifacts -}}
    {{- if and (hasKey . "sha256") (not (kindIs "invalid" .sha256)) (ne (toString .sha256) "") -}}
      {{- if not (regexMatch "^[0-9A-Fa-f]{64}$" (toString .sha256)) -}}
        {{- fail (printf "Error in kafka_connectors '%s', plugin '%s': artifact sha256 must be 64 hexadecimal characters, got '%v'" (toString $c.name) (toString $p.name) .sha256) -}}
      {{- end -}}
    {{- end -}}
  {{- end -}}
{{- end -}}
{{- end -}}

{{- define "kafka.clientBootstrapAddress" -}}
{{- $clusterName := include "kafka.clusterName" . -}}
{{- $bootstrapAddress := "" -}}
{{- $listenerName := "" -}}

{{- if .listenerName -}}
  {{- $listenerName = .listenerName -}}
{{- else if .Values.kafka_connectors -}}
  {{- range .Values.kafka_connectors -}}
    {{- if .listener -}}
      {{- $listenerName = .listener -}}
    {{- end -}}
  {{- end -}}
{{- end -}}

{{- if $listenerName -}}
  {{- if hasKey .Values.kafka.listeners $listenerName -}}
    {{- $listener := index .Values.kafka.listeners $listenerName -}}
    {{- if $listener.publicAddress -}}
      {{- $bootstrapAddress = printf "%s:3000" $listener.publicAddress -}}
    {{- else -}}
      {{- $containerPort := $listener.containerPort | int -}}
      {{- $bootstrapAddress = printf "%s:%d" $clusterName $containerPort -}}
    {{- end -}}
  {{- else -}}
    {{- $bootstrapAddress = include "kafka.bootstrapAddress" . -}}
  {{- end -}}
{{- else -}}
  {{- $bootstrapAddress = include "kafka.bootstrapAddress" . -}}
{{- end -}}

{{- $bootstrapAddress -}}
{{- end -}}

{{- define "kafka.propertiesMapToList" -}}
{{- range $key, $value := . -}}
{{ $key }}={{ $value }}
{{- end -}}
{{- end -}}



{{- define "kafka.connectors.download.script" -}}
{{- $c := .connector | default dict -}}
#!/bin/sh
# Kafka Connect plugin downloader (chart 4.3.0).
# Each artifact is downloaded to a staging dir on the plugin volume, verified, and renamed into
# <plugins>/<plugin>/<key>/ (same filesystem, so the rename is atomic). An installed artifact is never
# rewritten, so a restart skips it. Only artifacts recorded in .cpln-downloads/manifest are ever
# deleted; files this chart did not download are never touched.
# Kafka Connect waits for $SYNC/downloads-done before it scans plugin.path.
set -u
PLUGINS='{{ replace "'" "'\\''" (toString (.plugins_folder | default "/opt/kafka/plugins")) }}'
STATE="$PLUGINS/.cpln-downloads"
MANIFEST="$STATE/manifest"
STAGING="$STATE/staging"
RETIRED="$STATE/retired"
SYNC=/opt/kafka/sync
TOKEN='{{ replace "'" "'\\''" (toString ($c.plugins_redownload_token | default "")) }}'
VERBOSE={{ if .verbose }}1{{ else }}0{{ end }}
NL='
'
CHILD=""

log() { echo "[plugins $(date -u +%H:%M:%S)] $*"; }
vlog() { if [ "$VERBOSE" = 1 ]; then log "$@"; fi; return 0; }
# Credentials never reach the log: userinfo becomes ***@ and a query string becomes ?<redacted>.
redact() { printf '%s\n' "$1" | sed -e 's#\([A-Za-z][A-Za-z0-9+.-]*://\)[^/]*@#\1***@#g' -e 's#?.*#?<redacted>#'; }
strip_userinfo() { printf '%s\n' "$1" | sed 's#^\([A-Za-z][A-Za-z0-9+.-]*://\)[^/]*@#\1#'; }
lower() { printf '%s' "$1" | tr 'A-Z' 'a-z'; }

on_term() {
  log "SIGTERM: stopping"
  if [ -n "$CHILD" ]; then kill "$CHILD" 2>/dev/null; fi
  exit 143
}
trap on_term TERM INT
# Long operations run in the background and are waited on, so a SIGTERM is handled at once.
bg() { "$@" & CHILD=$!; wait "$CHILD"; _rc=$?; CHILD=""; return $_rc; }

plugin_name_ok() {
  case "$1" in ''|.*|*/*|lost+found) return 1 ;; esac
  case "$1" in *"$NL"*) return 1 ;; esac
  return 0
}

# Add an entry (<plugin>/<key>) to the manifest of artifact dirs this chart created.
record() {
  if [ -f "$MANIFEST" ] && grep -qxF -- "$1" "$MANIFEST"; then return 0; fi
  { if [ -f "$MANIFEST" ]; then cat "$MANIFEST"; fi; printf '%s\n' "$1"; } > "$MANIFEST.tmp" && mv -f "$MANIFEST.tmp" "$MANIFEST"
}

# File name for a jar artifact: the last segment of the URL path, with .jar appended if missing.
jar_name() {
  u=$(strip_userinfo "$1"); u=${u%%#*}; u=${u%%\?*}; u=${u#*://}
  case "$u" in */*) p=${u#*/} ;; *) p="" ;; esac
  n=${p##*/}
  if [ -z "$n" ]; then n=artifact; fi
  case "$n" in *.jar) ;; *) n="$n.jar" ;; esac
  printf '%s' "$n"
}

# fetch URL FILE ERRFILE. A URL with credentials on a JFrog host is resolved to its redirect first
# (unchanged from earlier chart versions); the redirect URL is presigned and is never logged.
fetch() {
  if echo "$1" | grep -q "@.*jfrog"; then
    log "Handling JFrog redirect for: $(redact "$1")"
    bg wget -S --spider -T 60 "$1" >"$3.spider" 2>&1
    redirect_url=$(grep 'Location:' "$3.spider" | awk '{print $2}')
    rm -f "$3.spider"
    if [ -n "$redirect_url" ]; then
      log "Downloading from redirect URL..."
      bg wget -q -T 60 -O "$2" "$redirect_url" 2>"$3"
    else
      log "Failed to get redirect URL, trying direct download..."
      bg wget -q -T 60 -O "$2" "$1" 2>"$3"
    fi
  else
    bg wget -q -T 60 -O "$2" "$1" 2>"$3"
  fi
}

config_skip() {
  log "ERROR $1"
  CONFIG_SKIPPED="${CONFIG_SKIPPED}$2${NL}"
}

fail_artifact() {
  FAILED="${FAILED}${plugin}: ${rurl} ($1)${NL}"
  rm -rf "$st"
}

# install_artifact PLUGIN TYPE URL SHA256. Returns 1 only for a failure worth retrying.
install_artifact() {
  plugin=$1; type=$2; url=$3; sha=$(lower "$4")
  rurl=$(redact "$url")
  if ! plugin_name_ok "$plugin"; then
    config_skip "invalid plugin name '$plugin' (empty, starts with '.', contains '/' or is lost+found): skipped $rurl" "${plugin}: $rurl (invalid plugin name)"
    return 0
  fi
  if [ -z "$url" ]; then
    config_skip "plugin $plugin: an artifact has no url: skipped" "${plugin}: (artifact without a url)"
    return 0
  fi
  case "$type" in
    jar|zip|tar|tgz|tar.gz) ;;
    *)
      config_skip "plugin $plugin: unsupported artifact type '$type' for $rurl (supported: jar, zip, tar, tgz, tar.gz): skipped" "${plugin}: $rurl (unsupported type '$type')"
      return 0 ;;
  esac
  if [ "$type" = jar ]; then JARP="${JARP}${plugin}${NL}"; fi
  key=$(printf 'v2\n%s\n%s\n%s\n%s\n' "$type" "$(strip_userinfo "$url")" "$sha" "$TOKEN" | sha256sum | cut -c1-16)
  KEEP="${KEEP}${plugin}/${key}${NL}"
  dest="$PLUGINS/$plugin/$key"
  st="$STAGING/$key"
  if [ -d "$dest" ]; then
    record "$plugin/$key"
    vlog "skip $plugin $type $rurl (installed as $plugin/$key)"
    return 0
  fi
  rm -rf "$st"
  if ! mkdir -p "$st/x"; then
    log "ERROR cannot create the staging dir $st"
    fail_artifact "staging dir"; return 1
  fi
  log "download $plugin $type $rurl"
  vlog "  key $key, staging $st"
  if ! fetch "$url" "$st/file" "$st/err"; then
    err=$(tail -n 3 "$st/err" 2>/dev/null | tr '\n' ' ')
    log "ERROR download failed: $rurl: $(redact "$err")"
    fail_artifact "download failed"; return 1
  fi
  vlog "  downloaded $(wc -c < "$st/file") bytes"
  if [ -n "$sha" ]; then
    got=$(sha256sum "$st/file" | cut -d' ' -f1)
    if [ "$got" != "$sha" ]; then
      log "ERROR sha256 mismatch for $plugin $rurl: expected $sha, got $got"
      fail_artifact "sha256 mismatch"; return 1
    fi
    vlog "  sha256 verified"
  fi
  case "$type" in
    jar)
      if ! unzip -l "$st/file" >/dev/null 2>&1; then
        log "ERROR not a valid jar: $rurl"; fail_artifact "not a valid jar"; return 1
      fi
      mv "$st/file" "$st/x/$(jar_name "$url")" ;;
    zip)
      if ! unzip -l "$st/file" >/dev/null 2>&1 || ! bg unzip -q -o "$st/file" -d "$st/x" >/dev/null 2>&1; then
        log "ERROR not a valid zip: $rurl"; fail_artifact "not a valid zip"; return 1
      fi ;;
    tgz|tar.gz)
      if ! tar -tzf "$st/file" >/dev/null 2>&1 || ! bg tar -xzf "$st/file" -C "$st/x" 2>/dev/null; then
        log "ERROR not a valid $type: $rurl"; fail_artifact "not a valid $type"; return 1
      fi ;;
    tar)
      if ! tar -tf "$st/file" >/dev/null 2>&1 || ! bg tar -xf "$st/file" -C "$st/x" 2>/dev/null; then
        log "ERROR not a valid tar: $rurl"; fail_artifact "not a valid tar"; return 1
      fi ;;
  esac
  rm -f "$st/file" "$st/err"
  if ! mkdir -p "$PLUGINS/$plugin"; then
    log "ERROR cannot create $PLUGINS/$plugin"; fail_artifact "plugin dir"; return 1
  fi
  if ! record "$plugin/$key"; then
    log "ERROR cannot write $MANIFEST"; fail_artifact "manifest"; return 1
  fi
  if ! mv "$st/x" "$dest"; then
    log "ERROR cannot move $plugin/$key into place"; fail_artifact "rename"; return 1
  fi
  rm -rf "$st"
  INSTALLED=$((INSTALLED+1))
  log "installed $plugin $type $rurl as $plugin/$key"
  return 0
}

# Plugins with "enabled: true" (the only ones downloaded, as in earlier chart versions).
enabled_plugins() {
{{- range .plugins }}
{{- if eq .enabled true }}
  printf '%s\n' '{{ replace "'" "'\\''" (toString .name) }}'
{{- end }}
{{- end }}
  :
}

not_enabled_plugins() {
{{- range .plugins }}
{{- if eq .enabled true }}
{{- else }}
  printf '%s\n' '{{ replace "'" "'\\''" (toString .name) }}'
{{- end }}
{{- end }}
  :
}

# One pass over every wanted artifact, in values order. Returns 1 if any retryable failure.
run_all() {
  KEEP=""; JARP=""; FAILED=""; CONFIG_SKIPPED=""; prc=0
{{- range .plugins }}
{{- if eq .enabled true }}
  P='{{ replace "'" "'\\''" (toString .name) }}'
{{- range .artifacts }}
  install_artifact "$P" '{{ replace "'" "'\\''" (toString (.type | default "")) }}' '{{ replace "'" "'\\''" (toString (.url | default "")) }}' '{{ replace "'" "'\\''" (toString (.sha256 | default "")) }}' || prc=1
{{- end }}
{{- end }}
{{- end }}
  printf '%s%s' "$FAILED" "$CONFIG_SKIPPED" > "$SYNC/pending.tmp" && mv -f "$SYNC/pending.tmp" "$SYNC/pending"
  return $prc
}

# Top-level entries this chart does not manage. Listed so they are visible; never touched.
report_unmanaged() {
  list=""
  for e in "$PLUGINS"/* "$PLUGINS"/.[!.]* "$PLUGINS"/..?*; do
    if [ ! -e "$e" ] && [ ! -L "$e" ]; then continue; fi
    n=${e##*/}
    case "$n" in .cpln-downloads|lost+found) continue ;; esac
    if enabled_plugins | grep -qxF -- "$n"; then continue; fi
    if [ -f "$MANIFEST" ] && grep -q "^$n/" "$MANIFEST" 2>/dev/null; then continue; fi
    list="$list $n"
  done
  if [ -n "$list" ]; then log "left untouched (not downloaded by this chart):$list"; fi
}

# A configured plugin dir that also holds files this chart did not download shares their classloader.
collision_check() {
  enabled_plugins | while IFS= read -r p; do
    if ! plugin_name_ok "$p" || [ ! -d "$PLUGINS/$p" ]; then continue; fi
    for e in "$PLUGINS/$p"/* "$PLUGINS/$p"/.[!.]* "$PLUGINS/$p"/..?*; do
      if [ ! -e "$e" ] && [ ! -L "$e" ]; then continue; fi
      n=${e##*/}
      if [ "$n" = "$p.jar" ]; then continue; fi
      if [ -f "$MANIFEST" ] && grep -qxF -- "$p/$n" "$MANIFEST"; then continue; fi
      log "WARNING: $p/ also contains files this chart did not download; they load in the same classloader as its artifacts"
      break
    done
  done
}

manifest_entry_ok() {
  case "$1" in [!./]*/*) ;; *) return 1 ;; esac
  p=${1%/*}; k=${1#*/}
  case "$p" in */*|lost+found) return 1 ;; esac
  case "$k" in *[!0-9a-f]*) return 1 ;; esac
  [ ${#k} -eq 16 ]
}

# Remove artifact dirs this chart created that are no longer wanted (URL changed, plugin removed or
# not enabled). Only manifest entries are ever deleted.
prune_manifest() {
  if [ ! -f "$MANIFEST" ]; then return 0; fi
  : > "$MANIFEST.new"
  while IFS= read -r entry; do
    if [ -z "$entry" ]; then continue; fi
    case "$NL$KEEP" in *"$NL$entry$NL"*) printf '%s\n' "$entry" >> "$MANIFEST.new"; continue ;; esac
    if ! manifest_entry_ok "$entry"; then
      log "WARNING: dropping an unexpected manifest entry; nothing deleted"
      continue
    fi
    if [ -e "$PLUGINS/$entry" ] || [ -L "$PLUGINS/$entry" ]; then
      log "removing $entry (no longer configured)"
      if ! rm -rf "${PLUGINS:?}/$entry"; then printf '%s\n' "$entry" >> "$MANIFEST.new"; continue; fi
    fi
    if rmdir "$PLUGINS/${entry%/*}" 2>/dev/null; then log "removed empty plugin dir ${entry%/*}"; fi
  done < "$MANIFEST"
  mv -f "$MANIFEST.new" "$MANIFEST"
}

# Chart <= 4.2.x wrote every jar artifact of plugin P to P/P.jar (possibly partial). For each enabled
# plugin that has a jar artifact now, move that file out of the plugin path (reversible).
retire_legacy() {
  printf '%s' "$JARP" | while IFS= read -r p; do
    if [ -z "$p" ]; then continue; fi
    f="$PLUGINS/$p/$p.jar"
    if [ ! -f "$f" ] || [ -L "$f" ]; then continue; fi
    mkdir -p "$RETIRED"
    if mv "$f" "$RETIRED/$p.jar.$(date +%s).retired"; then
      log "retired $p/$p.jar (written by chart 4.2.x or earlier) to .cpln-downloads/retired/"
    fi
  done
}

log "Kafka Connect plugin downloader starting (plugins folder $PLUGINS)"
mkdir -p "$SYNC"
rm -f "$SYNC/downloads-done" "$SYNC/pending"
if ! mkdir -p "$STATE"; then
  log "FATAL: cannot create $STATE; plugins_folder must be on the plugin volume"
  exit 1
fi
rm -rf "$STAGING"
mkdir -p "$STAGING"
printf '2\n' > "$STATE/layout"
not_enabled_plugins | while IFS= read -r p; do
  log "skipping plugin $p: not downloaded because it has no \"enabled: true\""
done
report_unmanaged
collision_check

attempt=0
INSTALLED=0
until run_all; do
  attempt=$((attempt+1)); delay=$((attempt*10)); if [ $delay -gt 60 ]; then delay=60; fi
  log "pass $attempt: some artifacts failed; retrying in ${delay}s. Kafka Connect keeps waiting."
  bg sleep "$delay"
done
log "all artifacts present ($INSTALLED downloaded by this run)"

if [ -f "$SYNC/connect-started-degraded" ]; then
  log "all artifacts are now installed; Kafka Connect started without some of them, so restart the worker (cpln workload force-redeployment) to load them. Cleanup deferred until then."
else
  prune_manifest
  retire_legacy
fi
printf '%s' "$CONFIG_SKIPPED" > "$SYNC/pending.tmp" && mv -f "$SYNC/pending.tmp" "$SYNC/pending"
touch "$SYNC/downloads-done"
log "all plugins ready; signalled kafka-connect"
while :; do bg sleep 2147483647; done
{{- end }}

{{- define "kafka.connectors.run.script" -}}
{{- $c := .connector | default dict -}}
{{- $waitTimeout := 900 -}}
{{- if and (hasKey $c "plugins_wait_timeout_seconds") (not (kindIs "invalid" $c.plugins_wait_timeout_seconds)) -}}
{{- $waitTimeout = int $c.plugins_wait_timeout_seconds -}}
{{- end -}}
{{- $waitAction := "start" -}}
{{- if and (hasKey $c "plugins_wait_timeout_action") (not (kindIs "invalid" $c.plugins_wait_timeout_action)) -}}
{{- $waitAction = toString $c.plugins_wait_timeout_action -}}
{{- end -}}
#!/bin/bash
set -e{{- if .verbose }}x{{- end }}

# Names of the keys in a connector config. Values are never logged: they often hold credentials.
config_keys() {
  echo "$1" | sed -n 's/^[[:space:],{]*"\([^"]*\)":[[:space:]]*".*/\1/p' | grep -v '^name$' | tr '\n' ' '
}

# Function to create or update a connector
create_or_update_connector() {
  local connector_name=$1
  local config=$2
  local cluster_connectors=$3
  
  echo "Checking if connector $connector_name exists in cluster..."
  
  # Check if connector exists in the cluster-wide list (reliable in distributed mode)
  local exists=false
  if echo "$cluster_connectors" | grep -q "\"$connector_name\""; then
    exists=true
    echo "Connector $connector_name found in cluster list"
  else
    echo "Connector $connector_name does not exist in cluster"
  fi
  
  if [ "$exists" = true ]; then
    echo "Connector $connector_name exists. Updating configuration..."
    
    # Extract just the config part from the full connector JSON
    # Remove the "name" line, remove everything up to and including "config": {, remove last two lines (both closing braces)
    local config_content=$(echo "$config" | sed '/^[[:space:]]*"name":/d' | sed '1,/^[[:space:]]*"config":[[:space:]]*{/d' | sed '$d' | sed '$d')
    local update_config="{${config_content}}"
    
    echo "Updating connector $connector_name (config keys: $(config_keys "$update_config"))"
    
    # Update the connector using PUT with nc (BusyBox wget doesn't support PUT)
    local content_length=$(echo -n "$update_config" | wc -c | xargs)
    local response
    response=$(echo -e "PUT /connectors/$connector_name/config HTTP/1.1\r\nHost: localhost:8083\r\nContent-Type: application/json\r\nContent-Length: $content_length\r\nConnection: close\r\n\r\n$update_config" | nc localhost 8083 2>&1)
    echo "HTTP response for $connector_name update: $(echo "$response" | head -1)"
    if ! echo "$response" | grep -q "HTTP/1\.. 2"; then
      echo "ERROR: Failed to update connector $connector_name. Response: $(echo "$response" | head -5)"
    else
      echo "Connector $connector_name updated successfully"
    fi
  else
    echo "Connector $connector_name does not exist. Creating..."
    
    echo "Creating connector $connector_name (config keys: $(config_keys "$config"))"
    
    # Create the connector using POST; a failed request returns non-zero so the caller retries
    local post_err
    if ! post_err=$(wget -q -O /dev/null "http://localhost:8083/connectors" \
          --header="Content-Type: application/json" --post-data="$config" 2>&1); then
      echo "ERROR: Failed to create connector $connector_name: ${post_err}. The Kafka Connect log has the reason."
      return 1
    fi
    
    echo "Connector $connector_name created successfully"
    
    # Add a delay after creation to allow connector to initialize
    sleep 2
  fi
}

# Function to check and setup truststore for SSL connections
truststore_init() {
  local hostname=$1
  local port=$2
  local alias=$3
  local jdbc_props=$4
  
  echo "Setting up truststore for $hostname:$port with alias $alias"
  
  # Parse JDBC connection properties
  local truststore_path
  local truststore_password
  
  # First check if ssl.truststore.location is provided in the config
  if [[ -n "${SSL_TRUSTSTORE_LOCATION}" ]]; then
    truststore_path="${SSL_TRUSTSTORE_LOCATION}"
    echo "Using ssl.truststore.location from config: $truststore_path"
  # Then check if it's in JDBC properties
  elif [[ "$jdbc_props" =~ ssl\.truststore\.location=([^;]+) ]]; then
    truststore_path="${BASH_REMATCH[1]}"
    echo "Using ssl.truststore.location from JDBC properties: $truststore_path"
  elif [[ "$jdbc_props" =~ trustStorePath=([^;]+) ]]; then
    truststore_path="${BASH_REMATCH[1]}"
    echo "Using trustStorePath from JDBC properties: $truststore_path"
  else
    # Use default path if not specified
    truststore_path="/tmp/kafka.client.truststore.jks"
    echo "No truststore path specified, using default: $truststore_path"
  fi
  
  # Check if ssl.truststore.password is provided
  if [[ -n "${SSL_TRUSTSTORE_PASSWORD}" ]]; then
    truststore_password="${SSL_TRUSTSTORE_PASSWORD}"
    echo "Using ssl.truststore.password from config"
  # Then check if it's in JDBC properties
  elif [[ "$jdbc_props" =~ ssl\.truststore\.password=([^;]+) ]]; then
    truststore_password="${BASH_REMATCH[1]}"
    echo "Using ssl.truststore.password from JDBC properties"
  elif [[ "$jdbc_props" =~ trustStorePassword=([^;]+) ]]; then
    truststore_password="${BASH_REMATCH[1]}"
    echo "Using trustStorePassword from JDBC properties"
  else
    # Generate random password if not specified
    truststore_password=$(openssl rand -base64 12)
    export SSL_TRUSTSTORE_PASSWORD="${truststore_password}"
    echo "Generated random ssl.truststore.password"
  fi
  
  # Create certs directory if it doesn't exist
  mkdir -p $(dirname "$truststore_path")
  
  # Download CA certificate
  echo "Downloading CA certificate for $hostname:$port"
  echo | openssl s_client -connect $hostname:$port -showcerts 2>/dev/null | \
    openssl x509 -outform PEM > $(dirname "$truststore_path")/$alias.pem || \
    echo "WARNING: Failed to download certificate from $hostname:$port, truststore may be incomplete"

  # Create truststore if it doesn't exist or override existing one
  echo "Creating new truststore from $JAVA_HOME/lib/security/cacerts"
  if [[ -f "$JAVA_HOME/lib/security/cacerts" ]]; then
    cp "$JAVA_HOME/lib/security/cacerts" "$truststore_path" || \
      echo "WARNING: Failed to copy cacerts to $truststore_path, truststore setup may be incomplete"
  else
    echo "WARNING: $JAVA_HOME/lib/security/cacerts not found, skipping truststore creation for $hostname"
    return 0
  fi

  # Change the default password to our password
  echo "Setting truststore password"
  keytool -storepasswd -keystore "$truststore_path" \
    -storepass "changeit" -new "${truststore_password}" || \
    echo "WARNING: Failed to change truststore password for $hostname, continuing with default password"

  # Import certificate into truststore (only if cert file is non-empty)
  local cert_file="$(dirname "$truststore_path")/$alias.pem"
  if [[ -s "$cert_file" ]]; then
    echo "Importing certificate into truststore"
    keytool -import -noprompt -alias $alias -file "$cert_file" \
      -keystore "$truststore_path" -storepass "${truststore_password}" || \
      echo "WARNING: Failed to import certificate for $alias, truststore may be incomplete"
  else
    echo "WARNING: Skipping certificate import for $alias, cert file is empty or missing"
  fi

  echo "Truststore setup completed for $hostname"
}

# Function to setup multi-domain truststore from values configuration
setup_multi_domain_truststore() {
  local plugin_name="$1"
  local ssl_truststore_config="$2"
  
  echo "Setting up multi-domain truststore for plugin: $plugin_name"
  
  # Parse the ssl_truststore configuration (passed as JSON-like string)
  local generate=$(echo "$ssl_truststore_config" | grep -o '"generate"[[:space:]]*:[[:space:]]*true' | wc -l)
  
  if [[ $generate -eq 0 ]]; then
    echo "Multi-domain truststore generation disabled for $plugin_name"
    return 0
  fi
  
  echo "Multi-domain truststore generation enabled for $plugin_name"
  
  # Extract truststore path (REQUIRED)
  local truststore_path=$(echo "$ssl_truststore_config" | grep -o '"truststore_path"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"truststore_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
  if [[ -z "$truststore_path" ]]; then
    echo "ERROR: ssl_truststore.truststore_path is required when ssl_truststore.generate is true for plugin $plugin_name"
    exit 1
  fi
  
  # Extract password environment variable name (REQUIRED)
  local password_env=$(echo "$ssl_truststore_config" | grep -o '"truststore_password_env"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/.*"truststore_password_env"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')
  if [[ -z "$password_env" ]]; then
    echo "ERROR: ssl_truststore.truststore_password_env is required when ssl_truststore.generate is true for plugin $plugin_name"
    exit 1
  fi
  
  # Check if password already exists
  if [[ -n "${!password_env}" ]]; then
    echo "Using existing password from environment variable: $password_env"
    local truststore_password="${!password_env}"
  else
    # Generate random password
    local truststore_password=$(openssl rand -base64 12)
    export "$password_env"="$truststore_password"
    echo "Generated random password for $password_env"
  fi
  
  # Create truststore directory if it doesn't exist
  mkdir -p $(dirname "$truststore_path")
  
  # Create truststore if it doesn't exist or if we're starting fresh
  if [[ ! -f "$truststore_path" ]]; then
    echo "Creating new multi-domain truststore at: $truststore_path"
    
    # Validate JAVA_HOME exists
    if [[ -z "$JAVA_HOME" ]]; then
      echo "ERROR: JAVA_HOME environment variable is not set, required for truststore creation for plugin $plugin_name"
      exit 1
    fi
    
    # Validate cacerts file exists
    if [[ ! -f "$JAVA_HOME/lib/security/cacerts" ]]; then
      echo "ERROR: Java cacerts file not found at $JAVA_HOME/lib/security/cacerts for plugin $plugin_name"
      exit 1
    fi
    
    # Copy cacerts as base truststore
    if ! cp "$JAVA_HOME/lib/security/cacerts" "$truststore_path"; then
      echo "ERROR: Failed to create truststore file at $truststore_path for plugin $plugin_name"
      exit 1
    fi
    
    # Change the default password to our password
    echo "Setting truststore password"
    if ! keytool -storepasswd -keystore "$truststore_path" \
         -storepass "changeit" -new "$truststore_password" >/dev/null 2>&1; then
      echo "ERROR: Failed to set truststore password for plugin $plugin_name"
      exit 1
    fi
  fi
  
  # Extract and process hostnames (REQUIRED)
  local hostnames=$(echo "$ssl_truststore_config" | grep -o '"hostnames"[[:space:]]*:[[:space:]]*\[[^]]*\]' | sed 's/.*"hostnames"[[:space:]]*:[[:space:]]*\[\([^]]*\)\].*/\1/' | tr ',' '\n')
  
  if [[ -z "$hostnames" ]]; then
    echo "ERROR: ssl_truststore.hostnames is required and must be a non-empty array when ssl_truststore.generate is true for plugin $plugin_name"
    exit 1
  fi
  
  # Validate that hostnames array is not empty
  local hostname_count=$(echo "$hostnames" | grep -v '^$' | wc -l)
  if [[ $hostname_count -eq 0 ]]; then
    echo "ERROR: ssl_truststore.hostnames must contain at least one hostname when ssl_truststore.generate is true for plugin $plugin_name"
    exit 1
  fi
  
  # Download and import certificates for each hostname
  while IFS= read -r hostname_entry; do
    if [[ -n "$hostname_entry" ]]; then
      # Clean up the hostname (remove quotes and whitespace)
      local clean_hostname=$(echo "$hostname_entry" | sed 's/[[:space:]]*"\([^"]*\)".*/\1/' | xargs)
      
      if [[ -n "$clean_hostname" ]]; then
        local hostname=$(echo "$clean_hostname" | cut -d':' -f1)
        local port=$(echo "$clean_hostname" | cut -d':' -f2)
        
        # Validate hostname:port format
        if [[ -z "$hostname" || -z "$port" || "$hostname" == "$port" ]]; then
          echo "ERROR: Invalid hostname format '$clean_hostname' in ssl_truststore.hostnames for plugin $plugin_name. Expected format: 'hostname:port'"
          exit 1
        fi
        
        # Validate port is numeric
        if ! [[ "$port" =~ ^[0-9]+$ ]]; then
          echo "ERROR: Invalid port '$port' in hostname '$clean_hostname' for plugin $plugin_name. Port must be numeric."
          exit 1
        fi
        
        local alias="$plugin_name-$(echo $hostname | tr '.' '-')"
        
                echo "Downloading certificate for $hostname:$port with alias $alias"
        
        # Download CA certificate
        local cert_file="$(dirname "$truststore_path")/$alias.pem"
        if ! echo | openssl s_client -connect $hostname:$port -showcerts 2>/dev/null | \
             openssl x509 -outform PEM > "$cert_file"; then
          echo "ERROR: Failed to download certificate from $hostname:$port for plugin $plugin_name"
          exit 1
        fi
        
        # Validate certificate file is not empty
        if [[ ! -s "$cert_file" ]]; then
          echo "ERROR: Downloaded certificate from $hostname:$port is empty for plugin $plugin_name"
          exit 1
        fi
        
        # Import certificate into truststore (skip if already exists)
        if keytool -list -keystore "$truststore_path" -storepass "$truststore_password" -alias "$alias" >/dev/null 2>&1; then
          echo "Certificate with alias $alias already exists in truststore, skipping"
        else
          echo "Importing certificate with alias $alias into truststore"
          if ! keytool -import -noprompt -alias "$alias" -file "$cert_file" \
               -keystore "$truststore_path" -storepass "$truststore_password" >/dev/null 2>&1; then
            echo "ERROR: Failed to import certificate with alias $alias into truststore for plugin $plugin_name"
            exit 1
          fi
        fi
      fi
    fi
  done <<< "$hostnames"
  

  
  echo "Multi-domain truststore setup completed for $plugin_name at: $truststore_path"
}

# Function to setup connectors in the background
setup_connectors() {
  echo "Starting connector setup process..."
  
  # Wait for Kafka Connect to start
  echo "Waiting for Kafka Connect to start..."
  until wget -q http://localhost:8083/ -O /dev/null; do
    echo "Waiting for Kafka Connect REST API..."
    sleep 5
  done

  echo "Kafka Connect REST API is up. Waiting for connector plugins to load..."
  # Wait for connector plugins to be available (indicates full initialization)
  local retry_count=0
  local max_retries=12
  until wget -q -O - http://localhost:8083/connector-plugins 2>/dev/null | grep -q "class" || [ $retry_count -ge $max_retries ]; do
    echo "Waiting for connector plugins to load... (attempt $((retry_count+1))/$max_retries)"
    sleep 5
    retry_count=$((retry_count+1))
  done
  
  echo "Kafka Connect plugins loaded. Now waiting for existing connectors to be restored from connect-config topic..."
  # Poll for connectors to be restored, but with a timeout
  local connector_wait=0
  local max_connector_wait=20
  local prev_count=-1
  while [ $connector_wait -lt $max_connector_wait ]; do
    INSTALLED_CONNECTORS=$(wget -q -O - http://localhost:8083/connectors 2>/dev/null || echo "[]")
    local current_count=$(echo "$INSTALLED_CONNECTORS" | tr -d '[]"' | tr ',' '\n' | grep -v '^$' | wc -l | xargs)
    
    if [ "$current_count" != "$prev_count" ]; then
      echo "Connectors being restored... Found $current_count connector(s) so far: $INSTALLED_CONNECTORS"
      prev_count=$current_count
      connector_wait=0  # Reset wait counter when we see changes
    else
      if [ $connector_wait -eq 0 ] && [ "$current_count" -gt 0 ]; then
        echo "Connector count stable at $current_count. Waiting 5 more seconds to ensure restoration is complete..."
      fi
      connector_wait=$((connector_wait+1))
    fi
    
    sleep 1
  done

  # Get final list of currently installed connectors
  echo "Fetching final list of installed connectors..."
  INSTALLED_CONNECTORS=$(wget -q -O - http://localhost:8083/connectors 2>/dev/null || echo "[]")
  echo "Installed connectors: $INSTALLED_CONNECTORS"

  # Build list of desired connectors from values file
  DESIRED_CONNECTORS=({{- range .plugins }} "{{ .name }}"{{- end }})
  echo "Desired connectors from values: ${DESIRED_CONNECTORS[@]}"
  echo "Number of desired connectors: ${#DESIRED_CONNECTORS[@]}"
  
  # Remove connectors that are not in the desired list
  if [[ "$INSTALLED_CONNECTORS" != "[]" && "$INSTALLED_CONNECTORS" != "" ]]; then
    echo "$INSTALLED_CONNECTORS" | tr -d '[]"' | tr ',' '\n' | while IFS= read -r connector; do
      connector=$(echo "$connector" | xargs) # trim whitespace
      if [[ -n "$connector" ]]; then
        found=false
        for desired in "${DESIRED_CONNECTORS[@]}"; do
          if [[ "$connector" == "$desired" ]]; then
            found=true
            break
          fi
        done
        if [[ "$found" == "false" ]]; then
          echo "Connector '$connector' is not enabled. Removing..."
          (echo -e "DELETE /connectors/$connector HTTP/1.1\r\nHost: localhost:8083\r\nConnection: close\r\n\r\n" | nc localhost 8083 > /dev/null 2>&1) || true
        fi
      fi
    done
  fi

  # Create/update connectors
  {{- range .plugins }}
  echo "Processing connector: {{ .name }}"
  {{- if hasKey . "enabled" }}
  {{- if not .enabled }}
  echo "Connector {{ .name }} is disabled. Removing if it exists..."
  (echo -e "DELETE /connectors/{{ .name }} HTTP/1.1\r\nHost: localhost:8083\r\nConnection: close\r\n\r\n" | nc localhost 8083 > /dev/null 2>&1) || true
  
  # Wait a bit between connectors to allow Kafka Connect API to stabilize
  sleep 3
  {{- else }}
  echo "Creating/updating connector: {{ .name }}"

{{- if hasKey . "ssl_truststore" }}
# Setup multi-domain truststore if configured
SSL_TRUSTSTORE_CONFIG='{"generate":{{ if hasKey .ssl_truststore "generate" }}{{ .ssl_truststore.generate }}{{ else }}false{{ end }}{{- if hasKey .ssl_truststore "truststore_path" }},"truststore_path":"{{ .ssl_truststore.truststore_path }}"{{- end }}{{- if hasKey .ssl_truststore "truststore_password_env" }},"truststore_password_env":"{{ .ssl_truststore.truststore_password_env }}"{{- end }}{{- if hasKey .ssl_truststore "hostnames" }},"hostnames":[{{- range $i, $hostname := .ssl_truststore.hostnames }}{{- if $i }},{{- end }}"{{ $hostname }}"{{- end }}]{{- end }}}'
setup_multi_domain_truststore "{{ .name }}" "$SSL_TRUSTSTORE_CONFIG"
{{- end }}

{{- if and (hasKey .config "ssl") (eq .config.ssl "true") }}
# Check if SSL is enabled
# Export ssl.truststore.location if it exists
{{- if hasKey .config "ssl.truststore.location" }}
export SSL_TRUSTSTORE_LOCATION={{ index .config "ssl.truststore.location" | quote }}
{{- end }}
# Export ssl.truststore.password if it exists
{{- if hasKey .config "ssl.truststore.password" }}
export SSL_TRUSTSTORE_PASSWORD={{ index .config "ssl.truststore.password" | quote }}
{{- end }}
# Setup truststore
truststore_init "{{ .config.hostname }}" "{{ .config.port }}" "{{ .name }}" "{{ default "" .config.jdbcConnectionProperties }}"
{{- end }}

CONFIG=$(cat << 'EOF'
{
  "name": "{{ .name }}",
  "config": {
    {{- $first := true }}
    {{- range $key, $value := .config }}
    {{- if $first }}{{ $first = false }}{{ else }},{{ end }}
    "{{ $key }}": "{{ $value }}"
    {{- end }}
    {{- if and (hasKey .config "ssl") (eq .config.ssl "true") (not (hasKey .config "ssl.truststore.password")) }}
    ,"ssl.truststore.password": "${SSL_TRUSTSTORE_PASSWORD}"
    {{- end }}
  }
}
EOF
)

# If we have a generated password, replace it in the config
if [[ -n "${SSL_TRUSTSTORE_PASSWORD}" && ! "{{ if hasKey .config "ssl.truststore.password" }}true{{ else }}false{{ end }}" == "true" ]]; then
  CONFIG=$(echo "$CONFIG" | sed "s|\${SSL_TRUSTSTORE_PASSWORD}|${SSL_TRUSTSTORE_PASSWORD}|g")
fi

  {{- if hasKey . "ssl_truststore" }}
  {{- if hasKey .ssl_truststore "truststore_password_env" }}
  # Replace plugin-specific truststore password if it exists
  PLUGIN_PASSWORD_VAR="{{ .ssl_truststore.truststore_password_env }}"
  echo "DEBUG: Looking for password in environment variable: $PLUGIN_PASSWORD_VAR"
  if [[ -n "${!PLUGIN_PASSWORD_VAR}" ]]; then
    echo "DEBUG: Replacing \${${PLUGIN_PASSWORD_VAR}} with password in config"
    CONFIG=$(echo "$CONFIG" | sed "s|\${${PLUGIN_PASSWORD_VAR}}|${!PLUGIN_PASSWORD_VAR}|g")
  else
    echo "DEBUG: No password found in $PLUGIN_PASSWORD_VAR"
  fi
  {{- end }}
  {{- end }}

# Try to create connector with retry logic
max_retries=5
retry_count=0
while [ $retry_count -lt $max_retries ]; do
  if create_or_update_connector "{{ .name }}" "$CONFIG" "$INSTALLED_CONNECTORS"; then
    echo "Successfully created/updated connector {{ .name }} on attempt $((retry_count+1))"
    break
  else
    retry_count=$((retry_count+1))
    if [ $retry_count -lt $max_retries ]; then
      echo "Failed to create/update connector {{ .name }}, retrying in 10 seconds (attempt $retry_count/$max_retries)..."
      sleep 10
    else
      echo "Failed to create/update connector {{ .name }} after $max_retries attempts"
    fi
  fi
done

# Wait a bit between connectors to allow Kafka Connect API to stabilize
sleep 3
{{- end }}
  {{- else }}
  echo "Creating/updating connector: {{ .name }}"
  {{- if and (hasKey .config "ssl") (eq .config.ssl "true") }}
  # Check if SSL is enabled
  # Export ssl.truststore.location if it exists
  {{- if hasKey .config "ssl.truststore.location" }}
  export SSL_TRUSTSTORE_LOCATION={{ index .config "ssl.truststore.location" | quote }}
  {{- end }}
  # Export ssl.truststore.password if it exists
  {{- if hasKey .config "ssl.truststore.password" }}
  export SSL_TRUSTSTORE_PASSWORD={{ index .config "ssl.truststore.password" | quote }}
  {{- end }}
  # Setup truststore
  truststore_init "{{ .config.hostname }}" "{{ .config.port }}" "{{ .name }}" "{{ default "" .config.jdbcConnectionProperties }}"
  {{- end }}

  CONFIG=$(cat << 'EOF'
{
  "name": "{{ .name }}",
  "config": {
    {{- $first := true }}
    {{- range $key, $value := .config }}
    {{- if $first }}{{ $first = false }}{{ else }},{{ end }}
    "{{ $key }}": "{{ $value }}"
    {{- end }}
    {{- if and (hasKey .config "ssl") (eq .config.ssl "true") (not (hasKey .config "ssl.truststore.password")) }}
    {{- if not $first }},{{ end }}
    "ssl.truststore.password": "${SSL_TRUSTSTORE_PASSWORD}"
    {{- end }}
  }
}
EOF
)

  # If we have a generated password, replace it in the config
  if [[ -n "${SSL_TRUSTSTORE_PASSWORD}" && ! "{{ if hasKey .config "ssl.truststore.password" }}true{{ else }}false{{ end }}" == "true" ]]; then
    CONFIG=$(echo "$CONFIG" | sed "s|\${SSL_TRUSTSTORE_PASSWORD}|${SSL_TRUSTSTORE_PASSWORD}|g")
  fi

  {{- if hasKey . "ssl_truststore" }}
{{- if hasKey .ssl_truststore "truststore_password_env" }}
# Replace plugin-specific truststore password if it exists
PLUGIN_PASSWORD_VAR="{{ .ssl_truststore.truststore_password_env }}"
echo "DEBUG: Looking for password in environment variable: $PLUGIN_PASSWORD_VAR"
if [[ -n "${!PLUGIN_PASSWORD_VAR}" ]]; then
  echo "DEBUG: Replacing \${${PLUGIN_PASSWORD_VAR}} with password in config"
  CONFIG=$(echo "$CONFIG" | sed "s|\${${PLUGIN_PASSWORD_VAR}}|${!PLUGIN_PASSWORD_VAR}|g")
else
  echo "DEBUG: No password found in $PLUGIN_PASSWORD_VAR"
fi
{{- end }}
{{- end }}

  # Try to create connector with retry logic
max_retries=5
retry_count=0
while [ $retry_count -lt $max_retries ]; do
  if create_or_update_connector "{{ .name }}" "$CONFIG" "$INSTALLED_CONNECTORS"; then
    echo "Successfully created/updated connector {{ .name }} on attempt $((retry_count+1))"
    break
  else
    retry_count=$((retry_count+1))
    if [ $retry_count -lt $max_retries ]; then
      echo "Failed to create/update connector {{ .name }}, retrying in 10 seconds (attempt $retry_count/$max_retries)..."
      sleep 10
    else
      echo "Failed to create/update connector {{ .name }} after $max_retries attempts"
    fi
  fi
done

# Wait a bit between connectors to allow Kafka Connect API to stabilize
sleep 3
  {{- end }}
  {{- end }}

  echo "All Kafka connectors have been configured and started."
}

# Signal handler for graceful shutdown
cleanup() {
  echo "Received shutdown signal, stopping Kafka Connect..."
  if [[ -n $KAFKA_PID ]]; then
    kill -TERM $KAFKA_PID
    wait $KAFKA_PID
  fi
  exit 0
}

# Set up signal handlers
trap cleanup SIGTERM SIGINT

# Wait for the plugins-downloader to finish (replaces the fixed 60 s sleep of chart 4.2.x and earlier):
# plugin.path is scanned once per JVM, so a plugin that is still downloading would never be loaded.
PLUGIN_SYNC=/opt/kafka/sync
PLUGIN_WAIT_TIMEOUT={{ $waitTimeout }}
PLUGIN_WAIT_ACTION={{ $waitAction }}
print_pending_plugins() {
  if [[ -s "$PLUGIN_SYNC/pending" ]]; then
    sed 's/^/  - /' "$PLUGIN_SYNC/pending"
  else
    echo "  - unknown: the downloader has not reported yet"
  fi
}
plugins_waited=0
while [[ ! -f "$PLUGIN_SYNC/downloads-done" ]]; do
  if [[ "$PLUGIN_WAIT_TIMEOUT" -gt 0 && "$plugins_waited" -ge "$PLUGIN_WAIT_TIMEOUT" ]]; then
    if [[ "$PLUGIN_WAIT_ACTION" == "restart" ]]; then
      echo "FATAL: connector plugins not ready after ${PLUGIN_WAIT_TIMEOUT}s; exiting so the container restarts and waits again. Missing:"
      print_pending_plugins
      exit 1
    fi
    echo "WARNING: connector plugins not ready after ${PLUGIN_WAIT_TIMEOUT}s; starting Kafka Connect WITHOUT:"
    print_pending_plugins
    touch "$PLUGIN_SYNC/connect-started-degraded"
    break
  fi
  if (( plugins_waited % 30 == 0 )); then
    echo "Waiting for plugin downloads (${plugins_waited}s, timeout ${PLUGIN_WAIT_TIMEOUT}s, 0 = none)..."
  fi
  sleep 5 &
  wait $!
  plugins_waited=$((plugins_waited+5))
done
if [[ -f "$PLUGIN_SYNC/downloads-done" ]]; then
  rm -f "$PLUGIN_SYNC/connect-started-degraded"
  echo "Plugins ready after ${plugins_waited}s"
  if [[ -s "$PLUGIN_SYNC/pending" ]]; then
    echo "WARNING: these plugin artifacts were skipped because of a configuration error and are not installed:"
    print_pending_plugins
  fi
fi

echo "Starting Kafka Connect distributed worker..."

# Updating rest.advertised.host.name dynamically
POD_ID=$(echo "$POD_NAME" | rev | cut -d'-' -f 1 | rev)
WORKLOAD_NAME=$(echo $CPLN_WORKLOAD | sed 's|.*/workload/\([^/]*\)$|\1|')
cp /opt/kafka/config/connect-distributed.properties /opt/kafka/config/connect-distributed-updated.properties
echo "" >> /opt/kafka/config/connect-distributed-updated.properties
echo "rest.advertised.host.name=${WORKLOAD_NAME}-${POD_ID}.${WORKLOAD_NAME}" >> /opt/kafka/config/connect-distributed-updated.properties

# Start the connector setup process in the background
setup_connectors &
SETUP_PID=$!

# Start Kafka Connect in the foreground
echo "Starting Kafka Connect in foreground mode..."
exec /opt/kafka/bin/connect-distributed.sh /opt/kafka/config/connect-distributed-updated.properties &
KAFKA_PID=$!

# Wait for either process to finish
wait $KAFKA_PID
{{- end }}


{{/* Labeling */}}

{{/*
Common labels
*/}}
{{- define "kafka.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}