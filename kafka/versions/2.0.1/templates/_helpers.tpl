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
{{- $heapSize := div (mul $memoryInMi 60) 100 | int }}
-Xmx{{ $heapSize }}m -Xms{{ $heapSize }}m
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
    echo "Generated random password for $password_env: $truststore_password"
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
  until curl -s http://localhost:8083/ > /dev/null; do
    echo "Waiting for Kafka Connect REST API..."
    sleep 5
  done

  echo "Kafka Connect started. Waiting 10 seconds for full initialization..."
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
  echo "DEBUG: Password value: ${!PLUGIN_PASSWORD_VAR}"
  if [[ -n "${!PLUGIN_PASSWORD_VAR}" ]]; then
    echo "DEBUG: Replacing \${${PLUGIN_PASSWORD_VAR}} with password in config"
    CONFIG=$(echo "$CONFIG" | sed "s|\${${PLUGIN_PASSWORD_VAR}}|${!PLUGIN_PASSWORD_VAR}|g")
    echo "DEBUG: Config after replacement:"
    echo "$CONFIG"
  else
    echo "DEBUG: No password found in $PLUGIN_PASSWORD_VAR"
  fi
  {{- end }}
  {{- end }}

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

  {{- if hasKey . "ssl_truststore" }}
{{- if hasKey .ssl_truststore "truststore_password_env" }}
# Replace plugin-specific truststore password if it exists
PLUGIN_PASSWORD_VAR="{{ .ssl_truststore.truststore_password_env }}"
echo "DEBUG: Looking for password in environment variable: $PLUGIN_PASSWORD_VAR"
echo "DEBUG: Password value: ${!PLUGIN_PASSWORD_VAR}"
if [[ -n "${!PLUGIN_PASSWORD_VAR}" ]]; then
  echo "DEBUG: Replacing \${${PLUGIN_PASSWORD_VAR}} with password in config"
  CONFIG=$(echo "$CONFIG" | sed "s|\${${PLUGIN_PASSWORD_VAR}}|${!PLUGIN_PASSWORD_VAR}|g")
  echo "DEBUG: Config after replacement:"
  echo "$CONFIG"
else
  echo "DEBUG: No password found in $PLUGIN_PASSWORD_VAR"
fi
{{- end }}
{{- end }}

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

echo "Starting Kafka Connect distributed worker..."

# Start the connector setup process in the background
setup_connectors &
SETUP_PID=$!

# Start Kafka Connect in the foreground
echo "Starting Kafka Connect in foreground mode..."
exec /opt/bitnami/kafka/bin/connect-distributed.sh /opt/bitnami/kafka/config/connect-distributed.properties &
KAFKA_PID=$!

# Wait for either process to finish
wait $KAFKA_PID
{{- end }}