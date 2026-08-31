# calcom — maintainer briefing

## What it is

- **Cal.com** — self-hosted scheduling and booking pages; the open-source Calendly alternative.
- **AGPL-3.0** (strong copyleft: anyone offering a *modified* version as a service must publish
  their changes). Free to self-host, nothing to register. We ship the unmodified upstream image,
  so the obligation does not attach to us.
- Shipped on `calcom/cal.com:v6.2.0` — the newest published non-`latest`, non-arm tag, matching
  upstream's newest GitHub release.

## Common use cases

- Team booking pages on your own domain, with your own data, instead of Calendly/SavvyCal.
- Round-robin and collective scheduling for sales/support rotas.
- Embedding a booking flow into an existing product via Cal.com's embed script.
- Keeping attendee PII (names, emails, meeting notes) inside the customer's own org rather than
  a third-party SaaS.

## Architecture on cpln

| Resource | Purpose |
|---|---|
| workload `{release}-calcom` (`standard`) | The whole app — UI, booking pages, `/api/*`. Port 3000, HTTP. Runs Prisma migrations at boot |
| workload `{release}-calcom-cron` (`standard`, 1 replica) | Drives Cal.com's scheduled endpoints on a 60 s `wget` loop. Same image, entrypoint overridden |
| subchart `postgres` 3.4.1 (default) / `postgres-highly-available` 2.7.0 (flag) | All state. Nothing else is persisted |
| secret (dictionary, **user-created**) `my-calcom-auth` | `nextAuthSecret`, `encryptionKey`, `cronSecret`, `cronApiKey` |
| secret (dictionary, chart-created) `my-calcom-db-credentials` | Bundled DB `username`/`password`/`database` |
| identity + policy | One identity for both workloads; `reveal` on exactly those secrets (plus the SMTP secret when configured) |

- **No volumeset on the app** — it is genuinely stateless (upstream's compose mounts no volume;
  avatars live in Postgres), which is what makes `replicas: 2+` work.
- **Private by default.** First run is: install → `cpln port-forward` → `/auth/setup` →
  `helm upgrade --set publicAccess.enabled=true`.

## Key knobs

| Knob | Default | Note |
|---|---|---|
| `calcom.image` | `calcom/cal.com:v6.2.0` | Official image |
| `calcom.replicas` | `1` | `2+` for zero-downtime rolling restarts; no clustering to form |
| `calcom.appUrl` | `""` | Empty = derived; set only for a custom domain, **with** the scheme |
| `calcom.auth.secretName` | `my-calcom-auth` | **Must exist before install** |
| `cron.enabled` | `true` | Turning it off silently stops every scheduled job |
| `email.enabled` | `false` | Off = no confirmations, invites or password resets |
| `publicAccess.enabled` | `false` | Flip only after claiming the admin account |
| `postgres.enabled` / `postgresHA.enabled` | `true` / `false` | Exactly one; the chart fails on both or neither |

## Troubleshooting / considerations

- **A missing `my-calcom-auth` secret wedges the install almost invisibly.** `cpln logs` returns
  *zero* lines. The only place the missing secret is named is
  `cpln workload get-deployments {workload} --gvc {gvc} -o yaml` → `status.versions[].message`.
  It self-heals ~5.5–10.5 minutes after the secret is created, or immediately with
  `cpln workload force-redeployment`.
- **`encryptionKey` must be exactly 32 characters** (`openssl rand -base64 24` — verified to
  produce exactly 32) and is effectively unrotatable: it encrypts every stored calendar and app
  credential, so changing it orphans them all. Treat it as write-once for the life of the install.
- **`cronSecret` is a real security control, not decoration — measured, not inferred.** Running
  the pinned image with `CRON_SECRET` unset: `GET /api/tasks/cron` with no header returns **401**,
  and with `Authorization: Bearer undefined` returns **400** — i.e. it got *past* the auth check
  and failed later. Any unauthenticated caller sending that header can trigger `tasker.cleanup()`
  and queue processing (upstream issue #29565, unfixed at v6.2.0). The template always sets it
  from the prerequisite secret; there is no valid unset path. Do not let anyone "simplify" it away.
- **Self-service signup cannot be turned off with an environment variable.** Cal.com reads
  `NEXT_PUBLIC_DISABLE_SIGNUP`, and every `NEXT_PUBLIC_*` value is compiled into the app when the
  image is *built*, so setting it at runtime does nothing. The working path is the database-backed
  feature flag `disable-signup` in Settings → Admin → Features, after the admin account exists.
  This is why public access defaults to off.
- **Whoever reaches `/auth/setup` first becomes the instance admin**, and there is no way to
  pre-create the owner from a secret (unlike keycloak or langfuse). Publishing the endpoint before
  finishing the wizard hands out admin.
- **Without the cron workload, nothing scheduled ever runs** — queued outbound email, calendar
  sync, credential refresh — and every health surface still reads green. This is the failure users
  will report as "reminders stopped working": check that `{release}-calcom-cron` exists and that
  its log shows `calcom-cron /api/tasks/cron -> 200` roughly every 60 s. `cron.enabled` with
  `internalAccess.type: none` is refused at render, because the loop's calls arrive on the app's
  internal inbound.
- **`HOSTNAME: "0.0.0.0"` on the app container is load-bearing insurance, not dead config.** The
  image builds a Next.js *standalone* bundle (`/calcom/apps/web/.next/standalone` exists at this
  tag) and a standalone server binds `process.env.HOSTNAME`, which the platform sets to the replica
  name — the `langfuse` `502 Unable to connect to upstream workload` failure. At v6.2.0 the
  container runs `next start` instead, which ignores `HOSTNAME`: verified by running the pinned
  image with `HOSTNAME` set to a replica-shaped name and getting `Local: http://localhost:3000`
  plus a 200 on `127.0.0.1:3000/api/version`. The variable is a no-op today and one upstream line
  away from being essential, and the whole private-first story depends on loopback. The API accepts
  and stores it verbatim (probed 2026-08-31; only `CPLN_`-prefixed names are reserved).
- **First boot is slow by design** — the container rewrites built assets when the public URL
  differs from the baked one, waits for the database, runs `prisma migrate deploy`, and seeds the
  app store, all before the HTTP server starts. Probes are budgeted to ~330 s to ready; do not read
  a slow first boot as a fault before that. The private default is the *fast* path: the baked
  `BUILT_NEXT_PUBLIC_WEBAPP_URL` is `http://localhost:3000` (read out of the pinned image), so
  `replace-placeholder.sh` prints "Nothing to replace" and skips the rewrite entirely.
- **Enterprise-gated / not shipped**: organizations, SAML/SSO and the v2 API. The first two are
  build-ARG-only in the official prebuilt image or licence-gated; the v2 API is a separate image
  with its own Redis dependency. Core scheduling, teams, workflows and booking pages are not gated.
- **A firewall flip takes ~30 s to ~10 minutes to propagate.** After
  `--set publicAccess.enabled=true`, keep re-polling; the catalog's measured high-water mark is
  559 s.
- **The first `helm upgrade` after an install may re-apply the bundled Postgres** and bounce it for
  a minute or two; at `replicas: 1` that is a visible app outage. It is probabilistic, not a chart
  defect.
- **Upstream is mid-rebrand.** `cal.com/docs/self-hosting/docker` now redirects to `cal.diy/docker`
  and names `calcom/cal.diy` — a Docker Hub repository with **zero tags and zero pulls**, and
  `github.com/calcom/cal.com` redirects to `calcom/cal.diy`. Designing from the docs would have
  pinned an image that does not exist. We ship `calcom/cal.com:v6.2.0` (4.7M pulls); expect the
  image line to move, and re-check the repository name at the next version bump.
