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
| `{release}-ghost-identity` / `-policy` | least-privilege `reveal` on the start script, `{release}-mysql-config`, and the SMTP secret (only if set) |
| `{release}-mysql` (+ `-config`, `-vs`) | MySQL 8 backing DB (created by the `mysql` subchart, image pinned `mysql:8`) |
| `{release}-mysql-backup` cron (optional) | scheduled `mysqldump` → S3/GCS, created only when `mysql.backup.enabled` |

- Public access = auto-assigned `*.cpln.app` HTTPS endpoint (no `loadBalancer.direct` — Ghost is HTTP).
- Ghost reaches MySQL at `{release}-mysql.{gvc}.cpln.local:3306`; config passed as `database__*` env vars.

## Key knobs
| Knob | Default | Meaning |
|---|---|---|
| `image` | `ghost:6.54.1-alpine` | Ghost 6 (GA); Ghost 5 final (`5.130.6-alpine`) also works — same MySQL-8/config/content requirements |
| `publicUrl` | `""` | custom domain URL; empty = derive canonical endpoint |
| `mail.secretName` + `mail.host/port/secure/from` | `""` (off) | SMTP for member/newsletter email |
| `publicAccess.enabled` / `internalAccess.type` | `true` / `same-gvc` | exposure |
| `mysql.config.*` | `ghost` / change-me | DB name, user, passwords |
| `mysql.backup.*` | `enabled: false` | scheduled DB dumps to S3/GCS (mysql template's native backup; tested dump AND restore) |

## Availability posture (state plainly)
- **Single-replica by design. No `replicas` knob, ever.** Ghost has **no upstream clustering/multi-instance support** (a "quorum" — majority-agreement — model does not apply; it simply is not built for >1 replica): it holds in-process scheduler, job-queue and cache state that is unsafe to run in parallel.
- Durability = durable MySQL + durable content volumeset + fast restart + optional scheduled DB dumps. A rolling restart of the one replica is a brief (seconds) outage — put a CDN in front for a public site.

## Troubleshooting / considerations
- **MySQL 8 only.** Ghost does NOT support MySQL 9 or MariaDB — the subchart image is pinned `mysql:8`. Do not "upgrade" it to 9; Ghost will refuse an unsupported DB.
- **DB backups require mysql subchart ≥ 1.4.3 + backup image 1.0.0 (current).** Earlier chart/image pairs dumped a placeholder database instead of the app DB — Ghost ships pinned to the fixed pair, and the e2e test proved dump + restore of real Ghost content. Backups need the README's cloud setup (bucket, cloud account, scoped policy).
- **First-run owner account:** there is no non-interactive admin bootstrap. After deploy the user visits `/ghost` to create the owner. If they never do, the site shows the default theme but has no admin.
- **`url` must be correct** or links/emails point at the wrong host. The startup script sets it from `CPLN_GLOBAL_ENDPOINT` (already `https://…` — never double-schemed); set `publicUrl` when using a custom domain. The readiness probe sends `X-Forwarded-Proto: https` so Ghost (which insists on its configured HTTPS origin) accepts probe traffic.
- **Startup ordering:** Ghost does not wait for MySQL and will restart a few times on first install until the DB is ready — early "connection refused" log lines during first boot are expected, not a fault.
- **Media lives on the volumeset, not object storage.** Uploaded images persist across restarts, but are single-replica-local. An S3/MinIO content adapter (CDN-friendly) is a possible follow-up.
- **SMTP is a prerequisite secret**, not values: user creates a dictionary secret with keys `user`,`password` and sets `mail.secretName` (plus `mail.host/from`). Empty `secretName` = email fully off (member magic-links/newsletters won't send).
- **Uninstall + reinstall to reset:** DB + content volumesets are `retain`; a fresh install over old volumes keeps old data/credentials. Use a new release name or uninstall (drops volumesets) for a clean slate.
- **cpu:minCpu ratio:** the mysql subchart defaults are overridden (`minCpu: 150m` vs `maxCpu: 500m`) to stay under the platform's 4:1 cap — don't restore the subchart's own defaults.
