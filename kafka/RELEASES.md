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


