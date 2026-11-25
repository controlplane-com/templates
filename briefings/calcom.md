# calcom — maintainer briefing

## What it is

- **Cal.com**: self-hosted scheduling and booking pages, the open-source Calendly alternative. **AGPL-3.0**, free to self-host, nothing to register; we ship the unmodified official image `calcom/cal.com:v6.2.0`.
- **Licence key**: none is set. Teams work without one (proven live); Workflows and Organizations show as commercial features and stay locked. Google/Outlook calendar and Zoom/Meet integrations need the user's own OAuth app credentials, entered by an admin at `/settings/admin/apps` (stored in the database). Webhooks proven live to public and `*.cpln.local` URLs with a valid HMAC signature. The separate v2 API service (own image, own Redis) is not shipped.
- **Upstream is mid-rebrand**: the Docker docs moved to `cal.diy/docker` and name `calcom/cal.diy`, a Docker Hub repo with no tags. Re-check the image name at the next version bump.

## Architecture on cpln

| Resource | Purpose |
|---|---|
| `{release}-calcom` (`standard`, port 3000) | UI, booking pages, `/api/*`. The inline start script waits for PostgreSQL, runs `prisma migrate deploy` under `set -e`, seeds the app store, then `yarn start` |
| `{release}-calcom-cron` (`standard`, 1 replica) | Inline `wget` loop calling the scheduled-job endpoints every 60 s with `cronSecret` |
| `postgres` 4.0.2 (default, `postgres:19`, boot guard naming `postgres.image`) / `postgres-highly-available` 3.0.0 alias `postgresHA` (patroni-postgres 0.9: new clusters PostgreSQL 18, 1.x clusters stay on 17) | All state. Both read the same prerequisite DB secret shape |
| identity + policy + GVC policy | `reveal` on the auth secret, the DB secret and the optional SMTP secret only; `view` on the install GVC for the boot-time location report; no `cpln-connector` anywhere (the subcharts' backup identities dropped it too) |

- **No chart-created secrets.** Both start and cron scripts are inline in `args` via `calcom.inlineScript` (every `$` doubled); the DB URL is assembled by the platform from `$(DB_USER)`, `$(DB_PASSWORD)`, `$(DB_NAME)`, all read from the DB secret.
- **Private by default**: install, `cpln port-forward`, `/auth/setup` (first visitor becomes admin), then `publicAccess.enabled: true`.
- **Pinned to ONE location** (`defaultOptions` 0/0 + one `localOptions` entry). The bundled database subcharts cannot be pinned, so a multi-location GVC runs an idle, billed database per extra location; the app logs a warning naming them.

## Key knobs

| Knob | Default | Note |
|---|---|---|
| `location` | `aws-us-east-1` | Must be a GVC location, or nothing runs |
| `calcom.replicas` | `1` | Stateless; `2+` for rolling restarts |
| `calcom.appUrl` | `""` | Custom domain only, with scheme |
| `calcom.auth.secretName` | `my-calcom-auth` | Prerequisite: `nextAuthSecret`, `encryptionKey` (exactly 32 chars), `cronSecret`, `cronApiKey` |
| `postgres(HA).config.credentialsSecretName` | `my-calcom-db-credentials` | Prerequisite: `username`, `password`, `database`, all URL-safe |
| `cron.enabled` | `true` | Off = no queued email, calendar sync or credential refresh, while health stays green |
| `email.enabled` / `email.auth.secretName` | `false` / `""` | SMTP login secret keys `username`, `password` |
| `postgresHA.enabled` | `false` | Simple shape by default (not a cascade service); one flag flips to HA |

## Guards (render-time `fail`, each mirrored in wizard.yaml)

- Exactly one database; `postgresHA.proxy.enabled` must stay true (HAProxy is the app's endpoint).
- `postgres.internalAccess` and `postgresHA.internal_access`: `none` is refused, and `workload-list` must include `//gvc/{gvc}/workload/{release}-calcom`.
- `cron.enabled` needs `internalAccess.type` other than `none`; `appUrl` needs a scheme; email needs host and from address.

## Troubleshooting

- **Upgrading a 1.x release on the single-instance database (2.0.0 is a major):** its data is PostgreSQL 18, and the postgres 4.0.2 boot guard refuses to start PostgreSQL 19 on it (`{release}-postgres` not ready, `[pg-guard] REFUSING TO START` every 30 s, volume untouched; Cal.com restarts on its 240 s database wait). Fix: `--set postgres.image=postgres:18` and keep it in values; the guard's log names that path, the wizard field (Upgrade > Database server > Postgres image) and the README section (`postgres.upgradeHint`, leave it alone). The Console wizard carries the installed image (a parent migration) and warns when another major is picked. Moving to 19 = side-by-side new release with the SAME auth secret (`encryptionKey`) and DB secret, stop the old app + cron, `pg_dump --clean --if-exists` from the old server, force-redeployment (README "Upgrading from 1.x"). HA releases upgrade normally and keep PostgreSQL 17 on the 0.9 image; moving a cluster to 18 is pgha's "Upgrading an existing cluster to PostgreSQL 18".
- **A missing prerequisite secret shows no logs**: the container never starts. `cpln workload get-deployments {release}-calcom --gvc {gvc} -o yaml` names the secret under `status.versions[].message`.
- **Never replace `encryptionKey`**: it encrypts every stored calendar and app credential.
- **Boot window**: readiness 30 s + 30 × 15 s ≈ 480 s; the database wait gives up at 240 s with `[calcom] FATAL: PostgreSQL at ... did not answer`, so the diagnostic reaches the log. The image's own `start.sh` is not used: its `nc -z` wait always succeeds through the mesh and it ignores a failed migration.
- **`cronSecret` is a real control**: upstream accepts `Bearer undefined` when the variable is unset (issue #29565), so the chart always sets it from the secret.
- **Signup cannot be disabled by env var** (`NEXT_PUBLIC_*` is build-time); use the `disable-signup` feature flag in Settings → Admin → Features.
- **`HOSTNAME: "0.0.0.0"`** keeps loopback working if upstream moves to a Next.js standalone server.

## Status
2.0.0: single-instance PostgreSQL 19 (postgres 4.0.2, backup image 19.1.0), HA on postgres-highly-available 3.0.0 (new clusters 18, logical backup image 18.2.0), NOTES.txt upgrade warning, wizard image carry-over + cross-major warning + upgrade notes, database-switch fields hidden (their rules are root rules), README "Upgrading from 1.x". CI: `fresh-is-19`, refused-then-pinned upgrade from 1.0.0 (`guard-holds`, `pinned-stays-18`, `data-survives`), and an `ha` variant (fresh HA install, `ha-is-18`).
