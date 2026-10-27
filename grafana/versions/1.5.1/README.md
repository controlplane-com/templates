# Grafana

This app deploys [Grafana](https://grafana.com/oss/grafana/) OSS — dashboards and alerting over **your own datasources**: the marketplace's Prometheus/Thanos/Mimir installs, your databases, and external systems. Control Plane's console already ships built-in workload-metrics dashboards, so this template bundles **no dashboards and no datasources** — it is the pane for the data you own. All Grafana state lives in the bundled PostgreSQL app database; the Grafana tier itself is stateless and can run multi-replica with Redis-coordinated alerting HA.

## Architecture

- **Grafana**: Standard (stateless) workload serving the UI and API on port 3000; `replicas` instances share the Postgres app database.
- **PostgreSQL (HA, default)** (subchart): the `postgres-highly-available` template — 3× Patroni Postgres, 3× etcd, and an HAProxy leader endpoint Grafana connects through.
- **PostgreSQL (dev/lightweight, optional)** (subchart): the single-instance `postgres` template instead, for lighter deployments.
- **Redis Sentinel (optional)** (subchart): alerting-HA coordination — required when `replicas >= 2` so exactly one alert notification is sent.
- **Database credentials secret** (dictionary): *not created by this template*. You create it before install; the enabled PostgreSQL initializes from it and Grafana connects with it.
- **Secrets, identity, and policy**: an optional datasource-provisioning file, and a least-privilege policy granting the Grafana identity `reveal` on exactly the secrets it uses, including your prerequisite secrets.
- **Optional database backups** (subchart): logical dumps or WAL-G archiving to S3, GCS, or an S3-compatible endpoint.

## Prerequisites

**Three secrets must exist BEFORE you install** — the install will wedge waiting on them otherwise. None of these values ever passes through Helm values, so none lands in the release.

1. **Database credentials** (dictionary) — the bundled PostgreSQL initializes with these and Grafana connects with them. Set `postgresHA.config.credentialsSecretName` (HA, the default) or `postgres.config.credentialsSecretName` (single-instance) to its name:

   ```bash
   cpln secret create-dictionary --name my-grafana-db-credentials \
     --entry username=grafana \
     --entry password="$(openssl rand -hex 24)" \
     --entry database=grafana
   ```

   Postgres reads it only when its data directory is first initialized; to change the password later, run `ALTER ROLE` first, then update the secret and right away force a redeployment of the Grafana workload (single-instance; in HA mode see the README's HA rotation steps). Do not redeploy the database: PostgreSQL reads the secret only when it is first initialized, so restarting it only adds downtime.

2. **Admin password** (`admin.passwordSecretName`) — the first-boot password for the `admin` login, which is reachable from the public internet while `publicAccess.enabled: true`. Use your own strong password. Needed only for the initial install: after your first login you can set `admin.applyPassword: false` and delete it.

   ```bash
   printf '%s' 'YOUR-STRONG-PASSWORD' | cpln secret create-opaque --name my-grafana-admin-password --encoding plain -f -
   ```

3. **Encryption key** (`admin.secretKeySecretName`) — encrypts every datasource credential Grafana stores in the database. Unlike the password, this one is read on every boot and must stay for the life of the install. Generate a random one, and **back it up**:

   ```bash
   printf '%s' "$(openssl rand -hex 32)" | cpln secret create-opaque --name my-grafana-secret-key --encoding plain -f -
   ```

Other prerequisites, only if you use the matching feature:

- For credentialed provisioned datasources: a **dictionary** secret per `datasources.credentialSecrets` entry, created **before install** (see [Provisioning datasources](#provisioning-datasources)).
- For authenticated SMTP: an **opaque** secret (encoding `plain`) holding the SMTP password, created **before install**.
- For optional database backups: a bucket and access setup on AWS S3, Google Cloud Storage, or a MinIO/S3-compatible server (see [Backup storage setup](#backup-storage-setup)). With `provider: minio` (either database mode), the endpoint's keys are a prerequisite `dictionary` secret — see that section.

**If a required secret does not exist at install time the deployment wedges silently.** `cpln logs` returns zero lines, because the container never starts. The only diagnostic is `status.versions[].message` in `cpln workload get-deployments RELEASE_NAME-grafana --gvc GVC_NAME -o yaml` (note **`get-deployments`**; plain `cpln workload get` has no `versions` key). Create the missing secret and it recovers on its own after several minutes, or skip the wait with `cpln workload force-redeployment RELEASE_NAME-grafana --gvc GVC_NAME`.

## Configuration

### Grafana

```yaml
image: grafana/grafana:13.1.1

replicas: 1                   # >=2 = HA over the shared Postgres; requires redis.enabled: true

resources:
  maxCpu: 1000m
  maxMemory: 1Gi
  minCpu: 500m
  minMemory: 512Mi

admin:                        # both secrets must exist BEFORE install — see Prerequisites
  user: admin                 # initial admin login name (not sensitive)
  applyPassword: true         # Set to false after your first login to stop referencing the password secret, which can then be deleted
  passwordSecretName: my-grafana-admin-password # opaque secret holding the first-boot admin password; read only while applyPassword is true
  secretKeySecretName: my-grafana-secret-key # opaque secret holding the datasource-encryption key; permanent — never delete, never rotate
```

The two secrets have **different lifecycles**. `GF_SECURITY_ADMIN_PASSWORD` is honored only when the admin account is first created — afterwards Grafana ignores it, and the password can only be changed in the UI or with `grafana-cli admin reset-admin-password`. So once you have logged in, set `applyPassword: false` and upgrade; the chart then stops referencing that secret entirely (no env var, no policy grant) and you can delete it. The encryption-key secret is read on **every** boot to decrypt stored datasource credentials, so it has no such toggle and must stay for the life of the install.

### Access

```yaml
publicAccess:
  enabled: true               # UI on the canonical *.cpln.app HTTPS endpoint

internalAccess:               # internal firewall scope (in-GVC callers)
  type: same-gvc              # none, same-gvc, same-org, workload-list
  workloads: []               # used with workload-list, e.g. //gvc/GVC/workload/NAME
```

### PostgreSQL

Exactly one of the two databases must be enabled (the chart enforces this at render). Set `credentialsSecretName` on the one you enable.

```yaml
postgresHA:                   # default: highly available PostgreSQL
  enabled: true
  config:
    credentialsSecretName: my-grafana-db-credentials # PREREQUISITE dictionary secret (username, password, database), must exist BEFORE install
  replicas: 3
  volumeset:
    capacity: 10              # GiB per replica
  backup:
    enabled: false            # optional — see Backup storage setup
```

```yaml
postgresHA:
  enabled: false
postgres:                     # dev/lightweight: single-instance PostgreSQL
  enabled: true
  config:
    credentialsSecretName: my-grafana-db-credentials # PREREQUISITE dictionary secret (username, password, database), must exist BEFORE install
  volumeset:
    capacity: 10              # GiB
  backup:
    enabled: false            # optional — see Backup storage setup
```

### High availability

```yaml
replicas: 2                   # any value >= 2
redis:                        # Sentinel-mode Redis coordinating alert evaluation
  enabled: true               # required when replicas >= 2
```

### SMTP (alert emails)

```yaml
smtp:
  enabled: false
  host: smtp.example.com:587  # host:port
  user: ""                    # empty = unauthenticated SMTP
  passwordSecretName: ""      # pre-created opaque secret (encoding: plain); required when user is set
  fromAddress: grafana@example.com
  fromName: Grafana
```

## Provisioning datasources

`datasources.definitions` entries are standard [Grafana provisioning](https://grafana.com/docs/grafana/latest/administration/provisioning/#data-sources) entries, passed through verbatim (provisioned datasources are read-only in the UI). Point them at your own datasources — for the marketplace `prometheus` and `thanos` templates in the same GVC:

```yaml
datasources:
  definitions:
    - name: Prometheus
      type: prometheus
      access: proxy
      url: http://RELEASE-prometheus.GVC.cpln.local:9095 # prometheus template
      isDefault: true
    - name: Thanos
      type: prometheus
      access: proxy
      url: http://RELEASE-thanos.GVC.cpln.local:10902    # thanos Query template
```

`datasources.credentialSecrets` holds the credentials **Grafana authenticates to each datasource with** — not user access to Grafana. `definitions` renders into a plaintext provisioning file, so put the password in a pre-created **dictionary** secret and write `$KEY` in the definition instead. Every `$KEY` you use needs an entry here, and the secrets must exist before install.

1. Create the secret, e.g. `my-grafana-ds-credentials` with key `PG_PASSWORD`:

   ```bash
   cpln secret create-dictionary --name my-grafana-ds-credentials --entry PG_PASSWORD=YOUR-DB-PASSWORD
   ```

2. List it under `datasources.credentialSecrets` — each key becomes an env var of that name, and the chart grants the workload `reveal` on exactly that secret.
3. Reference `$PG_PASSWORD` in the provisioning entry (Grafana interpolates env vars in provisioning files).

```yaml
datasources:
  definitions:
    - name: AppDB
      type: postgres
      url: my-db-host:5432
      user: grafana_reader
      jsonData: { database: appdb, sslmode: disable }
      secureJsonData:
        password: $PG_PASSWORD
  credentialSecrets:
    - name: my-grafana-ds-credentials
      keys: [PG_PASSWORD]
```

### Platform metrics as a datasource

The platform's own metrics store is Prometheus-compatible and holds more than the built-in dashboards display — including any [custom metrics](https://docs.controlplane.com/reference/workload/custom-metrics) your workloads expose via a container `metrics` block, cost-relevant series (`egress`, `cross_zone_traffic`, `volume_set_*`), and cron/stability counters. To dashboard and alert on those alongside your other datasources, add it per the [centralized metrics guide](https://docs.controlplane.com/guides/centralized-metrics-management):

1. Create a service account with the `readMetrics` org permission and generate a key (a workload's built-in `CPLN_TOKEN` will NOT authenticate to the metrics endpoint).
2. Put the key in a dictionary secret (e.g. key `CPLN_METRICS_TOKEN`) and list it under `datasources.credentialSecrets`.

```yaml
datasources:
  definitions:
    - name: Control Plane metrics
      type: prometheus
      access: proxy
      url: https://metrics.cpln.io/metrics/org/YOUR_ORG
      jsonData:
        httpHeaderName1: Authorization
      secureJsonData:
        httpHeaderValue1: Bearer $CPLN_METRICS_TOKEN
  credentialSecrets:
    - name: my-grafana-ds-credentials
      keys: [CPLN_METRICS_TOKEN]
```

This complements the built-in workload dashboards rather than replacing them — use it when you need custom app metrics, cost views, alerting you own, or one pane mixing platform metrics with your other datasources.

## Connecting

| What | Value |
|---|---|
| UI / API (public) | the canonical endpoint — read `status.canonicalEndpoint` from `cpln workload get {release}-grafana --gvc {gvc} -o yaml` |
| Internal (same GVC) | `http://{release}-grafana.{gvc}.cpln.local:3000` |
| Login | `admin.user` / the payload of the `admin.passwordSecretName` secret |
| Postgres (internal, HA mode) | `{release}-postgres-ha-proxy.{gvc}.cpln.local:5432`, credentials from your `postgresHA.config.credentialsSecretName` secret (`cpln secret reveal SECRET_NAME -o yaml`) |
| Postgres (internal, single mode) | `{release}-postgres.{gvc}.cpln.local:5432`, credentials from your `postgres.config.credentialsSecretName` secret |

## Upgrading from 1.4.1

`postgres.credentials` was removed: the database credentials are now a prerequisite secret, the same one the bundled database template requires on its own. Carrying the old key forward fails the render.

1.4.1 created the database secret itself, so **this upgrade deletes it**. Before upgrading, create a secret under a **new** name holding the values your database was initialized with, not new ones, or Grafana loses its database connection:

```bash
cpln secret create-dictionary --name RELEASE_NAME-grafana-db \
  --entry username=grafana --entry password='YOUR_CURRENT_PASSWORD' --entry database=grafana
```

Then upgrade with `postgres.credentials` removed and the `credentialsSecretName` of the mode you use (`postgresHA.config.credentialsSecretName` by default) set to that name. Your current values are in `postgres.credentials` of the 1.4.1 release, and also in the old secret (`cpln secret reveal my-grafana-db-credentials -o yaml`, or the name your release set in `credentialsSecretName`) until the upgrade deletes it.

The upgrade restarts the bundled PostgreSQL too (it now reads the new secret), so Grafana can briefly lose its database; it reconnects by itself. The new version of a workload can also wait about 10 minutes with `is not allowed to reveal the secret` in `get-deployments`, while access to the new secret propagates; the previous version keeps serving meanwhile, and it clears by itself.

## Backup storage setup

Only needed when backups are enabled (`postgresHA.backup.enabled` or `postgres.backup.enabled`). Complete the steps for your provider before installing.

### AWS S3

1. Create your S3 bucket. Set `backup.aws.bucket` and `backup.aws.region`.
2. If you do not have one, create a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account) for your AWS account. Set `backup.aws.cloudAccountName`.
3. Create an AWS IAM policy with the JSON below (replace `YOUR_BUCKET`), then set `backup.aws.policyName` to the policy's name:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:ListBucket", "s3:GetBucketLocation", "s3:GetObject", "s3:GetObjectVersion",
               "s3:PutObject", "s3:DeleteObject", "s3:DeleteObjectVersion", "s3:AbortMultipartUpload"],
    "Resource": ["arn:aws:s3:::YOUR_BUCKET", "arn:aws:s3:::YOUR_BUCKET/*"]
  }]
}
```

### Google Cloud Storage

1. Create your GCS bucket. Set `backup.gcp.bucket`.
2. If you do not have one, create a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account) for your GCP project. Set `backup.gcp.cloudAccountName` — access is keyless (no stored credentials).
3. Grant the **Storage Admin** role (`roles/storage.objectAdmin` scoped to the bucket also works) to the GCP service account created for the cloud account.

### S3-compatible (MinIO, R2, Wasabi, …)

1. Create your bucket on the server. Set `backup.minio.bucket`.
2. Set `backup.minio.endpoint` to the S3 API address including port. For the `minio` marketplace template in the same GVC, this is `http://WORKLOAD_NAME.GVC_NAME.cpln.local:9000`.
3. Create a `dictionary` secret holding the bucket credentials, and set `credentialsSecretName` to its name on whichever store you use — `postgresHA.backup.minio.credentialsSecretName` or `postgres.backup.minio.credentialsSecretName`. Both take the same secret:

```bash
cpln secret create-dictionary --name my-grafana-minio-credentials \
  --entry accessKey=YOUR_ACCESS_KEY \
  --entry secretKey=YOUR_SECRET_KEY
```

## Rotating the database password in HA mode

The HA database (`postgresHA`) needs its own order. The replication role `repl` shares the password, and a member that restarts with the old password can be promoted to leader, which splits the cluster. Move the leader to member `-0` first, so it restarts last, after every other member already has the new password. `pgx` runs a command in one member (`LOCATION` is your GVC's location, `DB_USERNAME` the secret's `username`):

```bash
pgx() { cpln workload exec RELEASE_NAME-postgres-ha --gvc GVC_NAME --location LOCATION \
  --container patroni-postgres --replica "RELEASE_NAME-postgres-ha-$1" -- "${@:2}"; }
# 1. Find the leader ("role": "leader"); the other two must be "streaming" on the same "timeline"
pgx 0 curl -s localhost:8008/cluster
# 2. If the leader is not RELEASE_NAME-postgres-ha-0, move it there (N = current leader), then repeat step 1
pgx 0 curl -s -XPOST -d '{"leader":"RELEASE_NAME-postgres-ha-N","candidate":"RELEASE_NAME-postgres-ha-0"}' localhost:8008/switchover
# 3-5. Back to back: change BOTH roles on -0, put the same password in the secret, restart the members
pgx 0 psql -h 127.0.0.1 -d postgres -c "ALTER ROLE DB_USERNAME PASSWORD 'NEW_PASSWORD'; ALTER ROLE repl PASSWORD 'NEW_PASSWORD';"
cpln secret edit SECRET_NAME
cpln workload force-redeployment RELEASE_NAME-postgres-ha --gvc GVC_NAME
# 6. After ~5-7 minutes, confirm one leader and two "streaming" replicas on one timeline (repeat step 1)
# 7. Optional: remove the install-time password Patroni keeps in its cluster config
pgx 0 curl -s -XPATCH -d '{"postgresql":{"authentication":null}}' localhost:8008/config
```

Then force-redeploy `RELEASE_NAME-grafana`, which keeps the old password until it restarts. The database itself drops connections for roughly 10–60 s at each switchover, but the app cannot open new connections from the `ALTER ROLE` until its own redeploy finishes (several minutes in all), so rotate in a quiet window. If a member stays `starting`, or `running` without `streaming` for several minutes, re-copy it from the leader. This copies the whole database, so it costs network traffic in proportion to its size:

```bash
pgx N curl -s -XPOST -d '{"force": true}' localhost:8008/reinitialize
```

## Important Notes

- **Create the database-credentials, admin-password and encryption-key secrets BEFORE installing** (see Prerequisites) — the deployment wedges waiting on a secret that does not exist, with zero log lines.
- **After your first login, set `admin.applyPassword: false` and upgrade** — the chart then stops referencing the password secret, so you can delete it. The admin password applies only when the account is first created; change it in the Grafana UI thereafter. Expect logins to return 401 and `/api/health` 503 for **a minute or two** after the upgrade while the bundled database restarts — this is not the toggle breaking authentication; logins work again once the database is back.
- **The encryption-key secret must remain forever, and must never be rotated.** It is read on every boot to decrypt stored datasource credentials; deleting it wedges the workload and changing its payload makes every saved datasource secret undecryptable — back it up instead.
- **Don't point Grafana at Control Plane's built-in workload metrics** — those dashboards already exist in the console; this template is for your own datasources.
- **Scaling**: set `replicas >= 2` together with `redis.enabled: true` — the chart refuses to render multi-replica without Redis, which coordinates alerting so only one notification is sent per alert.
- **Dashboards you create persist in Postgres** and survive Grafana restarts and redeploys; **uninstall deletes the database volumesets** — enable backups if the data matters.
- **Grafana Live push updates are per-instance** in multi-replica mode — dashboard auto-refresh and alerting are unaffected.
- **Upgrading from 1.2.x or 1.3.x**: the old database keys (`postgres.config.username/password/database` in single-instance mode, `postgresHA.postgres.*` in HA mode) fail the render. Put the values your database was initialized with into the database credentials secret under Prerequisites, set the `credentialsSecretName` of the mode you use to its name, and remove the old keys. `postgres.backup.minio.accessKey`/`secretKey` and `postgresHA.backup.minio.accessKey`/`secretKey` moved to a prerequisite secret the same way (see Backup storage setup).
- **Rotating any prerequisite secret needs a forced redeployment** (`cpln workload force-redeployment`) — a running workload keeps the values it started with. For the database password, run `ALTER ROLE` first: Postgres keeps the password it was initialized with, so a new value in the secret alone breaks Grafana's login to the database.
- **This template ships Grafana OSS only** — Enterprise features (RBAC, reporting, query caching) are not available.
- **Rotating the database password in HA mode needs a leader switchover first** — follow [Rotating the database password in HA mode](#rotating-the-database-password-in-ha-mode). A plain redeploy can promote a member still holding the old password and split the cluster.

## Links

- [Grafana documentation](https://grafana.com/docs/grafana/latest/)
- [Provisioning datasources](https://grafana.com/docs/grafana/latest/administration/provisioning/#data-sources)
- [Alerting high availability](https://grafana.com/docs/grafana/latest/alerting/set-up/configure-high-availability/)
- [Configuration reference](https://grafana.com/docs/grafana/latest/setup-grafana/configure-grafana/)
- [Grafana HTTP API](https://grafana.com/docs/grafana/latest/developers/http_api/)
