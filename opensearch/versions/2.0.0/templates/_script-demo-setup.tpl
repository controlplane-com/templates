{{/*
Demo setup script, passed inline (sh -c) and rendered through
"opensearch.inlineScript", which doubles every $ so the platform's $(VAR)
expansion in args leaves it untouched. The admin password arrives as the
OS_ADMIN_PASSWORD env var. Every step is safe to re-run: the workload restarts
the script after it exits.
*/}}
{{- define "opensearch.script.demoSetup" -}}
set -e

OS="https://{{ include "opensearch.name" . }}.{{ .Values.global.cpln.gvc }}.cpln.local:9200"
OSD="http://{{ include "opensearch.dashboard.name" . }}.{{ .Values.global.cpln.gvc }}.cpln.local:5601"
# The server certificate is not verified on this hop; the mesh carries server identity.
os_curl() { curl -k -u "admin:${OS_ADMIN_PASSWORD}" "$@"; }
osd_curl() { curl -u "admin:${OS_ADMIN_PASSWORD}" -H 'osd-xsrf: true' -H 'securitytenant: global' "$@"; }
MAX_RETRIES=60

echo "========================================="
echo "  OpenSearch Demo Setup"
echo "========================================="

# --- Step 1: wait for OpenSearch ---
RETRY_COUNT=0
until os_curl -sf "${OS}/_cluster/health" > /dev/null; do
  RETRY_COUNT=$((RETRY_COUNT + 1))
  if [ "${RETRY_COUNT}" -ge "${MAX_RETRIES}" ]; then
    echo "ERROR: OpenSearch not ready after ${MAX_RETRIES} attempts"
    exit 1
  fi
  echo "  Waiting for OpenSearch... (attempt ${RETRY_COUNT}/${MAX_RETRIES})"
  sleep 5
done
echo "OpenSearch is ready"

# --- Step 2: index template ---
RESPONSE=$(os_curl -w "%{http_code}" -o /tmp/template_response.json -s -X PUT \
  "${OS}/_index_template/demo-logs-template" \
  -H 'Content-Type: application/json' \
  -d '{
    "index_patterns": ["demo-logs*"],
    "template": {
      "settings": {
        "number_of_shards": 3,
        "number_of_replicas": 2,
        "refresh_interval": "5s"
      },
      "mappings": {
        "properties": {
          "@timestamp": {"type": "date"},
          "timestamp": {"type": "date"},
          "level": {"type": "keyword"},
          "service": {"type": "keyword"},
          "message": {"type": "text", "fields": {"keyword": {"type": "keyword", "ignore_above": 256}}},
          "user_id": {"type": "keyword"},
          "request_id": {"type": "keyword"},
          "duration_ms": {"type": "integer"},
          "status_code": {"type": "integer"},
          "ip_address": {"type": "ip"},
          "cluster": {"type": "keyword"},
          "environment": {"type": "keyword"}
        }
      }
    }
  }')
if [ "${RESPONSE}" -eq 200 ] || [ "${RESPONSE}" -eq 201 ]; then
  echo "Index template created"
else
  echo "ERROR: index template returned HTTP ${RESPONSE}"
  cat /tmp/template_response.json
  exit 1
fi

# --- Step 3: Security Analytics sample (log type, rule, detector) ---
# The detector needs its index to exist; Fluent Bit may not have written yet.
# 400 = resource_already_exists.
RESPONSE=$(os_curl -s -o /dev/null -w "%{http_code}" -X PUT "${OS}/demo-logs")
case "${RESPONSE}" in
  200|400) echo "Index demo-logs ready" ;;
  *) echo "ERROR: creating demo-logs returned HTTP ${RESPONSE}"; exit 1 ;;
esac

SA="${OS}/_plugins/_security_analytics"
total() { sed -n 's/.*"total":{"value":\([0-9]*\).*/\1/p'; }
first_id() { grep -o '"_id":"[^"]*"' | head -n 1 | cut -d'"' -f4; }

if [ "$(os_curl -s -X POST "${SA}/logtype/_search" -H 'Content-Type: application/json' \
    -d '{"query":{"match_phrase":{"name":"demo_app_logs"}}}' | total)" = "0" ]; then
  os_curl -sf -o /dev/null -X POST "${SA}/logtype" -H 'Content-Type: application/json' \
    -d '{"name":"demo_app_logs","description":"Sample application logs from the demo pipeline","source":"Custom","category":"Other"}'
  echo "Log type demo_app_logs created"
else
  echo "Log type demo_app_logs already exists"
fi

RULE_ID=$(os_curl -s -X POST "${SA}/rules/_search?pre_packaged=false" -H 'Content-Type: application/json' \
  -d '{"query":{"nested":{"path":"rule","query":{"match_phrase":{"rule.title":"Demo: invalid authentication token"}}}}}' | first_id)
if [ -z "${RULE_ID}" ]; then
  RULE_ID=$(os_curl -sf -X POST "${SA}/rules?category=demo_app_logs" -H 'Content-Type: application/json' --data-binary @- <<'RULE' | first_id
title: 'Demo: invalid authentication token'
id: 5e2f6a1c-0d3b-4c51-9a77-3f1b2c4d5e6f
description: An application rejected a request with an invalid authentication token.
status: experimental
author: opensearch template demo
date: 2026/11/16
logsource:
    product: demo_app_logs
detection:
    selection:
        message: 'Invalid authentication token'
    condition: selection
level: medium
falsepositives:
    - Expired client sessions
RULE
)
  echo "Rule created (${RULE_ID})"
else
  echo "Rule already exists (${RULE_ID})"
fi
if [ -z "${RULE_ID}" ]; then
  echo "ERROR: no Security Analytics rule id"
  exit 1
fi

if [ "$(os_curl -s -X POST "${SA}/detectors/_search" -H 'Content-Type: application/json' \
    -d '{"query":{"nested":{"path":"detector","query":{"match_phrase":{"detector.name":"demo-auth-failures"}}}}}' | total)" = "0" ]; then
  os_curl -sf -o /dev/null -X POST "${SA}/detectors" -H 'Content-Type: application/json' -d '{
    "type": "detector", "name": "demo-auth-failures", "detector_type": "demo_app_logs", "enabled": true,
    "schedule": {"period": {"interval": 1, "unit": "MINUTES"}},
    "inputs": [{"detector_input": {"description": "Demo pipeline logs", "indices": ["demo-logs"],
      "custom_rules": [{"id": "'"${RULE_ID}"'"}], "pre_packaged_rules": []}}],
    "triggers": [{"id": "demo-any-finding", "name": "Any finding", "severity": "1", "types": ["demo_app_logs"],
      "ids": ["'"${RULE_ID}"'"], "sev_levels": [], "tags": [], "actions": []}]
  }'
  echo "Detector demo-auth-failures created"
else
  echo "Detector demo-auth-failures already exists"
fi
{{- if .Values.dashboard.enabled }}

# --- Step 4: wait for Dashboards ---
RETRY_COUNT=0
until osd_curl -sf "${OSD}/api/status" > /dev/null; do
  RETRY_COUNT=$((RETRY_COUNT + 1))
  if [ "${RETRY_COUNT}" -ge "${MAX_RETRIES}" ]; then
    echo "ERROR: Dashboards not ready after ${MAX_RETRIES} attempts"
    exit 1
  fi
  echo "  Waiting for Dashboards... (attempt ${RETRY_COUNT}/${MAX_RETRIES})"
  sleep 5
done
echo "Dashboards is ready"

# --- Step 5: index pattern in the Global tenant (409 = already there) ---
RESPONSE=$(osd_curl -w "%{http_code}" -o /tmp/pattern_response.json -s -X POST \
  "${OSD}/api/saved_objects/index-pattern/demo-logs" \
  -H 'Content-Type: application/json' \
  -d '{"attributes": {"title": "demo-logs*", "timeFieldName": "@timestamp", "fields": "[{\"name\":\"@timestamp\",\"type\":\"date\",\"esTypes\":[\"date\"],\"searchable\":true,\"aggregatable\":true,\"readFromDocValues\":true}]"}}')
if [ "${RESPONSE}" -eq 200 ] || [ "${RESPONSE}" -eq 409 ]; then
  echo "Index pattern demo-logs* ready"
else
  echo "WARN: index pattern returned HTTP ${RESPONSE}"
  cat /tmp/pattern_response.json
fi

RESPONSE=$(osd_curl -w "%{http_code}" -o /tmp/default_response.json -s -X POST \
  "${OSD}/api/opensearch-dashboards/settings/defaultIndex" \
  -H 'Content-Type: application/json' \
  -d '{"value": "demo-logs"}')
if [ "${RESPONSE}" -eq 200 ]; then
  echo "Default index pattern set"
else
  echo "WARN: default index pattern returned HTTP ${RESPONSE}"
  cat /tmp/default_response.json
fi
{{- end }}

echo "========================================="
echo "  Setup Complete!"
echo "========================================="
echo "Logs appear in the demo-logs index within about a minute; Security Analytics"
echo "findings from detector demo-auth-failures within a few minutes."
{{- if .Values.dashboard.enabled }}
echo "Dashboards: cpln port-forward {{ include "opensearch.dashboard.name" . }} 5601:5601 --gvc {{ .Values.global.cpln.gvc }}, then http://localhost:5601 (log in as admin)"
{{- end }}

# Keep the container running briefly so the logs are visible
sleep 60
echo "Setup job complete - exiting"
{{- end -}}
