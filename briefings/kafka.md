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
- **`server.log` is off via `KAFKA_LOG4J_ROOT_LOGLEVEL=INFO`** (4.2.0, official `apache/kafka:3.x.y` only). On a
  4.x (log4j2) image that variable strips every appender including stdout, so Kafka 4 needs its own fix. The GC log
  cap (11 x 100MB) exceeds a 1-core broker's 1Gi, and Connect's `connect.log` also rolls without deletion.
- **`cdc-pipeline` pins kafka at 4.0.1**, not the latest. Bumping this template does not affect that chart.
- **Uninstalling deletes the volumesets**, and with them every topic's log.

## Kafka Connect plugins (4.3.0)

| Piece | What it does |
|---|---|
| `plugins-downloader` (`busybox:1.37.0-musl`, `downloader_cpu` 80m) | downloads each artifact to `.cpln-downloads/staging` on the volume, verifies it (`sha256` if set, `unzip -l`/`tar -t`), then renames it into `<plugin>/<key>/` (atomic); `exec`'d, exits on SIGTERM |
| `scratch://plugin-sync` at `/opt/kafka/sync` | shared markers: `downloads-done`, `pending` (redacted list), `connect-started-degraded` |
| Connect gate (in the `-init` script) | waits for `downloads-done` up to `plugins_wait_timeout_seconds` (900; 0 = forever), then `start` (default: WARN names what is missing) or `restart` (exit 1) |

- **Key** = 16 hex of sha256 over type, URL without userinfo, sha256 and `plugins_redownload_token`, so rotating a
  URL password does not re-download, and changing the token re-downloads everything once.
- **Files the chart did not download are never touched**: hand-placed dirs, old extracted archives, stray dirs,
  `lost+found`. They are listed in one INFO line at each start (`left untouched`).
- **The chart deletes only what `.cpln-downloads/manifest` records**, and only after a fully successful pass, and
  not while Connect runs degraded. A removed, disabled or re-URLed artifact is pruned.
- **No `enabled` key = not downloaded, but the connector is still created** (unchanged since 3.x). This is how a
  hand-placed plugin is used.
- **First start after upgrading from ≤ 4.2.x re-downloads every plugin once per replica**, with Connect waiting.
  Old `<plugin>/<plugin>.jar` files (plugins that still have a jar artifact) move to `.cpln-downloads/retired/`.
  Old extracted archive dirs stay and still load beside the new copy until removed by hand. Rollback to 4.2.x is
  not measured.
- **A connector FAILED with "Failed to find any class" after a slow download**: the plugin arrived after the JVM
  scanned. A REST restart does not rescan; run `cpln workload force-redeployment`.
- **`ready: true` while Connect waits or runs degraded** (no probe, by design: a probe's startup window cannot
  cover a 900 s or unbounded wait). Read the `kafka-connect` log for `Waiting for plugin downloads` / `WARNING`.
- **busybox wget does not check TLS certificates**; `sha256` is the integrity control. busybox also forwards basic
  auth across a redirect (measured at build), which is why the JFrog two-step branch exists and is kept.
- **Credentials are redacted in logs** (userinfo → `***@`, query → `?<redacted>`), and the setup script logs
  connector config key names only. URLs are still readable in the `-download` secret and in `ps`;
  `verbose: true` still runs the setup script with `set -x`, which prints configs.
- **Connect scans `.cpln-downloads` as a plugin location** (it does not skip hidden dirs). Harmless in a normal
  start (no jars there when it scans); a degraded start may see staged files, fixed by the restart it already needs.
- **Plugin or chart changes restart every Connect replica** (secret-hash tag); a chart bump also rolls the brokers.
  Task reassignment after losing one worker waits `scheduled.rebalance.max.delay.ms` (5 min). Data-gap and
  `downloader_cpu` timings are test rows, not measured yet.
- Known, not fixed: connector credentials are plaintext values; single-broker installs need
  `offsets.topic.replication.factor=1` (and the transaction-log equivalents) in `extra_configurations`; a connector
  with neither `listener` nor `bootstrap.servers` fails to render (`kafka.bootstrapAddress` is missing).
