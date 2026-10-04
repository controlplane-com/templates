# Kafka — maintainer briefing

**What it is.** An Apache Kafka cluster in KRaft mode (no ZooKeeper), with optional Kafbat UI, REST Proxy
and Kafka Connect, and optional public listener access via a domain.

**Common use cases.** Event streaming and service-to-service eventing, the transport under a CDC pipeline,
and log/metrics ingestion where consumers need replay rather than a queue.

**Operational note:** this template is in production use for a managed customer, so changes are handled
deliberately rather than swept. Nothing here is broken; treat it as change-controlled.

## Architecture

| Resource | Notes |
|---|---|
| workload (stateful) | brokers in KRaft mode; the first nodes take the combined controller+broker role |
| volumesets | per-broker log directories, `logDirs` spanning two mounts |
| secret `-controller-configuration` | `server.properties`, including the SASL/JAAS listener config |
| secret `-init` | startup script; substitutes runtime values into the config before Kafka starts |
| secret `-secrets` | cluster id and the inter-broker/controller/admin passwords |
| identity + policy | `reveal` on those secrets; cloud storage access when backups are on |
| kafbat-ui / rest-proxy / connectors | optional workloads |
| domain | optional, for public listener access |

Does not create a GVC.

## Key knobs (shipped defaults)

| Knob | Default | Notes |
|---|---|---|
| `kafka.image` | `apache/kafka:3.9.1` | pinned |
| `kafka.replicas` | `3` | **must not be 2**; the first nodes are controllers |
| `kafka.volumes.logs.initialCapacity` | `10` GB | autoscales to 1000 GB |
| `kafka.terminationGracePeriodSeconds` | `600` | brokers need time to hand off cleanly |
| `kafka.deletionProtection` | `false` | |
| `listeners.client.sasl.*` | `your-…` placeholders | see the trap below |
| `kafka.secrets.*` | `your-…` placeholders | cluster id, inter-broker, controller passwords |

## Troubleshooting traps

- **SASL credentials and the KRaft cluster id are plain values**, so they land in the Helm release. The
  defaults are **non-working placeholders**, so an install that never sets them has no usable credential
  rather than a weak one — this is a keep-them-out-of-the-release fix, not an exposure. Deferred
  deliberately (2026-08-23): the conversion means extending the chart's runtime `replace_placeholder` step
  across a variable-length per-listener user list, then proving every SASL path — admin, per-user,
  inter-broker, controller — on a real cluster. A subtle break authenticates one principal and not another.
- **`replace_placeholder` uses `sed` with an unescaped replacement.** A password containing `|`, `&` or `\`
  corrupts the config rather than failing loudly. Fix this whenever the credentials work is picked up.
- **Three images still float**: `confluentinc/cp-kafka-rest:latest`, `ghcr.io/kafbat/kafka-ui` and
  `jmx-exporter` (both untagged). Held back from the 2026-08-23 pinning sweep so kafka takes one version
  bump rather than two.
- **`replicas: 2` is explicitly unsupported** — no quorum. Shrinking a running cluster below the controller
  quorum makes it unavailable.
- **Replication factor derives from the replica count** unless overridden in `extra_configurations`, so a
  single-broker cluster replicates nothing and topics created there survive nothing.
- **`server.log` is turned off by `KAFKA_LOG4J_ROOT_LOGLEVEL=INFO`** (4.2.0), which is set only for official
  `apache/kafka:3.x.y` images. Without it that file grows forever in the container layer and gets brokers evicted.
  On a 4.x (log4j2) image the variable strips every appender from the root logger, including stdout, so moving
  to Kafka 4 needs its own fix. The GC log is still capped at 11 x 100MB, which is above the 1Gi limit of a
  1-core broker, and kafka-connectors' `connect.log` has the same never-deleted rolling problem.
- **`cdc-pipeline` pins kafka at 4.0.1**, not the latest. Bumping this template does not affect that chart.
- **Uninstalling deletes the volumesets**, and with them every topic's log.
