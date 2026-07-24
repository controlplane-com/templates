# Vaultwarden

This app deploys [Vaultwarden](https://github.com/dani-garcia/vaultwarden), a lightweight self-hosted password manager compatible with all official Bitwarden clients (browser, desktop, mobile). A single stateful workload with its SQLite database on a persistent volume, served over HTTPS on the canonical `*.cpln.app` endpoint.

## Architecture

- **Vaultwarden**: stateful workload, single replica, serving the web vault, APIs, and websocket notifications on port 80; `DOMAIN` is derived from the canonical endpoint at start.
- **Volumeset**: 10 GiB persistent volume at `/data` — SQLite database, attachments, sends, and RSA signing keys; a final snapshot is kept for 7 days on delete.
- **Start-script secret**: sets `DOMAIN` from the canonical endpoint at boot.
- **Identity + policy**: least-privilege `reveal` on exactly the mounted secrets (start script, plus your admin/SMTP secrets only when configured).

## Prerequisites

- None for a default install.
- **Optional — admin panel (`/admin`)**: an **opaque** secret (`encoding: plain`) in your org holding the argon2 hash of your admin token, created BEFORE install. Generate the hash with `docker run --rm -it vaultwarden/server:1.36.0 /vaultwarden hash` and store the full `$argon2...` output as-is (no `$$` doubling — that is docker-compose escaping and will break login here). Set the secret's name in `admin.tokenSecretName`.
- **Optional — authenticated SMTP**: a **dictionary** secret with exactly two keys, `username` and `password`, for your mail server. Set its name in `smtp.authSecretName`.

## Configuration

### Vaultwarden

```yaml
image: vaultwarden/server:1.36.0

resources:
  cpu: 500m
  memory: 512Mi
  minCpu: 125m
  minMemory: 256Mi

volumeset:
  capacity: 10                # GiB (minimum 10) — SQLite database, attachments, sends, and RSA keys

customDomain: ""              # full URL of a custom domain (e.g. https://vault.example.com); empty = canonical endpoint
```

### Sign-ups & invitations

```yaml
signups:
  allowed: true               # open registration — turn off after onboarding your users
  domainsWhitelist: []        # email domains that may register even when allowed=false, e.g. [mycompany.com]
  verify: false               # require email verification at registration (needs smtp.host)

invitations:
  allowed: true               # org owners can invite users; invited emails may register
```

### Admin panel

```yaml
admin:
  tokenSecretName: ""         # your pre-created opaque secret with the argon2 token hash (see Prerequisites); empty = /admin disabled
```

### SMTP

```yaml
smtp:
  host: ""                    # e.g. smtp.example.com; empty = all email features off
  port: 587
  security: starttls          # starttls, force_tls, off
  from: ""                    # sender address (required when host is set)
  authSecretName: ""          # your pre-created dictionary secret (see Prerequisites); empty = unauthenticated relay
```

### Privacy

```yaml
icons:
  disableDownload: false      # true = no favicon fetching (outbound requests reveal stored-site domains); clients show letter placeholders
```

### Access

```yaml
publicAccess:
  enabled: true               # Bitwarden clients connect via the canonical *.cpln.app HTTPS endpoint

internalAccess:               # internal firewall scope — keep closed for a password vault
  type: none                  # none, same-gvc, same-org, workload-list
  workloads: []               # used with workload-list, e.g. //gvc/GVC/workload/NAME
```

## Connecting

| What | Value |
|---|---|
| Web vault (public) | `https://<canonical>.cpln.app` — `status.canonicalEndpoint` of `{release}-vaultwarden` |
| Bitwarden apps | Set the self-hosted server URL to the same `https://<canonical>.cpln.app` |
| Admin panel (optional) | `https://<canonical>.cpln.app/admin` — log in with your plaintext admin token |
| Internal (if opened) | `http://{release}-vaultwarden.{gvc}.cpln.local:80` |
| Login | Account you register in the web vault (registration open by default) |

## Important Notes

- **Lock down registration after onboarding.** Sign-ups are open by default so the install works immediately — but that means anyone reaching the public endpoint can register. Once your users are on board, set `signups.allowed=false`, or restrict with `signups.domainsWhitelist` (whitelisted domains can register even with signups off).
- **Vault contents are end-to-end encrypted** with each user's master password — but master passwords are unrecoverable: without SMTP (password hint emails are off) a forgotten master password means a lost vault.
- **Admin panel settings override Helm values.** Saving settings in `/admin` writes `/data/config.json`, which silently wins over env vars from then on. If a values change does not take effect, delete that file to return control to values.
- **Do not change the domain casually** — passkey/WebAuthn logins are bound to the exact URL; switching between the canonical endpoint and a custom domain breaks them until re-registered.
- **No HA / multi-replica** — upstream does not support multiple instances, so the workload is pinned to 1 replica. Bitwarden apps keep a local offline copy of the vault, so users can read their vault through a brief restart.
- **No off-site backups in this version** — durability is the persistent volume plus snapshots (7-day retention, final snapshot on uninstall). Losing the volumeset loses the vault database and attachments.

## Links

- [Vaultwarden on GitHub](https://github.com/dani-garcia/vaultwarden)
- [Wiki / documentation](https://github.com/dani-garcia/vaultwarden/wiki)
- [Enabling the admin page](https://github.com/dani-garcia/vaultwarden/wiki/Enabling-admin-page)
- [SMTP configuration](https://github.com/dani-garcia/vaultwarden/wiki/SMTP-configuration)
- [Hardening guide](https://github.com/dani-garcia/vaultwarden/wiki/Hardening-Guide)
