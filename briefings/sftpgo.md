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
| Users secret (opaque, `plain`) | Chart-owned users TEMPLATE: declared users + per-user S3/GCS filesystem, passwords as `@@USERPW_<i>@@` tokens. No credential since 1.2.0 |
| Identity + policies | SFTPGo identity carries the AWS/GCP cloud-account binding (keyless bucket access); a **separate** proxy identity may `view`/`edit` exactly the one SFTPGo workload |

**Key knobs (shipped defaults):** `mode: scale_to_zero` · `scaleToZero.idleHold: 5m` · `resources.{minCpu 250m, minMemory 256Mi, maxCpu 1000m, maxMemory 512Mi}` · `image: drakkan/sftpgo:v2.7.4-alpine-slim` (1.2.0; was distroless) · `admin.secretName: my-sftpgo-admin` (prerequisite **dictionary**, keys `username` + `password`) · `storage.type: aws` (`aws`/`gcp` keyless, `minio` keys from `storage.minio.credentialsSecretName: my-sftpgo-minio-credentials`, dictionary `accessKey` + `secretKey`) · `userPasswords.secretName: my-sftpgo-user-passwords` (dictionary, one key per password username) · `users[]` (≥1; `username`, `publicKeys`, optional `passwordLogin`, `keyPrefix`; password login defaults on only when `publicKeys` is empty) · `volumeset.capacity: 10` · `publicAccess.enabled: true` · `internalAccess.type: same-gvc` · `webAdmin.enabled: false`

**Troubleshooting / considerations**
- **The admin login is a PREREQUISITE DICTIONARY SECRET as of 1.1.0.** It seeds `SFTPGO_DEFAULT_ADMIN_*`, which SFTPGo consumes **only when the data provider has no admin** — so on an existing volumeset, editing the secret changes nothing and the password must be rotated through the REST API. 1.0.0's `admin.username`/`admin.password` now hard-`fail` the render.
- **A missing prerequisite secret wedges the deploy with ZERO log lines.** Only diagnostic is `status.versions[].message` from `cpln workload get-deployments` (not plain `get`). Self-heals after several minutes (measured ~6–10 min on other templates), or `force-redeployment`.
- **1.2.0: no credential is a value.** `users[].password` and `storage.minio.accessKey`/`accessSecret` were removed (render `fail`s, wizard mirrors). The LOADDATA file is a FILE, so `cpln://` cannot go in it; instead the image moved to **`alpine-slim`** (same binary, same uid 1000, same `/etc/sftpgo/sftpgo.json` apart from the default driver, which the chart pins to bolt) and an **inline start script** (busybox `sh` + `awk`, `$` doubled) copies the chart's users template to `/tmp` (0600), replacing each `@@USERPW_<i>@@` with the JSON-escaped env `USERPW_<i>` (= `cpln://secret/{userPasswords.secretName}.{username}`), then `exec sftpgo serve`. `SFTPGO_LOADDATA_CLEAN=true` deletes the file once loaded. SFTPGo stores **bcrypt** (`$2a$10$…`, checked via `dumpdata` locally). MinIO keys never enter the file: they are `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` env from the secret, and the AWS SDK default chain picks them up when `s3config` omits keys (proven locally against SeaweedFS S3, with a wrong-key negative control → `Permission denied`). A custom `image` must have `/bin/sh` + `awk`; distroless tags crash.
- **A password user missing from the secret** crash-loops with `sftpgo: USERPW_<i> is empty …` in the log — IF the platform starts the container with an empty env var for a missing dictionary key. Whether it does, or wedges like a missing secret, is unmeasured.
- **Passwords are re-applied on every start (LOADDATA mode 0 updates existing users)**, so the secret value IS the password: rotating = update secret + `force-redeployment`. Upgrading from 1.1.0 must store the CURRENT passwords (readable from `cpln secret reveal {release}-sftpgo-users -o yaml` before the upgrade overwrites it), or logins change.
- **Declared users are authoritative** — the LOADDATA file is re-applied on every start and wake, so admin-API edits to a *declared* user are silently reverted. Users created through the API are untouched.
- **Cold start is ~30 s and occasionally ~75 s** (the volume re-attaches on each wake). Several SSH libraries default to a ~15 s banner timeout and give up right at the finish line — paramiko needs `banner_timeout=120`, WinSCP needs Timeout ≥120 s, OpenSSH CLI is fine untouched. For third-party clients you cannot configure, `always_warm` is the answer.
- **Switching modes moves the client-facing endpoint** between the proxy and SFTPGo workloads — a client cutover, not a no-op.
- **The dedicated load balancer, not the proxy's compute, is the dominant idle cost** in scale_to_zero. Do not sell the mode as free.
- `filesystemGroupId: 1000` is load-bearing: the image (distroless before 1.2.0, alpine-slim since) runs as UID/GID 1000 with no root entrypoint to chown the freshly-provisioned volumeset, so without it SFTPGo cannot create its bolt DB on first boot.
- **The web admin is never public.** `webAdmin.enabled` only declares port 8080. In `always_warm` + `publicAccess` the workload's external firewall opens and `loadBalancer.direct` maps 2022 only, so the public endpoint is a raw `tcp://…:2022` address that does not serve 8080. The supported path is `cpln port-forward {release}-sftpgo 8080:8080` (SFTPGo must be awake in scale_to_zero). The values comment and this briefing previously said otherwise (corrected 2026-10-01).
- **`storage.minio.endpoint` default `http://my-minio-workload:9000` is a short name.** It is a placeholder, but bare short names are not reliable on standard workloads; README now steers to `WORKLOAD_NAME.GVC_NAME.cpln.local`. Changing the default needs a patch version.
