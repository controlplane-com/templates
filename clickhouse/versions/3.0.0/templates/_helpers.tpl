{{/* Resource Naming */}}

{{/*
Clickhouse Keeper Workload Name
*/}}
{{- define "clickhouse.keeper.name" -}}
{{- printf "%s-clickhouse-keeper" .Release.Name }}
{{- end }}

{{/*
Clickhouse Server Workload Name
*/}}
{{- define "clickhouse.server.name" -}}
{{- printf "%s-clickhouse-server" .Release.Name }}
{{- end }}

{{/*
Clickhouse Secret Database Config Name
*/}}
{{- define "clickhouse.secretDatabase.name" -}}
{{- printf "%s-clickhouse-db-config" .Release.Name }}
{{- end }}

{{/*
Clickhouse Secret Keeper Config Name
*/}}
{{- define "clickhouse.secretKeeper.name" -}}
{{- printf "%s-clickhouse-keeper-startup" .Release.Name }}
{{- end }}

{{/*
Clickhouse Secret Server Config Name
*/}}
{{- define "clickhouse.secretServer.name" -}}
{{- printf "%s-clickhouse-server-startup" .Release.Name }}
{{- end }}

{{/*
Clickhouse Secret GCS Config Name
*/}}
{{- define "clickhouse.secretGCS.name" -}}
{{- printf "%s-clickhouse-gcs-config" .Release.Name }}
{{- end }}

{{/*
Clickhouse Secret S3 Config Name
*/}}
{{- define "clickhouse.secretS3.name" -}}
{{- printf "%s-clickhouse-s3-config" .Release.Name }}
{{- end }}

{{/*
Clickhouse Secret Azure Config Name
*/}}
{{- define "clickhouse.secretAzure.name" -}}
{{- printf "%s-clickhouse-azure-config" .Release.Name }}
{{- end }}

{{/*
Clickhouse Secret Hetzner Config Name
*/}}
{{- define "clickhouse.secretHetzner.name" -}}
{{- printf "%s-clickhouse-hetzner-config" .Release.Name }}
{{- end }}

{{/*
Clickhouse Identity Name
*/}}
{{- define "clickhouse.identity.name" -}}
{{- printf "%s-clickhouse-identity" .Release.Name }}
{{- end }}

{{/*
Clickhouse Policy Name
*/}}
{{- define "clickhouse.policy.name" -}}
{{- printf "%s-clickhouse-policy" .Release.Name }}
{{- end }}

{{/*
Clickhouse GVC-read Policy Name
*/}}
{{- define "clickhouse.policy.gvc.name" -}}
{{- printf "%s-clickhouse-gvc-policy" .Release.Name }}
{{- end }}

{{/*
Clickhouse Volume Set Server Name
*/}}
{{- define "clickhouse.volumeServer.name" -}}
{{- printf "%s-clickhouse-server-vs" .Release.Name }}
{{- end }}

{{/*
Clickhouse Volume Set Keeper Name
*/}}
{{- define "clickhouse.volumeKeeper.name" -}}
{{- printf "%s-clickhouse-keeper-vs" .Release.Name }}
{{- end }}


{{/* Validation */}}

{{/*
Determine if this is a single-node deployment.
Requires exactly 1 location with exactly 1 replica.
1 location with >1 replica is a single-shard cluster and still requires Keeper.
*/}}
{{- define "clickhouse.isSingleNode" -}}
{{- $locs := .Values.locations | default (list) -}}
{{- if and (eq (len $locs) 1) (eq ((index $locs 0).replicas | int) 1) -}}
true
{{- end -}}
{{- end -}}

{{- define "clickhouse.validateStorage" -}}
{{- $provider := .Values.provider -}}
{{- if not (or (eq $provider "aws") (eq $provider "gcp") (eq $provider "azure") (eq $provider "hetzner")) -}}
  {{- fail "provider must be set to 'aws', 'gcp', 'azure', or 'hetzner'." -}}
{{- end -}}
{{- if eq $provider "aws" -}}
  {{- if not .Values.aws.bucket -}}
    {{- fail "All fields are required for AWS. Missing: aws.bucket" -}}
  {{- end -}}
  {{- if not .Values.aws.region -}}
    {{- fail "All fields are required for AWS. Missing: aws.region" -}}
  {{- end -}}
  {{- if not .Values.aws.cloudAccountName -}}
    {{- fail "All fields are required for AWS. Missing: aws.cloudAccountName" -}}
  {{- end -}}
  {{- if not .Values.aws.policyName -}}
    {{- fail "All fields are required for AWS. Missing: aws.policyName" -}}
  {{- end -}}
{{- end -}}
{{- if eq $provider "gcp" -}}
  {{- if not .Values.gcp.bucket -}}
    {{- fail "All fields are required for GCP. Missing: gcp.bucket" -}}
  {{- end -}}
    {{- end -}}
{{- if eq $provider "azure" -}}
  {{- if not .Values.azure.storageAccount -}}
    {{- fail "All fields are required for Azure. Missing: azure.storageAccount" -}}
  {{- end -}}
  {{- if not .Values.azure.container -}}
    {{- fail "All fields are required for Azure. Missing: azure.container" -}}
  {{- end -}}
  {{- if not .Values.azure.credentialsSecretName -}}
    {{- fail "All fields are required for Azure. Missing: azure.credentialsSecretName" -}}
  {{- end -}}
{{- end -}}
{{- if eq $provider "hetzner" -}}
  {{- if not .Values.hetzner.bucket -}}
    {{- fail "All fields are required for Hetzner. Missing: hetzner.bucket" -}}
  {{- end -}}
  {{- if not .Values.hetzner.region -}}
    {{- fail "All fields are required for Hetzner. Missing: hetzner.region" -}}
  {{- end -}}
    {{- end -}}
{{- end -}}

{{/*
`locations` is the topology, not just placement: its length selects the mode, a
node's position in it is its shard number, and the first three entries are the
Keeper Raft group. Every shape check therefore has to pass before anything else
in the chart reads the list.
*/}}
{{- define "clickhouse.validateLocations" -}}
{{- if not .Values.locations -}}
  {{- fail "clickhouse: `locations` must contain at least 1 location. It is a top-level values key from 3.0.0 (it was `gvc.locations` in 2.x) and every location listed must already exist in the GVC you install into." -}}
{{- end -}}
{{- $count := len .Values.locations -}}
{{- if eq $count 2 -}}
  {{- fail "2 locations is not supported. Use 1 location for single-node mode or 3+ locations for cluster mode." -}}
{{- end -}}
{{- $seen := dict -}}
{{- range .Values.locations -}}
  {{- if not .name -}}
    {{- fail "clickhouse: every entry in `locations` needs a `name`." -}}
  {{- end -}}
  {{- if hasKey $seen .name -}}
    {{- fail (printf "clickhouse: location '%s' is listed more than once in `locations`. Each location is one shard, and the shard index is the location's position in the list -- a duplicate emits two shards with identical replica hostnames, and the second is aliased onto the first and unreachable. List each location exactly once." .name) -}}
  {{- end -}}
  {{- $_ := set $seen .name true -}}
{{- end -}}
{{- end -}}

{{/*
2.8.0 quietly turned `replicas: 0` into a suspended location. That was never
documented, and with defaultOptions pinned to 0/0 the branch is dead code that
would still consume a shard index and a Keeper Raft slot. Refuse it instead.
*/}}
{{- define "clickhouse.validateReplicas" -}}
{{- range .Values.locations -}}
{{- if lt (.replicas | int) 1 -}}
{{- fail (printf "clickhouse: location '%s' must have at least 1 replica. To stop running in a location, remove it from `locations` (and from the GVC if nothing else uses it) -- a location with 0 replicas would still take a shard number and a Keeper Raft slot." .name) -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/*
clusterName becomes an XML element name in <remote_servers> AND is interpolated
unquoted into `ON CLUSTER <name>` DDL, so anything that is not a bare identifier
produces a config that parses as something else or DDL that does not parse.
*/}}
{{- define "clickhouse.validateClusterName" -}}
{{- if not .Values.clusterName -}}
{{- fail "clickhouse: clusterName is required." -}}
{{- end -}}
{{- if not (regexMatch "^[A-Za-z_][A-Za-z0-9_]*$" (.Values.clusterName | toString)) -}}
{{- fail (printf "clickhouse: clusterName '%s' is not a bare identifier. It becomes an XML element name and is used unquoted in `ON CLUSTER` DDL, so it must match ^[A-Za-z_][A-Za-z0-9_]*$ -- letters, digits and underscores, not starting with a digit. 'my_cluster' is valid; 'my-cluster' is not." .Values.clusterName) -}}
{{- end -}}
{{- end -}}

{{/*
The chart stopped creating a GVC in 3.0.0. Refuse to render if the values still
carry the 2.x `gvc` key -- an in-place `helm upgrade` from 2.x would drop
`kind: gvc` from the manifest, and Helm deletes what a chart no longer declares,
taking the GVC and everything inside it.
*/}}
{{- define "clickhouse.validateNoLegacyGvc" -}}
{{- if hasKey .Values "gvc" -}}
{{- fail "clickhouse 3.0.0: the `gvc` values key was REMOVED. This chart no longer creates a GVC -- it deploys into the GVC you install into, and `gvc.locations` moved to the top-level `locations`. DO NOT `helm upgrade` a 2.x release onto 3.0.0: the upgrade drops `kind: gvc` from the manifest and Helm deletes what a chart no longer declares, which DESTROYS that GVC and every workload, volumeset and identity inside it -- including your ClickHouse metadata and Keeper state. Install 3.0.0 as a NEW release against an existing GVC, reload your data, then uninstall the old release. See `Migrating from 2.x` in the README." -}}
{{- end -}}
{{- end -}}

{{/*
Object-storage credentials for gcp and hetzner moved to prerequisite secrets. They
are supplied as AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY and read via
<use_environment_credentials>, because a cpln:// reference inside the disk XML is
never resolved by the platform.
*/}}
{{- define "clickhouse.validateStorageCreds" -}}
{{- range $p := list "gcp" "hetzner" -}}
{{- if eq $.Values.provider $p -}}
{{- $c := index $.Values $p -}}
{{- if or $c.accessKeyId $c.secretAccessKey -}}
{{- fail (printf "clickhouse: %s.accessKeyId and %s.secretAccessKey were REMOVED -- they are now a `dictionary` secret you create, named by %s.credentialsSecretName, holding those two keys. Delete them from your values." $p $p $p) -}}
{{- end -}}
{{- if not $c.credentialsSecretName -}}
{{- fail (printf "clickhouse: %s.credentialsSecretName is required -- it names the `dictionary` secret holding accessKeyId and secretAccessKey. Create it BEFORE installing." $p) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "clickhouse.validateCredentials" -}}
{{- if hasKey .Values.azure "accountKey" -}}
{{- fail "clickhouse: azure.accountKey was REMOVED -- it is now a `dictionary` secret you create, named by azure.credentialsSecretName, holding the key `accountKey`. Delete it from your values. See Prerequisites in the README." -}}
{{- end -}}
{{- if or (hasKey .Values.database "password") (hasKey .Values.database "name") -}}
{{- fail "clickhouse: database.password and database.name were REMOVED -- they are now a `dictionary` secret you create, named by database.credentialsSecretName, holding the keys `password` and `database`. Delete them from your values. See Prerequisites in the README." -}}
{{- end -}}
{{- if not .Values.database.credentialsSecretName -}}
{{- fail "clickhouse: database.credentialsSecretName is required -- it names the `dictionary` secret holding `password` and `database`. Create it BEFORE installing; see Prerequisites in the README." -}}
{{- end -}}
{{- end -}}

{{/*
Single aggregate validator. Invoked once, from identity.yaml, which is
unconditionally rendered in every mode -- so `is validation still wired up?` is
one grep. 2.8.0 scattered validateStorage across four files and still managed to
leave validateLocations unreachable in single-node mode.
*/}}
{{- define "clickhouse.validate" -}}
{{- include "clickhouse.validateNoLegacyGvc" . -}}
{{- include "clickhouse.validateLocations" . -}}
{{- include "clickhouse.validateReplicas" . -}}
{{- include "clickhouse.validateClusterName" . -}}
{{- include "clickhouse.validateStorage" . -}}
{{- include "clickhouse.validateStorageCreds" . -}}
{{- include "clickhouse.validateCredentials" . -}}
{{- end -}}


{{/* Topology */}}

{{/*
The topology, rendered ONCE for the whole chart and consumed by both startup
scripts, so the server and the Keeper can never disagree about the cluster.
`loc:replicas` pairs, comma separated.
*/}}
{{- define "clickhouse.locationsEnv" -}}
- name: LOCATIONS_STR
  value: "{{- $locs := .Values.locations | default (list) -}}{{- range $i, $loc := $locs -}}{{ $loc.name }}:{{ $loc.replicas }}{{ if lt $i (sub (len $locs) 1) }},{{ end }}{{- end }}"
{{- end -}}

{{/*
Shared boot-time GVC reconciliation prelude, emitted into all three startup
script bodies (server single-node, server cluster, keeper).

Why it exists: the platform accepts a localOptions entry naming a location the
GVC does not have. It is stored verbatim, is inert, and nothing reports it -- so
a typo in `locations` yields a cluster whose declared shards can never exist,
and (before 3.0.0) a bootstrap node that printed "Keeper not ready yet" forever.
Helm cannot see a live GVC at render time, so ask the GVC itself at boot.

Portability: neither image ships curl (server is ubuntu + GNU wget, keeper is
alpine + BusyBox wget), so this uses only the wget options both accept -- no
--tries, no --timeout=, no -w. HTTP failure surfaces as a non-zero exit and the
retry is done in shell. Measured byte-identical output under both.

Requires LOG_PREFIX to be set by the caller, so the Keeper's lines are not
attributed to the server.
Sets: GVC, CONFIGURED_LOCS, GVC_READ_OK, GVC_LOCS, MISSING. The caller decides
what to do about MISSING -- the disposition differs per script.
*/}}
{{- define "clickhouse.gvcLocationGuard" -}}
# --- GVC location reconciliation ---
# GVC comes from the runtime built-in, not from Helm, so it cannot drift from
# the GVC the workload is actually running in.
GVC="${CPLN_GVC}"

CONFIGURED_LOCS=""
for _pair in $(printf '%s' "${LOCATIONS_STR:-}" | tr ',' ' '); do
    CONFIGURED_LOCS="${CONFIGURED_LOCS}${_pair%%:*} "
done

GVC_LOCS=""
GVC_READ_OK="false"
for _try in 1 2 3; do
    if GVC_JSON=$(wget -q -O - -T 10 \
            --header="Authorization: ${CPLN_TOKEN:-}" \
            "${CPLN_ENDPOINT:-http://api.cpln.io}/org/${CPLN_ORG:-}/gvc/${GVC}" 2>/dev/null); then
        GVC_LOCS=$(printf '%s' "$GVC_JSON" | tr -d ' \n' \
            | sed -n 's/.*"locationLinks":\[\([^]]*\)\].*/\1/p' \
            | tr ',' '\n' | sed 's#.*/##;s/"//g' | tr '\n' ' ')
        if [ -n "$GVC_LOCS" ]; then
            GVC_READ_OK="true"
            break
        fi
    fi
    sleep 2
done

MISSING=""
if [ "$GVC_READ_OK" != "true" ]; then
    # A control-plane hiccup must never be the reason a database refuses to
    # start. Skip the API-backed checks; the values-only guards still apply.
    echo "${LOG_PREFIX} WARNING: could not read the location list of GVC '${GVC}' -- skipping the GVC location check." >&2
else
    for _loc in ${CONFIGURED_LOCS}; do
        case " ${GVC_LOCS} " in
            *" ${_loc} "*) : ;;
            *) MISSING="${MISSING}${_loc} " ;;
        esac
    done
    EXTRA=""
    for _loc in ${GVC_LOCS}; do
        case " ${CONFIGURED_LOCS} " in
            *" ${_loc} "*) : ;;
            *) EXTRA="${EXTRA}${_loc} " ;;
        esac
    done
    if [ -n "${EXTRA}" ]; then
        echo "${LOG_PREFIX} GVC '${GVC}' also has locations this release does not use: ${EXTRA% } -- nothing ClickHouse-related runs there."
    fi
    if [ -z "${MISSING}" ]; then
        echo "${LOG_PREFIX} GVC location check OK -- '${GVC}' has every configured location (${CONFIGURED_LOCS% })"
    fi
fi
{{- end -}}

{{/*
Keeper quorum feasibility, shared by the keeper (unconditional) and the server
(fresh data directory only). Keeper members are replica-0 of the first
min(3, len(locations)) declared locations; a Raft group of TOTAL needs
floor(TOTAL/2)+1 members to elect at all. Requires the guard above to have run.
Sets: KEEPER_MEMBER_LOCS, KEEPER_TOTAL, KEEPER_PRESENT, KEEPER_QUORUM_OK.
*/}}
{{- define "clickhouse.keeperQuorumArithmetic" -}}
# --- Keeper quorum feasibility ---
KEEPER_MEMBER_LOCS=""
_n=0
for _loc in ${CONFIGURED_LOCS}; do
    if [ "$_n" -ge 3 ]; then break; fi
    KEEPER_MEMBER_LOCS="${KEEPER_MEMBER_LOCS}${_loc} "
    _n=$((_n+1))
done
KEEPER_TOTAL=$_n
KEEPER_PRESENT=0
KEEPER_QUORUM_OK="unknown"
if [ "$GVC_READ_OK" = "true" ]; then
    for _loc in ${KEEPER_MEMBER_LOCS}; do
        case " ${GVC_LOCS} " in
            *" ${_loc} "*) KEEPER_PRESENT=$((KEEPER_PRESENT+1)) ;;
        esac
    done
    if [ $((2 * KEEPER_PRESENT)) -gt "$KEEPER_TOTAL" ]; then
        KEEPER_QUORUM_OK="true"
    else
        KEEPER_QUORUM_OK="false"
    fi
fi
{{- end -}}


{{/* Labeling */}}

{{/*
Common labels - delegated to cpln-common
*/}}
{{- define "clickhouse.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}
