# OpenBao — Maintainer Briefing

## What it is
- Linux Foundation open-source fork of HashiCorp Vault: an infrastructure secrets engine (stores secrets, issues database credentials on demand, signs certificates, encrypts data via API) with a Vault-compatible API/CLI. License: MPL-2.0 (permissive open source with per-file share-back; no paid tiers or registration).
- Not the same job as infisical: infisical = app-secrets workflow (UI, environments, developer ergonomics); OpenBao = the engine underneath (dynamic credentials, PKI — certificate issuance, transit — encryption-as-a-service, plus drop-in compatibility for existing Vault tooling). Teams migrating off Vault want this, not infisical; they complement each other in the catalog.

## Common use cases
- Drop-in replacement for HashiCorp Vault (Vault went BSL — source-available, no longer open source) using existing Vault agents/CLI/integrations.
- Dynamic short-lived database credentials instead of shared static passwords.
- Internal PKI: issue and rotate TLS certificates for services.
- Transit encryption: apps call the API to encrypt/decrypt without holding keys.

## Architecture on cpln
| Resource | Purpose |
|---|---|
| `{release}-openbao` (stateful, 1 replica, :8200) | `openbao/openbao:2.6.1` — HTTP API + web UI; runs non-root (`uid 100 openbao`, `filesystemGroupId: 1000`) |
| `{release}-openbao-data` volumeset (10Gi) | raft data (integrated storage) at `/openbao/data`; final snapshot retained 7 days |
| `{release}-openbao-config` secret (opaque) | rendered HCL server config, file-mounted |
| `{release}-openbao-identity` / `-policy` | `reveal` on exactly the config (+ unseal-key secret in static mode); carries the cloud-account link in KMS modes |

- Container TLS off; the platform edge terminates HTTPS on the `*.cpln.app` endpoint, mesh mTLS covers internal traffic. Public access is OFF by default.
- No dependencies, no GVC created.

## Key knobs
| Knob | Default | Meaning |
|---|---|---|
| `openbao.image` | `openbao/openbao:2.6.1` | 2.6.x pinned deliberately (see 2.7 note below) |
| `openbao.resources.*` | 250m/1000m · 256Mi/1Gi | minCpu:cpu is exactly 4:1 — the platform cap; do not widen |
| `seal.type` | `static` | auto-unseal mode: `static` \| `awskms` \| `gcpckms` — all three live-verified |
| `seal.static.secretName` | `my-openbao-unseal-key` | prerequisite opaque secret with a 32-byte key |
| `seal.aws.{kmsKeyId,region,cloudAccountName,policyName}` | placeholder ARN / `us-east-1` / `my-aws-cloud-account` / `my-openbao-kms-policy` | keyless KMS via cloud account + a customer-managed key-scoped IAM policy |
| `seal.gcp.{project,region,keyRing,cryptoKey,cloudAccountName}` | placeholders (`region: global`) | keyless Cloud KMS; needs the post-install key grant below |
| `volumeset.capacity` | `10` | GiB of raft data (minimum 10) |
| `publicAccess.enabled` / `internalAccess.type` | `false` / `same-gvc` | private by default; `workload-list` + `internalAccess.workloads` tested (allow AND deny) |

Prerequisite secret (static mode), exact form:
`printf '%s' "$(openssl rand -hex 32)" | cpln secret create-opaque --name my-openbao-unseal-key --encoding plain -f -`

## Availability posture
- **Single replica in v1. No `replicas` knob.** Raft HA (multi-replica with quorum) IS supported in OSS, but peer join needs per-replica DNS, which has known platform routing flakiness — HA is a spike-gated follow-up. Recovery today = one container boot + auto-unseal: measured 104–126 s from a forced redeploy to unsealed-and-serving, zero manual steps, in every seal mode.

## Troubleshooting / considerations
- **Unseal key is WRITE-ONCE** (static mode): it decrypts the whole data store on every boot. Lost or rotated-in-place key = all data permanently unrecoverable. Same class as infisical's `ENCRYPTION_KEY`. The prerequisite secret must exist BEFORE install — a missing secret wedges the deployment and looks broken. Uninstall leaves the user's secret intact (verified).
- **One-time init is expected**: a fresh install sits uninitialized (health 501) until `bao operator init` runs once. That prints 5 recovery keys + the root token to the operator's terminal only — never stored by the template; close the window without saving and only wiping the volumeset recovers.
- **Sealed/uninitialized ≠ crashed**: probes are tuned so those states stay ready and reachable (readiness uses `?standbyok=true&sealedcode=200&uninitcode=200`; liveness is TCP-only). Install→ready is ~31–33 s while still uninitialized. Do not "fix" a 501/503 health response by restarting.
- **`gcpckms` needs a POST-INSTALL key grant — the workload crash-loops until it exists.** The identity ships with **no `gcp.bindings`** (Cloud KMS resources are NOT a valid Control Plane identity binding target — every `//cloudkms.googleapis.com/...` form is rejected with `Unsupported resourceName`); the platform materializes the service account from `cloudAccountLink` alone. After install the user reads `status.objectName` from the identity and grants **BOTH** `roles/cloudkms.cryptoKeyEncrypterDecrypter` **and** `roles/cloudkms.viewer` on the ONE key to `{objectName}@{project}.iam.gserviceaccount.com`. Encrypt/decrypt alone is not enough — OpenBao calls `cloudkms.cryptoKeys.get` at startup and exits(1) without it. The workload self-heals ~30 s after the grant, no redeploy needed.
- **A broken gcpckms config installs "successfully".** The binding/permission failure surfaces asynchronously, so `cpln helm install` reports success while the workload crash-loops. Diagnose with `cpln identity get {release}-openbao-identity -o yaml` → `status.gcp.usable` / `lastError`. Also a behavioral asymmetry worth knowing: in `awskms` a bad key still yields a READY, uninitialized server, but `gcpckms` exits at seal configuration.
- **`awskms` needs no post-install step** — the identity carries `cloudAccountLink` + `policyRefs: [cpln-connector, {policyName}]` and is usable on first apply. Least privilege confirmed at the AWS layer: the materialized role holds exactly `cpln-connector` + the key-scoped customer policy, zero inline policies, no `ReadOnlyAccess`.
- **Keyless is genuine in both KMS modes** — the container has no `AWS_*`, `GOOGLE_*`, or `GCLOUD_*` variable and no `BAO_UNSEAL_KEY`; init/unseal reach KMS through the cloud-account identity.
- **Pinned to 2.6.x on purpose**: OpenBao 2.7 moves the built-in KMS seal mechanisms — including AWS auto-unseal — into external plugins. Every KMS-mode boot logs the upstream `Support for this Auto Unseal mechanism has been moved into an external plugin` WARN; harmless on 2.6.1 and the reason for the pin. Never bump to 2.7 without wiring the external seal plugin.
- **Do not switch `seal.type` after initialization** — the seal wraps existing data; changing modes needs an OpenBao seal migration, not a values change.
- **Uninstall deletes the volumeset** (all stored secrets); the 7-day final snapshot is the only rollback for an accidental uninstall. A reinstall starts uninitialized.
- Cosmetic log noise that is not a fault: `raft FSM db file has wider permissions than needed` (setgid volumeset dir), and single-node-raft drain churn (`unlocking HA lock failed: cannot find peer`, `Raft RPC layer closed`) during replica replacement.
