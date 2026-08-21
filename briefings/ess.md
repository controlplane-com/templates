# ESS (External Secret Syncer) — maintainer briefing

**What it is.** Control Plane's own syncer: it pulls secrets from an external store — HashiCorp Vault, AWS
Parameter Store, AWS Secrets Manager, 1Password, Doppler, GCP Secret Manager — and materializes them as
Control Plane secrets on an interval.

**Common use cases.** Teams whose source of truth for secrets is already Vault or 1Password and who want
workloads to consume Control Plane secrets without hand-copying values or wiring a second auth path.

## Architecture

| Resource | Notes |
|---|---|
| workload `-ess` (standard) | the syncer, HTTP admin API on `port` (default `3004`), `/about` health check |
| identity + policy | see the blast-radius note below |

The chart creates **no secret of its own** from 2.1.0 — the sync configuration is the user's secret, mounted
at `/usr/src/app/sync.yaml`.

## Key knobs (shipped defaults)

| Knob | Default | Notes |
|---|---|---|
| `configSecretName` | `my-ess-config` | **prerequisite** `opaque` secret holding `sync.yaml` (2.1.0+) |
| `port` | `3004` | admin API: health checks and manual sync triggers |
| `allowedIp` | `1.2.3.4` | CIDRs allowed to reach the admin API externally — **replace it** |
| `resources` | `200m` / `256Mi` | |

## Troubleshooting traps

- **The sync config is a prerequisite `opaque` secret from 2.1.0.** It carries provider credentials — a Vault
  token, AWS keys, a 1Password service-account token — and through 2.0.0 it was the `essConfig` values block,
  so every one of them sat in the Helm release. An upgrade still carrying `essConfig` is refused at render.
  Anyone migrating should **rotate** the credentials that were in their values file.
- **Why the whole file and not individual keys:** `cpln://secret/...` is resolved only for environment
  variables. Inside a mounted configuration file it stays literal text, so there is no way to swap out just
  the token — the file itself has to be the secret. Same reasoning as pgedge's pgcat config.
- **The schema did not change.** Moving from 2.0.0 is a verbatim lift of the `essConfig` block into
  `sync.yaml`, minus the top-level `essConfig:` wrapper.
- **This template's identity holds `manage` on EVERY secret in the org** (`target: all`, `targetKind:
  secret`). That is inherent to what a syncer does — it creates and updates arbitrary Control Plane secrets —
  but it is the widest grant in the catalog, so treat the workload as security-sensitive: keep `allowedIp`
  narrow, and remember that anyone who can reach the admin API can trigger syncs.
- **`allowedIp` ships as `1.2.3.4`**, a placeholder that admits nothing. That is deliberate — the admin API
  should not be publicly reachable — but it means an operator who expects to curl it externally sees a
  connection failure rather than a permission error.
- **A missing prerequisite secret wedges the deployment silently** — `cpln logs` returns zero lines; read
  `status.versions[].message` from `cpln workload get-deployments RELEASE_NAME-ess`.
