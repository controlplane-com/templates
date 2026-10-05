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
  | `encryptionKey` | a random **32-character** string (the AES-256 key PocketBase documents) — encrypts SMTP, OAuth2, and S3 settings at rest |

  ```bash
  cpln secret create-dictionary --name my-pocketbase-credentials \
    --entry email=admin@example.com \
    --entry password='choose-a-strong-password' \
    --entry encryptionKey="$(openssl rand -hex 16)"
  ```

  `openssl rand -hex 16` produces a 32-character key. Other lengths are not safe to rely on — an invalid AES key length crashes the container at start.

- **If the secret does not exist, the deployment wedges silently.** The container never starts, so `cpln logs` returns **zero lines** — not an error, nothing. The missing secret is named in only one place:

  ```bash
  cpln workload get-deployments RELEASE_NAME-pocketbase --gvc GVC_NAME -o yaml
  ```

  under `status.versions[].message`. Create the secret and the deployment recovers by itself in up to about ten minutes, or run `cpln workload force-redeployment RELEASE_NAME-pocketbase --gvc GVC_NAME` to skip the wait.

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
| Public base URL | the canonical endpoint — read `status.canonicalEndpoint` from `cpln workload get RELEASE_NAME-pocketbase --gvc GVC_NAME -o yaml` |
| Admin dashboard | the canonical endpoint + `/_/` |
| REST API | the canonical endpoint + `/api/` |
| Health check | `GET /api/health` — no auth, always 200 |
| Internal (in-GVC) | `http://RELEASE_NAME-pocketbase.GVC_NAME.cpln.local:8090` (use the fully qualified name) |
| Credentials | The `email` and `password` entries of your `credentials.secretName` secret |
| Private install | `cpln port-forward RELEASE_NAME-pocketbase 8090:8090 --gvc GVC_NAME`, then open `http://localhost:8090/_/` |

## First steps after install

1. Sign in at `/_/` with the `email` and `password` from your secret.
2. Set **Settings → Application → Application URL** to your public endpoint. Verification and password-reset emails build their links from it, so until you set it they point at the wrong host. It is a database setting, so this template cannot write it for you.
3. Configure SMTP and any OAuth2 providers under **Settings** — these live in the database too, not in Helm values. They are encrypted at rest with your `encryptionKey`.
4. Create your collections and their API rules. New collections are superuser-only until you write a rule that opens them.
5. Optionally point PocketBase's own scheduled backups at S3 under **Settings → Backups** if you want an off-platform copy in addition to the volume snapshots.

## Important Notes

- **Single instance, no HA — this does not scale horizontally.** PocketBase is single-server by design (embedded SQLite, no clustering), and each stateful replica on this platform would get its own volume and therefore its own empty database. There is deliberately no `replicas` knob. Every `helm upgrade` that changes the container spec, every forced redeployment (including after a secret rotation) and every reschedule is a short full outage — typically a minute or two — while the one replica hands its volume over; requests fail with 503 meanwhile. Data is not at risk — the same volume reattaches.
- **The superuser password is re-applied from the secret on EVERY start.** Changing it in the dashboard is reverted at the next restart — change it in the secret instead, and note that this changes your login.
- **After updating the credentials secret you must force a redeployment — the workload does NOT pick it up on its own.** Until you do, the old password keeps authenticating and the workload stays `ready: true`, with no error and no warning, so a rotation looks like it worked while the old credential stays valid indefinitely. Apply it with:

  ```bash
  cpln workload force-redeployment RELEASE_NAME-pocketbase --gvc GVC_NAME
  ```

  The rotation takes effect once the new replica is serving (after the short outage described above); until then the old password continues to work.
- **Realtime subscriptions are capped at ten minutes per connection.** Requests are closed after the workload timeout, which this template already sets to the platform maximum (600 s), and Server-Sent Events are not exempt. An idle stream ends sooner — PocketBase itself disconnects an idle subscription after about five minutes. No events are lost while the stream is open — the cut is a clean close, not an error — but **your client must reconnect and resubscribe**. The official PocketBase SDKs do this automatically; a hand-rolled `EventSource` or `curl` consumer must handle it.
- **Never change `encryptionKey` after install.** It encrypts the SMTP password, OAuth2 client secrets, and S3 backup credentials stored inside the database; changing it orphans all of them with no way back.
- **Uploads and local backup ZIPs share the volume with the database.** A file-heavy app needs more than the 10 GiB default; raise `volumeset.capacity` at install time.
- **Backups are platform volume snapshots**, not off-site copies — they live in the platform storage layer alongside the volume. For an off-platform copy, use PocketBase's own S3 backups under Settings → Backups.
- **Access-knob changes can take several minutes to propagate.** After changing `publicAccess` or `internalAccess`, re-poll rather than trusting the first response.
- **This is not an official image** — no official PocketBase image exists. This template pins a well-used community build and overrides its entrypoint, so it depends only on the pinned binary. If you override `image`, it must run as root with `pocketbase` on `PATH`.

## Links

- [PocketBase documentation](https://pocketbase.io/docs/)
- [Going to production](https://pocketbase.io/docs/going-to-production/)
- [REST API reference](https://pocketbase.io/docs/api-records/)
- [Realtime API (Server-Sent Events)](https://pocketbase.io/docs/api-realtime/)
- [FAQ — scaling and SQLite](https://pocketbase.io/faq/)
