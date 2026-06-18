# Release Notes - Version 3.4.1

## What's New

- **Grafana Dashboard**: Added optional `GrafanaDashboard` CRD provisioned via the [Grafana Operator](https://grafana.github.io/grafana-operator/). Enable with `grafana.dashboard.enabled: true` (disabled by default). When enabled, a pre-built Redis dashboard is automatically created in your Grafana instance with CPU and memory panels always included, and Connected Clients, Redis Memory Used, Commands/sec, and Cache Hit Rate panels added when `redis.exporter.enabled: true`. Compatible ArgoCD deployments. Configure the target folder, datasource name, and Grafana CR selector via `grafana.folder`, `grafana.datasource`, and `grafana.instanceSelector`.


# Release Notes - Version 3.4.0

## What's New

- **Configurable Probe Settings**: Readiness and liveness probe timing (`initialDelaySeconds`, `periodSeconds`, `failureThreshold`, `timeoutSeconds`) are now overridable via `redis.probes.readiness` and `redis.probes.liveness` in the values file. The startup probe is derived by the platform from the readiness probe with a fixed `failureThreshold` of 30, giving a startup window of `initialDelaySeconds + (30 × periodSeconds)`. For large persistent datasets increase `periodSeconds` to extend this window.
- **Temp File Cleanup Hooks**: When `redis.persistence.enabled` is `true`, `postStart` and `preStop` lifecycle hooks are automatically added to remove orphaned `temp-*.rdb` and `temp-rewriteaof-*.aof` files. These files accumulate when pods are terminated mid-sync and can fill the volume over time, causing crash loops.
- **Metrics Exporter**: Added optional `redis_exporter` sidecar via `redis.exporter.enabled`. When enabled, Prometheus metrics are exposed at `:9121/metrics` on each Redis replica and auto-scraped by the Control Plane platform every 30 seconds. Supports auth passthrough and `dropMetrics` regex filtering for high-cardinality series. Works in both standard and `publicAccess` modes.


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


