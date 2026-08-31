# Documenso — maintainer briefing

## What it is

- **Documenso** — open-source e-signature (a DocuSign alternative): upload a PDF, place fields, send
  it to signers, get back a cryptographically signed PDF plus a tamper-evident audit trail.
- **AGPL-3.0** at the pinned tag, whole repository, no `/ee` carve-out. Free to self-host, nothing to
  register, and nothing this template ships is feature-gated. (The enterprise surface is CSC/HSM
  signing, Stripe billing and the license-key features — none of which is here, and none of which is
  horizontal scaling.)
- Image `documenso/documenso:v2.17.0`. **Published tags carry the `v`; there is no bare `2.17.0`**
  (`docker manifest inspect documenso/documenso:2.17.0` → `no such manifest`), so `appVersion` is
  `"2.17.0"` while `values.yaml` keeps the `v`.

## Common use cases

- Contracts, NDAs and offer letters signed in-house instead of through a per-seat SaaS.
- Regulated or data-resident work where signed documents may not leave the customer's own cloud.
- Templates plus a REST API for embedding "sign this" into an existing product.

## Architecture on cpln

| Resource | Purpose |
|---|---|
| `{release}-documenso` (**standard** workload, :3000 http) | UI, REST API, signing pages and the background-job runner — one image |
| `{release}-postgres` (subchart, default) *or* `{release}-postgres-ha-*` + `-proxy` (flag) | Users, envelopes, fields, audit log, jobs — and the PDFs themselves when `storage.type: database` |
| `{release}-documenso-identity` + `-policy` | `reveal` on exactly the secrets it reads; carries the AWS cloud-account link in keyless S3 mode |
| `my-documenso-db-credentials` `dictionary` (template-created) | Handed to the app and to whichever Postgres is enabled |
| *(user-created)* `my-documenso-secrets` `dictionary`, `my-documenso-signing-cert` `opaque` | App keys + the certificate passphrase; base64 text of the `.p12` |

- **No volumeset in this chart** — the app tier is genuinely stateless, which is what makes
  `documenso.replicas` real. All durable state is in Postgres or the S3 bucket.
- **`standard`, not `stateful`**, deliberately: nothing needs replica identity, and the
  `cpu:minCpu ≤ 4:1` cap and the dropping of `rolloutOptions.maxUnavailableReplicas` are both
  `stateful`-only. Consequence respected everywhere: bare short DNS names are NXDOMAIN on a standard
  workload, so every hostname the chart emits is fully qualified.
- **Public by default.** Documenso's signers are external by definition — emailed links must resolve
  — so `publicAccess.enabled: true`. There is no weak default credential behind it: logins come from
  a prerequisite secret and email verification is mandatory before the first sign-in.

## Key knobs

| Knob | Default | Notes |
|---|---|---|
| `documenso.image` / `.replicas` | `documenso/documenso:v2.17.0` / `1` | tag keeps the `v`; `2+` = continuity through restarts |
| `documenso.publicUrl` | `""` | empty derives from `$(CPLN_GLOBAL_ENDPOINT)` when public access is on, `http://localhost:3000` (the port-forward origin) when it is off; set with the scheme for a custom domain |
| `secrets.name` | `my-documenso-secrets` | **required prerequisite** `dictionary`: `nextAuthSecret`, `encryptionKey`, `encryptionSecondaryKey`, `signingPassphrase` |
| `signing.certificateSecretName` | `my-documenso-signing-cert` | **required prerequisite** `opaque`, `encoding: plain`, payload = base64 text of the `.p12` |
| `storage.type` / `.documentSizeLimitMb` | `database` / `5` | `s3` for volume; `database` puts PDFs in Postgres |
| `signup.disabled` / `.allowedDomains` | `false` / `""` | close or restrict sign-up right after creating your account |
| `smtp.enabled` | `false` | off = no verification mail, no signature-request mail |
| `telemetry.enabled` | `false` | the published image bakes in live PostHog credentials, so upstream's default is ON |
| `publicAccess.enabled` / `internalAccess.type` | `true` / `same-gvc` | firewall changes take ~30 s to ~10 min |
| `postgres.enabled` / `postgresHA.enabled` | `true` / `false` | exactly one; HA = Patroni (automatic leader failover) + etcd (a consensus store: a majority must agree) |
| `database.name` / `.username` / `.password` | `documenso` / `documenso` / `change-me-documenso-db` | flat, not nested under `credentials:` — a database *name* is not a credential, and the nested form trips lint R12 (as shipped `docmost` and `unleash` both do) |

## Troubleshooting / considerations

- **The first-sign-in trap.** Email verification is mandatory (`emailVerified` NULL → *"Unverified
  email"*) and there is **no admin bootstrap**. With SMTP off the way in is two SQL statements
  against the bundled database — both are in the README's First run section and both were executed
  against the real v2.17.0 schema. Note Documenso auto-creates `serviceaccount@localhost` and
  `deleted-account@localhost`; filter by your own address.
- **`NEXT_PRIVATE_SIGNING_TRANSPORT=local` is load-bearing and easy to miss.** `cert-status.ts`
  short-circuits to `{isAvailable: true}` for any value that is not exactly `local` — **including
  unset**. Measured: with the variable absent and no certificate at all, `/api/health` reports
  `certificate: ok` and `/api/certificate-status` reports `isAvailable: true`. With it set, the same
  container correctly reports `warning` / `false`. The chart sets it explicitly; do not remove it.
- **A missing *or wrong-passphrase* certificate leaves every health surface green.** Measured on the
  real image: a valid `.p12` with a deliberately wrong passphrase gives `status: ok` and
  `isAvailable: true`, because the check never decodes the base64 or opens the PKCS#12. The failure
  appears only at signing time, as `Integrity for the PKCS#12 data is broken!`.
- **`-legacy` is NOT required at v2.17.0.** Upstream's docs still say to use it (issue #1087), but a
  probe inside the image parsed `-legacy`, OpenSSL-3-default and password-less `.p12` files all
  successfully through `P12Signer.create`. The README therefore ships the plain (stronger-encryption)
  `openssl pkcs12 -export` form.
- **The image sets no `NODE_ENV`.** Confirmed by `docker inspect`. Four behaviours key off it, so the
  chart sets `NODE_ENV: production`: without it the session cookie loses its `__Secure-` prefix on an
  HTTPS endpoint, the language cookie loses `secure`, embedding presign tokens accept `expiresIn: 0`,
  and the logger emits pretty text instead of JSON.
- **Telemetry is live in the published image.** The Dockerfile's `ARG` defaults are empty, but the
  release build passes real ones — `docker inspect` shows a PostHog project key and
  `https://eu.i.posthog.com`. Upstream sends a startup event plus an hourly heartbeat (app version,
  installation ID, node ID). `telemetry.enabled: false` renders `DOCUMENSO_DISABLE_TELEMETRY=true`;
  the app reads that as `!!process.env.X`, so any non-empty value disables it and the chart omits the
  variable entirely to enable.
- **Background jobs — including every outgoing email — are triggered over the container's own
  loopback** (`http://127.0.0.1:3000`), with a 150 ms fire-and-forget race. This is deliberate: it
  means `internalAccess.type: none` does not silently stop the app from emailing anyone. Loopback
  reachability was confirmed inside the running image. If mail stops, look at SMTP and the
  `BackgroundJob` rows, not at the firewall.
- **Narrowing the bundled Postgres to a `workload-list` that omits the app is a boot hang, not an
  error.** `postgres.internalAccess` is the subchart's own knob and a parent cannot inject into it,
  so the chart hard-fails at render instead, naming the exact link to add. `postgres.internalAccess.type:
  none` is refused outright. `postgres-highly-available` exposes no such knob, so the HA path is
  unaffected.
- **Rotating a secret does NOT redeploy the workload.** The old certificate or key keeps working
  indefinitely with `ready: true` throughout — run `cpln workload force-redeployment` after any
  rotation, or the "rotation" changed nothing.
- **A missing prerequisite secret wedges the deployment nearly silently.** `cpln logs` returns *zero*
  lines; the only place the missing secret is named is `status.versions[].message` from
  `cpln workload get-deployments`. Recovery takes ~5–10 minutes, or force a redeployment.
- **S3 mode uploads and downloads SERVER-side in the web UI.** `putNormalizedPdfFileServerSide` and
  `getFileServerSide` both run in the Node process (the latter presigns and then fetches the URL
  itself), so an internal-only MinIO/SeaweedFS endpoint is fine for the UI. The REST API v1 and the
  embedded-authoring flows *do* hand presigned URLs to the caller, so those need a client-reachable
  endpoint. `get-file.ts`'s browser-side S3 fetch still exists but is marked dead upstream.
- **`database` storage puts PDFs in Postgres**, so the volumeset fills faster than people expect —
  raise `postgres.volumeset.capacity` or switch to `storage.type: s3` before volume grows.
- **Switching a release from keyless S3 to static keys leaves the old AWS binding on the identity**
  (the API merges cloud bindings and never removes them). Test provider variants with fresh installs.
- **Every replica runs `prisma migrate deploy` at boot**; Prisma's advisory lock serializes them, so
  concurrent starts are safe but the second replica waits.
