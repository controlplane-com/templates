# OpenSearch — maintainer briefing

**What it is.** A multi-node OpenSearch 3.8.0 cluster (search, log analytics and a self-hosted SIEM, Apache-2.0)
with the security plugin always on: a login, TLS on the API and between nodes, and a security audit log.
Security Analytics (Sigma-rule detectors, findings, alerts) ships in the image. Optional Dashboards UI (private
by default, optional public login page), demo log pipeline with a sample detector, and scheduled snapshots to
S3 or GCS. Deploys into an existing GVC.

**Common use cases.** Self-hosted SIEM over CloudTrail/VPC/DNS/Windows logs; log search with per-user roles;
application search and analytics where the user wants to own the index and the retention policy.

## Architecture

| Resource | Notes |
|---|---|
| workload `-opensearch` (stateful) | `replicas` nodes, HTTPS `9200` + TLS transport `9300` (both `tcp` ports: TLS passes through the mesh), `replicaDirect`, OrderedReady, `minReadySeconds: 60` |
| volumeset `-opensearch-vs` | per-node data directory, optional autoscaling; daily volume snapshots kept 7 d from 2.1.0 (none were ever taken through 2.0.0) |
| secret `-opensearch-startup` | startup script: issues certificates with `keytool` from the user's CA at every boot, writes the security config, reconciles `admin`/`kibanaserver` |
| node identity + policy | reveals startup, credentials and CA secrets; cloud binding only with backups |
| client identity + policy | Dashboards and both setup jobs; reveals the credentials secret only |
| workload `-opensearch-dashboard` *(optional)* | UI on `5601` with login; `publicAccess.enabled` opens it on a `*.cpln.app` endpoint |
| backup setup / demo pipeline *(optional)* | demo setup also creates log type `demo_app_logs`, a custom rule and detector `demo-auth-failures` |

Two prerequisite dictionary secrets: credentials (`password`, `dashboardsPassword`, `cookieSecret`) and the CA
(`keystore` = base64 PKCS#12, `passphrase`). One GVC location only; `replicas` must be odd.

## Key knobs (shipped defaults)

| Knob | Default | Notes |
|---|---|---|
| `security.credentialsSecretName` / `security.caSecretName` | `my-opensearch-credentials` / `my-opensearch-ca` | required; empty → render `fail` |
| `replicas` | `3` | must be odd |
| `resources` | `500m`/`2Gi` → `1`/`4Gi` | |
| `dashboard.resources` | `250m` / `1Gi` | raised from 100m/512Mi for the security plugin |
| `dashboard.publicAccess.enabled` | `false` | adds `cookie.secure=true` when on |
| `demoLogs.enabled`, `backup.enabled` | `false` | |

## Troubleshooting traps

- **Nodes stuck, no logs** → a prerequisite secret is missing; read `status.versions[].message`.
- **The secret is the source of truth for `admin` and `kibanaserver`.** Every node start PATCHes both users
  (with the admin client cert) and logs `security-reconcile: admin,kibanaserver updated`; a password changed
  in Dashboards reverts. The PATCH `add` replaces the whole user, so it must resend `reserved: true` (measured:
  without it the user loses its reserved flag). Rotation = update secret + `force-redeployment` nodes and Dashboards.
- **Dashboards opens in the Global tenant.** The same reconcile step sets `default_tenant: Global` only while it is
  unset (logs `default tenant set to Global`); a choice made under Security > Tenants > Configure is kept (measured).
- **Changing the CA is a full-cluster restart**: old and new nodes do not trust each other.
- **1.0.x → 2.0.0** breaks every client (https + login); mixed old/new nodes cannot talk. Measured: never red,
  API out ~2-5 min, roll ~11-12 min on 3 nodes, data kept. Old saved objects are in the **Global** tenant. Stall on new grants: wait ~5 min, then
  `force-redeployment`.
- **Restores must exclude `.opendistro_security`**, and never `_all/_close` (it closes the security index).
- **The template's own clients do not verify the server cert** (maintainer ruling Q2); users pin `ca.crt`.
- `_plugins/_security/api/ssl/certs` needs the admin CERT (basic-auth admin gets `FORBIDDEN`); the admin cert
  is deleted after reconcile, so checks read the transport cert with `keytool -printcert -sslserver :9300`.
- `internal_access.type: workload-list` always adds the chart's own workloads (nodes need it for 9300);
  the user list names extra clients only.
- Upstream 3.8.0 Dashboards bugs: **Create correlation rule** and **Add threat intel source** (local file)
  do nothing; the API works (README note).
- Audit and finding indices have no retention policy; add ISM if volume is high.
- Still from 1.0.x: enabling backups on a running cluster retries for a few minutes; switching
  `backup.provider` leaves the old cloud binding; the S3 policy needs both ARNs; use FQDN hostnames.

## Test status (2.0.0, `test-gvc`, 2026-11-17)

Rounds 1-3b: E2E 34/34 incl. 1.0.2 upgrade; drift clean; rotation, availability (rolling 2194/2194, master
kill 923/925), snapshots and restore, auth/TLS, CA not retained; demo pipeline parses and finds; browser:
Discover, Visualize/Dashboards, saved-object round trip, Query Workbench, Index Management, Advanced settings,
SA rules/detectors, Alerting → webhook, ISM, Reporting, PPL, Anomaly detection, tenants. Generic bundled
plugins (Maps, Search Relevance, Query Insights, Flow Framework, ML, Notebooks, Traces) skipped by ruling.

## What 2.1.0 changed

- Volume snapshots are scheduled, daily at 03:00 UTC by default (`volumeset.snapshots.schedule`, `""` = off; `retentionDuration` 7d). 2.0.0 and earlier rendered `retentionDuration` with no schedule, so the platform never took one (work item 5219). A schedule more frequent than hourly fails at render (`opensearch.validateSnapshots`, mirrored in the wizard); the API would reject it only at apply. These are platform volume snapshots, separate from the optional snapshot backups to S3/GCS. The demo-logs `shared` volumeset still takes none (demo data).
- E2E baseline `2.1.0` added (upgrade from 2.0.0).
