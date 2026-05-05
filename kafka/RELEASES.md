# Release Notes - Version 3.5.0

## What's New

- **Kafka Cluster Parallel Scaling Policy**: Changed the default `scalingPolicy` for the Kafka cluster stateful workload from `OrderedReady` to `Parallel`

# Release Notes - Version 4.0.0

## What's New

- **kafka-orchestrator sidecar for accurate readiness**: The Kafka cluster workload now runs `ghcr.io/controlplane-com/kafka-orchestrator` as a sidecar container. The sidecar exposes an HTTP `/health/ready` endpoint that validates broker registration, controller election, under-replicated partition count, and log-directory health using franz-go — a much stronger readiness signal than the previous TCP-socket check on port 9093.
  - Sidecar readiness probe: `httpGet /health/ready` on port 8080
  - Prometheus metrics exposed at `/metrics` (cgroup memory and OOM-risk ratios)
  - SASL credentials are wired automatically from the configured listener (default: `client`)
  - The kafka container's existing TCP probes on port 9093 are preserved; workload readiness is now gated on both probes passing
  - Configurable under the new `kafka_orchestrator:` section in `values.yaml`; set to `null` or comment out to disable the sidecar

- **Graceful broker shutdown**: The kafka container's `terminationGracePeriodSeconds` is now exposed via `kafka.terminationGracePeriodSeconds` in `values.yaml` (default `600` seconds, up from the previous hardcoded `30`). Brokers carrying large amounts of data now have time to complete `controlled.shutdown` (leadership transfer + log flush) before SIGKILL.

- **Init script signal propagation**: The kafka container's bash wrapper now `exec`s into `/tmp/kafka-init.sh`, which already `exec`s into the Kafka run script. PID 1 is now the Kafka JVM itself, so SIGTERM from Control Plane reaches the broker directly and triggers `controlled.shutdown` instead of being absorbed by the bash wrapper.

- **Suppressed Control Plane's default preStop drain delay (all four containers)**: Control Plane's default container lifecycle injects a `preStop sleep $((terminationGracePeriodSeconds / 2))` on **every** container (the actuator's `getLifecycle` runs per-container in the `for...containers` loop in `workloadDeployment.ts:246-258`). For our 600s grace period that means a 300s idle preStop on each of `kafka`, `kafka-orchestrator`, `kafka-exporter`, and `jmx-exporter`. The drain delay is intended for L7 envoy/ingress connections, none of which apply to a kafka stateful workload — clients reconnect via Metadata refresh, inter-broker traffic is handled by `controlled.shutdown`'s leadership transfer, and the prometheus-scrape sidecars have no draining semantics. All four containers now declare an explicit no-op `preStop: exec: ['true']`, suppressing the default on each. Net effect: the entire pod terminates in seconds (bounded by the kafka container's `controlled.shutdown`), not 300s+ of useless sleep on three sidecars holding the pod hostage.

- **`cpln/publishNotReadyAddresses=true` on the Kafka cluster workload**: Required so the headless Service exposes not-yet-Ready broker pods in DNS, which is what lets the KRaft controller quorum form on cold start (or after suspend/unsuspend). Earlier versions of the chart got away with this missing because the Kafka container's TCP probe on 9093 briefly flickered Ready every crash-loop iteration, just long enough to publish endpoints. The new kafka-orchestrator sidecar's `/health/ready` probe (correctly) requires actual cluster health, which closes that race — making the tag mandatory rather than optional. Without it, pods crash-loop with `UnknownHostException: etl-cluster-N.etl-cluster:9093`.

- **Reliability and recovery defaults in `server.properties`**: The chart now emits the following defaults in the broker config (each can be overridden via `kafka.extra_configurations`):
  - `default.replication.factor` — auto-derived as `min(3, kafka.replicas)`; clamps correctly when scaling below 3 replicas
  - `min.insync.replicas` — auto-derived as `max(1, default.replication.factor - 1)`
  - `controlled.shutdown.enable=true`, `controlled.shutdown.max.retries=3`, `controlled.shutdown.retry.backoff.ms=5000` — clean shutdown with retry on leadership-transfer failures
  - `unclean.leader.election.enable=false` — never promote out-of-sync replicas; prevents data loss
  - `num.recovery.threads.per.data.dir` — auto-derived as `8 * ceil(cores)` from `kafka.cpu` (e.g. `1000m` → 8, `2000m` → 16, `4` → 32). Recovery only runs after a *dirty* shutdown; a clean `controlled.shutdown` (now achievable thanks to the grace-period and signal-propagation fixes above) skips it entirely.
  - `num.replica.fetchers=4` — faster follower replication so brokers rejoin the ISR quickly after transient outages

# Release Notes - Version 3.4.0

## What's New

- **Kafka Connect Init Script: Bulletproof TLS/Truststore Handling**: The connector init script no longer crashes when TLS certificate download fails (e.g. ClickHouse Cloud IP allowlist blocking the TLS handshake)
  - Certificate download failure (`openssl s_client`) is now non-fatal — logs a visible WARNING and continues
  - Truststore creation (`cp cacerts`) is guarded: skipped gracefully if the Java `cacerts` file is missing
  - Truststore password change (`keytool -storepasswd`) failure is non-fatal — logs a WARNING and continues
  - Certificate import (`keytool -import`) is skipped if the downloaded cert file is empty, preventing a hard crash from an invalid X.509 input
  - All failure paths log a clearly visible WARNING to stdout for easier future troubleshooting
  - **Impact**: Previously, a single TLS failure in any connector's truststore setup would kill the entire `setup_connectors` process, preventing all subsequent connectors from being created or updated

- **Kafka Connect Init Script: Reliable Connector Update via PUT**: Fixed connector config updates silently failing
  - `Content-Length` header now correctly trimmed of whitespace (`wc -c | xargs`) to prevent malformed HTTP requests
  - HTTP response is captured and logged; non-2xx responses are reported as ERROR to stdout
  - **Impact**: Connector configuration updates (e.g. `flush.size`) were silently dropped due to a malformed PUT request

# Release Notes - Version 3.3.0

## What's New

- **Kafka Connect Dynamic Advertised Hostname**: Added automatic configuration of `rest.advertised.host.name` for distributed workers
  - Enables proper worker-to-worker communication in multi-replica Kafka Connect deployments
  - Dynamically sets hostname based on pod ID and workload name

# Release Notes - Version 3.2.0

## What's New

- **Drop Metrics**: Added support to filter metrics on the kafka-exporter and jmx-exporter containers
  - Include regex patterns that drop all matching metrics

# Release Notes - Version 3.1.1

## What's New

- **Kafka Connect Plugin Downloader Improvements**: Enhanced the plugin download script with JFrog Artifactory support
  - Added automatic redirect handling for JFrog URLs with embedded credentials (`user:token@*.jfrog.io`)
  - Two-step download process: extracts pre-signed URL from redirect, then downloads from the resolved location
  - Fallback to direct download if redirect extraction fails
  - Improved filename handling using plugin names instead of URL basename (avoids issues with query parameters in signed URLs)
  - **Backward Compatible**: Non-JFrog URLs continue to work as before

- **Kafka Connect Secret Naming**: Shortened secret names to avoid hitting the 64 character limit
  - Changed `-distributed-properties` suffix to `-config`
  - Example: `kafka-connect-my-connector-distributed-properties` → `kafka-connect-my-connector-config`

# Release Notes - Version 3.1.0

## What's New

- **Direct Replica Routing for Public Listeners**: Added support for new domain routing mode with automatic replica endpoint generation
  - This direct replica routing method allows publicly exposed Kafka clusters running on multi-AZ to route traffic effectively to the correct zone and reduce cross-zone traffic costs
  - **Note**: Requires `Multi Zone` setting to be enabled on the GVC's Load Balancer configuration (this must be configured separately outside of this template)
  - New optional `directReplicaRouting` configuration for public listeners
  - When enabled, creates a single domain with DNS01 certificate challenge
  - Platform automatically generates location-aware replica-specific endpoints in format: `{replica-name}-{location}.{publicAddress}:{containerPort}`
  - Example endpoints: `kafka-cluster-0-aws-us-east-1.kafka.example.com:9095`, `kafka-cluster-1-aws-us-east-1.kafka.example.com:9095`
  - **Backward Compatible**: Existing configurations without `directReplicaRouting` continue using the legacy multi-port approach (ports 3000-300X) when `publicAddress` is provided at the listener level
  
- **Kafka Connect Volume Configuration**: Added configurable volume settings for Kafka Connect, including:
  - `initialCapacity`: Configure initial volume size (default: 10 GB)
  - `performanceClass`: Choose between `general-purpose-ssd` or `high-throughput-ssd` (default: general-purpose-ssd)
  - `fileSystemType`: Select `ext4` or `xfs` (default: ext4)
  - `snapshots`: Configure snapshot settings with `createFinalSnapshot`, `retentionDuration`, and optional `schedule`
  - `customEncryption`: Optional AWS KMS encryption support for volumes
  - **Backward Compatible**: Existing deployments without volume configuration will continue to work with the same default values

# Release Notes - Version 3.0.0

A major update due to the deprecation of Bitnami public images support and migration to Apache upstream images.

## What's New

- Deprecated support for Bitnami images for Kafka and Kafka Connect. The template now supports and has been tested with Apache Kafka upstream images.
- Kafka Connect improvement: updating configurations of existing plugins results in faster startup of Kafka Connect.
- Custom encryption setting for Kafka volume set


