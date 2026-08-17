# mariadb — maintainer briefing

**What it is.** A single-instance MariaDB on a persistent volume, with two optional extras: a phpMyAdmin
web console and a `cron` job that dumps to S3 or GCS. Not a cluster — one replica, one volume, no
replication. Deliberately the same shape as the `mysql` template; users compare them side by side, so
knob names, defaults and README structure are kept identical apart from the image and workload names.

**Common use cases.** A MySQL-compatible application database for teams who prefer MariaDB's licensing
or its drop-in compatibility with older MySQL clients; the database behind a PHP app in the same GVC.

## Architecture

| Resource | Kind | Notes |
|---|---|---|
| `{release}-maria` | workload (`stateful`) | MariaDB on tcp/3306, `minScale`/`maxScale` pinned to 1 |
| `{release}-maria-vs` | volumeset | `ext4`, mounted at `/var/lib/mysql`, `general-purpose-ssd` |
| `{release}-maria-identity` | identity | carries the AWS/GCP cloud-account binding when backups are on |
| `{release}-maria-policy` | policy | `reveal` on exactly the two user-created credential secrets |
| `{release}-phpmyadmin` | workload (`serverless`) | optional, OFF by default; no identity, reads no secret |
| `{release}-maria-backup` | workload (`cron`) | optional; dump to S3/GCS on a schedule |

Note the phpMyAdmin workload name has **no `maria` infix** (`{release}-phpmyadmin`), unlike mysql's
`{release}-mysql-phpmyadmin`. Historical, kept for name stability.

The chart creates **no secret of its own** (since 1.4.0). Bucket names, regions and prefixes are plain
env values on the backup job — they are not credentials; bucket access comes from the identity binding.

## Key knobs (shipped defaults)

| Knob | Default | Notes |
|---|---|---|
| `image` | `mariadb:11` | |
| `credentialsSecretName` | `my-mariadb-credentials` | **prerequisite** `dictionary` secret: `username`, `password`, `database` |
| `rootPasswordSecretName` | `my-mariadb-root-password` | **prerequisite** `opaque` secret (`encoding: plain`) |
| `resources` | 100m/250m cpu, 128Mi/264Mi mem | `minCpu`/`maxCpu`/`minMemory`/`maxMemory` |
| `internalAccess.type` | `same-gvc` | governs the **database** only |
| `volumeset.capacity` | `10` | GiB, minimum 10; optional autoscaling block |
| `phpMyAdmin.enabled` | `false` | console is opt-in |
| `phpMyAdmin.image` | `phpmyadmin:5.2.3-apache` | official Docker library image, pinned |
| `phpMyAdmin.publicAccess.enabled` | `false` | true = login form on the public internet |
| `phpMyAdmin.internalAccess.type` | `same-gvc` | separate from the database's knob |
| `backup.enabled` | `false` | `provider` is `aws` or `gcp` |

## Troubleshooting traps

- **Both prerequisite secrets must exist before install.** Missing either leaves the workload wedged on
  an unresolvable `cpln://secret/...` reference — it looks like a crash, it is a missing secret.
- **Credentials are only honoured when the volume is first initialized.** Rotating the secret and
  redeploying does nothing; the data directory keeps the original passwords. Change them with
  `ALTER USER`, or uninstall (which deletes the volumeset) and reinstall.
- **Two different `internalAccess` blocks.** `internalAccess` is the database; `phpMyAdmin.internalAccess`
  is the console. Before 1.4.0 the console had **no** access knob at all and was hardcoded public — that
  was the security defect 1.4.0 fixes.
- **Root is deliberately in its own secret.** The application credentials get shared with app workloads
  and teammates; bundling root in the same dictionary would ship root along with them.
- **phpMyAdmin ignores `MYSQL_ROOT_PASSWORD`.** The upstream image never reads it (only `PMA_USER`/
  `PMA_PASSWORD` pre-fill a login). Versions before 1.4.0 passed it anyway, which bought nothing and
  cost the console a `reveal` grant on the root password. It is gone; the console has no identity now.
- **`enablePhpMyAdmin` and the whole `config` block were removed in 1.4.0.** Setting either fails at
  render with a message naming the replacement, rather than silently ignoring a password the user set.
- **Probes use `mariadb-admin`, not `mysqladmin`.** MariaDB 11 renamed the client binaries; a probe
  copied from the mysql template will fail on this image.
- **The backup job now passes `MYSQL_DATABASE`** (new in 1.4.0, matching mysql 1.4.3). Earlier versions
  did not, so the dump relied on the image's own default.

## History

- **1.4.0** (2026-08-17) — credentials became two prerequisite secrets; phpMyAdmin defaults off, gains
  its own `publicAccess`/`internalAccess` knobs and a pinned image; template-created secret removed;
  backup job passes `MYSQL_DATABASE`.
- **1.3.2** — backup images moved to ghcr.
