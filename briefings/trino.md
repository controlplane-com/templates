# Trino — Maintainer Briefing

## What it is
- Distributed SQL query engine that runs one query **across** many separate databases at once, without copying the data anywhere. Image `trinodb/trino:483`; a coordinator plus a scalable stateless worker tier.
- License: Apache-2.0 (permissive open source — no paid edition, nothing gated, no registration).

## Common use cases
- Join data living in different systems — orders in PostgreSQL with users in MySQL — in a single `SELECT`, turning the catalog's ~nine database templates into one surface.
- A SQL front door for BI tools (`metabase`, JDBC clients) that points at Trino instead of at each database separately.
- Ad-hoc analytics over production replicas with no ETL pipeline.
- Analysts get one endpoint and no per-database credentials — Trino holds them.

## Architecture on cpln
| Resource | Purpose |
|---|---|
| `{release}-trino` (standard, always 1 replica, :8080 `http`) | Coordinator — query planner, Web UI, JDBC/REST endpoint, in-process discovery |
| `{release}-trino-worker` (standard, `workers.replicas`, :8080 `tcp`) | Stateless execution tier; the whole workload is absent at `replicas: 0` |
| secrets `…-coordinator-config` / `…-worker-config` / `…-jvm` / `…-node` | The rendered Trino config files, file-mounted into `/etc/trino` |
| secret `…-catalog-{name}` (one per `catalogs[]` entry) | `/etc/trino/catalog/{name}.properties`, mounted on **both** tiers |
| secret `…-password-authenticator` | Coordinator only, gated on `auth.enabled` |
| identity + policy (one shared pair) | `reveal` on exactly the config/catalog secrets plus each user-created credential secret |

- No volumeset, no database, no GVC — entirely stateless. Uninstall touches nothing in the queried databases and leaves the user's secrets in place.
- Workers announce to `{release}-trino.{gvc}.cpln.local:8080` and are dialed back at raw pod IPs (verified). Worker-tier firewall is always `workload-list` (coordinator + siblings only), independent of `internalAccess.type`.

## Key knobs
| Knob | Default | Meaning |
|---|---|---|
| `image` | `trinodb/trino:483` | one image for both tiers; `appVersion` tracks it |
| `workers.replicas` | `1` | `0` = single-node (coordinator executes queries itself); raise for capacity and restart tolerance |
| `coordinator.resources.*` | 500m/1000m · 2Gi/4Gi | `minCpu`/`maxCpu` · `minMemory`/`maxMemory`; render-validated (whole GiB, ≥2Gi, ≤4:1 cpu ratio) |
| `workers.resources.*` | 500m/2000m · 2Gi/4Gi | same validation; only checked when `replicas > 0` |
| `jvm.maxRAMPercentage` | `70` | heap = this % of each tier's `maxMemory`; render-validated to 40–80 |
| `catalogs[]` | `[]` | one entry per data source; `properties` pasted from the connector's doc page |
| `catalogs[].secrets[]` | — | maps a pre-created secret into an env var referenced as `${ENV:NAME}` in the properties file |
| `auth.enabled` | `false` | password-file login; **REQUIRES `publicAccess.enabled`**, and public requires auth — the two are mutually mandatory |
| `auth.passwordFileSecretName` / `auth.sharedSecretName` | `""` / `""` | opaque prerequisite secrets, required when auth is on (empty = feature off) |
| `publicAccess.enabled` | `false` | Web UI + JDBC on the automatic `*.cpln.app` HTTPS endpoint |
| `internalAccess.type` / `.workloads` | `same-gvc` / `[]` | `same-gvc` \| `same-org` \| `workload-list`; **`none` is render-rejected** (see below) |

Prerequisite secrets (create BEFORE install; verbatim from the shipped README):
`htpasswd -B -C 10 -n alice | cpln secret create-opaque --name my-trino-passwords --encoding plain -f -`
`printf '%s' "$(openssl rand -hex 32)" | cpln secret create-opaque --name my-trino-shared-secret --encoding plain -f -`
Catalog credentials: opaque for one value (referenced without `secretKey`), else `cpln secret create-dictionary --name my-mysql-credentials --entry password=the-password`.

## Availability posture
- **Worker tier scales and is restart-tolerant; the coordinator is a single point of failure** — OSS Trino allows exactly one coordinator (multi-coordinator needs the separate Trino Gateway project). Shipped default is `workers.replicas: 1`; the measured figures below are at 3.
- Measured: worker-tier rolling restart **3 of 80 queries failed** (all inside the ~180 s rollout, 65 consecutive successes after); a killed worker replica cost **0 of 90 queries** (replacement joined at +41 s, stale node evicted at +115 s); a coordinator restart served **exactly 6 s of HTTP 503** and lost **1 of 45** in-flight queries (`Query is gone (server restarted?)`).
- Convergence: coordinator `ready: true` in ~38–65 s, workers register ~7 s later. There is no fault-tolerant execution, so queries in flight on a replaced node die and must be retried.

## Troubleshooting / considerations
- **`internalAccess.type: none` is rejected UNCONDITIONALLY, not just when workers exist.** The coordinator pins `node.internal-address` to its own service DNS name, so its own task/status calls leave the pod and re-enter through this firewall — at `workers.replicas: 0` even `SELECT 1` returned `403 RBAC: access denied`. The coordinator also auto-adds **itself** (and its worker workload) to `inboundAllowWorkload` under `workload-list`; without that self-entry `system.*`/`jmx.*` queries 403 at any replica count. Both were round-1 blockers, fixed and re-proven with the allow-list containing only the chart's own entries.
- **`auth.enabled` requires `publicAccess.enabled` — the SERVER, not the client, is the reason.** Trino 483 refuses password auth over plain HTTP (`401 Password not allowed for insecure authentication`), so auth-without-public deployed healthy and was queryable by nobody. Render now blocks it, as does the mirror rule (public without auth = an arbitrary-read primitive over every connected data source). The stale values comment blaming the CLI/JDBC driver is inaccurate; the refusal is server-side.
- **`http-server.process-forwarded=true` is set unconditionally and must stay that way.** The cpln mesh injects `X-Forwarded-Proto` on **internal** workload-to-workload hops, and Jetty's default REJECT mode answers those with `406 Not Acceptable` — silently breaking worker announcements even with public access off. It also makes edge-terminated requests read as HTTPS (proven: `Secure` UI cookie + absolute `https://` redirect).
- **`-XX:+UseG1GC` is set explicitly, deliberately diverging from upstream's jvm.config.** Upstream relies on JVM ergonomics, which pick SerialGC on a 1-CPU cgroup — exactly the coordinator's `maxCpu: 1000m` default, which produced `Trino recommends the G1 garbage collector` and made `-XX:G1HeapRegionSize=32M` a no-op. Do not drop the flag when refreshing the file from upstream.
- **Out-of-memory is the classic Trino failure.** Heap = `jvm.maxRAMPercentage` × `maxMemory`; per-query-per-node budget is 30 % of heap. Raise `maxMemory` first, workers second; raising the percentage above ~75 makes it worse (the JVM needs the rest for code cache, metaspace, buffers). Capacity AI is hardcoded off on both workloads — the JVM sizes its heap once from the container limit.
- **Trino refuses to boot on an unknown config property** (`Configuration property 'x' was not used`) — fatal, not a warning. Every property the template emits was accepted at 483.
- **Credentials never appear in values or in any rendered file** — catalog properties carry only `${ENV:NAME}`. A "password not working" report means the secret's key name does not match `catalogs[].secrets[].secretKey`, or the secret is missing (a missing prerequisite secret leaves the deployment waiting).
- **Rotating a secret's payload does not take effect until the workload is redeployed** — cpln resolves `cpln://secret/…` env at deployment time; `cpln workload replica stop` is not enough.
- **Only the FQDN resolves for in-GVC clients**: `http://{workload}:8080` gave `UnknownHostException` from another workload; use `{workload}.{gvc}.cpln.local`. (Open question against CLAUDE.md's short-name claim.)
- The image ships the `tpch`, `tpcds`, `memory` and `jmx` demo catalogs and the file mounts do not shadow them, so a default install is queryable immediately. `jmx` exposes JVM internals to anyone who can query. Object-storage catalogs (Hive, Iceberg, Delta Lake) are out of scope in 1.0.0 — they need an external metastore.
- **Keep the GVC single-location** — a workload runs in every location its GVC has, so a second location puts per-query coordinator↔worker chatter across regions (slow and billed).
