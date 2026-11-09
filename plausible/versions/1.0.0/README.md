# Plausible Analytics

This app deploys [Plausible Community Edition](https://plausible.io/self-hosted-web-analytics), privacy-friendly web analytics that uses no cookies (AGPL-3.0). One Plausible workload serves the dashboard, the tracker script and the event API on one port. Events and sessions are stored in a bundled single-node ClickHouse, and accounts, sites and goals in a bundled PostgreSQL. The install is private by default: you register the owner account first, then publish it.

## Architecture

- **Plausible**: `standard` workload on port 8000 with one replica. It serves the dashboard, `/js/*` tracker scripts and `POST /api/event`, and runs the scheduled jobs. It keeps no data of its own. Upgrades start the new replica before the old one stops.
- **PostgreSQL**: the `postgres` template, holding users, teams, sites, goals and the job queue.
- **ClickHouse**: the `clickhouse` template as a single node with `provider: local`, so every event and session is stored on its volume and no bucket is needed.
- **Identity and policies**: the Plausible workload can `reveal` exactly the secrets it reads and `view` its own GVC. At start it checks that the GVC has one location.

The GVC must have **exactly one location**, and `clickhouse.locations[0].name` must be that location. The bundled PostgreSQL runs a separate, empty copy in every location of the GVC, so Plausible refuses to start in a GVC with more than one.

## Prerequisites

**Three secrets must exist BEFORE you install**, or the deployment waits for them with no logs. Their values never pass through Helm values.

**Signing key** (`app.secretKeyBaseSecretName`): an opaque secret of at least 32 bytes. It signs sessions and derives the two-factor encryption key, so keep it for the life of the install.

```bash
printf '%s' "$(openssl rand -base64 48)" | cpln secret create-opaque --name my-plausible-secret-key-base --encoding plain -f -
```

**PostgreSQL credentials** (`postgres.config.credentialsSecretName`): a dictionary secret with `username`, `password` and `database`. Use URL-safe values, because Plausible puts them in its connection URL.

```bash
cpln secret create-dictionary --name my-plausible-db-credentials \
  --entry username=plausible \
  --entry password="$(openssl rand -hex 24)" \
  --entry database=plausible
```

**ClickHouse credentials** (`clickhouse.database.credentialsSecretName`): a dictionary secret with `password` (URL-safe, no quotes) and `database` (a bare identifier).

```bash
cpln secret create-dictionary --name my-plausible-clickhouse-credentials \
  --entry password="$(openssl rand -hex 24)" \
  --entry database=plausible_events_db
```

Optional: an SMTP relay (see [Email](#email)) and a free [MaxMind](https://www.maxmind.com/en/geolite2/signup) licence key for city-level locations.

## Configuration

### Application

```yaml
image: ghcr.io/plausible/community-edition:v3.2.1 # v3.2.1 or newer: the chart refuses older tags (CVE-2026-8467)

resources:
  minCpu: 250m
  maxCpu: 1
  minMemory: 512Mi
  maxMemory: 1Gi

app:
  secretKeyBaseSecretName: my-plausible-secret-key-base
  registration: invite_only # invite_only | true (closed) | false (open to anyone)
  baseUrl: ""               # "" = derived; custom domain: https://stats.example.com
```

- **`registration`**: the first account can always register. After that, `invite_only` admits only users invited from the dashboard.
- **`baseUrl`**: Plausible builds links from it and accepts browser connections only from its host. Empty means the canonical endpoint when public access is on, otherwise `http://localhost:8000` (the port-forward address). Set it, with `https://`, when you serve Plausible on your own domain.

### Email

Without SMTP, Plausible sends no invitations, password resets or email reports.

```yaml
smtp:
  enabled: true
  host: smtp.example.com
  port: 587                 # 465 = implicit TLS; other ports use STARTTLS when the relay offers it
  fromEmail: analytics@example.com
  fromName: Plausible
  credentialsSecretName: my-plausible-smtp # dictionary with username and password; "" = no relay auth
```

### Geolocation

The bundled DB-IP database gives countries. A MaxMind licence key, stored in an opaque secret, adds regions and cities:

```yaml
geoip:
  maxmindLicenseKeySecretName: my-plausible-maxmind
  maxmindEdition: GeoLite2-City   # or GeoLite2-Country
```

### Access

```yaml
publicAccess:
  enabled: false # true = dashboard, tracker script and /api/event on the canonical *.cpln.app endpoint

internalAccess:
  type: same-gvc # options: none, same-gvc, same-org, workload-list
  workloads: []  # used with workload-list, e.g. //gvc/GVC_NAME/workload/WORKLOAD_NAME
```

### Bundled stores

```yaml
postgres:
  config:
    credentialsSecretName: my-plausible-db-credentials
  volumeset:
    capacity: 10 # GiB

clickhouse:
  provider: local
  locations:
    - name: aws-us-east-1 # the one location of your GVC
      replicas: 1
  database:
    credentialsSecretName: my-plausible-clickhouse-credentials
  volumeset:
    server:
      capacity: 10 # GiB; holds all analytics data
```

Every knob of the `postgres` template is available under `postgres`, including scheduled backups (`postgres.backup.enabled: true` with `provider: aws`, `gcp` or `minio`; see that template's README for the bucket setup). ClickHouse is limited to one location with one replica.

## Connecting

| What | Value |
|---|---|
| Local access (public access off) | `cpln port-forward {release}-plausible 8000:8000 --gvc {gvc}`, then open `http://localhost:8000` |
| Public URL | `status.canonicalEndpoint` from `cpln workload get {release}-plausible --gvc {gvc} -o yaml`, when `publicAccess.enabled: true` |
| Tracker script | `https://{canonical-endpoint}/js/script.js`; the dashboard shows the snippet for each site |
| Event API | `https://{canonical-endpoint}/api/event` |
| In-GVC | `http://{release}-plausible.{gvc}.cpln.local:8000`, subject to `internalAccess.type` |
| ClickHouse (raw events) | `http://{release}-clickhouse-server.{gvc}.cpln.local:8123`, user `default` with the password from your ClickHouse secret |

### First run

Until the first account exists, anyone who can open Plausible can register as its owner. Register over a private tunnel first:

1. Install with `publicAccess.enabled: false` (the default).
2. Run `cpln port-forward {release}-plausible 8000:8000 --gvc {gvc}` and open `http://localhost:8000`. Plausible redirects to `/register`; create the owner account and add your first site.
3. Run `cpln helm upgrade` with `publicAccess.enabled: true`. Firewall changes take a few minutes to propagate.
4. Log in again at the canonical URL. Your account and sites are kept. Then add the tracker snippet to your site.

Use `http://localhost:8000` in step 2, not another host name: Plausible accepts browser connections only from the host of its base URL.

## Important Notes

- **Tracking needs `publicAccess.enabled: true`.** Visitors' browsers must reach the tracker script and `/api/event`.
- **One app replica.** Plausible keeps each visitor's open session in the replica's memory, so several replicas would split visits and distort bounce rate and visit duration. A restart of the replica is a short outage, and tracker hits during it are lost.
- **Analytics events are not backed up.** They live only on the ClickHouse volume, which this chart does not snapshot. Uninstalling deletes the volumes and all data.
- **Do not change the signing key.** A new `SECRET_KEY_BASE` logs everyone out and breaks two-factor logins for every enrolled user.
- **A deployment that never starts and shows no logs** is a missing prerequisite secret. Check `cpln workload get-deployments {release}-plausible --gvc {gvc} -o yaml`, field `status.versions[].message`.
- **A `FATAL` about the location in the Plausible log** means `clickhouse.locations[0].name` is not your GVC's location, or the GVC has more than one location.
- **Visitor IP and country** come from the leftmost `X-Forwarded-For` entry.
- **Community Edition** has no funnels, ecommerce revenue goals, SSO or Sites API; those are Plausible Cloud features. The Stats API and shared dashboard links are available.

## Links

- [Plausible documentation](https://plausible.io/docs)
- [Community Edition repository](https://github.com/plausible/community-edition)
- [Community Edition configuration](https://github.com/plausible/community-edition/wiki/configuration)
- [Events API](https://plausible.io/docs/events-api)
- [Plausible v3.2.1 release notes](https://github.com/plausible/analytics/releases/tag/v3.2.1)
