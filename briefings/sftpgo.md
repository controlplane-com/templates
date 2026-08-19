# sftpgo — Maintainer Briefing

**What it is:** [SFTPGo](https://github.com/drakkan/sftpgo) (AGPL-3.0) exposed as a plain SFTP server whose storage backend is **object storage, not a disk**. Clients speak standard SFTP; bytes land in the customer's S3/GCS bucket, one folder per user. The differentiator over every other SFTP option is the **scale-to-zero mode**: the server suspends when idle and a ~100m always-on proxy wakes it on the next connection.

**Common use cases**
- Partner/vendor file drops where the data must end up in the customer's own bucket, not on a volume
- Legacy systems that can only speak SFTP, in front of a modern object store
- Low-duty-cycle transfers (nightly batches) where paying for an always-on SFTP server is the wrong shape

**Architecture on cpln**

| Resource | Purpose |
|---|---|
| Stateful workload ×1 (`{release}-sftpgo`) | SFTPGo on :2022; bolt DB + SSH host keys on a 10 GiB volumeset. Port 8080 (web admin/REST) only declared when `webAdmin.enabled` |
| Standard workload ×1 (`{release}-sftpgo-proxy`) | `scale_to_zero` mode only — holds the client TCP connection, wakes the target via the platform API, re-suspends after `idleHold` |
| Volumeset (10 GiB, ext4) | Embedded bolt database and SSH host keys — host-key stability across restarts *and wakes* is why this exists |
| Users secret (opaque, `plain`) | The SFTPGo LOADDATA file: declared users + their per-user S3/GCS filesystem, re-applied on every start |
| Identity + policies | SFTPGo identity carries the AWS/GCP cloud-account binding (keyless bucket access); a **separate** proxy identity may `view`/`edit` exactly the one SFTPGo workload |

**Key knobs (shipped defaults):** `mode: scale_to_zero` · `scaleToZero.idleHold: 5m` · `resources.{minCpu 250m, minMemory 256Mi, maxCpu 1000m, maxMemory 512Mi}` · `admin.secretName: my-sftpgo-admin` (prerequisite **dictionary** secret, keys `username` + `password`) · `storage.type: aws` (`aws`/`gcp` keyless, `minio` static keys) · `users[]` (≥1 enforced, each needs a password or a public key) · `volumeset.capacity: 10` · `publicAccess.enabled: true` · `internalAccess.type: same-gvc` · `webAdmin.enabled: false`

**Troubleshooting / considerations**
- **The admin login is a PREREQUISITE DICTIONARY SECRET as of 1.1.0.** It seeds `SFTPGO_DEFAULT_ADMIN_*`, which SFTPGo consumes **only when the data provider has no admin** — so on an existing volumeset, editing the secret changes nothing and the password must be rotated through the REST API. 1.0.0's `admin.username`/`admin.password` now hard-`fail` the render.
- **A missing prerequisite secret wedges the deploy with ZERO log lines.** Only diagnostic is `status.versions[].message` from `cpln workload get-deployments` (not plain `get`). Self-heals in ~6–10 min, or `force-redeployment` (~90 s).
- **`users[].password` and `storage.minio.accessKey`/`accessSecret` are still values, deliberately.** They are rendered into the LOADDATA **file**, and SFTPGo does no `${VAR}` substitution in that file (confirmed against the config-file docs) — so a `cpln://` reference would be stored literally. The image is `distroless-slim` with **no shell**, so there is no startup script to substitute them either. Moving them needs either a shell-bearing image variant or proving SFTPGo's AWS SDK picks up `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` when the loaddata entry omits the keys — both are live-deploy questions. Steer users to `publicKeys`, which needs no secret at all.
- **Declared users are authoritative** — the LOADDATA file is re-applied on every start and wake, so admin-API edits to a *declared* user are silently reverted. Users created through the API are untouched.
- **Cold start is ~30 s and occasionally ~75 s** (the volume re-attaches on each wake). Several SSH libraries default to a ~15 s banner timeout and give up right at the finish line — paramiko needs `banner_timeout=120`, WinSCP needs Timeout ≥120 s, OpenSSH CLI is fine untouched. For third-party clients you cannot configure, `always_warm` is the answer.
- **Switching modes moves the client-facing endpoint** between the proxy and SFTPGo workloads — a client cutover, not a no-op.
- **The dedicated load balancer, not the proxy's compute, is the dominant idle cost** in scale_to_zero. Do not sell the mode as free.
- `filesystemGroupId: 1000` is load-bearing: the distroless image runs as UID/GID 1000 with no root entrypoint to chown the freshly-provisioned volumeset, so without it SFTPGo cannot create its bolt DB on first boot.
- Only `webAdmin.enabled: true` **plus** `always_warm` **plus** `publicAccess` puts the admin UI on the public canonical endpoint; the default shape exposes only raw TCP 2022 through the proxy.
