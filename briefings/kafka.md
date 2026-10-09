# Kafka — maintainer briefing

**What it is.** An Apache Kafka cluster in KRaft mode (no ZooKeeper), with optional Kafbat UI, REST Proxy
and Kafka Connect, and optional public listener access via a domain.

**Use cases.** Event streaming between services, the transport under a CDC pipeline, and log/metrics
ingestion where consumers need replay rather than a queue.

**Change-controlled:** production installs depend on this template, so changes ship deliberately and are
not swept into catalog-wide edits.

## Architecture

| Resource | Notes |
|---|---|
| workload (stateful) | brokers in KRaft mode; the first nodes are combined controller+broker |
| volumesets | one per `logDirs` entry, per broker |
| secrets `-controller-configuration`, `-init`, `-secrets` | `server.properties` (SASL/JAAS), the startup script, cluster id + passwords |
| kafbat-ui / rest-proxy / connectors | optional workloads; each connector group is its own stateful workload + volumeset |
| domain | optional, for public listener access |

Does not create a GVC. Key defaults: `apache/kafka:3.9.1`, `kafka.replicas: 3` (**never 2**), 10 GB log
volumes autoscaling to 1000 GB, `terminationGracePeriodSeconds: 600`, SASL and cluster secrets as
non-working `your-…` placeholders.

## Troubleshooting traps

- **SASL credentials and the KRaft cluster id are plain values** in the Helm release (placeholders by default,
  so an untouched install has no usable credential). Converting them means extending the runtime
  `replace_placeholder` step across per-listener user lists and re-proving every SASL principal; deferred.
- **`replace_placeholder` uses `sed` with an unescaped replacement**: a password with `|`, `&` or `\`
  corrupts the config silently.
- **Floating images**: `cp-kafka-rest:latest`, `kafbat/kafka-ui`, `jmx-exporter` (untagged).
- **Replication factor derives from `kafka.replicas`**; a single broker replicates nothing. Single-broker
  installs also need `offsets.topic.replication.factor=1` (and the transaction-log equivalents).
- **`server.log` is off via `KAFKA_LOG4J_ROOT_LOGLEVEL=INFO`** (4.2.0, official `apache/kafka:3.x.y` only); on a
  4.x image that variable strips every appender. Connect's `connect.log` still rolls without deletion.
- **`cdc-pipeline` pins kafka 4.0.1**; bumping this template does not affect it.
- **Uninstalling deletes the volumesets**, and with them every topic's log.
- Known, not fixed: `appVersion: "3.9"` vs image `3.9.1` (display only); connector credentials are plaintext
  values; a connector with neither `listener` nor `bootstrap.servers` fails to render (`kafka.bootstrapAddress`
  is missing).

## Kafka Connect plugins (4.3.0)

| Piece | What it does |
|---|---|
| `plugins-downloader` (`busybox:1.37.0-musl`, `downloader_cpu` 80m) | stages each artifact in `.cpln-downloads/staging` on the volume, verifies it, renames it into `<plugin>/<key>/`; exits promptly on SIGTERM |
| `scratch://plugin-sync` (`/opt/kafka/sync`) | `downloads-done`, `pending` (redacted), `connect-started-degraded` |
| Connect gate (`-init`) | waits for `downloads-done` up to `plugins_wait_timeout_seconds` (900; 0 = forever), then `start` (WARN, default) or `restart` |

- **Deletes only what `.cpln-downloads/manifest` records**, only after a fully successful pass, never while an
  artifact has a config error, and never while Connect runs degraded. Files it did not download are never
  deleted; the old `<plugin>/<plugin>.jar` (pre-4.3 naming, so a hand file at that exact path too) is moved to
  `.cpln-downloads/retired/`. Old extracted archive dirs stay and still load beside the new copy.
- **No `enabled` key = not downloaded, but the connector is still created** (unchanged since 3.x).
- **Degraded start is sticky per replica**: the marker is cleared only by a new replica, so a Connect-only
  restart starts at once (no second timeout) and still loads old and new copies of a changed plugin; a
  `force-redeployment` loads the late plugin and lets cleanup run. REST restart never rescans.
- **First start after ≤ 4.2.x re-downloads every plugin once per replica** with Connect waiting.
- **`ready: true` while Connect waits** (no probe by design). Read the `kafka-connect` log.
- **busybox wget skips TLS validation** (`sha256` is the control) and forwards basic auth across redirects,
  which is why the JFrog two-step branch is kept.
- **Logs are credential-free**: URLs redacted, connector configs logged as key names only, `verbose` adds
  downloader detail only. URLs remain readable in the `-download` secret and `ps`.
- **Connect scans `.cpln-downloads` as a plugin location**; harmless unless started degraded mid-extraction.
- **Plugin or chart changes restart every Connect replica**; a chart bump rolls the brokers too. Task
  reassignment after a lost worker waits 5 min. Not measured yet: data gaps, `downloader_cpu` timings, rollback.
