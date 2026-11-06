# calcom — maintainer briefing

## What it is

- **Cal.com**: self-hosted scheduling and booking pages, the open-source Calendly alternative. **AGPL-3.0**, free to self-host, nothing to register; we ship the unmodified official image `calcom/cal.com:v6.2.0`.
- **Licence key**: none is set. Teams work without one (proven live); Workflows and Organizations show as commercial features and stay locked. Google/Outlook calendar and Zoom/Meet integrations need the user's own OAuth app credentials, which the template does not configure. The separate v2 API service (own image, own Redis) is not shipped.
- **Upstream is mid-rebrand**: the Docker docs moved to `cal.diy/docker` and name `calcom/cal.diy`, a Docker Hub repo with no tags. Re-check the image name at the next version bump.

## Architecture on cpln

| Resource | Purpose |
|---|---|
| `{release}-calcom` (`standard`, port 3000) | UI, booking pages, `/api/*`. The inline start script waits for PostgreSQL, runs `prisma migrate deploy` under `set -e`, seeds the app store, then `yarn start` |
| `{release}-calcom-cron` (`standard`, 1 replica) | Inline `wget` loop calling the scheduled-job endpoints every 60 s with `cronSecret` |
| `postgres` 3.4.1 (default) / `postgres-highly-available` 2.8.1 alias `postgresHA` | All state. Both read the same prerequisite DB secret shape |
| identity + policy + GVC policy | `reveal` on the auth secret, the DB secret and the optional SMTP secret only; `view` on the install GVC for the boot-time location report |

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

- **A missing prerequisite secret shows no logs**: the container never starts. `cpln workload get-deployments {release}-calcom --gvc {gvc} -o yaml` names the secret under `status.versions[].message`.
- **Never replace `encryptionKey`**: it encrypts every stored calendar and app credential.
- **Boot window**: readiness 30 s + 30 × 15 s ≈ 480 s; the database wait gives up at 240 s with `[calcom] FATAL: PostgreSQL at ... did not answer`, so the diagnostic reaches the log. The image's own `start.sh` is not used: its `nc -z` wait always succeeds through the mesh and it ignores a failed migration.
- **`cronSecret` is a real control**: upstream accepts `Bearer undefined` when the variable is unset (issue #29565), so the chart always sets it from the secret.
- **Signup cannot be disabled by env var** (`NEXT_PUBLIC_*` is build-time); use the `disable-signup` feature flag in Settings → Admin → Features.
- **`HOSTNAME: "0.0.0.0"`** keeps loopback working if upstream moves to a Next.js standalone server.
