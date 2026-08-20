# Gitea — Maintainer Briefing

## What it is
- Lightweight self-hosted Git service (repos, pull requests, issues, built-in package registry) — the "lean self-hosted GitHub." Fills the previously-empty developer-tooling category.
- License: **MIT** (free for any use, including commercial and managed hosting, no obligations).

## Common use cases
- Internal/team Git hosting with a web UI and code review.
- Git-over-HTTPS and Git-over-SSH for clone/push.
- Private container/package registry (works on the same HTTP port, no extra config).
- Self-hosted alternative to GitHub/GitLab for small-to-medium teams.

## Architecture on cpln
| Resource | Purpose |
|---|---|
| `{release}-gitea` (stateful, 1 replica) | Gitea server: http 3000 (UI + Git-over-HTTPS + registry), tcp 2222 (SSH) |
| volumeset `/var/lib/gitea` (20 GiB) | Repos, LFS, attachments, built-in SSH host keys |
| auth secret (dictionary, **user-created**) | `adminUsername/Password/Email`, `secretKey`, `internalToken`, `jwtSecret` — named by `gitea.auth.secretName`, NOT created by the chart |
| `{release}-gitea-bootstrap` (opaque secret) | Admin-bootstrap wrapper script |
| identity + policy | `reveal` scoped to the bootstrap script, the DB credential secret, and the user's auth secret by name |
| `my-gitea-db-credentials` (dictionary, **chart-created**, 1.2.0+) | `username`/`password`/`database` for the bundled DB; built from `postgres.credentials.*` and handed to the postgres subchart by name |
| `{release}-postgres` (postgres subchart, **3.4.1** since 1.2.0) | Backing database — reused template, not bundled |

- Shape: single stateful Gitea replica + one Postgres (via the `postgres` dependency). `createsGvc: false`.
- Uses the **rootless** image (`gitea/gitea:1.27.1-rootless`): runs as UID 1000, built-in SSH server on 2222 — deliberately avoids the default image's root + OpenSSH-on-port-22.
- Public HTTPS UI via the auto `*.cpln.app` canonical endpoint. **Git-over-SSH is OFF by default** (`ssh.enabled: false`); when enabled it exposes SSH via `loadBalancer.direct` (externalPort 22 → containerPort 2222, `TCP`/`tcp`) — but see the endpoint trade-off below.

## Key knobs
| Knob | Effect |
|---|---|
| `gitea.auth.secretName` (default `my-gitea-auth`) | REQUIRED prerequisite dictionary secret: admin login + the three signing keys. Must exist BEFORE install |
| `gitea.disableRegistration` | `true` = admin-invite only; `false` = open sign-ups |
| `publicAccess.enabled` | Public HTTPS web UI + Git-over-HTTPS on the canonical endpoint |
| `ssh.enabled` (default **false**) / `ssh.externalPort` / `ssh.domain` | Opt-in public Git-over-SSH (raw-TCP LB) + advertised port/domain — takes over the endpoint (see below) |
| `postgres.credentials.{username,password,database}` | **1.2.0** — was `postgres.config.*`; bundled plumbing, still plain values |
| `postgres.config.credentialsSecretName` (default `my-gitea-db-credentials`) | **1.2.0** — name of the dictionary secret the CHART creates and the subchart reads; org-wide, so unique per release |
| `postgres.*` (resources, volumeset, image) | Pass-through to the backing `postgres` template |

## Troubleshooting / considerations
- **Since 1.1.0 the admin login and all three signing keys live in a PREREQUISITE dictionary secret** named by `gitea.auth.secretName` — the chart creates no credential secret at all. `gitea.admin.*` and `gitea.security.*` were removed with `fail` guards naming each replacement; there are no compatibility shims.
- **A missing prerequisite secret wedges the deploy SILENTLY.** `cpln logs` returns zero lines (the container never starts). The only diagnostic is `status.versions[].message` from `cpln workload get-deployments {release}-gitea --gvc {gvc} -o yaml` — note **`get-deployments`**, plain `get` has no `versions` key. Self-heals in ~6-8 min once the secret exists, or ~90 s with `force-redeployment`.
- **`jwtSecret` has a HARD FORMAT: base64url of exactly 32 bytes.** Gitea's `DecodeJwtSecretBase64` errors on any other length. `openssl rand -base64 32 | tr '+/' '-_' | tr -d '='` produces it. `secretKey` and `internalToken` are format-free — `secretKey` is PBKDF2'd, `internalToken` is a plain constant-time string compare — so `openssl rand -hex 32` suits both (confirmed against upstream `modules/generate` and `routers/private/internal.go`, 2026-08-19; the older "run `gitea generate secret`" advice needs the gitea binary and is no longer the documented path).
- **Never rotate `secretKey` or `jwtSecret` after install.** A new `secretKey` makes all encrypted data (2FA secrets, tokens, mirror creds) permanently unreadable; a new `jwtSecret` invalidates issued OAuth2 tokens. For an install still carrying the published 1.0.0 defaults, the safe path is a fresh 1.1.0 install plus repo migration, not a key swap.
- **Editing the auth secret after first boot does NOT change the admin login.** The account is created once by the bootstrap script; the data directory keeps it. Password changes happen in the Gitea UI.
- **Single replica only — brief downtime on restart/upgrade.** HA needs a shared repo filesystem (RWX) across replicas, which cpln volumesets (per-replica) don't provide. Multi-instance is a **spiked follow-up**, not available in v1. Do not raise the workload's `minScale` above 1 — replicas would each get separate repo volumes and split-brain.
- **Public SSH and the public web UI cannot share the one canonical endpoint — SSH is OFF by default.** A workload has a single `*.cpln.app` endpoint, and it is either the L7 HTTPS ingress (web UI + Git-over-HTTPS) OR a raw-TCP LB (SSH on :22), not both. Enabling `ssh.enabled: true` repoints the endpoint to SSH and the public web UI on 443 becomes unreachable (verified in test). Leave SSH off (the default) unless you serve the web UI via a custom domain or only need Git-over-SSH. Git-over-HTTPS works fully regardless, so most users need nothing here.
- **SSH clone endpoint ≠ the web URL** (when SSH is on). The reachable SSH host is the `loadBalancer.direct` address from `cpln workload get {release}-gitea -o yaml` (status), on `ssh.externalPort`. Clone URLs advertise `ssh.domain` (defaults to the web domain) — set it to a custom domain pointing at the direct LB for clean `git@` URLs.
- **`INSTALL_LOCK` is on; there is no web install page.** The admin is created by the bootstrap script via `gitea admin user create`. If the admin login fails, check the workload logs for the bootstrap/migrate step and confirm the DB came up first.
- **Data lives on the volumeset; reinstalling under the same release reuses it.** To reset Gitea (e.g. after changing admin creds — the data dir keeps the original), `helm uninstall` (deletes the volumeset) then reinstall, or use a fresh release name.
- **Registry/packages and LFS work out of the box** (LFS stored on the local volume). External object storage for LFS is a follow-up.
- **Public access is ON by default and that is deliberate** (reviewed 2026-08-19): Git-over-HTTPS clone/push from laptops and CI is the service's purpose, self-registration is closed by default, and after 1.1.0 there is no published default credential to protect against. `publicAccess.enabled: false` works — reach the UI with `cpln port-forward {release}-gitea 3000:3000 --gvc {gvc}`.
- **`appVersion` is `1.27.1-rootless`** (corrected in 1.1.0) — it must match the actual image tag, and the rootless variant is what ships.
- **Bundled Postgres credentials are still plain values** (`postgres.credentials.*`, placeholder `change-me-gitea-db`): the database serves Gitea only, is unreachable outside the GVC, and no human ever types the password — the bundled-plumbing exception.
- **1.2.0 adopted postgres 3.4.1 and absorbed the break rather than passing it on.** 3.4.0 deleted its `{release}-pg-config` secret and now takes only a secret NAME. Because a parent cannot template a subchart value, the name is a plain value (`postgres.config.credentialsSecretName`) that BOTH sides read: gitea's `secret-db.yaml` renders it, the subchart's env refs and policy consume it, and `gitea.secretPostgres.name` points the app at it. Net user-visible change is one rename (`postgres.config.*` → `postgres.credentials.*`); **no new prerequisite**. The auth secret (1.1.0) is untouched.
- **The DB secret name is org-wide, not release-scoped** (forced by the Helm limitation above). Two gitea releases in one org left at the default both render `my-gitea-db-credentials`, and the second install is **REFUSED** (`cannot be updated because it is being managed by a different release`) and creates nothing — nothing is shared, overwritten or deleted, and the first release is unaffected.
- **A stale 1.1.x values file fails with the SUBCHART's message, not gitea's.** Helm renders `charts/…` before `templates/…`, so the postgres chart's "create a dictionary secret" advice always wins — wrong here, since this template creates it. The README's "Upgrading from 1.1.0" table carries the correction; a parent-side guard would be dead code.
