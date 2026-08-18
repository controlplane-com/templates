# mysql — maintainer briefing

**What it is.** A single-instance MySQL on a persistent volume, with two optional extras: a phpMyAdmin
web console and a `cron` job that dumps to S3 or GCS. Not a cluster — one replica, one volume, no
replication. For HA PostgreSQL-style shapes the catalog has `postgres-highly-available` and
`postgres-multi-location`; there is no MySQL equivalent.

**Common use cases.** The application database behind a WordPress/PHP/Rails app in the same GVC; a
drop-in MySQL for teams migrating off RDS; a scratch database for development GVCs.

## Architecture

| Resource | Kind | Notes |
|---|---|---|
| `{release}-mysql` | workload (`stateful`) | MySQL on tcp/3306, `minScale`/`maxScale` pinned to 1 |
| `{release}-mysql-vs` | volumeset | `ext4`, mounted at `/var/lib/mysql`, `general-purpose-ssd` |
| `{release}-mysql-identity` | identity | carries the AWS/GCP cloud-account binding when backups are on |
| `{release}-mysql-policy` | policy | `reveal` on exactly the two user-created credential secrets |
| `{release}-mysql-phpmyadmin` | workload (`serverless`) | optional, OFF by default; no identity, reads no secret |
| `{release}-mysql-backup` | workload (`cron`) | optional; `mysqldump` to S3/GCS on a schedule |

The chart creates **no secret of its own** (since 1.5.0). Bucket names, regions and prefixes are plain
env values on the backup job — they are not credentials; bucket access comes from the identity binding.

## Key knobs (shipped defaults)

| Knob | Default | Notes |
|---|---|---|
| `image` | `mysql:9` | any MySQL major works, including with the backup image |
| `credentialsSecretName` | `my-mysql-credentials` | **prerequisite** `dictionary` secret: `username`, `password`, `database` |
| `rootPasswordSecretName` | `my-mysql-root-password` | **prerequisite** `opaque` secret (`encoding: plain`) |
| `resources` | 100m/400m cpu, 128Mi/512Mi mem | `minCpu`/`maxCpu`/`minMemory`/`maxMemory`; 400m/100m is exactly the 4:1 cap |
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
  is the console. Before 1.5.0 the console had **no** access knob at all and was hardcoded public — that
  was the security defect 1.5.0 fixes.
- **Root is deliberately in its own secret.** The application credentials get shared with app workloads
  and teammates; bundling root in the same dictionary would ship root along with them.
- **phpMyAdmin ignores `MYSQL_ROOT_PASSWORD`.** The upstream image never reads it (only `PMA_USER`/
  `PMA_PASSWORD` pre-fill a login). Versions before 1.5.0 passed it anyway, which bought nothing and
  cost the console a `reveal` grant on the root password. It is gone; the console has no identity now.
- **`enablePhpMyAdmin` and the whole `config` block were removed in 1.5.0.** Setting either fails at
  render with a message naming the replacement, rather than silently ignoring a password the user set.
- **One replica only.** `defaultOptions.autoscaling` pins min=max=1 and the volumeset is single-mount.

## History

- **1.5.0** (2026-08-17) — credentials became two prerequisite secrets; phpMyAdmin defaults off, gains
  its own `publicAccess`/`internalAccess` knobs and a pinned image; template-created secret removed.
- **1.4.3** — backup job passes `MYSQL_DATABASE`; schedule quoted.
