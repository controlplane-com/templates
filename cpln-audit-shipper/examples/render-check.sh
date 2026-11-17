#!/usr/bin/env bash
# Renders the chart for each example and each invalid setting; fails on any unexpected result.
set -euo pipefail
cd "$(dirname "$0")/.."
chart=versions/${1:-1.0.0}
helm dependency build "$chart" >/dev/null 2>&1 || helm dependency update "$chart" >/dev/null
gvc=(--set global.cpln.gvc=g1)
fails=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fails=$((fails + 1)); }
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

expect_render() { # name file grep-patterns... (a leading ! means must not match)
  local name=$1 file=$2; shift 2
  local out
  if ! out=$(helm template t "$chart" "${gvc[@]}" -f "$file" 2>&1); then bad "$name: $out"; return; fi
  helm lint "$chart" "${gvc[@]}" -f "$file" >/dev/null 2>&1 || { bad "$name: helm lint"; return; }
  for p in "$@"; do
    if [[ $p == !* ]]; then
      grep -qE -- "${p:1}" <<<"$out" && { bad "$name: unexpected /${p:1}/"; return; }
    else
      grep -qE -- "$p" <<<"$out" || { bad "$name: missing /$p/"; return; }
    fi
  done
  ok "$name"
}

expect_fail() { # name base-values expected-message --set...
  local name=$1 base=$2 msg=$3; shift 3
  local out
  if out=$(helm template t "$chart" "${gvc[@]}" -f "$base" "$@" 2>&1); then bad "$name: rendered"; return; fi
  grep -qF -- "$msg" <<<"$out" && ok "$name" || bad "$name: wrong error: $out"
}

expect_render defaults /dev/null \
  'cloudAccountLink: //cloudaccount/my-aws-cloud-account' '//auditctx/cpln' '!cpln://secret/' \
  'kind: serviceaccount' 'name: SERVICE_ACCOUNT_NAME' 'value: "t-audit-shipper"' '!SERVICE_ACCOUNT_KEY' \
  'name: t-audit-shipper-key' 'targetKind: serviceaccount' '- addKey' '//serviceaccount/t-audit-shipper$' \
  '!name: t-audit-shipper-secrets' \
  'type: standard' 'maxSurgeReplicas: "0"' '/cpln-audit-shipper' '!kind: volumeset' '!readLogs' '!name: CPLN_'
expect_render s3-identity examples/s3-identity.yaml \
  'value: "s3"' 'value: "my-audit-bucket"' 'value: "identity"' '//serviceaccount/t-audit-shipper' \
  '!STATE_S3_BUCKET' '!AWS_SOURCE_' '!securityOptions' '!targetKind: org'
expect_render s3-secret-assume-role examples/s3-secret-assume-role.yaml \
  'cpln://secret/cpln-audit-shipper-aws-temp.accessKeyId' 'cpln://secret/cpln-audit-shipper-aws-temp.sessionToken' \
  'value: "arn:aws:iam::123456789012:role/cpln-audit-writer"' 'value: "cpln-my-org"' 'value: "3600s"' \
  'value: "alias/audit-trail"' 'value: "15m"' '//secret/cpln-audit-shipper-aws-temp' '!cloudAccountLink'
expect_render syslog-k8s-volumeset examples/syslog-k8s-volumeset.yaml \
  'kind: volumeset' 'fileSystemType: shared' 'performanceClass: shared' 'uri: cpln://volumeset/t-audit-shipper-state' \
  'filesystemGroupId: 65532' 'targetKind: org' 'target: all' 'readLogs' 'value: "prod-cluster"' 'value: "syslog"' \
  'value: "5550"' 'targetKind: gvc' '- view' 'value: /state' \
  '!readAudit' '!AWS_' '!cloudAccountLink' '!S3_BUCKET' '!AUDIT_CONTEXTS'
expect_render otlp-both-sources examples/otlp-both-sources.yaml \
  'value: "https://otlp.example.com:4318"' 'value: "X-Scope-OrgID=my-org"' 'value: "Authorization"' \
  'cpln://secret/cpln-audit-shipper-otlp-token.payload' '//secret/cpln-audit-shipper-otlp-token' \
  'value: "my-audit-state"' 'value: "\| verb != \\"get\\""' 'readAudit' 'readLogs' 'name: t-audit-shipper-secrets' \
  'policyRefs:' '!kind: volumeset' '!name: S3_BUCKET$' '!name: CPLN_'

cat >"$tmp/syslog-ca.yaml" <<'YAML'
sources: {cplnAudit: {enabled: true}}
sink: {type: syslog, syslog: {host: 10.0.0.5, port: 6514, caSecret: my-ca, framing: octet-counting}}
state: {backend: volumeSet, volumeSet: {existingName: shared-state}}
YAML
expect_render syslog-private-ca "$tmp/syslog-ca.yaml" \
  'uri: cpln://secret/my-ca' 'path: /etc/cpln-audit-shipper/syslog-ca.pem' 'value: /etc/cpln-audit-shipper/syslog-ca.pem' \
  '//secret/my-ca' 'uri: cpln://volumeset/shared-state' 'value: "octet-counting"' '!kind: volumeset' '!kind: identity.*\n.*aws'

{ sed '/^aws:/,$d' examples/s3-identity.yaml; printf 'identity:\n  existingName: shared-id\n'; } >"$tmp/existing.yaml"
sed 's/caSecret: my-ca/caSecret: my-ca, tls: false/' "$tmp/syslog-ca.yaml" >"$tmp/syslog-notls.yaml"
expect_render syslog-ca-without-tls "$tmp/syslog-notls.yaml" '!syslog-ca.pem' '!//secret/my-ca' 'value: "false"'
printf 'tuning:\n  maxBatchEvents: 1000000\n  maxObjectEvents: 500000\n' >"$tmp/counts.yaml"
expect_render large-counts "$tmp/counts.yaml" 'value: "1000000"' 'value: "500000"' '!e\+0'

printf 'serviceAccount:\n  existingName: my-sa\n  existingKeySecret: my-sa-key\nsources:\n  k8sAudit:\n    enabled: true\n    clusters: [c1]\n' >"$tmp/existing-sa.yaml"
expect_render existing-service-account "$tmp/existing-sa.yaml" \
  '!kind: serviceaccount' '!name: t-audit-shipper-key$' '!SERVICE_ACCOUNT_NAME' 'name: SERVICE_ACCOUNT_KEY' \
  'cpln://secret/my-sa-key.payload' '//secret/my-sa-key' '//serviceaccount/my-sa' 'readAudit' 'readLogs'

expect_render existing-identity "$tmp/existing.yaml" 'identityLink: //gvc/g1/identity/shared-id' '!kind: identity'

printf 'sources:\n  cplnAudit:\n    contexts: [cpln, orders-audit]\n' >"$tmp/multi.yaml"
expect_render several-contexts "$tmp/multi.yaml" '//auditctx/cpln' '//auditctx/orders-audit' 'value: "cpln,orders-audit"'

s3=examples/s3-identity.yaml
sys=examples/syslog-k8s-volumeset.yaml
otlp=examples/otlp-both-sources.yaml
expect_fail existing-sa-without-key $s3 "set serviceAccount.existingName and serviceAccount.existingKeySecret together" --set serviceAccount.existingName=my-sa
expect_fail existing-key-without-sa $s3 "set serviceAccount.existingName and serviceAccount.existingKeySecret together" --set serviceAccount.existingKeySecret=my-key
expect_fail no-source $s3 "enable at least one source" --set sources.cplnAudit.enabled=false
expect_fail no-contexts $s3 "must list at least one audit context" --set sources.cplnAudit.contexts=null
expect_fail bad-context $s3 "is not a valid audit context name" --set 'sources.cplnAudit.contexts={cpln,bad ctx}'
expect_fail duplicate-context $s3 "lists a name twice" --set 'sources.cplnAudit.contexts={cpln,cpln}'
expect_fail no-clusters $sys "must list at least one mk8s cluster" --set sources.k8sAudit.clusters=null
expect_fail bad-cluster $sys "is not a valid mk8s cluster name" --set 'sources.k8sAudit.clusters={Prod_Cluster}'
expect_fail bad-pipeline $sys "must start with |" --set 'sources.k8sAudit.pipeline=json'
expect_fail bad-start $s3 "RFC 3339" --set sources.cplnAudit.startTime=yesterday
expect_fail end-before-start $s3 "must be after sources.cplnAudit.startTime" --set sources.cplnAudit.startTime=2026-02-01T00:00:00Z --set sources.cplnAudit.endTime=2026-01-01T00:00:00Z
expect_fail bad-overlap $sys "sources.k8sAudit.overlap must be a duration" --set sources.k8sAudit.overlap=two
expect_fail bad-interval $s3 "interval must be a duration" --set interval=often
expect_fail bad-sink $s3 "sink.type must be s3, syslog or otlp" --set sink.type=kafka
expect_fail no-bucket $s3 "sink.s3.bucket is required" --set sink.s3.bucket=
expect_fail bad-region $s3 "sink.s3.region must be an AWS region" --set sink.s3.region=useast1
expect_fail bad-prefix $s3 "sink.s3.prefix may hold only" --set sink.s3.prefix=a/../b
expect_fail no-syslog-host $sys "sink.syslog.host is required" --set sink.syslog.host=
expect_fail syslog-port $sys "sink.syslog.port must be" --set sink.syslog.port=70000
expect_fail syslog-framing $sys "sink.syslog.framing must be" --set sink.syslog.framing=lf
expect_fail no-otlp-endpoint $otlp "sink.otlp.endpoint is required" --set sink.otlp.endpoint=collector:4318
expect_fail otlp-auth-without-secret $otlp "sink.otlp.authHeader.secret is required" --set sink.otlp.authHeader.secret=
expect_fail bad-state $s3 "state.backend must be s3 or volumeSet" --set state.backend=redis
expect_fail state-bucket-for-syslog $sys "state.s3.bucket and state.s3.region are required" --set state.backend=s3
expect_fail small-volume $sys "at least 10" --set state.volumeSet.capacity=5
expect_fail bad-mode $s3 "aws.authMode must be identity or secret" --set aws.authMode=static
expect_fail identity-no-account $s3 "needs aws.identity.cloudAccountName" --set aws.identity.cloudAccountName=
expect_fail role-and-policies $s3 "not both" --set aws.identity.roleName=r
expect_fail identity-with-secret $s3 "only used with aws.authMode secret" --set aws.secret.name=s
expect_fail secret-without-name $s3 "needs aws.secret.name" --set aws.authMode=secret --set aws.identity.cloudAccountName= --set aws.identity.policyRefs=null
expect_fail user-arn examples/s3-secret-assume-role.yaml "must be an IAM role ARN" --set aws.secret.assumeRole.roleArn=arn:aws:iam::123456789012:user/bob
expect_fail external-id-alone examples/s3-secret-assume-role.yaml "without aws.secret.assumeRole.roleArn" --set aws.secret.assumeRole.roleArn=
expect_fail duration examples/s3-secret-assume-role.yaml "between 900 and 43200" --set aws.secret.assumeRole.durationSeconds=60
expect_fail log-level $s3 "tuning.logLevel must be" --set tuning.logLevel=verbose
expect_fail object-bytes $s3 "tuning.maxObjectBytes must be between 1048576" --set tuning.maxObjectBytes=1000
expect_fail batch-events $s3 "tuning.maxBatchEvents must be between 1 and 1000000" --set tuning.maxBatchEvents=1000001
expect_fail short-interval $s3 "interval must be between 10s and 24h" --set interval=5s
expect_fail long-interval $s3 "interval must be between 10s and 24h" --set interval=25h
expect_fail short-lease $s3 "tuning.leaseTTL must be at least 1m" --set tuning.leaseTTL=30s
expect_fail zero-budget $s3 "tuning.cycleBudget and tuning.heartbeatMaxAge must be longer than 0" --set tuning.cycleBudget=0
expect_fail drain-over-grace $s3 "tuning.drainTimeout plus 15s must fit in half" --set tuning.drainTimeout=31s
expect_fail zero-lookback $s3 "sources.cplnAudit.initialLookback must be longer than 0" --set sources.cplnAudit.initialLookback=0
expect_fail long-context $s3 "is not a valid audit context name" --set "sources.cplnAudit.contexts={$(printf 'c%.0s' {1..130})}"
expect_fail external-id-format examples/s3-secret-assume-role.yaml "externalId must be 2 to 1224" --set aws.secret.assumeRole.externalId=x
expect_fail otlp-header-name $otlp "authHeader.name must be an HTTP header name" --set 'sink.otlp.authHeader.name=Bad Header'
expect_fail stream $s3 "stream must be lowercase" --set stream=Bad_Stream
expect_fail grace $s3 "terminationGracePeriodSeconds must be" --set tuning.terminationGracePeriodSeconds=1000

# Every rendered policy must name its targets: a policy without targetLinks or target would not do what it says.
for f in /dev/null examples/*.yaml "$tmp"/*.yaml; do
  out=$(helm template t "$chart" "${gvc[@]}" -f "$f" 2>/dev/null) || continue
  if awk '/^kind: policy/{p=1; t=0; next} p && /^(targetLinks|target):/{t=1} /^---/{if (p && !t) bad=1; p=0} END{if (p && !t) bad=1; exit !bad}' <<<"$out"; then
    bad "policy without a target in $(basename "$f")"
  fi
done

[ "$fails" -eq 0 ] && echo "all render checks passed" || { echo "$fails render check(s) failed"; exit 1; }
