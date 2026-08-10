# Grafana — Maintainer Briefing

## What it is
- Grafana OSS 13.1.1 — the standard open-source dashboarding + alerting UI. License: AGPL-3.0 (strong open source: anyone offering a modified version as a service must share their changes) — same as metabase/mimir, accepted precedent.
- **Scope guard:** it visualizes USER-OWNED data. Ships **zero dashboards and zero datasources** by design (proven live: `/api/datasources` → `[]`, `/api/search` → `[]` on a default install) — it must never mirror the console's built-in workload-metrics view.

## Common use cases
- The missing pane for the catalog's prometheus / thanos / mimir / otel-collector installs (all UI-less).
- Dashboards + user-defined alerting (Slack/PagerDuty/email/webhook) over the user's own databases (ClickHouse, Postgres, TimescaleDB…).
- Datasources-as-code: version-controlled datasource provisioning via values.
- Dashboarding the platform's own Prometheus-compatible metrics endpoint (custom app metrics, egress/cost series) alongside other datasources.
- Sharing dashboards with people who have no Control Plane org access (viewer accounts).

## Architecture on cpln
| Resource | Purpose |
|---|---|
| `{release}-grafana` (standard, :3000) | Grafana server; stateless (no volumeset), `replicas` instances over the shared DB |
| user-created opaque secrets (×2, **prerequisite**) | admin password (droppable via `admin.applyPassword: false` after first login) + datasource-encryption key (permanent); consumed as `.payload`, never created by the chart (1.2.0) |
| `{release}-grafana-datasources` secret | rendered datasource provisioning YAML, file-mounted at `/etc/grafana/provisioning/datasources/` — only when `datasources.definitions` is set |
| identity + policy | `reveal` on exactly the mounted secrets (admin, datasources, user credential secrets, SMTP password) |
| `postgresHA` subchart (default) / `postgres` subchart (alt) | app DB — ALL state lives here; exactly one must be enabled (XOR validated at render) |
| `redis` subchart (only when `redis.enabled`) | alerting-HA coordination via Sentinel; dedupes notifications across replicas |

- Image is `grafana/grafana:13.1.1` — NOT `grafana-oss:`; that repo never published 13.1.x (stops at 13.0.2). Identical OSS build.
- Public URL = canonical `*.cpln.app` endpoint; `GF_SERVER_ROOT_URL` derived at boot from `CPLN_GLOBAL_ENDPOINT` (verified single-scheme).

## Key knobs
| Knob | Default | Meaning |
|---|---|---|
| `replicas` | `1` | ≥2 = HA tier; **render-blocked unless `redis.enabled: true`** |
| `admin.user` | `admin` | login name, plain value; first-boot bootstrap only |
| `admin.applyPassword` | `true` | false = stop referencing the password secret (no env var, no policy grant) so it can be deleted after first login |
| `admin.passwordSecretName` | `my-grafana-admin-password` | **prerequisite** opaque secret with the first-boot admin password; required only while `applyPassword` is true |
| `admin.secretKeySecretName` | `my-grafana-secret-key` | **prerequisite** opaque secret with the AES key for stored datasource secrets — permanent, no toggle, write-once |
| `datasources.definitions` | `[]` | Grafana provisioning entries, passed through verbatim |
| `datasources.credentialSecrets` | `[]` | the credentials Grafana authenticates TO each datasource with; user-created dictionary secrets, each key exposed as an env var referenced as `$KEY` in `definitions` |
| `smtp.enabled` (+ `host/user/passwordSecretName/fromAddress/fromName`) | `false` | alert email; password via a prerequisite opaque secret |
| `publicAccess.enabled` / `internalAccess.type` | `true` / `same-gvc` | `none` and `workload-list` both enforced live |
| `postgresHA.enabled` / `postgres.enabled` | `true` / `false` | HA (3 Patroni + 3 etcd + HAProxy) vs single-instance; `postgresHA.proxy.enabled` must stay true |
| `redis.enabled` | `false` | Sentinel tier for alerting HA; auth knobs are validation-blocked in this version |
| `postgresHA.backup.*` / `postgres.backup.*` | `enabled: false` | subchart DB backups (logical or WAL-G) to S3/GCS/MinIO |

## Availability posture
- Multi-instance IS supported in OSS (shared-Postgres HA is upstream's documented setup), so the template ships a `replicas` knob: default 1, ≥2 = HA with **Redis-Sentinel-coordinated alerting** — not gossip mode, so no dependence on flaky per-replica DNS.
- Measured at `replicas: 2`: distinct peers registered in Redis, **exactly one notification per window (4 singles, zero doubles)**, and **0 non-200** across a full rolling restart (255 probes) and a replica kill (169 probes, replacement ready ~98 s).

## Troubleshooting / considerations
- **Admin password and encryption key are PREREQUISITE opaque secrets as of 1.2.0** (`admin.passwordSecretName` / `admin.secretKeySecretName`, consumed as `.payload`, n8n pattern). Neither value transits values or the Helm release — the admin login is public-internet-facing whenever `publicAccess.enabled: true`, and the encryption key cannot be rotated. **Both must exist BEFORE install or the deployment wedges** on a missing secret. 1.1.0's `admin.password` / `admin.secretKey` values and the chart-created `{release}-grafana-admin` dictionary secret are gone; the version bump is the migration (existing 1.1.0 installs are untouched).
- **The two prerequisite secrets have DIFFERENT lifecycles — this is the thing users get wrong.** `GF_SECURITY_ADMIN_PASSWORD` is honored only when the admin account is first created (upstream behavior; afterwards only the UI or `grafana-cli admin reset-admin-password` changes it), so `admin.applyPassword: false` drops both the env var and the policy target and the user may then delete that secret — tidb's `deployInitWorkload` shape. The **encryption key has no such toggle**: it is read on every boot, so deleting it wedges the workload on a missing `cpln://secret/…` reference. If someone reports a wedge after "cleaning up secrets", this is why.
- **The encryption-key secret is write-once.** It encrypts datasource credentials in the DB; changing its payload breaks every saved datasource secret ("Save & test" fails to decrypt). Back it up rather than rotating it.
- **Admin user/password apply on FIRST boot only.** Later changes to `admin.user` or to the password secret do not update the stored account — change the password in the UI.
- **`replicas >= 2` without `redis.enabled` is blocked at render** ("Redis Sentinel coordinates alerting HA…") — without it every replica evaluates rules independently and notifications double.
- **`root_url` is NOT derived when `publicAccess.enabled: false`** — `GF_SERVER_ROOT_URL` is simply not exported, so Grafana falls back to localhost and absolute links in alert emails from an internal-only + SMTP install point at localhost. Known v1 limitation; an internal-DNS fallback is a possible follow-up.
- **User confused about missing CPU/memory dashboards:** by design — workload metrics live in the console's built-in Grafana. If they want them in this pane, the README's *Platform metrics as a datasource* section covers it: create a **service account with the `readMetrics` org permission** and use its key (a workload's built-in `CPLN_TOKEN` will NOT authenticate to `metrics.cpln.io`), carried in a credential secret as a bearer header.
- **Credentialed datasources:** `datasources.credentialSecrets` is the single most-misread knob — it is what Grafana logs in to a datasource WITH (your Postgres password, a metrics bearer token), not user access to Grafana. It exists because `definitions` renders verbatim into a provisioning file, so a password typed there would be plaintext in values. Credentials never go in values — the user creates the dictionary secret first (`cpln secret create-dictionary --name my-grafana-ds-credentials --entry PG_PASSWORD=…`), lists its name + keys under `datasources.credentialSecrets`, and references `$KEY` in `secureJsonData`. The secret must exist before install or the deployment wedges. Provisioned datasources are read-only in the UI. Uninstall correctly leaves the user's secret alone.
- **SMTP is render- and policy-verified only** (no live mail server in the test run) — live send is unproven; `smtp.user` without `smtp.passwordSecretName` fails validation.
- **DB reinstall wipes everything** (dashboards, users, alert rules live in Postgres). Uninstall deletes the subchart volumesets; workload-only restarts/redeploys are safe (dashboard persistence across a full replica cycle verified).
- **Multi-replica: Grafana Live push updates degrade** (per-instance websockets land on one replica). Dashboards, queries, and alerting are unaffected.
- **Expected transient log noise:** a Postgres `connection reset` while pg-HA is still forming; ~6 s of `sentinel: GetMasterAddrByName … EOF` when redis+grafana cold-start in the same rollout; `Creating shutdown snapshot failed err=EOF` on draining old replicas. All self-recover; steady state is zero ERROR/WARN.
- **Convergence:** default pg-HA stack ready in ~6 min (etcd 11 s, pg-HA + proxy 85 s, then Grafana); redis+sentinel ~25 s; rolling restart ~2.5 min. Firewall changes take ~30 s to propagate.
- **Dashboards-as-code is a staged follow-up** (platform secret payload size limit undocumented; dashboard JSON can be 100s of KB). v1: import via UI/API — persisted in Postgres, survives restarts.
