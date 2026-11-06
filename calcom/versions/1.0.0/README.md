# Cal.com

Open-source scheduling: public booking pages, event types, availability and calendar connections, a self-hosted alternative to Calendly. This template deploys the Cal.com app with a caller for its scheduled jobs and a bundled PostgreSQL, single-instance by default and highly available behind one flag. It installs **private**: you create the admin account over a port-forward, then publish.

## Architecture

- **`{release}-calcom`**: a `standard` workload on HTTP :3000 serving the UI, booking pages and `/api/*`. Each start waits for PostgreSQL, applies database migrations and seeds the app store before serving. Pinned to `location`.
- **`{release}-calcom-cron`** *(optional, on by default)*: one replica of the same image that calls Cal.com's scheduled-job endpoints every minute (queued email, calendar sync, credential refresh). Cal.com runs no scheduler of its own.
- **`{release}-postgres`**: the bundled `postgres` template (default), holding all Cal.com data.
- **`{release}-postgres-ha` + `{release}-postgres-ha-proxy`** *(optional)*: the `postgres-highly-available` template instead: 3 Patroni replicas, 3 etcd and an HAProxy leader endpoint.
- **Identity and policies**: `reveal` on exactly the secrets Cal.com reads, and `view` on the install GVC so the app can log a warning when the GVC has other locations.

## Prerequisites

Two `dictionary` secrets must exist **before** you install, in a GVC with **one location**. If a secret is missing, the deployment waits with no log lines; `cpln workload get-deployments {release}-calcom --gvc {gvc} -o yaml` names it under `status.versions[].message`.

**1. Application keys** (`calcom.auth.secretName`). `encryptionKey` must be exactly 32 characters:

```bash
cpln secret create-dictionary --name my-calcom-auth \
  --entry nextAuthSecret="$(openssl rand -hex 32)" \
  --entry encryptionKey="$(openssl rand -hex 16)" \
  --entry cronSecret="$(openssl rand -hex 32)" \
  --entry cronApiKey="$(openssl rand -hex 32)"
```

**2. Database credentials** (`postgres.config.credentialsSecretName`, or `postgresHA.config.credentialsSecretName` in HA mode). The bundled PostgreSQL initializes with them and Cal.com puts them in a connection URL, so keep all three values URL-safe:

```bash
cpln secret create-dictionary --name my-calcom-db-credentials \
  --entry username=calcom --entry password="$(openssl rand -hex 24)" --entry database=calcom
```

Optional: an SMTP relay login (`email.auth.secretName`, keys `username` and `password`) and a backup bucket.

## Configuration

### Location

```yaml
location: aws-us-east-1   # the ONE location of your GVC that Cal.com runs in; it must already be a GVC location
```

### Application

```yaml
calcom:
  image: calcom/cal.com:v6.2.0
  replicas: 1          # stateless; 2+ keeps the UI up through a rolling restart
  appUrl: ""           # empty = canonical endpoint (http://localhost:3000 when private); custom domain with scheme, e.g. https://cal.example.com
  resources: { minCpu: 500m, maxCpu: 2, minMemory: 1Gi, maxMemory: 4Gi }   # boot runs migrations and the app-store seed
  auth:
    secretName: my-calcom-auth   # application keys (Prerequisites 1)
```

### Scheduled Jobs

```yaml
cron:
  enabled: true        # calls Cal.com's scheduled-job endpoints every minute; needs internalAccess.type other than none
  resources: { cpu: 100m, memory: 128Mi }
```

### Email

```yaml
email:
  enabled: false       # off = no booking confirmations, invites or password resets
  fromAddress: no-reply@example.com
  fromName: Cal.com
  host: smtp.example.com
  port: 587
  auth:
    secretName: ""     # optional dictionary with username + password, e.g. my-calcom-smtp; empty = unauthenticated relay
```

### Access

```yaml
publicAccess:
  enabled: false       # claim the admin account over `cpln port-forward` first, then set true
internalAccess:
  type: same-gvc       # none | same-gvc | same-org | workload-list
  workloads: []        # workload-list only; this release's own workloads are always added
```

### Database

```yaml
# set postgresHA.enabled: true (and postgres.enabled: false) for near-zero-downtime upgrades and failover
postgres:
  enabled: true
  image: postgres:18
  config: { credentialsSecretName: my-calcom-db-credentials }   # Prerequisites 2
  resources: { minCpu: 250m, maxCpu: 1, minMemory: 512Mi, maxMemory: 1Gi }
  volumeset: { capacity: 10 }   # GiB (minimum 10)
  backup: { enabled: false }    # scheduled pg_dump; provider aws | gcp | minio, schedule "0 2 * * *"
postgresHA:
  enabled: false
  config: { credentialsSecretName: my-calcom-db-credentials }   # same shape, in HA mode
  replicas: 3
  volumeset: { capacity: 10 }   # GiB per replica (minimum 10)
  backup: { enabled: false }    # mode logical (logical.schedule) | wal-g (walg.intervalSeconds)
```

The full `backup` blocks in `values.yaml` pass straight through to the `postgres` and `postgres-highly-available` templates, whose READMEs carry the bucket, cloud account and IAM policy setup and the restore steps.

## Connecting

| Target | Address | Credentials |
|---|---|---|
| Private UI (default) | `cpln port-forward {release}-calcom 3000:3000 --gvc {gvc}`, then `http://localhost:3000` | your account |
| Public UI and booking pages | `status.canonicalEndpoint` of `cpln workload get {release}-calcom --gvc {gvc} -o yaml`, with `publicAccess.enabled: true` | your account |
| Internal | `http://{release}-calcom.{gvc}.cpln.local:3000` | your account |
| Version | `GET /api/version` | none |
| PostgreSQL | `{release}-postgres.{gvc}.cpln.local:5432`, or `{release}-postgres-ha-proxy.{gvc}.cpln.local:5432` in HA mode | the database credentials secret |

### First Run

Whoever completes `/auth/setup` first becomes the instance admin, so the install starts private:

1. Install with `publicAccess.enabled: false` (the default).
2. Run `cpln port-forward {release}-calcom 3000:3000 --gvc {gvc}` and open `http://localhost:3000/auth/setup`. Use `http://localhost:3000` exactly: while private, Cal.com issues its session cookie for that origin.
3. Create your admin account.
4. Set `publicAccess.enabled: true` and upgrade the release. A firewall change takes from 30 seconds to several minutes to take effect.

## Important Notes

- **Install into a GVC with one location** and set `location` to it: if the GVC lacks that location, Cal.com runs no replica at all. The bundled PostgreSQL starts in every GVC location; the app logs `also has locations this release does not use` when that happens.
- **Never replace `encryptionKey`**: it encrypts every connected calendar and app credential. Rotating any other key does not restart Cal.com; run `cpln workload force-redeployment {release}-calcom --gvc {gvc}` (and `{release}-calcom-cron` for `cronSecret`) afterwards.
- **Keep the scheduled-job caller on** unless you call the endpoints yourself: without it queued email, calendar sync and credential refresh never run while Cal.com still reports healthy.
- **Turn email on before inviting anyone**: without SMTP, booking confirmations, invites and password resets are not sent.
- **If PostgreSQL does not answer within 240 seconds, the app exits** with `[calcom] FATAL: PostgreSQL at ... did not answer` and retries; check the database workload.
- **Created a missing prerequisite secret after install?** The deployment does not retry on its own: run `cpln workload force-redeployment {release}-postgres --gvc {gvc}` and the same for `{release}-calcom`.
- **Any firewall change restarts Cal.com**; at `calcom.replicas: 1` that is about a minute of downtime, so set `replicas: 2` for zero-downtime changes.
- **This template runs the official image without a Cal.com license key**: teams work, while Workflows, Organizations and other licensed features stay locked. Calendar and video integrations (Google, Outlook, Zoom) need your own OAuth app credentials, which this template does not configure. The separate v2 API service is not included.

## Links

- [Cal.com](https://cal.com/)
- [Self-hosting with Docker](https://cal.diy/docker)
- [Source and releases](https://github.com/calcom/cal.com/releases)
- [Environment variables at v6.2.0](https://github.com/calcom/cal.com/blob/v6.2.0/.env.example)
- [Published image](https://hub.docker.com/r/calcom/cal.com)
