# Release Notes - Version 3.3.0

## What's New

- **Smart Master Discovery**: Non-primary replicas now query Sentinel at startup to find the current master rather than hardcoding replica-0, ensuring correct replication after any failover.
- **Resilient Sentinel Targeting**: All modes query the Sentinel service endpoint so any healthy Sentinel instance can respond, rather than always targeting replica-0.


# Release Notes - Version 3.2.0

## What's New

- **Backup Support**: Added optional scheduled backup to AWS S3 or GCS via a dedicated cron workload. Configure with `backup.enabled`, `backup.provider`, and your cloud provider settings. Supports Redis password authentication (inline or from secret). See the README for full setup instructions.


# Release Notes - Version 3.1.1

## What's New

- **Template Refactoring**: Centralized all resource naming into helper functions, improving consistency across templates.
- **Password Quoting Fix**: Secret password values are now properly quoted, preventing YAML parsing issues with special characters.
- **README Rewrite**: Documentation updated with clearer configuration examples and internal endpoint reference.


# Release Notes - Version 3.1.0

## What's New

- **replicaDirect Support**: Added `replicaDirect` configuration option for both Redis and Sentinel workloads in a single location GVC. This is especially useful for allowing access to individual Redis replicas from other GVCs using internal domain routing.  The startup commands of Redis and Sentinels were fixed to support `replicaDirect`.  See docs: https://docs.controlplane.com/reference/workload/general#internal-endpoint-formatting


# Release Notes - Version 3.0.4

## What's New

- **replicaDirect Support**: Added `replicaDirect` configuration option for both Redis and Sentinel workloads. This is especially useful for allowing access to individual Redis replicas from other GVCs using internal domain routing. See docs: https://docs.controlplane.com/reference/workload/general#internal-endpoint-formatting


# Release Notes - Version 3.0.3

## What's New

- **Multi-Zone Support**: Added `multiZone` configuration option for both Redis and Sentinel workloads
- **Custom Encryption**: Added optional AWS KMS encryption support for Redis and Sentinel volumes via `customEncryption`


