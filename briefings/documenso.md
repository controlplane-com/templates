# Documenso — Maintainer Briefing

## What it is
- Documenso: open-source e-signature (a DocuSign alternative). Upload a PDF, place fields, send it to signers, get back a PDF signed with your own certificate plus an audit trail.
- AGPL-3.0, whole repository, no `/ee` gate on anything this template uses. Free to self-host, no registration. The enterprise surface (CSC/HSM signing, billing, license-key features) is not shipped.
- Image `documenso/documenso:v2.22.0` (Docker Hub, official). Tags carry the `v`; `appVersion` is `"2.22.0"`. Runs as `nodejs`, `start.sh` applies Prisma migrations and starts the server on :3000.
- Versions: 1.0.0 = v2.21.1; 1.1.0 = v2.22.0 (image bump only; the upgrade applies three schema migrations at boot: envelope contents and lowercased user/recipient emails); 2.0.0 = same app image, single-instance database moves to PostgreSQL 19 (major bump: a 1.x upgrade needs the image pinned to 18).

## Common use cases
- Contracts, NDAs and offer letters signed in-house instead of through a per-seat SaaS.
- Data-resident signing where signed documents must stay in the customer's own database or bucket.
- Templates plus the REST API to embed "sign this" into an existing product.

## Architecture on cpln
| Resource | Purpose |
|---|---|
| `{release}-documenso` (standard, :3000 http) | UI, REST API, signing pages and background jobs in one image |
| `{release}-postgres` (postgres 4.0.1, default, `postgres:19`, boot guard naming `postgres.image`) or `{release}-postgres-ha` + `-proxy` (postgres-highly-available 3.0.0, patroni-postgres 0.9: new clusters PostgreSQL 18, 1.x clusters stay on 17) | All data, and the PDFs when `storage.type: database`; HA connects through the HAProxy leader endpoint |
| identity + policy | `reveal` on exactly the three prerequisite secrets plus the optional S3-keys and SMTP secrets; keyless S3 attaches only the bucket-scoped policy (no `cpln-connector` since 2.0.0) |

- **Three user-created prerequisite secrets, no chart-created secret:** `secrets.name` (dictionary `nextAuthSecret`, `encryptionKey`, `encryptionSecondaryKey`, `signingPassphrase`), `signing.certificateSecretName` (opaque, plain, base64 text of the `.p12`, read from `NEXT_PRIVATE_SIGNING_LOCAL_FILE_CONTENTS`), and the DB dictionary (`username`, `password`, `database`) named by `postgres.config.credentialsSecretName` or `postgresHA.config.credentialsSecretName`.
- **DB URL** is composed from `$(DB_USER)`, `$(DB_PASSWORD)`, `$(DB_NAME)` env vars that reference the DB secret, so no credential is rendered. Values must be URL-safe.
- **One location:** `defaultOptions` min/max 0 plus one `localOptions` entry for `location`. The bundled database subcharts are not pinned, so the wizard limits the GVC to one location and the README says so.
- **Stateless app tier:** `documenso.replicas` is real (all state in Postgres or S3); Prisma's migration lock serializes concurrent boots.
- **Public by default with open sign-up**, because signers are external and there is no admin bootstrap. The README tells the user to close sign-up after creating their account; the wizard shows that warning in the Sign-up step.
- **Probes:** readiness `GET /api/health` (database error = 500; certificate problem = `status: warning`, still 200); liveness `GET /api/certificate-status`.

## Key knobs
`location` · `documenso.image` / `.replicas` / `.publicUrl` / `.resources` · `secrets.name` · `signing.certificateSecretName` · `signup.disabled` / `.allowedDomains` · `storage.type` (`database` | `s3`, keyless AWS or S3-compatible with a keys secret) · `smtp.*` (+ `auth.secretName`) · `telemetry.enabled` (default off) · `publicAccess` / `internalAccess` · `postgres` / `postgresHA` (exactly one; backup blocks pass through)

## Troubleshooting / considerations
- **Upgrading a 1.x release on the single-instance database (2.0.0 is a major):** its data is PostgreSQL 18, and the postgres 4.0.1 boot guard refuses to start PostgreSQL 19 on it (`{release}-postgres` not ready, `[pg-guard] REFUSING TO START` every 30 s, volume untouched; Documenso's health check fails without its database). Fix: `--set postgres.image=postgres:18` and keep it in values; the guard's log names that path, the wizard field (`Upgrade > Database server > Postgres image`) and the README section (`postgres.upgradeHint`, leave it alone). The Console wizard carries the installed image (a parent migration) and the postgres import warns when a different major is picked. Moving to 19 = side-by-side new release with the same three secrets and storage settings, `pg_dump --clean --if-exists` from the old server (copies the PDFs too in `database` storage; S3 objects stay in the bucket), force-redeployment (README "Upgrading from 1.x"). HA releases upgrade normally and keep PostgreSQL 17; moving a cluster to 18 is pgha's "Upgrading an existing cluster to PostgreSQL 18".
- **No logs, deployment stuck:** a prerequisite secret is missing; read `status.versions[].message` via `cpln workload get-deployments`.
- **First sign-in says "Unverified email":** email verification is mandatory and without SMTP no mail is sent. The README's first-run SQL sets `emailVerified` and the `ADMIN` role.
- **Certificate:** generate it with the default `openssl pkcs12 -export` (AES-256), not `-legacy`. At v2.22.0 `/api/certificate-status` opens the `.p12` with the passphrase, so a wrong passphrase or unreadable file returns `{"isAvailable":false}`. The real proof is a sealed document (`BackgroundJob` "Seal Document" `COMPLETED`), which the e2e checks assert.
- **Boot line `Certificate not found or not readable`:** `start.sh` looks for a certificate file; this chart passes the contents in an env var, so the line always appears and means nothing.
- **Secret rotation** does not redeploy: `cpln workload force-redeployment`. `encryptionKey` must never change (2FA secrets and API tokens become unreadable).
- **`storage.type: database`** grows the Postgres volume with every PDF; raise `volumeset.capacity` or use S3. With S3, a DB backup holds only object keys.
- **First `helm upgrade`** can briefly restart the single-instance Postgres, and Documenso with it.
- **Keyless S3 to static keys on an existing release** leaves the AWS binding on the identity; reinstall to clear it.
- **Signing certificate:** a `-legacy` (RC2) `.p12` loads at v2.22.0. A wrong passphrase or unreadable `.p12` reports `isAvailable: false` and health `warning`, but the workload stays ready; check the certificate status after install.

## Status
2.0.0: single-instance PostgreSQL 19 (postgres 4.0.1, backup image 19.1.0), HA on postgres-highly-available 3.0.0 (new clusters 18, logical backup image 18.2.0), `cpln-connector` dropped from the identity, NOTES.txt upgrade warning, wizard image carry-over + cross-major warning, README "Upgrading from 1.x". CI: `fresh-is-19`, refused-then-pinned upgrade from 1.1.0 (`guard-holds`, `pinned-stays-18`, `signed-document-survives`), and an `ha` variant (fresh HA install, `ha-is-18`).
