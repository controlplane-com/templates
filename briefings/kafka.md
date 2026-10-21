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

- **Inline SASL and cluster passwords are still supported and still the values default** (4.4.0 kept them
  byte-identical on purpose: production releases upgrade without a change). The KRaft cluster id stays a plain
  value; it is an identifier, not a credential.
- **`replace_placeholder` uses `sed` with an unescaped replacement**: an inline password with `|`, `&` or `\`
  corrupts the config silently. The credentials-secret path routes only `${env:…}` strings through it.
- **Floating images**: `cp-kafka-rest:latest`, `kafbat/kafka-ui`, `jmx-exporter` (untagged).
- **Replication factor derives from `kafka.replicas`**; a single broker replicates nothing. Single-broker
  installs also need `offsets.topic.replication.factor=1` (and the transaction-log equivalents).
- **`server.log` is off via `KAFKA_LOG4J_ROOT_LOGLEVEL=INFO`** (4.2.0, official `apache/kafka:3.x.y` only); on a
  4.x image that variable strips every appender. Connect's `connect.log` still rolls without deletion.
- **`cdc-pipeline` 1.1.0 bundles kafka 4.3.0** and reaches the same EnvVarConfigProvider result by hand
  (`${env:CDC_KAFKA_*}` values + `kafka.env` + `extra_configurations`), refusing the sidecars that need the
  admin password in clear. Bumping it to 4.4.0 would let it drop that scaffolding and turn the health sidecar
  and exporter back on; not done (separate change, its own test round).
- **Uninstalling deletes the volumesets**, and with them every topic's log.
- Known, not fixed: `appVersion: "3.9"` vs image `3.9.1` (display only); a connector with neither `listener` nor `bootstrap.servers` fails to render (`kafka.bootstrapAddress`
  is missing).

## Credentials from secrets (4.4.0)

| Value (default `""` = inline) | Secret | How it reaches the workload |
|---|---|---|
| `kafka.credentialsSecretName` | dictionary: `inter-broker-password`, `controller-password`, `<listener>-<username>-password` per SASL admin/user (listener = `name` lower-cased) | brokers: `KCRED_*` env = `cpln://secret/…`; server.properties carries `${env:KCRED_*}` resolved by Kafka's `EnvVarConfigProvider` (`config.providers=env` rendered only in this mode); inter-broker/controller go through the `-secrets` dict as `${env:…}` strings into the init script's placeholders. Orchestrator, kafka-exporter: env points straight at the user's key. Deprecated kafka_ui: own identity+policy, JAAS via `$(KCRED_ADMIN_PASSWORD)` |
| `kafka_rest_proxy.jaas_conf_secret` | opaque, whole JAAS file | mounted in place of the chart's `-rest-jaas-conf` (kafbat `configuration_secret` precedent) |
| `kafka_rest_proxy.password_properties_secret` | opaque, whole `password.properties` | mounted in place of `-rest-password-properties` |
| Kafka Connect | none new | existing: `env` entry with `cpln://secret/…` (policy auto-grants) + `config.providers: env` and `${env:VAR}` in `connector_properties`/plugin `config` (README example) |

- **The secret wins** over every inline password; inline password count checks are skipped in that mode
  (`kafka.validateAuthUsers` replaces `kafka.validateAuthConfig`). Usernames and listener names must be
  `[A-Za-z0-9._-]+` (they form keys); `extra_configurations` may not drop `env` from `config.providers`.
- **`KCRED_`, never `KAFKA_`**: the apache/kafka image writes every `KAFKA_*` env var into server.properties,
  which would put the resolved password in the file (cdc-pipeline measured this).
- **Wizard**: a new install starts on "From a secret" (virtual init reads `context.mode`); an upgraded release
  that has `""` stays on "In values". `requiredKeysFrom` derives the key list from the listeners.
- **Rotation needs `cpln workload force-redeployment`** of the brokers (or REST Proxy); a running replica keeps
  the old value. Switching a running cluster inline → secret restarts the brokers once; put today's passwords
  in the secret.
- **Proof status (2026-10-21):** renders only. cdc-pipeline measured the broker mechanism locally on
  `apache/kafka:3.9.1`; this chart's own live rows (all-secret install, inline→secret switch, rotation, REST
  Proxy file secrets, Connect `${env:}`, kafka_ui `$(VAR)`) are pending.

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
- **FileStream connectors are NOT on the Connect worker's classpath** on `apache/kafka:3.9.1` (measured 2026-10-21:
  `Failed to find any class that implements Connector … FileStreamSinkConnector`); test with MirrorHeartbeat or Datagen.
- **REST Proxy basic auth on `confluentinc/cp-kafka-rest:latest` (kafka-rest 8.3.x, Jetty 12)** needs
  `org.eclipse.jetty.security.jaas.spi.PropertyFileLoginModule`; the old `org.eclipse.jetty.jaas.spi.…` class returns
  401 for every request (measured 2026-10-21).
