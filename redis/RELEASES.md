# Release Notes - Version 3.9.0

## What's New

- **Suspend switch**: `suspend: true` stops every workload in the release (Redis, Sentinel and the backup job) while keeping its volume sets and secrets; set it back to `false` to start again. With persistence on, the data is reloaded at start.
- **Adding persistence to a running release**: turn on `redis.persistence.enabled` (and `sentinel.persistence.enabled`) together with `suspend: true`, then set `suspend: false` in the next upgrade. Data held only in memory is lost, so turn persistence on at install when you can.
- **README**: reorganized around how the template works and how to set it up, with all version-upgrade notes in one Upgrading section.


# Release Notes - Version 3.8.0

## What's New

- **Dev mode**: `mode: dev` runs a single Redis node that boots as a plain master, with no Sentinel tier at all — for development and testing, with no failover and not for production. `redis.replicas` and the `sentinel` sizing settings are ignored in dev mode; Sentinel public access, persistence and authentication are refused at render. `mode: production` is the default and deploys the same topology as 3.7.0. Turn on `redis.persistence.enabled` at install if dev data must survive restarts. A `helm upgrade` from dev to production keeps the data and ends with one Sentinel failover to a new node.
- **Fix: temp-file cleanup no longer races Redis**: with persistence on, the `postStart` hook that removed leftover `temp-*.rdb` / `temp-rewriteaof-*.aof` files could delete a file Redis was writing, crashing a fresh node or aborting a replica's first full sync. The cleanup now runs in the start script before the server starts, and the `preStop` hook only waits.
- **Fix: whole-number CPU values**: `cpu`, `memory`, `minCpu` and `minMemory` are now quoted, so a value such as `redis.resources.maxCpu: 1` installs instead of being rejected by the API.


# Release Notes - Version 3.7.0

## What's New

- **Valkey engine option**: `engine: valkey` runs both the Redis and Sentinel tiers on `valkeyImage` (default `valkey/valkey:8.1.9`) instead of `redis.image`/`sentinel.image`. Valkey is the BSD-3-Clause fork of Redis 7.2 stewarded by the Linux Foundation. Nothing else in the chart changes — the Valkey image ships `redis-server`/`redis-cli`/`redis-sentinel` compatibility symlinks, so every command, config directive and probe is identical. `engine: redis` remains the default and an install that does not set it is unchanged. The engine is an **install-time** choice: an existing data directory cannot be moved between engines, because Valkey refuses the RDB format `redis:8` writes.


# Release Notes - Version 3.4.1

## What's New

- **Grafana Dashboard**: Added optional `GrafanaDashboard` CRD provisioned via the [Grafana Operator](https://grafana.github.io/grafana-operator/). Enable with `grafana.dashboard.enabled: true` (disabled by default). When enabled, a pre-built Redis dashboard is automatically created in your Grafana instance with CPU and memory panels always included, and Connected Clients, Redis Memory Used, Commands/sec, and Cache Hit Rate panels added when `redis.exporter.enabled: true`. Compatible with ArgoCD deployments. Configure the target folder, datasource name, and Grafana CR selector via `grafana.folder`, `grafana.datasource`, and `grafana.instanceSelector`.


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


