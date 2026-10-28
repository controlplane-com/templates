# Temporal — Maintainer Briefing

## What it is

- Temporal is a durable-execution platform: apps write workflows as ordinary code, and the server persists every step so runs survive crashes, restarts and waits of days or months. MIT license; the paid product is hosted-only, so nothing in the self-hosted server is feature-gated.

## Common use cases

- Order, payment, refund and onboarding flows.
- Reliable background jobs with retries (replaces queue + cron + retry glue).
- Multi-step service or AI orchestration where a half-finished run is unacceptable.
- Timers, reminders and human-approval waits that must survive deploys.

## Architecture on Control Plane (2.1.0)

| Resource | Purpose |
|---|---|
| `{release}-temporal` (standard, `replicas` 1-5, default 1) | Each replica: `temporal` container (all four services in one process; gRPC 7233, HTTP API 7243, metrics 8000, cluster ports 6933-6939 / 7234-7239, all declared at every N) + `admin` sidecar (`temporalio/admin-tools`). Replicas form one ringpop cluster over pod IPs. |
| `admin` sidecar | Refuses to start unless the credentials secret's `database` key is `temporal` (`CPLN_TEMPORAL_DATABASE_GUARD`, FATAL + sleep 120 + exit 1; the server container runs the same check), then creates both DBs, takes a migration **lease** (one-row table `cpln_temporal_schema_lock` in the `postgres` DB), refuses a **skipped minor**, runs `update-schema`, opens a scratch gate (`/temporal-gate/schema-ready`) for the server, creates `default` (create-only), then idles as the `temporal` CLI. |
| `{release}-temporal-ui` | Web UI :8080 (no login), internal-only by default. `ui.allowedCIDRs` opens ONLY this workload's external firewall to the listed ranges (its single `http` port serves the canonical endpoint; no load balancer). `cpln port-forward` stays for curl-level checks: browsers through the tunnel stall. `/healthz` probes. |
| postgresHA (pg-ha **2.7.0**, default) / postgres **3.4.1** | All state, in `temporal` and `temporal_visibility`; plus the lease table and `cpln_temporal_schema_migration` (resume markers) in the `postgres` DB. |
| DB secret | **User-created prerequisite since 2.1.0** (work item 5284): a dictionary (`username`, `password`, `database`=`temporal`) named by `postgresHA.config.credentialsSecretName` or `postgres.config.credentialsSecretName`. The subchart initializes from it; Temporal reads all three keys as `cpln://secret/…` env vars (`database` only for the boot guard). The identity reveals only it. No URL is assembled from it, so no `$(VAR)` use. |
| Archival (optional, `archival.enabled`) | S3 only. The server runs from `files/temporal-config-1.30.yaml` (1.30/1.31) or `-1.32.yaml` (1.32): the upstream embedded config template of that minor, verbatim, plus an `s3store` provider, written to `/tmp` by the start script and loaded via `TEMPORAL_SERVER_CONFIG_FILE_PATH`. Keyless: the identity gets `aws.cloudAccountLink` + `policyRefs [cpln-connector, policyName]`; s3store uses the AWS default chain. The admin sidecar brings `default` to the state `archival.defaultNamespace` asks for on every boot, deciding from parsed `describe -o json` and logging each decision; an existing URI is kept, never overwritten. Refused at render on minor 30 (1.30.8 is a hop stop nobody ran with archival; 1.31.4 is live-proven with the 1.30 file, and its archive stays readable after the hop to 1.32.1). |

- Both start scripts are **inline args** (`_script-server.tpl`, `_script-admin.tpl`, `$` doubled by `temporal.inlineScript`); the upgrade adds no secret and no grant.
- The server runs `/etc/temporal/entrypoint.sh` as a **child** (TERM forwarded; SIGSTOP from inside works), with `TEMPORAL_BROADCAST_ADDRESS` set to the replica's own IP and a mandatory empty dynamic-config file in `/tmp`.

## Key knobs

| Knob | Default | Note |
|---|---|---|
| `image` / `adminTools.image` | `temporalio/server:1.32.1` / `temporalio/admin-tools:1.32.1` | Same tag, minor 30-32 only (render-enforced); auto-setup refused at render |
| `replicas` | 1 | 1-5; `rolloutOptions` (surge 1, unavailable 0, minReady 120, grace 90) rendered only when >1 |
| `historyShards` | 512 | Permanent: a later change is IGNORED, not refused (server logs `Supplied configuration key/value mismatches persisted cluster metadata`; the workload env then shows the ignored value) |
| `namespaceRetention` | 72h | Applied only when `default` is created |
| `ui.enabled` | true | |
| `archival.enabled` | false | Declares the S3 archiver (generated config) and adds the AWS binding to the identity. Needs minor ≥ 31. **Never turn it off once used** (V6): namespaces keep `s3://` URIs, every `default` update then fails `unable to find archiver config`, closes retry forever, archived reads 500. The identity keeps its AWS block (platform merge) |
| `archival.defaultNamespace` | true | Archive `default`; false = stop archiving (admin disables both states, URIs kept). The supported off switch |
| `archival.s3.*` | `my-temporal-archival-bucket` / us-east-1 / `temporal` / `my-s3-cloud-account` / `my-temporal-archival-policy` | URIs `s3://bucket[/prefix]/{history,visibility}`; prefix has no leading `/` or spaces |
| `ui.allowedCIDRs` | `[]` | Empty = internal-only (default render byte-identical to before the knob). Render refuses non-CIDR entries (strict IPv6), any `/0`, IPv4 broader than /8 or IPv6 broader than /32, and a list with `ui.enabled: false`. Entries are rendered quoted. The server workload is never opened |
| `internalAccess.type` | same-gvc | Server and UI. With workload-list the chart always prepends `//gvc/{gvc}/workload/{release}-temporal` (and `…-temporal-ui` when the UI is on) to the server's list: ringpop and internal RPC between replicas, and UI→server gRPC, go through that same firewall. Without it N≥2 split into single-member clusters (`ShardOwnershipLost`) and the UI was cut off (test round 1, T11). A change rolls every replica; enforcement follows the roll (~8 min at N=3) |
| `postgresHA.backup.resources.memory` | 512Mi | Was 128Mi, which OOMKills wal-g |
| `postgresHA.config.credentialsSecretName` / `postgres.config.credentialsSecretName` | `my-temporal-db-credentials` | REQUIRED prerequisite secret of the active mode; must exist before install (missing = silent wedge, only `get-deployments` `status.versions[].message` names it). `postgres.credentials` (removed in 2.1.0) fails the render with the replacement |

**DB connection budget (D6 A):** per-service pools are computed from `replicas` so N replicas plus one surge replica stay under the bundled DB's 100 connections (budget 84/(N+1)): main/vis per service 7/3, 5/2, 4/1, 3/1, 2/1 for N=1..5 (40/28/20/16/12 connections per replica). Not a values knob. 1.x ran 20/10 (up to 120 per replica) and could exhaust the DB under load. **Caveat:** a `replicas` change rolls every replica (the pool env vars change), and while old-N and new-N replicas coexist the total can pass 100 (2→4 ≈ 120); the README says to change `replicas` under light load.

## 2.1.0 — database credentials became a prerequisite secret (2026-10-16)

- **Rule (maintainer ruling 2026-10-14):** when the database subchart takes only a credentials-secret NAME, the parent requires the user to create that secret; no plaintext `postgres.credentials` turned into a chart secret. Mirrors unleash 1.5.0 / chatwoot 1.3.0.
- **`database` must be `temporal`** — 2.0.0 enforced it at render; the value now lives in the secret, so both start scripts enforce it at boot instead (`CPLN_TEMPORAL_DATABASE_GUARD`). Unproven live until the test round: the guard firing on a wrong key, and a correct key passing.
- **Upgrade trap:** 2.0.0 created the secret itself (named by the active mode's `credentialsSecretName`), so the 2.1.0 upgrade DELETES it. The user must create a NEW-name secret first with the current username/password and `database=temporal` (README snippet uses `RELEASE_NAME-postgres-credentials`, a name no earlier version created: 1.0.x HA used `{release}-postgres-config`, single `{release}-pg-config`, 1.1.0-2.0.0 `credentialsSecretName`). The wizard errors on an unchanged name when `context.fromVersion < 2.1.0`. Expect the bundled PostgreSQL to restart and a possible ~10 min `is not allowed to reveal the secret` wait on the new workload version (previous version keeps serving).
- **Rotation:** single-instance = `ALTER ROLE` → `cpln secret edit` → right away redeploy temporal only (tested 2026-10-16: 0 of 77 probes failed; the old order with a postgres redeploy cost 142 s). The boot guard leaves the wrongly-named database behind (harmless). `admin-tools` 1.32.1 has no `psql` — run DB checks from the postgres container. HA = the leader-switchover procedure in the README (move leader to `-0`, ALTER both roles incl. `repl`), then redeploy `RELEASE_NAME-temporal`. The UI reads no DB credentials.

## Feature round findings (2026-10-14)

- **Nexus** works with the empty dynamic config for endpoints targeting a namespace + task queue in this cluster: the callback is the internal `temporal://system` URL. External-URL endpoints would need `component.nexusoperations.callback.endpoint.template`; not offered.
- **Workflow Updates** work (CLI and the UI's update API). The UI dialog's Submit click did not fire from headless Chrome — an automation gap; a human click is the outstanding confirmation.
- **Worker Deployments / versioning** work on Python SDK 1.18; the UI Workers "Instances" tab (worker heartbeats) needs Python SDK ≥ 1.20.
- **The UI's Agents page is marketing** (static page in UI 2.55.0, no server API) — nothing to configure.
- **Archival mechanics:** without the s3store config a namespace with an `s3://` URI is refused (`unable to find archiver config for the given scheme`). Objects land ~2 min after close; `workflow show` of a run deleted from the primary store is served from S3. Namespace archival URIs can never change once enabled, so the admin step logs and continues if `default` already archives elsewhere. 1.32's embedded template differs from 1.30/1.31 outside sqlite (`clusterMetadata` rpc/http address uses the broadcast address), hence one file per template. Turning archival OFF via `archival.enabled: false` breaks `default` (V6); the split knob `archival.defaultNamespace` is the off switch. GCS (`gstore`) is untested.

## Troubleshooting / considerations

- **One minor at a time.** 1.x (server 1.29.7) → 2.0.0 is three upgrades: `--set` both images to 1.30.8, then 1.31.4, then defaults, ~10 min apart, at `replicas: 1`. The wizard lands a console upgrade from <2.0.0 on 1.30.8. A skip is refused under the lease, before any migration: the admin container logs `CPLN_TEMPORAL_SKIP_GUARD` with the next tag, sleeps 120 s and exits; the new replica never becomes ready.
- **"Not ready" → read the `admin` container.** "another replica is migrating the schema" is normal while one replica holds the lease. A holder that dies mid-migration leaves its lease to expire (3 min) and a resume marker; the next replica finishes the same-target migration instead of tripping the skip guard (a fresh install half-migrated to, e.g., visibility 1.7 is otherwise indistinguishable from an ancient DB — found and fixed at build).
- **The server waits at most 560 s for the schema gate**, inside its ~615 s readiness-derived startup window, so its FATAL always prints.
- **`tdbg membership list-gossip`** (from the admin container, `--address 127.0.0.1:7233`) shows ring members; there is no `list-members`.
- **Multi-replica rolls (1.32.1, measured):** ~8–9.5 min per roll at N=3 (surge 1, minReady 120), 0% client errors, 0 failed workflows, 0–3 worker-service restarts (`error starting scanner`) per roll, always on a freshly started replica within ~3.5 min. July's 60–90 min / ~5% on 1.29 + auto-setup no longer applies. **Root cause of the remaining restarts:** the worker service dials frontends by member pod IP on 7233, and the mesh resets pod-IP calls on that `grpc` port (`The server requires TLS` / Envoy `connection termination`) while the `tcp` cluster ports work. Re-declaring 7233 as `tcp` fixes the peer dial but breaks SDK long-polls, so it is not a fix. Follow-up spike: `USE_INTERNAL_FRONTEND=true` (internal frontend on 7236 / membership 6936, declared `tcp`), leaving client-facing 7233 as `grpc`.
- **Replica loss (measured, SIGSTOP at N=3):** membership drops in ≤19 s, the replica leaves service at ~54 s, liveness replaces it at ~4 min and it rejoins at ~4.5 min; 0.7% client timeouts in the first ~40 s; timers ≤0.21 s late.
- **First HA hop = ~148 s database outage.** 1.x → 2.0.0 also moves pg-ha 2.5.0 → 2.7.0, which rolls all Patroni members and fails the leader over (measured ha-0 → ha-2, timeline 1 → 2) AFTER the schema step finished: `no usable database connection found` for 148 s, plus a few `read-only transaction` errors. No data lost. Later hops and the single-Postgres path have no outage.
- **Workers need the full FQDN.** Python workers need the `__main__` guard.
- **No rollback after a hop migrates the schema.** Back up first through `postgresHA.backup` / `postgres.backup` (logical → S3 and wal-g → GCS verified). **Volume set snapshots are not a recovery path for HA:** a pre-upgrade `volumeset snapshot create` makes one snapshot per volume, restore is per volume, and restoring all three onto the running Patroni cluster left members on different timelines with the leader still serving post-upgrade data (test round 1, m4). An uninstall while a snapshot restore is `Restoring` can leave the release half-deleted; a second uninstall finished it.
- 1.32's visibility filters are stricter (type-mismatched or empty `Text` filters error). Upstream, not the template.
- Snapshots never run on the bundled DB (no schedule, work item 5219). Use `backup.*`.
- **pg-ha's local `max_connections: 100` is dead config** (Patroni takes it from the DCS only); flagged to the pg-ha owner. Raising the DB limit for throughput is the documented follow-up (D6 B), not built.
- **2.1.1: HA database image override for CVE-2026-103484 (work item 5376).** The vendored pg-ha 2.7.0 defaults to `patroni-postgres:0.7` (pgvector 0.8.0); 2.1.1 sets `postgresHA.image: controlplanecorporation/patroni-postgres:0.8` (pgvector 0.8.7) and keeps 2.7.0 because pg-ha 2.8.1 was not published yet. `temporal.validatePostgresHAImage` refuses tags 0.1–0.7, and an empty value (which would fall back to the subchart's 0.7), when HA is on (pg-ha 2.8.1's matching), mirrored in the wizard. Temporal does not use pgvector. The upgrade restarts the Patroni members (unconstrained stateful rollout), giving a brief write interruption while the leader changes; the HAProxy proxy workload does not restart (stays `Unchanged`; measured on the chatwoot and keycloak rounds). The app workload restarts as on any version upgrade; with a single server replica that is the longer interruption. Single-instance mode is unaffected. Drop the override when temporal vendors pg-ha 2.8.1+. E2E onboarded in 2.1.1 (`temporal/tests/`): checks call the HTTP API from the patroni container (start + describe a workflow, no worker needed).
