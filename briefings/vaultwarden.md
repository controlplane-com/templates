# Vaultwarden — Maintainer Briefing

## What it is

- Lightweight self-hosted password-manager server, compatible with all official Bitwarden apps (browser, desktop, mobile). ~59k GitHub stars; the de-facto self-hosted vault.
- License: AGPL-3.0 (a strong open-source license: free to self-host with no keys or gating; share-your-changes obligations only apply to modified versions offered to others, which we never ship).

## Common use cases

- Team/company password vault without paying per-seat Bitwarden cloud fees
- Personal/family credential storage under your own control
- Storing shared secrets (logins, cards, notes, file attachments) with org-based sharing
- Encrypted one-time text/file sharing via Bitwarden "Send"

## Architecture on cpln

| Resource | Purpose |
|---|---|
| workload `{release}-vaultwarden` | the server — exactly 1 replica, stateful, port 80 |
| volumeset `{release}-vaultwarden-data` | `/data`: SQLite database (a single-file database, upstream default), attachments, signing keys |
| secret (start script) | sets `DOMAIN` from the canonical endpoint at boot |
| identity + policy | secret-read rights on only the secrets actually mounted |

- Single replica, hard-capped: upstream does not support running multiple instances (replicas can't share the data disk or notify each other of changes). Availability posture: brief downtime is tolerated by design — Bitwarden apps keep a local offline copy of the vault, so users are never locked out during a restart.
- Vault contents are end-to-end encrypted (only the user's master password can decrypt them — server compromise does not expose stored passwords).

## Key knobs

| Knob | Default | Meaning |
|---|---|---|
| `signups.allowed` | `true` | open registration ON by maintainer ruling (usability) — turn off after onboarding |
| `signups.domainsWhitelist` | `[]` | email domains that may register anyway — main onboarding path |
| `admin.tokenSecretName` | `""` | `/admin` panel off; set to a pre-created secret holding an argon2 hash (a scrambled, uncrackable form of the token) to enable |
| `smtp.*` / `smtp.authSecretName` | off | outgoing email (invites, verification) via user's mail server |
| `icons.disableDownload` | `false` | website icons fetched by default; set true for privacy (fetching reveals which sites users store) |
| `publicAccess.enabled` | `true` | required — apps connect over the public HTTPS endpoint |

## Troubleshooting / considerations

- **Signups are OPEN by default** (maintainer ruling: usability first) — the vault registration page is internet-reachable on the public endpoint. The documented post-onboarding step: set `signups.allowed=false` or restrict with `signups.domainsWhitelist`.
- **Admin panel settings override Helm values.** Saving settings in `/admin` writes `/data/config.json`, which silently wins over env vars from then on. If a values change "doesn't take", check for that file (delete it to return control to values).
- **Admin token hash goes in raw.** Store the argon2 output (starts with `$argon2`) as-is in the secret — the `$$` doubling advice in upstream docs is for docker-compose only and will break login here.
- **Never change the domain casually.** Passkey/WebAuthn logins (fingerprint/security-key sign-in) are bound to the exact URL; moving from canonical endpoint to a custom domain breaks them until re-registered.
- **Backups = scheduled volumeset snapshots** (platform-native, default daily / 7-day retention, hourly is the platform minimum) + a final snapshot on uninstall. Crash-consistent; SQLite recovers cleanly (test-proven: restore recovered the vault, canary cipher decrypted intact). Restore is in-place via `cpln volumeset snapshot restore` (~90s workload restart). Snapshots are IN-PLATFORM, not off-site — losing the whole GVC loses them too; off-cluster object-storage backup is a possible follow-up.
- **`rsa_key.pem` on the volumeset signs login sessions** — it persists across restarts; a wiped volumeset logs everyone out (data loss aside).
- **Websocket live-sync** (instant updates across open apps) rides the same HTTPS port; if a client only updates on manual sync, check the websocket upgrade isn't being rejected at the edge (known Envoy Host-header quirk class).
- **HTTPS is mandatory** for apps and passkeys — the canonical `*.cpln.app` endpoint provides it; there is no plain-HTTP mode.
- Follow-ups staged (not v1): PostgreSQL backend for large installs (does NOT unlock multi-replica), mobile push relay (needs bitwarden.com credentials; untestable without a real phone), off-site/object-storage backups (v1 has in-platform scheduled snapshots), SSO (single-sign-on — still experimental upstream).
