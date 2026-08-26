# PocketBase — Maintainer Briefing

## What it is
- **PocketBase** — an open-source backend that is a single executable: an embedded SQLite database, an auto-generated REST API over your collections, realtime updates, user authentication, file uploads, and a web admin dashboard. **MIT licensed** (permissive: no obligations for us or the user).
- Template ships v0.40.1, **one instance, no clustering** — that is upstream's design ("Horizontal scaling? Only on a single server, aka. vertical"), not a limitation we chose.

## Common use cases
- Backend for a mobile or single-page web app: collections, auth, and file uploads without writing a server.
- Prototype or internal tool that needs a real API in an afternoon.
- Small SaaS or intranet app — upstream measures 10,000+ live realtime connections on 2 vCPU / 4 GB.
- A lightweight alternative to a Postgres + API-server + auth-service stack when the team is small.

## Architecture on cpln
| Resource | Purpose |
|---|---|
| workload `{release}-pocketbase` (stateful, 1 replica, HTTP :8090) | The whole product: one container running `pocketbase serve` |
| volumeset `{release}-pocketbase-data` (ext4, 10 GiB) | `/pb_data` — SQLite database, uploaded files, local backup ZIPs; the snapshot schedule IS the backup story |
| identity `{release}-pocketbase-identity` + `-policy` | `reveal` on exactly one secret, nothing else — PocketBase talks to nothing but its own disk |
| *user-created* dictionary secret | `email`, `password`, `encryptionKey` — a prerequisite, **not** created by the chart |

- The container starts with `sh -c`: `superuser upsert` runs to completion, then `exec pocketbase serve`. The admin account therefore exists **before** the port is ever open — which is why `publicAccess` defaults to `true` with no unclaimed-admin window.
- `exec` makes pocketbase PID 1 so SIGTERM closes SQLite cleanly (verified in a local container: `/proc/1/cmdline` is the pocketbase process).
- No dependency on any other catalog template — PocketBase has no external datastore.

## Key knobs
`image` (`ghcr.io/muchobien/pocketbase:0.40.1`) · `resources.{minCpu 125m, maxCpu 500m, minMemory 256Mi, maxMemory 1Gi}` · `volumeset.capacity` (10 GiB) · `credentials.secretName` (**required prerequisite**, default `my-pocketbase-credentials`) · `backup.{enabled true, schedule "0 3 * * *", retention 7d}` · `cors.allowedOrigins` (`["*"]`) · `publicAccess.enabled` (**true**) · `internalAccess.type` (`same-gvc`). There is deliberately **no `replicas` knob**.

## Troubleshooting / considerations
- **Deployment stuck with zero logs = the prerequisite secret does not exist.** The container never starts, so there is nothing to log. The missing name appears only in `cpln workload get-deployments <wl> -o yaml` under `status.versions[].message`. It self-heals in up to about ten minutes after you create the secret (measured: 10 min 11 s), or force a redeployment to skip the wait.
- **The superuser password is re-applied from the secret on EVERY start.** Changing it in the dashboard is reverted at the next restart; changing it in the secret changes the login. (Same behavior as `n8n`, unlike `keycloak`/`metabase`, which are first-boot only.) This is the single most likely support call.
- **But a rotation does NOT take effect on its own — it needs a forced redeployment.** Measured: eleven minutes after rotating the secret the container still held the old environment, the old password still authenticated, and the workload reported `ready: true` throughout. No error, no warning. This reverses what CLAUDE.md claimed before 2026-08-25, and it is the trap most likely to be mistaken for "the rotation worked".
- **Never change `encryptionKey` after install.** It encrypts the SMTP password, OAuth2 client secrets, and S3 backup credentials stored inside the database; changing it orphans all of them.
- **Credential rules, measured against the pinned image:** password minimum is **8 characters** (`password: Must be at least 8 character(s).`); the encryption key must be a valid AES key length — 31 characters fails with `crypto/aes: invalid key size 31`. Upstream documents 32 and `openssl rand -hex 16` gives exactly that, so the README requires 32. A bad credential is a loud crash, not a silent skip (`set -e`).
- **Single instance, no HA — every upgrade is an outage of about 85 seconds.** One replica holds one block volume, so the new replica cannot start until the old one lets go; volume detach/attach dominates the gap. Measured three ways within a tight band: forced redeployment 88 s, `helm upgrade` 83 s, replica stop 87 s. Note CLAUDE.md's "~15-23 s for unplanned loss" is platform reschedule time and does NOT describe user-visible availability here.
- **Rescheduling is not data loss.** The same volume reattaches; the difference between us and HA is minutes of downtime, not durability.
- **Backups are volumeset snapshots** (nightly 03:00 UTC, 7-day retention, final snapshot on uninstall). They cover everything — database, uploads, and PocketBase's own local backup ZIPs, which land in `/pb_data/backups` (verified locally). PocketBase's S3 backups exist but are a dashboard setting (Settings → Backups) that this template deliberately does not configure — they live in DB settings with no flag or env var.
- **Realtime is Server-Sent Events, not WebSocket.** The platform exempts *upgraded* connections from the request timeout; SSE is not upgraded, so `timeoutSeconds: 600` (the platform max) is set deliberately. If a user reports "realtime keeps reconnecting", look here — and note PocketBase itself disconnects an idle stream after 5 minutes by design, with the SDK reconnecting automatically. **Now measured: the stream is cut at exactly 10 minutes** — `timeoutSeconds` is a hard ceiling on every realtime connection, proven causally by lowering it to 60 and seeing the identical stream cut at 60 s. No events are lost while open (10/10 delivered) and the cut is a clean EOF, so SDK clients reconnect transparently; a hand-rolled `EventSource` consumer must handle it.
- **Emails link to the wrong host until you set it.** Verification and password-reset links come from **Settings → Application → Application URL**, a database setting the chart cannot write. Set it at first login.
- **Uploads and local backups share the volumeset with the database.** A file-heavy app needs more than the 10 GiB default; there is no separate storage knob unless the user points PocketBase at S3 in the dashboard.
- **PocketBase core reads no environment variables.** The `PB_ADMIN_EMAIL`/`PB_ADMIN_PASSWORD` variables people find online are a feature of the community image's `entrypoint.sh`, which this chart overrides. Anything you want configured has to be a CLI flag or a dashboard setting.
- **Not an official image.** No official PocketBase image exists; we pin a well-used community build (`muchobien`) and override its entrypoint so we depend only on the binary at the pinned version. The pinned tag runs as **root** with no `USER` directive (verified: `id` → `uid=0`), which is why no `securityOptions.filesystemGroupId` is set. A user overriding `image` must supply one that runs as root with `pocketbase` on `PATH`.
