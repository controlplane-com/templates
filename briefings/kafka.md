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
- **First start after ≤ 4.2.x re-downloads every plugin once per replica** with Connect waiting. Measured
  (Snowflake 3 jars + 4 small, 80m): ~80 s wait per replica, replicas roll one at a time, ~7 min for 3
  replicas, well inside the 900 s default. Later restarts wait 0-5 s, then ~40 s JVM to REST.
- **`downloader_cpu`: 80m is the default only to keep 4.2.0's footprint**; recommend 250m for artifacts
  ≥ 50 MB. Fetch + verify of a 183 MB jar: 73 s at 80m, 25 s at 250m, 13 s at 500m (60 MB https: 24/8/4 s).
- **`ready: true` while Connect waits** (no probe by design). Read the `kafka-connect` log.
- **busybox wget skips TLS validation** (`sha256` is the control) and forwards URL credentials to every redirect
  target, so URLs with credentials bypass it: one raw request (`nc`, plus `ssl_client` for https) to the URL's own
  host, same-host redirects keep the credentials, any other host is fetched by wget without them. The request
  file (it holds the Authorization header) lives in a mode-700 `/tmp` dir, never on the volume. nc runs a
  small `sh` program on the socket (`-e`, never a half-close) that splits off the head and streams the body
  straight to the staging file (one write; only a chunked body is copied, by the de-chunker, which relies on
  busybox `head -c` reading exactly N bytes from a shared descriptor). The request runs under `setsid`, and
  the 60 s idle watchdog (real seconds, size via `stat`) kills the whole process group.
- **History of that path (fixed before release, re-tested live: http and https credentialed downloads install, 183 MB at 80m in ~60 s like wget, 61 s hang timeout with no leftover processes):** D1, credentialed `http://` never downloaded on the
  platform: busybox nc half-closes at stdin EOF, and the sidecar on an `http` port then drops the response
  (0 B; plain and https URLs were fine). D2, credentialed https ran ~2.2x slower than wget at 80m: the
  watchdog ran `wc -c` (reads the whole file, ~20 s at 183 MB) every second and counted iterations, so
  "60 s" stretched to minutes, and the body was copied once more after download. D3, a timeout inside the
  first pass printed `unknown`; `pending` now names the most recently started artifact and how many are unchecked.
- **Logs are credential-free**: URLs redacted, connector configs logged as key names only, `verbose` adds
  downloader detail only. URLs remain readable in the `-download` secret; userinfo never reaches `ps`, but query-string tokens of URLs without userinfo do.
- **Connect scans `.cpln-downloads` as a plugin location**; harmless unless started degraded mid-extraction.
- **Plugin or chart changes restart every Connect replica**; a chart bump rolls the brokers too (single test
  broker: 144 s gap). A rolling Connect restart costs a task ~4 s when it migrates, and up to several minutes
  (208 s measured) when its own worker is the one restarting (Kafka's delayed reassignment); that depends on
  task placement, not chart version. A hung (SIGSTOPped) worker's task moved in ~10 s, not 5 min; after
  resume both owners committed offsets once, so duplicates are possible.
- **SIGTERM:** the downloader stops at once (exit 143); replica turnaround 60-65 s vs 64-70 s on 4.2.0. The
  `replica stop` API delivers TERM ~45 s after the call.
- **Rollback to 4.2.x works** (connectors stay RUNNING), but 4.2.x writes `<plugin>/<plugin>.jar` again
  beside the 4.3.0 `<plugin>/<key>/` dirs (one classloader), re-extracts archives at the folder root, and its
  60 s startup race returns. Re-upgrading retires those files again.
- **Stock `apache/kafka:3.9.1` ships `connect-file-3.9.1.jar` in `/opt/kafka/libs`**, so FileStream always
  resolves from the classpath; test plugin loading with another connector (e.g. Datagen).
