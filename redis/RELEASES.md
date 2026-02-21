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


