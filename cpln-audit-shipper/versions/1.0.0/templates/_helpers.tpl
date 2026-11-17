{{/* Resource names */}}

{{- define "cas.name" -}}
{{- printf "%s-audit-shipper" .Release.Name }}
{{- end }}

{{- define "cas.identity.name" -}}
{{- default (include "cas.name" .) .Values.identity.existingName }}
{{- end }}

{{- define "cas.identity.link" -}}
{{- printf "//gvc/%s/identity/%s" .Values.global.cpln.gvc (include "cas.identity.name" .) }}
{{- end }}

{{- define "cas.volumeset.name" -}}
{{- default (printf "%s-state" (include "cas.name" .)) .Values.state.volumeSet.existingName }}
{{- end }}

{{- define "cas.tags" -}}
{{- include "cpln-common.tags" . }}
{{- end }}

{{/* "true" when the sink or the state store is S3, so the shipper needs AWS credentials. */}}
{{- define "cas.needAWS" -}}
{{- if or (eq .Values.sink.type "s3") (eq .Values.state.backend "s3") }}true{{- end }}
{{- end }}

{{/* Secrets the workload identity reveals, as a list of names. */}}
{{- define "cas.secrets" -}}
{{- $v := .Values -}}
{{- $s := list $v.serviceAccount.keySecret -}}
{{- if and (eq $v.sink.type "syslog") $v.sink.syslog.tls $v.sink.syslog.caSecret }}{{- $s = append $s $v.sink.syslog.caSecret }}{{- end -}}
{{- if eq $v.sink.type "otlp" }}
{{- with $v.sink.otlp.caSecret }}{{- $s = append $s . }}{{- end }}
{{- if $v.sink.otlp.authHeader.name }}{{- $s = append $s $v.sink.otlp.authHeader.secret }}{{- end }}
{{- end -}}
{{- if and (include "cas.needAWS" .) (eq $v.aws.authMode "secret") }}{{- $s = append $s $v.aws.secret.name }}{{- end -}}
{{- toJson (uniq $s) }}
{{- end }}

{{/* Seconds in a duration such as 90s, 1h30m or 7d, as a float. */}}
{{- define "cas.seconds" -}}
{{- $total := 0.0 -}}
{{- $unit := dict "ns" 0.000000001 "us" 0.000001 "ms" 0.001 "s" 1.0 "m" 60.0 "h" 3600.0 "d" 86400.0 -}}
{{- range regexFindAll "[0-9.]+(ns|us|ms|s|m|h|d)" (toString .) -1 -}}
{{- $total = addf $total (mulf (float64 (regexFind "^[0-9.]+" .)) (get $unit (regexReplaceAll "^[0-9.]+" . ""))) -}}
{{- end -}}
{{- $total -}}
{{- end -}}

{{/* Validation */}}

{{- define "cas.checkBucket" -}}
{{- $path := index . 0 -}}{{- $b := index . 1 -}}
{{- if not (regexMatch "^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$" (toString $b.bucket)) -}}
{{- fail (printf "%s.bucket is required and must be a valid S3 bucket name" $path) -}}
{{- end -}}
{{- if not (regexMatch "^[a-z]{2}(-[a-z]+)+-[0-9]+$" (toString $b.region)) -}}
{{- fail (printf "%s.region must be an AWS region such as us-east-1" $path) -}}
{{- end -}}
{{- $prefix := trimAll "/" (toString $b.prefix) -}}
{{- if or (not (regexMatch "^[A-Za-z0-9!_.*'()=/-]*$" $prefix)) (contains "//" $prefix) (contains "/../" (printf "/%s/" $prefix)) -}}
{{- fail (printf "%s.prefix may hold only letters, digits, / and !_.*'()=- and no empty or .. segments" $path) -}}
{{- end -}}
{{- end -}}

{{- define "cas.checkTimes" -}}
{{- $path := index . 0 -}}{{- $src := index . 1 -}}
{{- $rfc3339 := "^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}([.][0-9]+)?(Z|[+-][0-9]{2}:[0-9]{2})$" -}}
{{- range $k := list "startTime" "endTime" -}}
{{- $t := toString (index $src $k) -}}
{{- if and $t (not (regexMatch $rfc3339 $t)) -}}
{{- fail (printf "%s.%s must be an RFC 3339 time such as 2026-01-01T00:00:00Z" $path $k) -}}
{{- end -}}
{{- end -}}
{{- if and $src.startTime $src.endTime -}}
{{- if le (toDate "2006-01-02T15:04:05Z07:00" $src.endTime).Unix (toDate "2006-01-02T15:04:05Z07:00" $src.startTime).Unix -}}
{{- fail (printf "%s.endTime must be after %s.startTime" $path $path) -}}
{{- end -}}
{{- end -}}
{{- $duration := "^(0|[0-9]+d|([0-9]+([.][0-9]+)?(ns|us|ms|s|m|h))+)$" -}}
{{- range $k := list "initialLookback" "settleDelay" "overlap" -}}
{{- if not (regexMatch $duration (toString (index $src $k))) -}}
{{- fail (printf "%s.%s must be a duration such as 90s, 15m, 24h or 7d" $path $k) -}}
{{- end -}}
{{- end -}}
{{- if le (float64 (include "cas.seconds" $src.initialLookback)) 0.0 -}}
{{- fail (printf "%s.initialLookback must be longer than 0" $path) -}}
{{- end -}}
{{- end -}}

{{- define "cas.checkNames" -}}
{{- $path := index . 0 -}}{{- $names := index . 1 -}}{{- $re := index . 2 -}}{{- $what := index . 3 -}}
{{- if or (not (kindIs "slice" $names)) (empty $names) -}}
{{- fail (printf "%s must list at least one %s" $path $what) -}}
{{- end -}}
{{- range $names -}}
{{- if not (regexMatch $re (toString .)) -}}
{{- fail (printf "%s: %q is not a valid %s name" $path (toString .) $what) -}}
{{- end -}}
{{- end -}}
{{- if ne (len $names) (len (uniq $names)) -}}
{{- fail (printf "%s lists a name twice" $path) -}}
{{- end -}}
{{- end -}}

{{- define "cas.validate" -}}
{{- $v := .Values -}}
{{- if or (not $v.serviceAccount.name) (not $v.serviceAccount.keySecret) -}}
{{- fail "serviceAccount.name and serviceAccount.keySecret are required: a service account and an opaque secret holding one of its keys (the audit and logs APIs do not accept a workload's own token)" -}}
{{- end -}}
{{- if not (regexMatch "^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$" (toString $v.stream)) -}}
{{- fail "stream must be lowercase letters, digits and dashes, up to 63 characters" -}}
{{- end -}}
{{- $duration := "^(0|[0-9]+d|([0-9]+([.][0-9]+)?(ns|us|ms|s|m|h))+)$" -}}
{{- range $k, $d := dict "interval" $v.interval "tuning.leaseTTL" $v.tuning.leaseTTL "tuning.cycleBudget" $v.tuning.cycleBudget "tuning.drainTimeout" $v.tuning.drainTimeout "tuning.heartbeatMaxAge" $v.tuning.heartbeatMaxAge -}}
{{- if not (regexMatch $duration (toString $d)) -}}
{{- fail (printf "%s must be a duration such as 90s, 15m, 24h or 7d" $k) -}}
{{- end -}}
{{- end -}}
{{- $interval := float64 (include "cas.seconds" $v.interval) -}}
{{- if or (lt $interval 10.0) (gt $interval 86400.0) -}}
{{- fail "interval must be between 10s and 24h" -}}
{{- end -}}
{{- if lt (float64 (include "cas.seconds" $v.tuning.leaseTTL)) 60.0 -}}
{{- fail "tuning.leaseTTL must be at least 1m" -}}
{{- end -}}
{{- if or (le (float64 (include "cas.seconds" $v.tuning.cycleBudget)) 0.0) (le (float64 (include "cas.seconds" $v.tuning.heartbeatMaxAge)) 0.0) -}}
{{- fail "tuning.cycleBudget and tuning.heartbeatMaxAge must be longer than 0" -}}
{{- end -}}
{{- if ge (float64 (include "cas.seconds" $v.tuning.drainTimeout)) (float64 (int $v.tuning.terminationGracePeriodSeconds)) -}}
{{- fail "tuning.drainTimeout must be shorter than tuning.terminationGracePeriodSeconds, or a delivery under way is cut off at shutdown" -}}
{{- end -}}
{{- $c := $v.sources.cplnAudit -}}{{- $k := $v.sources.k8sAudit -}}
{{- if not (or $c.enabled $k.enabled) -}}
{{- fail "enable at least one source: sources.cplnAudit or sources.k8sAudit" -}}
{{- end -}}
{{- if $c.enabled -}}
{{- include "cas.checkNames" (list "sources.cplnAudit.contexts" $c.contexts "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$" "audit context") -}}
{{- include "cas.checkTimes" (list "sources.cplnAudit" $c) -}}
{{- end -}}
{{- if $k.enabled -}}
{{- include "cas.checkNames" (list "sources.k8sAudit.clusters" $k.clusters "^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$" "mk8s cluster") -}}
{{- include "cas.checkTimes" (list "sources.k8sAudit" $k) -}}
{{- if and $k.pipeline (not (hasPrefix "|" (trim $k.pipeline))) -}}
{{- fail "sources.k8sAudit.pipeline must start with | (it is appended to the stream selector), e.g. | json | verb != \"get\"" -}}
{{- end -}}
{{- end -}}

{{- $sink := $v.sink.type -}}
{{- if eq $sink "s3" -}}
{{- include "cas.checkBucket" (list "sink.s3" $v.sink.s3) -}}
{{- else if eq $sink "syslog" -}}
{{- $s := $v.sink.syslog -}}
{{- if not (regexMatch "^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$" (toString $s.host)) -}}
{{- fail "sink.syslog.host is required: the syslog listener's host name or IP address" -}}
{{- end -}}
{{- if or (lt (int $s.port) 1) (gt (int $s.port) 65535) -}}
{{- fail "sink.syslog.port must be between 1 and 65535" -}}
{{- end -}}
{{- if not (has (toString $s.framing) (list "newline" "octet-counting")) -}}
{{- fail "sink.syslog.framing must be newline or octet-counting" -}}
{{- end -}}
{{- if or (lt (int $s.facility) 0) (gt (int $s.facility) 23) (lt (int $s.severity) 0) (gt (int $s.severity) 7) -}}
{{- fail "sink.syslog.facility must be 0 to 23 and sink.syslog.severity 0 to 7" -}}
{{- end -}}
{{- if or (lt (int $s.maxMessageBytes) 480) (gt (int $s.maxMessageBytes) 1048576) -}}
{{- fail "sink.syslog.maxMessageBytes must be between 480 and 1048576" -}}
{{- end -}}
{{- if not (regexMatch $duration (toString $s.timeout)) -}}
{{- fail "sink.syslog.timeout must be a duration such as 60s" -}}
{{- end -}}
{{- else if eq $sink "otlp" -}}
{{- $o := $v.sink.otlp -}}
{{- if not (regexMatch "^https?://[^/ ]+" (toString $o.endpoint)) -}}
{{- fail "sink.otlp.endpoint is required: the collector's http(s) base URL, e.g. https://otlp.example.com:4318" -}}
{{- end -}}
{{- if and $o.authHeader.name (not (regexMatch "^[!#$%&'*+.^_`|~0-9A-Za-z-]+$" $o.authHeader.name)) -}}
{{- fail "sink.otlp.authHeader.name must be an HTTP header name, such as Authorization" -}}
{{- end -}}
{{- if and $o.authHeader.name (not $o.authHeader.secret) -}}
{{- fail "sink.otlp.authHeader.secret is required with sink.otlp.authHeader.name: an opaque secret holding the header's value" -}}
{{- end -}}
{{- range $h, $val := $o.headers -}}
{{- if or (not (regexMatch "^[!#$%&'*+.^_`|~0-9A-Za-z-]+$" $h)) (contains "," (toString $val)) -}}
{{- fail (printf "sink.otlp.headers: %q must be a header name with a value without commas" $h) -}}
{{- end -}}
{{- end -}}
{{- if not (regexMatch $duration (toString $o.timeout)) -}}
{{- fail "sink.otlp.timeout must be a duration such as 30s" -}}
{{- end -}}
{{- else -}}
{{- fail "sink.type must be s3, syslog or otlp" -}}
{{- end -}}

{{- $state := $v.state.backend -}}
{{- if eq $state "s3" -}}
{{- if $v.state.s3.bucket -}}
{{- include "cas.checkBucket" (list "state.s3" $v.state.s3) -}}
{{- else if ne $sink "s3" -}}
{{- fail "state.s3.bucket and state.s3.region are required with state.backend s3 and a sink other than s3 (or use state.backend volumeSet in a single-location GVC)" -}}
{{- end -}}
{{- else if eq $state "volumeSet" -}}
{{- if and (not $v.state.volumeSet.existingName) (lt (int $v.state.volumeSet.capacity) 10) -}}
{{- fail "state.volumeSet.capacity must be at least 10 (GiB)" -}}
{{- end -}}
{{- else -}}
{{- fail "state.backend must be s3 or volumeSet" -}}
{{- end -}}

{{- if include "cas.needAWS" . -}}
{{- $mode := $v.aws.authMode -}}
{{- if eq $mode "identity" -}}
  {{- $s := $v.aws.secret -}}
  {{- if or $s.name $s.sessionTokenKey $s.assumeRole.roleArn $s.assumeRole.externalId -}}
  {{- fail "aws.secret.* is only used with aws.authMode secret; clear it, or set authMode to secret (with authMode identity the identity's AWS access is used)" -}}
  {{- end -}}
  {{- if not $v.identity.existingName -}}
    {{- if not $v.aws.identity.cloudAccountName -}}
    {{- fail "aws.authMode identity needs aws.identity.cloudAccountName (a Control Plane AWS cloud account) or identity.existingName" -}}
    {{- end -}}
    {{- if and $v.aws.identity.roleName $v.aws.identity.policyRefs -}}
    {{- fail "set either aws.identity.roleName or aws.identity.policyRefs, not both (set policyRefs: [] to use roleName)" -}}
    {{- end -}}
    {{- if not (or $v.aws.identity.roleName $v.aws.identity.policyRefs) -}}
    {{- fail "aws.authMode identity needs aws.identity.policyRefs (bucket-scoped IAM policy names) or aws.identity.roleName" -}}
    {{- end -}}
  {{- end -}}
{{- else if eq $mode "secret" -}}
  {{- if not $v.aws.secret.name -}}
  {{- fail "aws.authMode secret needs aws.secret.name: an aws or dictionary secret holding the access key ID and secret access key" -}}
  {{- end -}}
  {{- if or (not $v.aws.secret.accessKeyIdKey) (not $v.aws.secret.secretAccessKeyKey) -}}
  {{- fail "aws.secret.accessKeyIdKey and aws.secret.secretAccessKeyKey must name keys in the secret" -}}
  {{- end -}}
  {{- $ar := $v.aws.secret.assumeRole -}}
  {{- if $ar.roleArn -}}
    {{- if not (regexMatch "^arn:aws[a-z-]*:iam::[0-9]{12}:role/.+" $ar.roleArn) -}}
    {{- fail "aws.secret.assumeRole.roleArn must be an IAM role ARN (arn:aws:iam::<account>:role/<name>), not a user or policy ARN" -}}
    {{- end -}}
    {{- if or (lt (int $ar.durationSeconds) 900) (gt (int $ar.durationSeconds) 43200) -}}
    {{- fail "aws.secret.assumeRole.durationSeconds must be between 900 and 43200" -}}
    {{- end -}}
    {{- if and $ar.externalId (or (not (regexMatch "^[A-Za-z0-9_+=,.@:/-]+$" $ar.externalId)) (lt (len $ar.externalId) 2) (gt (len $ar.externalId) 1224)) -}}
    {{- fail "aws.secret.assumeRole.externalId must be 2 to 1224 characters of letters, digits and _+=,.@:/-" -}}
    {{- end -}}
    {{- if and $ar.sessionName (not (regexMatch "^[A-Za-z0-9_+=,.@-]{2,64}$" $ar.sessionName)) -}}
    {{- fail "aws.secret.assumeRole.sessionName must be 2 to 64 characters of letters, digits and _+=,.@-" -}}
    {{- end -}}
  {{- else if $ar.externalId -}}
  {{- fail "aws.secret.assumeRole.externalId is set without aws.secret.assumeRole.roleArn" -}}
  {{- end -}}
{{- else -}}
{{- fail "aws.authMode must be identity or secret" -}}
{{- end -}}
{{- end -}}

{{- if not (has (toString $v.tuning.logLevel) (list "debug" "info" "warn" "error")) -}}
{{- fail "tuning.logLevel must be debug, info, warn or error" -}}
{{- end -}}
{{- range $k, $n := dict "tuning.maxObjectBytes" $v.tuning.maxObjectBytes "tuning.maxBatchBytes" $v.tuning.maxBatchBytes -}}
{{- if or (lt (int64 $n) 1048576) (gt (int64 $n) 1073741824) -}}
{{- fail (printf "%s must be between 1048576 (1 MiB) and 1073741824 (1 GiB)" $k) -}}
{{- end -}}
{{- end -}}
{{- range $k, $n := dict "tuning.maxObjectEvents" $v.tuning.maxObjectEvents "tuning.maxBatchEvents" $v.tuning.maxBatchEvents -}}
{{- if or (lt (int64 $n) 1) (gt (int64 $n) 1000000) -}}
{{- fail (printf "%s must be between 1 and 1000000" $k) -}}
{{- end -}}
{{- end -}}
{{- if or (lt (int $v.tuning.terminationGracePeriodSeconds) 10) (gt (int $v.tuning.terminationGracePeriodSeconds) 900) -}}
{{- fail "tuning.terminationGracePeriodSeconds must be between 10 and 900" -}}
{{- end -}}
{{- end -}}
