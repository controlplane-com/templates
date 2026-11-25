{{/*
Backup setup script, passed inline (sh -c) and rendered through
"opensearch.inlineScript", which doubles every $ so the platform's $(VAR)
expansion in args leaves it untouched. The admin password arrives as the
OS_ADMIN_PASSWORD env var.
*/}}
{{- define "opensearch.script.backupSetup" -}}
set -e

echo "========================================="
echo "  OpenSearch Backup Configuration"
echo "========================================="
echo ""

OPENSEARCH_URL="https://{{ include "opensearch.name" . }}.{{ .Values.global.cpln.gvc }}.cpln.local:9200"
MAX_RETRIES=60
# The server certificate is not verified on this hop; the mesh carries server identity.
os_curl() { curl -k -u "admin:${OS_ADMIN_PASSWORD}" "$@"; }
RETRY_COUNT=0

# ============================================
# Wait for OpenSearch cluster to be healthy
# ============================================
echo "Step 1: Waiting for OpenSearch cluster..."

until os_curl -sf "${OPENSEARCH_URL}/_cluster/health" > /dev/null; do
  RETRY_COUNT=$((RETRY_COUNT + 1))
  if [ $RETRY_COUNT -ge $MAX_RETRIES ]; then
    echo "❌ ERROR: OpenSearch not ready after ${MAX_RETRIES} attempts"
    exit 1
  fi
  echo "  Waiting for OpenSearch... (attempt $RETRY_COUNT/$MAX_RETRIES)"
  sleep 5
done

echo "✅ OpenSearch is ready!"
echo ""

# ============================================
# Configure Snapshot Repository
# ============================================
echo "Step 2: Configuring snapshot repository..."

{{- if eq .Values.backup.provider "aws" }}
# AWS S3 Repository
REPO_CONFIG='{
  "type": "s3",
  "settings": {
    "bucket": "{{ .Values.backup.aws.bucket }}",
    "region": "{{ .Values.backup.aws.region }}",
    "base_path": "{{ .Values.backup.aws.prefix }}",
    "compress": true
  }
}'
{{- else if eq .Values.backup.provider "gcp" }}
# GCP GCS Repository
REPO_CONFIG='{
  "type": "gcs",
  "settings": {
    "bucket": "{{ .Values.backup.gcp.bucket }}",
    "base_path": "{{ .Values.backup.gcp.prefix }}",
    "compress": true
  }
}'
{{- end }}

RESPONSE=$(os_curl -w "%{http_code}" -o /tmp/repo_response.json -s -X PUT \
  "${OPENSEARCH_URL}/_snapshot/backup-repo" \
  -H 'Content-Type: application/json' \
  -d "${REPO_CONFIG}")

if [ "$RESPONSE" -eq 200 ] || [ "$RESPONSE" -eq 201 ]; then
  echo "✅ Snapshot repository configured"
  echo "   Provider: {{ .Values.backup.provider }}"
  {{- if eq .Values.backup.provider "aws" }}
  echo "   Bucket: s3://{{ .Values.backup.aws.bucket }}/{{ .Values.backup.aws.prefix }}"
  {{- else if eq .Values.backup.provider "gcp" }}
  echo "   Bucket: gs://{{ .Values.backup.gcp.bucket }}/{{ .Values.backup.gcp.prefix }}"
  {{- end }}
else
  echo "❌ Failed to configure repository (HTTP $RESPONSE)"
  cat /tmp/repo_response.json
  exit 1
fi
echo ""

# ============================================
# Verify Repository
# ============================================
echo "Step 3: Verifying repository connectivity..."

RESPONSE=$(os_curl -w "%{http_code}" -o /tmp/verify_response.json -s -X POST \
  "${OPENSEARCH_URL}/_snapshot/backup-repo/_verify")

if [ "$RESPONSE" -eq 200 ]; then
  echo "✅ Repository verified - connectivity OK"
else
  echo "⚠️  Repository verification returned HTTP $RESPONSE"
  cat /tmp/verify_response.json
  echo ""
  echo "Continuing anyway (might work for snapshots)..."
fi
echo ""

# ============================================
# Create Snapshot Policy
# ============================================
echo "Step 4: Creating snapshot policy..."

POLICY_CONFIG='{
  "description": "Automated snapshot policy",
  "creation": {
    "schedule": {
      "cron": {
        "expression": "{{ .Values.backup.schedule }}",
        "timezone": "UTC"
      }
    },
    "time_limit": "1h"
  },
  "deletion": {
    "schedule": {
      "cron": {
        "expression": "0 3 * * *",
        "timezone": "UTC"
      }
    },
    "condition": {
      "max_age": "{{ .Values.backup.retention.maxAge }}",
      "max_count": {{ .Values.backup.retention.maxCount }}
    },
    "time_limit": "1h"
  },
  "snapshot_config": {
    "indices": "*",
    "repository": "backup-repo",
    "ignore_unavailable": true,
    "include_global_state": false
  }
}'


# Try to get existing policy
if os_curl -sf "${OPENSEARCH_URL}/_plugins/_sm/policies/automated-snapshots" > /dev/null 2>&1; then
  echo "✅ Snapshot policy already exists (skipping)"
else
  # Create new policy
  RESPONSE=$(os_curl -w "%{http_code}" -o /tmp/policy_response.json -s -X POST \
    "${OPENSEARCH_URL}/_plugins/_sm/policies/automated-snapshots" \
    -H 'Content-Type: application/json' \
    -d "${POLICY_CONFIG}")

  if [ "$RESPONSE" -eq 200 ] || [ "$RESPONSE" -eq 201 ] || [ "$RESPONSE" -eq 409 ]; then
    echo "✅ Snapshot policy created"
  else
    echo "❌ Failed (HTTP $RESPONSE)"
    cat /tmp/policy_response.json
    exit 1
  fi
fi
echo ""

# ============================================
# Summary
# ============================================
echo "========================================="
echo "  Backup Configuration Complete!"
echo "========================================="
echo ""
echo "📊 Configuration Summary:"
echo "   Repository: backup-repo"
{{- if eq .Values.backup.provider "aws" }}
echo "   Location: s3://{{ .Values.backup.aws.bucket }}/{{ .Values.backup.aws.prefix }}"
{{- else if eq .Values.backup.provider "gcp" }}
echo "   Location: gs://{{ .Values.backup.gcp.bucket }}/{{ .Values.backup.gcp.prefix }}"
{{- end }}
echo "   Schedule: {{ .Values.backup.schedule }}"
echo "   Retention: {{ .Values.backup.retention.maxAge }} / max {{ .Values.backup.retention.maxCount }} snapshots"
echo ""
echo "📝 Next Steps:"
echo "   • First snapshot will run at scheduled time"
echo "   • Manual snapshot: curl -k -u admin:PASSWORD -X PUT '${OPENSEARCH_URL}/_snapshot/backup-repo/manual-snapshot'"
echo "   • List snapshots: curl -k -u admin:PASSWORD '${OPENSEARCH_URL}/_snapshot/backup-repo/_all?pretty'"
echo "   • View policy: curl -k -u admin:PASSWORD '${OPENSEARCH_URL}/_plugins/_sm/policies/automated-snapshots?pretty'"
echo ""

# Keep container running briefly so logs are visible
echo "Setup job will complete in 30 seconds..."
sleep 30
echo "✅ Setup job complete - exiting"
{{- end -}}
