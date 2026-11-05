# Ghost — Maintainer Briefing

## What it is
- Ghost: open-source publishing platform (blogs, newsletters, paid memberships, REST/Content APIs). License **MIT** (fully free; no key or registration to self-host).
- Template = one stateful Ghost workload + a bundled **MySQL 8** database via the `mysql` subchart. Public HTTPS site on the standard cpln HTTP path.

## Common use cases
- Company blog / editorial site with a first-class editor.
- Email newsletters to members (needs SMTP — see below).
- Paid memberships / subscriptions (Stripe, configured in Ghost admin).
- Headless content delivery via Ghost's Content API to a separate frontend.

## Architecture on cpln
| Resource | Purpose |
|---|---|
| `{release}-ghost` (stateful, 1 replica, :2368) | Ghost Node app; content volumeset at `/var/lib/ghost/content` |
| `{release}-ghost-vs` volumeset | durable uploaded images, themes, logs |
| `{release}-ghost-start` secret | startup script: derives `url` from the canonical endpoint, then execs the image entrypoint |
| `{release}-ghost-identity` / `-policy` | least-privilege `reveal` on the start script, the DB credentials secret (`mysql.credentialsSecretName`), and the SMTP secret (only if set) — never the root-password secret |
| `{release}-mysql` (+ `-vs`) | MySQL 8 backing DB (`mysql` subchart 1.5.2, image pinned `mysql:8`); reads the two prerequisite secrets |
| user-created secrets | `mysql.credentialsSecretName` (dictionary `username`/`password`/`database`, read by MySQL AND Ghost) + `mysql.rootPasswordSecretName` (opaque root password, MySQL only) — required, must exist before install |
| `{release}-mysql-backup` cron (optional) | scheduled `mysqldump` → S3/GCS, created only when `mysql.backup.enabled` |

- Public access = auto-assigned `*.cpln.app` HTTPS endpoint (no `loadBalancer.direct` — Ghost is HTTP).
- Ghost reaches MySQL at `{release}-mysql.{gvc}.cpln.local:3306`; config passed as `database__*` env vars.

## Key knobs
| Knob | Default | Meaning |
|---|---|---|
| `image` | `ghost:6.54.1-alpine` | Ghost 6 (GA); Ghost 5 final (`5.130.6-alpine`) also works — same MySQL-8/config/content requirements |
| `publicUrl` | `""` | custom domain URL; empty = derive canonical endpoint |
| `mail.secretName` + `mail.host/port/secure/from` | `""` (off) | SMTP for member/newsletter email |
| `staffDeviceVerification` | `false` | Ghost 6 admin-login 2FA; off by default (needs SMTP), guarded against being enabled without mail |
| `publicAccess.enabled` / `internalAccess.type` | `true` / `same-gvc` | exposure |
| `mysql.credentialsSecretName` | `my-ghost-db-credentials` | prerequisite dictionary secret: `username`, `password`, `database` (since 1.3.0; replaced `mysql.config.*`) |
| `mysql.rootPasswordSecretName` | `my-ghost-mysql-root-password` | prerequisite opaque secret: MySQL root password |
| `mysql.internalAccess.type` / `.workloads` | `same-gvc` / `[]` | DB firewall; `none` breaks Ghost; `workload-list` must include `{release}-ghost` |
| `mysql.backup.*` | `enabled: false` | scheduled DB dumps to S3/GCS (mysql template's native backup; tested dump AND restore) |

## Availability posture (state plainly)
- **Single-replica by design. No `replicas` knob, ever.** Ghost has **no upstream clustering/multi-instance support** (a "quorum" — majority-agreement — model does not apply; it simply is not built for >1 replica): it holds in-process scheduler, job-queue and cache state that is unsafe to run in parallel.
- Durability = durable MySQL + durable content volumeset + fast restart + optional scheduled DB dumps. A rolling restart of the one replica is a brief (seconds) outage — put a CDN in front for a public site.

## Troubleshooting / considerations
- **1.3.0: no credential is a value any more.** `mysql.config.*` and `mysql.enablePhpMyAdmin` are gone (the chart, and the mysql 1.5.2 subchart before it, `fail` at render if they are still set — so a 1.2.0 values file is refused before anything is touched). Note the subchart's `fail` fires first (Helm renders subchart templates first), so users see mysql's wording, not ghost's.
- **PHP2Shell (CVE-2026-109618/109619, work item 5369).** ghost ≤1.2.0 bundles mysql 1.4.3, whose phpMyAdmin (`phpmyadmin/phpmyadmin:latest`, PHP 8.3.26, stale upstream since 2025-10) is public when `mysql.enablePhpMyAdmin` is on → unauthenticated RCE. 1.3.0 bundles mysql 1.5.2: `phpmyadmin:5.2.3-apache` (PHP 8.3.36, rebuilt 2026-10-21) and internal-only. Old versions are not patched; the path is upgrade or turn it off.
- **Upgrade 1.2.0 → 1.3.0 deletes `{release}-mysql-config`** (mysql 1.4.3 created it; 1.5.2 does not). Users must copy its CURRENT values (`cpln secret reveal`) into NEW secrets with different names; ghost `fail`s if either secret name equals `{release}-mysql-config`, and the wizard mirrors it. New values do NOT change the passwords MySQL was initialized with — that just breaks the login.
- **Upgrade adds new reveal grants** (mysql identity and ghost identity both get new secret targets), so the new workload version can sit ~10 min on `is not allowed to reveal the secret` (authorization edge cache) while the old version keeps serving. Unavoidable: the subchart's design.
- **Missing prerequisite secret = silent wedge**: zero log lines; read `status.versions[].message` via `cpln workload get-deployments`.
- **Rotation needs a forced redeployment** of `{release}-mysql` and `{release}-ghost` (change the password inside MySQL first); the SMTP secret likewise for `{release}-ghost`.
- **MySQL 8 only.** Ghost does NOT support MySQL 9 or MariaDB — the subchart image is pinned `mysql:8`. Do not "upgrade" it to 9; Ghost will refuse an unsupported DB.
- **DB backups require mysql subchart ≥ 1.4.3 + backup image 1.0.0 (current).** Earlier chart/image pairs dumped a placeholder database instead of the app DB — Ghost ships pinned to the fixed pair, and the e2e test proved dump + restore of real Ghost content. Backups need the README's cloud setup (bucket, cloud account, scoped policy).
- **First-run owner account:** there is no non-interactive admin bootstrap. After deploy the user visits `/ghost` to create the owner. If they never do, the site shows the default theme but has no admin.
- **Ghost 6 staff device verification bricks admin login when SMTP is off (fixed 1.2.0).** Since Ghost 5.118 the admin emails a 6-digit code on every new-device sign-in; with no SMTP that send 500s and `/ghost` is unreachable — the default install could not reach its own admin. 1.2.0 ships `staffDeviceVerification: false` (rendered as `security__staffDeviceVerification` env), and a validate guard rejects enabling it without `mail.secretName`. Set it `true` only after configuring SMTP.
- **`url` must be correct** or links/emails point at the wrong host. The startup script sets it from `CPLN_GLOBAL_ENDPOINT` (already `https://…` — never double-schemed); set `publicUrl` when using a custom domain. The readiness probe sends `X-Forwarded-Proto: https` so Ghost (which insists on its configured HTTPS origin) accepts probe traffic.
- **Startup ordering:** Ghost does not wait for MySQL and will restart a few times on first install until the DB is ready — early "connection refused" log lines during first boot are expected, not a fault.
- **Media lives on the volumeset, not object storage.** Uploaded images persist across restarts, but are single-replica-local. An S3/MinIO content adapter (CDN-friendly) is a possible follow-up.
- **SMTP is a prerequisite secret**, not values: user creates a dictionary secret with keys `user`,`password` and sets `mail.secretName` (plus `mail.host/from`). Empty `secretName` = email fully off (member magic-links/newsletters won't send).
- **Uninstall + reinstall to reset:** DB + content volumesets are `retain`; a fresh install over old volumes keeps old data/credentials. Use a new release name or uninstall (drops volumesets) for a clean slate.
- **cpu:minCpu ratio:** the mysql subchart defaults are overridden (`minCpu: 150m` vs `maxCpu: 500m`) to stay under the platform's 4:1 cap — don't restore the subchart's own defaults.
