{{/* Resource Naming */}}

{{/*
Artemis broker workload name
*/}}
{{- define "artemis.name" -}}
{{- printf "%s-artemis" .Release.Name }}
{{- end }}

{{/*
Artemis volume set name
*/}}
{{- define "artemis.volume.name" -}}
{{- printf "%s-artemis-vs" .Release.Name }}
{{- end }}

{{/*
Artemis identity name
*/}}
{{- define "artemis.identity.name" -}}
{{- printf "%s-artemis-identity" .Release.Name }}
{{- end }}

{{/*
Artemis policy name (reveal on the credentials secret)
*/}}
{{- define "artemis.policy.name" -}}
{{- printf "%s-artemis-policy" .Release.Name }}
{{- end }}

{{/*
Artemis GVC-read policy name (two locations only)
*/}}
{{- define "artemis.policy.gvc.name" -}}
{{- printf "%s-artemis-gvc-policy" .Release.Name }}
{{- end }}


{{/* Labeling */}}

{{/*
Common tags
*/}}
{{- define "artemis.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}


{{/* Topology and sizing */}}

{{/*
The listed locations, rendered once as a space-separated env var. The start
script derives this broker's peer from it, and refuses to run in a location the
list does not name. `ARTEMIS_` and not `CPLN_`: env names starting with CPLN_
are rejected by the API at apply time, invisibly to `helm template`.
*/}}
{{- define "artemis.locationEnv" -}}
- name: ARTEMIS_LOCATIONS
  {{- $names := list }}{{ range .Values.locations }}{{ $names = append $names .name }}{{ end }}
  value: {{ join " " $names | quote }}
{{- end -}}

{{/*
The active-passive primary location: mirror.primary, or the first listed
location when it is empty.
*/}}
{{- define "artemis.primary" -}}
{{- .Values.mirror.primary | default (index .Values.locations 0).name -}}
{{- end -}}

{{/*
JVM maximum heap in MiB: half of resources.memory (Mi or Gi only, enforced by
artemis.validateResources). The image's own default is -Xmx2G, which
OOM-kills a smaller container, so the heap must follow the memory knob.
*/}}
{{- define "artemis.heapMb" -}}
{{- $m := toString .Values.resources.memory -}}
{{- $n := int (regexFind "^[0-9]+" $m) -}}
{{- if hasSuffix "Gi" $m -}}{{- $n = mul $n 1024 -}}{{- end -}}
{{- div $n 2 -}}
{{- end -}}

{{/*
Render a script for a container arg. The platform, like Kubernetes, expands
$(VAR) and turns $$ into $ inside container args (even inside single quotes).
Doubling every $ makes the shell receive the script byte for byte.
A |- block scalar: the first line is "|-", so heredoc terminators keep column 0.
*/}}
{{- define "artemis.inlineScript" -}}
|-
{{ . | replace "$" "$$" | indent 2 }}
{{- end -}}


{{/* Validation */}}

{{/*
This chart never creates or reads a GVC: it deploys into the GVC you install
into. A `gvc` key (for example a block pasted from a chart that creates its
own GVC) would otherwise be ignored silently.
*/}}
{{- define "artemis.validateNoGvcKey" -}}
{{- if hasKey .Values "gvc" -}}
{{- fail "artemis: the `gvc` values key is not supported. This chart never creates a GVC -- it deploys into the GVC you install into. List that GVC's location(s) under the top-level `locations` and delete `gvc` from your values." -}}
{{- end -}}
{{- end -}}

{{/*
One or two locations, each listed once, each a valid location name.
More than two is refused: mirroring more than two brokers duplicates messages
(brokers pass mirrored events on to their other peers, so copies arrive by two
routes).
*/}}
{{- define "artemis.validateLocations" -}}
{{- if and .Values.locations (not (kindIs "slice" .Values.locations)) -}}
{{- fail (printf "artemis: `locations` must be a list of objects with a `name`, e.g. `locations: [{name: aws-us-east-1}]` (got %v)." .Values.locations) -}}
{{- end -}}
{{- $locs := .Values.locations | default list -}}
{{- if lt (len $locs) 1 -}}
{{- fail "artemis: `locations` must list at least one location of the GVC you install into, e.g. `locations: [{name: aws-us-east-1}]`." -}}
{{- end -}}
{{- if gt (len $locs) 2 -}}
{{- fail (printf "artemis: `locations` lists %d locations; list one or two. Mirroring more than two brokers duplicates messages." (len $locs)) -}}
{{- end -}}
{{- $seen := dict -}}
{{- range $locs -}}
{{- if not (kindIs "map" .) -}}
{{- fail (printf "artemis: every `locations` entry must be an object with a `name`, e.g. `- name: aws-us-east-1` (got %v)." .) -}}
{{- end -}}
{{- $n := toString (.name | default "") -}}
{{- if not (regexMatch "^[a-z0-9]([a-z0-9-]*[a-z0-9])?$" $n) -}}
{{- fail (printf "artemis: location name %q is not a valid location name (lowercase letters, digits and dashes, e.g. aws-us-east-1)." $n) -}}
{{- end -}}
{{- if hasKey $seen $n -}}
{{- fail (printf "artemis: location '%s' is listed more than once in `locations`. List each location exactly once." $n) -}}
{{- end -}}
{{- $_ := set $seen $n true -}}
{{- end -}}
{{- end -}}

{{/*
The credentials secret name is required.
*/}}
{{- define "artemis.validateCredentials" -}}
{{- if not .Values.credentialsSecretName -}}
{{- fail "artemis: credentialsSecretName is required -- it names the `dictionary` secret holding `username` and `password`. Create that secret BEFORE installing; see Prerequisites in the README." -}}
{{- end -}}
{{- end -}}

{{/*
applicationUsers: each entry names a prerequisite dictionary secret (username, password)
and the address patterns its user may send to and/or consume from.
*/}}
{{- define "artemis.validateApplicationUsers" -}}
{{- $apps := .Values.applicationUsers | default list -}}
{{- if not (kindIs "slice" $apps) -}}
{{- fail (printf "artemis: applicationUsers must be a list, e.g. `applicationUsers: [{secretName: my-orders-app, send: [orders.#], consume: [orders.#]}]` (got %v)." $apps) -}}
{{- end -}}
{{- $seen := dict -}}
{{- range $i, $a := $apps -}}
{{- if not (kindIs "map" $a) -}}
{{- fail (printf "artemis: applicationUsers[%d] must be an object with secretName, send and/or consume (got %v)." $i $a) -}}
{{- end -}}
{{- if not $a.secretName -}}
{{- fail (printf "artemis: applicationUsers[%d].secretName is required: the dictionary secret holding this application's username and password." $i) -}}
{{- end -}}
{{- if eq $a.secretName $.Values.credentialsSecretName -}}
{{- fail (printf "artemis: applicationUsers[%d] uses the admin credentials secret %q; give each application its own secret." $i $a.secretName) -}}
{{- end -}}
{{- if hasKey $seen $a.secretName -}}
{{- fail (printf "artemis: the secret %q is listed in applicationUsers more than once; list each application once, with all its patterns." $a.secretName) -}}
{{- end -}}
{{- $_ := set $seen $a.secretName true -}}
{{- if and (not $a.send) (not $a.consume) -}}
{{- fail (printf "artemis: applicationUsers[%d] (%s) needs at least one address pattern under send or consume, e.g. send: [orders.#]." $i $a.secretName) -}}
{{- end -}}
{{- range $k := list "send" "consume" -}}
{{- $ps := get $a $k | default list -}}
{{- if not (kindIs "slice" $ps) -}}
{{- fail (printf "artemis: applicationUsers[%d].%s must be a list of address patterns, e.g. [orders.#] (got %v)." $i $k $ps) -}}
{{- end -}}
{{- range $ps -}}
{{- if not (regexMatch "^[A-Za-z0-9_*#-]+([.][A-Za-z0-9_*#-]+)*$" (toString .)) -}}
{{- fail (printf "artemis: applicationUsers[%d].%s pattern %q is not a valid address pattern: words of letters, digits, _ and - separated by dots, with * (one word) and # (any words) as wildcards, e.g. orders.#." $i $k (toString .)) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
broker.properties lines for applicationUsers: role app<i> for the i-th entry.
Artemis applies only the MOST SPECIFIC security match to an address (roles are
not merged with the broker.xml "#" match), so every pattern also grants the
admin role amq everything; otherwise the admin, the console and the mirror
(which logs in as the admin) would lose access to those addresses.
send    = send + create the address and its durable queue (auto-create on first send)
consume = consume + browse + create the address and its queue, and the
          subscription queues a topic consumer needs
*/}}
{{- define "artemis.appSecurity" -}}
{{- $all := list "send" "consume" "browse" "createAddress" "deleteAddress" "createDurableQueue" "deleteDurableQueue" "createNonDurableQueue" "deleteNonDurableQueue" "manage" "view" "edit" -}}
{{- $grants := dict -}}
{{- range $i, $a := .Values.applicationUsers | default list -}}
{{- range ($a.send | default list) -}}
{{- $g := get $grants (toString .) | default dict -}}
{{- range list "send" "createAddress" "createDurableQueue" -}}{{- $_ := set $g (printf "app%d.%s" $i .) true -}}{{- end -}}
{{- $_ := set $grants (toString .) $g -}}
{{- end -}}
{{- range ($a.consume | default list) -}}
{{- $g := get $grants (toString .) | default dict -}}
{{- range list "consume" "browse" "createAddress" "createDurableQueue" "createNonDurableQueue" "deleteNonDurableQueue" -}}{{- $_ := set $g (printf "app%d.%s" $i .) true -}}{{- end -}}
{{- $_ := set $grants (toString .) $g -}}
{{- end -}}
{{- end -}}
{{- range $pat := keys $grants | sortAlpha -}}
{{- range $all }}
securityRoles."{{ $pat }}".amq.{{ . }}=true
{{- end }}
{{- range $rp := keys (get $grants $pat) | sortAlpha }}
securityRoles."{{ $pat }}".{{ $rp }}=true
{{- end }}
{{- end -}}
{{- end -}}

{{/*
Memory in Mi or Gi, at least 1Gi: the JVM heap is half of it.
*/}}
{{- define "artemis.validateResources" -}}
{{- $m := toString .Values.resources.memory -}}
{{- if not (regexMatch "^[0-9]+(Mi|Gi)$" $m) -}}
{{- fail (printf "artemis: resources.memory must be a whole number of Mi or Gi, e.g. 2Gi or 1536Mi (got %q)." $m) -}}
{{- end -}}
{{- $n := int (regexFind "^[0-9]+" $m) -}}
{{- if hasSuffix "Gi" $m -}}{{- $n = mul $n 1024 -}}{{- end -}}
{{- if lt $n 1024 -}}
{{- fail (printf "artemis: resources.memory must be at least 1Gi (got %s); the JVM heap is half of it." $m) -}}
{{- end -}}
{{- end -}}

{{/*
ha.enabled runs a primary/backup pair in ONE location; it does not combine
with the two-location mirror.
*/}}
{{- define "artemis.validateHa" -}}
{{- if not (kindIs "bool" .Values.ha.enabled) -}}
{{- fail (printf "artemis: ha.enabled must be true or false (got %v)." .Values.ha.enabled) -}}
{{- end -}}
{{- if and .Values.ha.enabled (ne (len .Values.locations) 1) -}}
{{- fail "artemis: ha.enabled runs a primary/backup pair in one location and does not combine with the two-location mirror. List exactly one location, or set ha.enabled: false." -}}
{{- end -}}
{{- if and .Values.ha.enabled .Values.publicAccess.enabled -}}
{{- fail "artemis: ha.enabled does not combine with publicAccess.enabled: the public endpoint spreads console requests over both brokers, whose logins are separate. Reach each broker's console with cpln port-forward --replica (see the README), or set ha.enabled: false." -}}
{{- end -}}
{{- end -}}

{{/*
Mirror settings: the catch-up timeout, the mode, the active-passive primary
(one of the listed locations) and the takeover delay.
*/}}
{{- define "artemis.validateMirror" -}}
{{- $t := toString .Values.mirror.catchUpTimeoutSeconds -}}
{{- if or (not (regexMatch "^[0-9]+$" $t)) (lt (int $t) 30) (gt (int $t) 1800) -}}
{{- fail (printf "artemis: mirror.catchUpTimeoutSeconds must be a whole number of seconds from 30 to 1800 (got %v)." .Values.mirror.catchUpTimeoutSeconds) -}}
{{- end -}}
{{- if not (has (toString .Values.mirror.mode) (list "active-passive" "active-active")) -}}
{{- fail (printf "artemis: mirror.mode must be active-passive or active-active (got %v)." .Values.mirror.mode) -}}
{{- end -}}
{{- $k := toString .Values.mirror.takeoverSeconds -}}
{{- if or (not (regexMatch "^[0-9]+$" $k)) (lt (int $k) 30) (gt (int $k) 1800) -}}
{{- fail (printf "artemis: mirror.takeoverSeconds must be a whole number of seconds from 30 to 1800 (got %v)." .Values.mirror.takeoverSeconds) -}}
{{- end -}}
{{- if .Values.mirror.primary -}}
{{- $names := list }}{{ range .Values.locations }}{{ $names = append $names (toString .name) }}{{ end -}}
{{- if not (has (toString .Values.mirror.primary) $names) -}}
{{- fail (printf "artemis: mirror.primary %q is not one of the listed locations (%s). Name one of them, or leave it empty for the first." .Values.mirror.primary (join ", " $names)) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
internalAccess.type: `none` is not offered -- it would break the mirror and
leave a broker no client can reach.
*/}}
{{- define "artemis.validateAccess" -}}
{{- if not (has .Values.internalAccess.type (list "same-gvc" "same-org" "workload-list")) -}}
{{- fail (printf "artemis: internalAccess.type must be one of same-gvc, same-org, workload-list (got %v)." .Values.internalAccess.type) -}}
{{- end -}}
{{- end -}}

{{/*
The platform rejects volume snapshot schedules more frequent than hourly, at
apply time only -- the release would be left half-installed. A schedule runs at
most hourly when its minute field is a single fixed minute.
*/}}
{{- define "artemis.validateSnapshots" -}}
{{- $s := toString .Values.volumeset.snapshots.schedule -}}
{{- if $s -}}
{{- if not (regexMatch "^[0-5]?[0-9] +[^ ]+ +[^ ]+ +[^ ]+ +[^ ]+$" (trim $s)) -}}
{{- fail (printf "artemis: volumeset.snapshots.schedule %q must be a 5-field cron with a single fixed minute (snapshots cannot run more often than hourly), e.g. \"0 3 * * *\"; use \"\" to turn snapshots off" $s) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
Single aggregate validator. Invoked once, from identity.yaml, which is
unconditionally rendered -- so `is validation still wired up?` is one grep.
*/}}
{{- define "artemis.validate" -}}
{{- include "artemis.validateNoGvcKey" . -}}
{{- include "artemis.validateLocations" . -}}
{{- include "artemis.validateCredentials" . -}}
{{- include "artemis.validateApplicationUsers" . -}}
{{- include "artemis.validateResources" . -}}
{{- include "artemis.validateHa" . -}}
{{- include "artemis.validateMirror" . -}}
{{- include "artemis.validateAccess" . -}}
{{- include "artemis.validateSnapshots" . -}}
{{- end -}}
