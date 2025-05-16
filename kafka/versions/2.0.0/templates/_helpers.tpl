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
-Xmx{{ $memoryInMi }}m -Xms{{ $memoryInMi }}m
{{- end }}

{{- define "kafka.validateListenerConfig" -}}
  {{- if not .name -}}
    {{- fail "Error: 'name' must be provided for the listener" -}}
  {{- end -}}
  {{- if not .protocol -}}
    {{- fail "Error: 'protocol' must be provided for the listener" -}}
  {{- end -}}
  {{- if not (or .publicAddress .containerPort) -}}
    {{- fail "Error: At least one of 'publicAddress' or 'containerPort' must be provided for the listener" -}}
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
{{- end }}
{{- if gt $publicAddressCount 1 -}}
  {{- fail "There must be at most one listener with a publicAddress set." -}}
{{- end }}
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
      {{- $replicas := .Values.kafka.replicas | int -}}
      {{- $addresses := list -}}
      {{- range $i := until $replicas -}}
        {{- $port := add 3000 $i -}}
        {{- $addresses = append $addresses (printf "%s:%d" $listener.publicAddress $port) -}}
      {{- end -}}
      {{- $bootstrapAddress = join "," $addresses -}}
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
#!/bin/sh
set -ex

# Function to download and extract artifacts
download_and_extract() {
  local artifact_type=$1
  local artifact_url=$2
  local plugin_path=$3
  local plugin_name=$4
  local temp_dir=$(mktemp -d)
  
  echo "Downloading artifact from $artifact_url"
  
  if [ "$artifact_type" == "jar" ]; then
    # For jar files, create a directory for the plugin if it doesn't exist
    local plugin_dir="$plugin_path/$plugin_name"
    mkdir -p "$plugin_dir"
    
    # Download jar file to the plugin-specific directory
    wget -q "$artifact_url" -O "$plugin_dir/$(basename "$artifact_url")"
    echo "Downloaded JAR file to $plugin_dir/$(basename "$artifact_url")"
  else
    # For archives, download to temp dir and extract
    local archive_file="$temp_dir/$(basename "$artifact_url")"
    wget -q "$artifact_url" -O "$archive_file"
    
    echo "Extracting $artifact_type archive to $plugin_path"
    case "$artifact_type" in
      "tgz"|"tar.gz")
        tar -xzf "$archive_file" -C "$plugin_path"
        ;;
      "tar")
        tar -xf "$archive_file" -C "$plugin_path"
        ;;
      "zip")
        unzip -o "$archive_file" -d "$plugin_path"
        ;;
      *)
        echo "Unsupported archive type: $artifact_type"
        ;;
    esac
    
    rm -rf "$temp_dir"
  fi
}
# Process each Kafka connector
echo "Setting up Kafka connector plugins"

# Download and extract artifacts for each enabled plugin
{{- range .plugins }}
{{- if eq .enabled true }}
echo "Processing plugin: {{ .name }}"
{{- $pluginName := .name }}
{{- range .artifacts }}
download_and_extract "{{ .type }}" "{{ .url }}" "{{ $.plugins_folder }}" "{{ $pluginName }}"
{{- end }}
{{- else }}
echo "Skipping disabled plugin: {{ .name }}"
{{- end }}
{{- end }}

echo "All Kafka connector plugins have been downloaded and extracted."
echo "Sleeping..."
sleep infinity
{{- end }}

{{- define "kafka.connectors.run.script" -}}
#!/bin/bash
set -ex

# Function to create or update a connector
create_or_update_connector() {
  local connector_name=$1
  local config=$2
  
  echo "Checking if connector $connector_name exists..."

  # Try to delete the connector if it exists
  curl -s -X DELETE "http://localhost:8083/connectors/$connector_name" || true
  
  echo "Creating connector $connector_name with config:"
  echo "$config"
  
  # Create the connector
  curl -s -X POST -H "Content-Type: application/json" --data "$config" http://localhost:8083/connectors
  
  echo "Connector $connector_name created/updated successfully"
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
    echo "Generated random ssl.truststore.password: ${truststore_password}"
  fi
  
  # Create certs directory if it doesn't exist
  mkdir -p $(dirname "$truststore_path")
  
  # Download CA certificate
  echo "Downloading CA certificate for $hostname:$port"
  echo | openssl s_client -connect $hostname:$port -showcerts 2>/dev/null | \
    openssl x509 -outform PEM > $(dirname "$truststore_path")/$alias.pem
  
  # Create truststore if it doesn't exist or override existing one
  echo "Creating new truststore with password"
  cp $JAVA_HOME/lib/security/cacerts "$truststore_path"
  
  # Change the default password to our password
  echo "Setting truststore password"
  keytool -storepasswd -keystore "$truststore_path" \
    -storepass "changeit" -new "${truststore_password}"
  
  # Import certificate into truststore
  echo "Importing certificate into truststore"
  keytool -import -noprompt -alias $alias -file $(dirname "$truststore_path")/$alias.pem \
    -keystore "$truststore_path" -storepass "${truststore_password}"
    
  echo "Truststore setup completed for $hostname"
}

# Start Kafka Connect in the background
echo "Starting Kafka Connect distributed worker..."

# Start Kafka Connect in the background
nohup /opt/bitnami/kafka/bin/connect-distributed.sh /opt/bitnami/kafka/config/connect-distributed.properties > /proc/1/fd/1 2>&1 &

# Wait for Kafka Connect to start
echo "Waiting for Kafka Connect to start..."
until curl -s http://localhost:8083/ > /dev/null; do
  echo "Waiting for Kafka Connect REST API..."
  sleep 5
done

echo "Kafka Connect started. Waiting 10 seconds..."
sleep 10

# Create/update connectors
{{- range .plugins }}
echo "Processing connector: {{ .name }}"
{{- if hasKey . "enabled" }}
{{- if not .enabled }}
echo "Connector {{ .name }} is disabled. Removing if it exists..."
curl -s -X DELETE "http://localhost:8083/connectors/{{ .name }}" || true
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

# Try to create connector with retry logic
max_retries=5
retry_count=0
while [ $retry_count -lt $max_retries ]; do
  if create_or_update_connector "{{ .name }}" "$CONFIG"; then
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

# Try to create connector with retry logic
max_retries=5
retry_count=0
while [ $retry_count -lt $max_retries ]; do
  if create_or_update_connector "{{ .name }}" "$CONFIG"; then
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
{{- end }}
{{- end }}

echo "All Kafka connectors have been configured and started."
sleep infinity
{{- end }}

{{- define "kafka.validateListenerName" -}}
{{- if not (regexMatch "^[a-zA-Z0-9_]+$" .name) -}}
  {{- fail (printf "Error: Listener name '%s' contains invalid characters. Only alphanumeric characters and underscores are allowed." .name) -}}
{{- end -}}
{{- end -}}
