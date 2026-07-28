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
| `{release}-gitea-env` (dictionary secret) | SECRET_KEY, INTERNAL_TOKEN, JWT_SECRET, admin user/pass/email |
| `{release}-gitea-bootstrap` (opaque secret) | Admin-bootstrap wrapper script |
| identity + policy | `reveal` scoped to the two gitea secrets + the postgres `{release}-pg-config` secret |
| `{release}-postgres` (postgres subchart) | Backing database — reused template, not bundled |

- Shape: single stateful Gitea replica + one Postgres (via the `postgres` dependency). `createsGvc: false`.
- Uses the **rootless** image (`gitea/gitea:1.27.1-rootless`): runs as UID 1000, built-in SSH server on 2222 — deliberately avoids the default image's root + OpenSSH-on-port-22.
- Public HTTPS UI via the auto `*.cpln.app` canonical endpoint. **Git-over-SSH is OFF by default** (`ssh.enabled: false`); when enabled it exposes SSH via `loadBalancer.direct` (externalPort 22 → containerPort 2222, `TCP`/`tcp`) — but see the endpoint trade-off below.

## Key knobs
| Knob | Effect |
|---|---|
| `gitea.admin.{username,password,email}` | First site-admin login (template-scoped; change before install) |
| `gitea.security.{secretKey,internalToken,jwtSecret}` | Stable app secrets — set once, never rotate |
| `gitea.disableRegistration` | `true` = admin-invite only; `false` = open sign-ups |
| `publicAccess.enabled` | Public HTTPS web UI + Git-over-HTTPS on the canonical endpoint |
| `ssh.enabled` (default **false**) / `ssh.externalPort` / `ssh.domain` | Opt-in public Git-over-SSH (raw-TCP LB) + advertised port/domain — takes over the endpoint (see below) |
| `postgres.*` | Pass-through to the backing `postgres` template (db name/creds/resources/storage) |

## Troubleshooting / considerations
- **Never rotate `gitea.security.secretKey` after install.** Changing it makes all encrypted data (2FA secrets, tokens, mirror creds) unreadable. It is a values-backed secret (not auto-generated) precisely so `helm upgrade` does not rotate it — cpln Helm has no `lookup`, so a random default would regenerate and corrupt state.
- **Change the three security values + admin password before first install.** The shipped defaults are illustrative placeholders (same convention as `langfuse`); a default install is insecure until overridden.
- **Single replica only — brief downtime on restart/upgrade.** HA needs a shared repo filesystem (RWX) across replicas, which cpln volumesets (per-replica) don't provide. Multi-instance is a **spiked follow-up**, not available in v1. Do not raise the workload's `minScale` above 1 — replicas would each get separate repo volumes and split-brain.
- **Public SSH and the public web UI cannot share the one canonical endpoint — SSH is OFF by default.** A workload has a single `*.cpln.app` endpoint, and it is either the L7 HTTPS ingress (web UI + Git-over-HTTPS) OR a raw-TCP LB (SSH on :22), not both. Enabling `ssh.enabled: true` repoints the endpoint to SSH and the public web UI on 443 becomes unreachable (verified in test). Leave SSH off (the default) unless you serve the web UI via a custom domain or only need Git-over-SSH. Git-over-HTTPS works fully regardless, so most users need nothing here.
- **SSH clone endpoint ≠ the web URL** (when SSH is on). The reachable SSH host is the `loadBalancer.direct` address from `cpln workload get {release}-gitea -o yaml` (status), on `ssh.externalPort`. Clone URLs advertise `ssh.domain` (defaults to the web domain) — set it to a custom domain pointing at the direct LB for clean `git@` URLs.
- **`INSTALL_LOCK` is on; there is no web install page.** The admin is created by the bootstrap script via `gitea admin user create`. If the admin login fails, check the workload logs for the bootstrap/migrate step and confirm the DB came up first.
- **Data lives on the volumeset; reinstalling under the same release reuses it.** To reset Gitea (e.g. after changing admin creds — the data dir keeps the original), `helm uninstall` (deletes the volumeset) then reinstall, or use a fresh release name.
- **Registry/packages and LFS work out of the box** (LFS stored on the local volume). External object storage for LFS is a follow-up.
- **Admin password change (post-install) is done in the Gitea UI**, not by editing values — the volumeset already holds the initialized account.
