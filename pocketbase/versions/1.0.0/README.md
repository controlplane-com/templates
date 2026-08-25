# PocketBase

This app deploys [PocketBase](https://pocketbase.io), an open-source backend that is a single executable: an embedded SQLite database, an auto-generated REST API over your collections, realtime subscriptions, user authentication, file storage, and a web admin dashboard. One stateful workload with its data directory on a persistent volume, served over HTTPS on the canonical `*.cpln.app` endpoint.

## Architecture

- **PocketBase**: stateful workload, **exactly one replica**, serving the REST API, realtime stream, and the `/_/` dashboard on port 8090.
- **Volumeset**: 10 GiB persistent volume at `/pb_data` — SQLite database, uploaded files, and any locally-stored backup ZIPs; snapshotted on a schedule, with a final snapshot on uninstall.
- **Identity + policy**: least-privilege `reveal` on exactly one secret — your credentials secret. PocketBase talks to nothing but its own disk.
- **Credentials secret**: *not created by this template* — you create it before install (see Prerequisites).

## Prerequisites

- **A dictionary secret holding the superuser login and the settings-encryption key**, created **before** you install. Name it in `credentials.secretName`. It must have exactly these three keys:

  | Key | Value |
  |---|---|
  | `email` | superuser email for the `/_/` dashboard |
  | `password` | superuser password — **at least 8 characters** |
  | `encryptionKey` | **exactly 32 characters** — encrypts SMTP, OAuth2, and S3 settings at rest |

  ```bash
  cpln secret create-dictionary --name my-pocketbase-credentials \
    --entry email=admin@example.com \
    --entry password='choose-a-strong-password' \
    --entry encryptionKey="$(openssl rand -hex 16)"
  ```

  `openssl rand -hex 16` produces exactly the 32 characters PocketBase requires.

- **If the secret does not exist, the deployment wedges silently.** The container never starts, so `cpln logs` returns **zero lines** — not an error, nothing. The missing secret is named in only one place:

  ```bash
  cpln workload get-deployments {release}-pocketbase --gvc {gvc} -o yaml
  ```

  under `status.versions[].message`. Create the secret and the deployment recovers by itself in roughly 5–10 minutes, or run `cpln workload force-redeployment {release}-pocketbase --gvc {gvc}` to skip the wait.

## Configuration

### PocketBase

```yaml
image: ghcr.io/muchobien/pocketbase:0.40.1 # must run as root with `pocketbase` on PATH

resources:
  maxCpu: 500m
  maxMemory: 1Gi
  minCpu: 125m                # ratio to maxCpu may not exceed 4:1 on a stateful workload
  minMemory: 256Mi

volumeset:
  capacity: 10                # GiB (minimum 10) — SQLite database, uploaded files, and any local backups
```

### Credentials

```yaml
credentials:
  secretName: my-pocketbase-credentials   # your pre-created dictionary secret (see Prerequisites) — must exist BEFORE install
```

### Backup

```yaml
backup:
  enabled: true               # periodic snapshots of the data volume (platform-managed, no bucket needed)
  schedule: "0 3 * * *"       # cron in UTC — default daily at 03:00 (hourly is the most frequent the platform allows)
  retention: 7d               # how long each snapshot is kept (e.g. 7d, 720h, 30d)
```

### API

```yaml
cors:
  allowedOrigins:             # browser origins allowed to call the API; ["*"] allows any
    - "*"
```

### Access

```yaml
publicAccess:
  enabled: true               # REST API, realtime and the /_/ dashboard on the canonical *.cpln.app HTTPS endpoint

internalAccess:               # internal firewall scope (in-GVC callers of the API)
  type: same-gvc              # none, same-gvc, same-org, workload-list
  workloads: []               # used with workload-list, e.g. //gvc/GVC_NAME/workload/WORKLOAD_NAME
```

## Connecting

| What | Value |
|---|---|
| Public base URL | `https://<canonical>.cpln.app` — `status.canonicalEndpoint` of `{release}-pocketbase` |
| Admin dashboard | `https://<canonical>.cpln.app/_/` |
| REST API | `https://<canonical>.cpln.app/api/` |
| Health check | `GET /api/health` — no auth, always 200 |
| Internal (in-GVC) | `http://{release}-pocketbase.{gvc}.cpln.local:8090` (use the fully qualified name) |
| Credentials | The `email` and `password` entries of your `credentials.secretName` secret |
| Private install | `cpln port-forward {release}-pocketbase 8090:8090 --gvc {gvc}`, then open `http://localhost:8090/_/` |

## First steps after install

1. Sign in at `/_/` with the `email` and `password` from your secret.
2. Set **Settings → Application → Application URL** to your public endpoint. Verification and password-reset emails build their links from it, so until you set it they point at the wrong host. It is a database setting, so this template cannot write it for you.
3. Configure SMTP and any OAuth2 providers under **Settings** — these live in the database too, not in Helm values. They are encrypted at rest with your `encryptionKey`.
4. Create your collections and their API rules. New collections are superuser-only until you write a rule that opens them.
5. Optionally point PocketBase's own scheduled backups at S3 under **Settings → Backups** if you want an off-platform copy in addition to the volume snapshots.

## Important Notes

- **Single instance, no HA — this does not scale horizontally.** PocketBase is single-server by design (embedded SQLite, no clustering), and each stateful replica on this platform would get its own volume and therefore its own empty database. There is deliberately no `replicas` knob. Every `helm upgrade` that changes the container spec is a short full outage while the one replica hands the volume over; a node reschedule and a secret rotation cost the same gap. Data is not at risk — the same volume reattaches.
- **The superuser password is re-applied from the secret on EVERY start.** Changing it in the dashboard is reverted at the next restart — change it in the secret instead. Note that changing the secret changes your login, and that updating a referenced secret restarts the workload by itself.
- **Never change `encryptionKey` after install.** It encrypts the SMTP password, OAuth2 client secrets, and S3 backup credentials stored inside the database; changing it orphans all of them with no way back.
- **Uploads and local backup ZIPs share the volume with the database.** A file-heavy app needs more than the 10 GiB default; raise `volumeset.capacity` at install time.
- **Backups are platform volume snapshots**, not off-site copies — they live in the platform storage layer alongside the volume. For an off-platform copy, use PocketBase's own S3 backups under Settings → Backups.
- **Access-knob changes take up to about five minutes to propagate.** After changing `publicAccess` or `internalAccess`, re-poll rather than trusting the first response.
- **This is not an official image** — no official PocketBase image exists. This template pins a well-used community build and overrides its entrypoint, so it depends only on the pinned binary. If you override `image`, it must run as root with `pocketbase` on `PATH`.

## Links

- [PocketBase documentation](https://pocketbase.io/docs/)
- [Going to production](https://pocketbase.io/docs/going-to-production/)
- [REST API reference](https://pocketbase.io/docs/api-records/)
- [Realtime API (Server-Sent Events)](https://pocketbase.io/docs/api-realtime/)
- [FAQ — scaling and SQLite](https://pocketbase.io/faq/)
