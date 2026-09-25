{{/*
Base name → {release}-spark
*/}}
{{- define "spark.name" -}}
{{- printf "%s-spark" .Release.Name -}}
{{- end -}}

{{- define "spark.master.name" -}}
{{- printf "%s-spark-master" .Release.Name -}}
{{- end -}}

{{- define "spark.worker.name" -}}
{{- printf "%s-spark-worker" .Release.Name -}}
{{- end -}}

{{- define "spark.connect.name" -}}
{{- printf "%s-spark-connect" .Release.Name -}}
{{- end -}}

{{- define "spark.history.name" -}}
{{- printf "%s-spark-history" .Release.Name -}}
{{- end -}}

{{- define "spark.secret.conf.name" -}}
{{- printf "%s-spark-conf" .Release.Name -}}
{{- end -}}

{{- define "spark.identity.name" -}}
{{- printf "%s-spark-identity" .Release.Name -}}
{{- end -}}

{{- define "spark.policy.name" -}}
{{- printf "%s-spark-policy" .Release.Name -}}
{{- end -}}

{{/*
Fully-qualified internal DNS of the master (CLAUDE.md: short name is unreliable).
*/}}
{{- define "spark.master.fqdn" -}}
{{- printf "%s.%s.cpln.local" (include "spark.master.name" .) .Values.global.cpln.gvc -}}
{{- end -}}

{{/*
The spark:// URL workers and drivers register with.
*/}}
{{- define "spark.master.url" -}}
{{- printf "spark://%s:7077" (include "spark.master.fqdn" .) -}}
{{- end -}}

{{/*
Tags — delegate to cpln-common.
*/}}
{{- define "spark.tags" -}}
{{- include "cpln-common.tags" . -}}
{{- end -}}

{{/*
Validation of required fields / enum checks.
*/}}
{{- define "spark.validate" -}}
{{- if not .Values.global.cpln.gvc -}}
{{- fail "global.cpln.gvc is required (injected at install time)" -}}
{{- end -}}
{{- $providers := list "aws" "gcp" -}}
{{- if .Values.historyServer.enabled -}}
{{- if not (has .Values.storage.provider $providers) -}}
{{- fail "storage.provider must be one of: aws, gcp" -}}
{{- end -}}
{{- if not .Values.storage.bucket -}}
{{- fail "storage.bucket is required when historyServer.enabled" -}}
{{- end -}}
{{- if not .Values.storage.cloudAccountName -}}
{{- fail "storage.cloudAccountName is required when historyServer.enabled" -}}
{{- end -}}
{{- end -}}
{{- $accessTypes := list "same-gvc" "same-org" "workload-list" -}}
{{- if not (has .Values.internalAccess.type $accessTypes) -}}
{{- fail "internalAccess.type must be one of: same-gvc, same-org, workload-list" -}}
{{- end -}}
{{- end -}}

{{/*
Boot prelude: emitted into every workload's launch script. Downloads the S3A/GCS
connector jars into a uid-185-writable dir and appends them to SPARK_DIST_CLASSPATH
(honored by spark-class for all daemons AND drivers). Only rendered when the History
Server is enabled — the default install needs no object-storage connectors.
Fails fast on a 404 / truncated download so a bad pin surfaces at boot.
*/}}
{{- define "spark.jarPrelude" -}}
{{- if .Values.historyServer.enabled }}
EXTRA=/opt/spark/work-dir/extra-jars
mkdir -p "$EXTRA"
dl() {
  url="$1"; out="$EXTRA/$2"; min="$3"
  if [ ! -s "$out" ]; then
    echo "[spark-prelude] downloading $2"
    curl -fSL --retry 3 --retry-delay 5 -o "$out" "$url" || { echo "[spark-prelude] FATAL: download failed $url"; exit 1; }
  fi
  sz=$(wc -c < "$out")
  if [ "$sz" -lt "$min" ]; then echo "[spark-prelude] FATAL: $2 too small ($sz bytes) — check the pin"; exit 1; fi
  echo "[spark-prelude] ok $2 ($sz bytes)"
}
{{- if eq .Values.storage.provider "aws" }}
dl https://repo1.maven.org/maven2/org/apache/hadoop/hadoop-aws/3.4.1/hadoop-aws-3.4.1.jar hadoop-aws-3.4.1.jar 500000
dl https://repo1.maven.org/maven2/software/amazon/awssdk/bundle/2.24.6/bundle-2.24.6.jar aws-sdk-bundle-2.24.6.jar 400000000
{{- end }}
{{- if eq .Values.storage.provider "gcp" }}
dl https://repo1.maven.org/maven2/com/google/cloud/bigdataoss/gcs-connector/hadoop3-2.2.29/gcs-connector-hadoop3-2.2.29-shaded.jar gcs-connector-hadoop3-2.2.29-shaded.jar 20000000
{{- end }}
export SPARK_DIST_CLASSPATH="$(ls $EXTRA/*.jar | tr '\n' ':')${SPARK_DIST_CLASSPATH:-}"
{{- end }}
{{- end -}}
