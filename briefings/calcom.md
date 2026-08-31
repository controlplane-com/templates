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
| secret (opaque, chart-created) `{release}-calcom-startup` | The app's boot script, mounted at `/cpln/start.sh` and run with `/bin/bash`. REPLACES the image entrypoint |
| identity + 2 policies | One identity for both workloads; `reveal` on exactly those secrets (plus the SMTP secret when configured), and `view` on the ONE install GVC for the boot-time location report |

- **No volumeset on the app** — it is genuinely stateless (upstream's compose mounts no volume;
  avatars live in Postgres), which is what makes `replicas: 2+` work.
- **Private by default.** First run is: install → `cpln port-forward` → `/auth/setup` →
  `helm upgrade --set publicAccess.enabled=true`.
- **Pinned to ONE location.** `defaultOptions.minScale/maxScale: 0` on both workloads, with a
  single `localOptions` entry for `location`. An unasked-for GVC location starts nothing.

## Key knobs

| Knob | Default | Note |
|---|---|---|
| `location` | `aws-us-east-1` | The ONE GVC location Cal.com runs in. Must exist in the GVC or NOTHING starts |
| `calcom.image` | `calcom/cal.com:v6.2.0` | Official image |
| `calcom.replicas` | `1` | `2+` for zero-downtime rolling restarts; no clustering to form |
| `calcom.appUrl` | `""` | Empty = derived; set only for a custom domain, **with** the scheme |
| `calcom.auth.secretName` | `my-calcom-auth` | **Must exist before install** |
| `cron.enabled` | `true` | Turning it off silently stops every scheduled job |
| `email.enabled` | `false` | Off = no confirmations, invites or password resets |
| `publicAccess.enabled` | `false` | Flip only after claiming the admin account |
| `postgres.enabled` / `postgresHA.enabled` | `true` / `false` | Exactly one; the chart fails on both or neither |

## Troubleshooting / considerations

- **The image's own `scripts/start.sh` CANNOT be used, and this is the defect that nearly shipped.**
  It gates the boot on `scripts/wait-for-it.sh`, which at v6.2.0 is the eficode POSIX-sh variant
  testing readiness with `nc -w 1 -z` — and the Control Plane mesh sidecar completes the TCP
  handshake for anything. Proven in-container with three controls that all had to fail and did
  not: a dead port (9999), a nonexistent hostname, and the real port, all "up" in ~0 s. `start.sh`
  also runs `set -x` without `set -e`, so the `prisma migrate deploy` that then failed did not stop
  the boot: Cal.com served HTTP against a schema-less database with `ready: true`, `200` on
  `/api/version` and **0 tables**. It is a race, and a fresh volumeset — the first-install case —
  is the one that loses it. The template now mounts its own `/cpln/start.sh`, which waits by
  sending a **Postgres SSLRequest** (`\x00\x00\x00\x08\x04\xd2\x16\x2f`) and requiring the
  one-byte `S`/`N` reply, three times consecutively, for up to 600 s, and runs under `set -e` so a
  failed migration crash-loops instead of serving. Verified against the pinned image: live
  Postgres → ready; dead port, nonexistent host and an accepts-but-never-replies server (the
  sidecar's shape) → not ready, and the gate exits 1 with a named FATAL; a bad-credentials
  migration exits 1 before `yarn start`. Do not "simplify" this back to the image entrypoint.
  No probe can catch this instead: v6.2.0 has no `/api/health` or equivalent under `apps/web` and
  `/auth/setup` answers 307 against an empty database, so "HTTP listening implies migrations
  applied" is now true by construction rather than by assumption — it was false before.
- **Multi-location GVCs silently split Cal.com — half-fixed, and the half that is not is the
  database.** A workload runs in EVERY location its GVC has, so before pinning, a default install
  into a 3-location GVC produced three app replicas, each bound by service DNS to its own local
  Postgres: three separate databases sharing one `NEXTAUTH_SECRET`, so a session validated against
  a database that did not contain the user. Measured — a table created in `aws-us-east-1` did not
  exist in the other two, and every status surface read green. The app and cron caller are now
  pinned via `defaultOptions` 0/0 + `localOptions`. **The bundled `postgres` /
  `postgres-highly-available` subcharts are NOT pinned**: a parent cannot template a subchart's
  values and neither exposes a location knob (same gap as `plane`, `docmost`, `metabase`). So in a
  multi-location GVC an empty database still starts in every location with its own volumeset —
  idle, never read, and billed. The app reads its own GVC at boot and logs a warning naming them;
  that warning is the only signal a user gets. **The honest statement is: data-splitting is fixed,
  cost sprawl is not.**
- **`location` naming a location the GVC lacks starts NOTHING, with no failed deployment.** The
  platform stores such a `localOptions` entry verbatim and it is simply inert. It cannot be caught
  at boot either — no container runs to complain. README Prerequisites tells the user to check
  `cpln gvc get` first; that is all the defence there is.
- **Liveness `initialDelaySeconds` is 780, deliberately above the 600 s database-wait budget.**
  Lower it and a slow first install is killed mid-wait, and the script's own FATAL diagnostic never
  prints — the operator sees an unexplained restart loop instead.
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
- **Narrowing the bundled Postgres to a `workload-list` that omits the app is a boot hang, not an
  error.** `postgres.internalAccess` is the subchart's own knob and a parent cannot inject into it,
  so the chart hard-fails at render instead, naming the exact link to add;
  `postgres.internalAccess.type: none` is refused outright. `postgres-highly-available` exposes no
  such knob, so the HA path is unaffected.
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
- **First boot is slow by design** — the container waits for the database, rewrites built assets
  when the public URL differs from the baked one, runs `prisma migrate deploy`, and seeds the app
  store, all before the HTTP server starts. Readiness can exhaust its threshold during a slow
  database wait; that is benign, it keeps probing. The private default is the *fast* path: the
  baked `BUILT_NEXT_PUBLIC_WEBAPP_URL` is `http://localhost:3000` (read out of the pinned image),
  so `replace-placeholder.sh` prints "Nothing to replace" and skips the rewrite entirely.
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
