# Grafana

This app deploys [Grafana](https://grafana.com/oss/grafana/) OSS — dashboards and alerting over **your own datasources**: the marketplace's Prometheus/Thanos/Mimir installs, your databases, and external systems. Control Plane's console already ships built-in workload-metrics dashboards, so this template bundles **no dashboards and no datasources** — it is the pane for the data you own. All Grafana state lives in the bundled PostgreSQL app database; the Grafana tier itself is stateless and can run multi-replica with Redis-coordinated alerting HA.

## Architecture

- **Grafana**: Standard (stateless) workload serving the UI and API on port 3000; `replicas` instances share the Postgres app database.
- **PostgreSQL (HA, default)** (subchart): the `postgres-highly-available` template — 3× Patroni Postgres, 3× etcd, and an HAProxy leader endpoint Grafana connects through.
- **PostgreSQL (dev/lightweight, optional)** (subchart): the single-instance `postgres` template instead, for lighter deployments.
- **Redis Sentinel (optional)** (subchart): alerting-HA coordination — required when `replicas >= 2` so exactly one alert notification is sent.
- **Secrets, identity, and policy**: an optional datasource-provisioning file, and a least-privilege policy granting the Grafana identity `reveal` on exactly the secrets it uses — including your two prerequisite secrets.
- **Optional database backups** (subchart): logical dumps or WAL-G archiving to S3, GCS, or an S3-compatible endpoint.

## Prerequisites

**Two opaque secrets must exist BEFORE you install** — the install will wedge waiting on them otherwise. Neither value ever passes through Helm values, so neither lands in the release.

1. **Admin password** (`admin.passwordSecretName`) — the first-boot password for the `admin` login, which is reachable from the public internet while `publicAccess.enabled: true`. Use your own strong password. Needed only for the initial install: after your first login you can set `admin.applyPassword: false` and delete it.

   ```bash
   printf '%s' 'YOUR-STRONG-PASSWORD' | cpln secret create-opaque --name my-grafana-admin-password --encoding plain -f -
   ```

2. **Encryption key** (`admin.secretKeySecretName`) — encrypts every datasource credential Grafana stores in the database. Unlike the password, this one is read on every boot and must stay for the life of the install. Generate a random one, and **back it up**:

   ```bash
   printf '%s' "$(openssl rand -hex 32)" | cpln secret create-opaque --name my-grafana-secret-key --encoding plain -f -
   ```

Other prerequisites, only if you use the matching feature:

- For credentialed provisioned datasources: a **dictionary** secret per `datasources.credentialSecrets` entry, created **before install** (see [Provisioning datasources](#provisioning-datasources)).
- For authenticated SMTP: an **opaque** secret (encoding `plain`) holding the SMTP password, created **before install**.
- For optional database backups: a bucket and access setup on AWS S3, Google Cloud Storage, or a MinIO/S3-compatible server (see [Backup storage setup](#backup-storage-setup)).

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

Exactly one of the two databases must be enabled (the chart enforces this at render).

```yaml
postgresHA:                   # default: highly available PostgreSQL
  enabled: true
  postgres:
    username: grafana
    password: change-me-grafana-db-password # change before installing
    database: grafana
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
    username: grafana
    password: change-me-grafana-db-password # change before installing
    database: grafana
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
| UI / API (public) | `https://<canonical>.cpln.app` — `status.canonicalEndpoint` of `{release}-grafana` |
| Internal (same GVC) | `http://{release}-grafana.{gvc}.cpln.local:3000` |
| Login | `admin.user` / the payload of the `admin.passwordSecretName` secret |
| Postgres (internal, HA mode) | `{release}-postgres-ha-proxy.{gvc}.cpln.local:5432`, credentials in the `{release}-postgres-config` secret |
| Postgres (internal, single mode) | `{release}-postgres.{gvc}.cpln.local:5432`, credentials in the `{release}-pg-config` secret |

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
2. Set `backup.minio.endpoint` to the S3 API address including port. For the `minio` marketplace template in the same GVC, this is `http://WORKLOAD_NAME:9000`.
3. Set `backup.minio.accessKey` and `backup.minio.secretKey` to credentials with access to the bucket.

## Important Notes

- **Create the admin-password and encryption-key secrets BEFORE installing** (see Prerequisites) — the deployment wedges waiting on a secret that does not exist. Change the bundled database password too.
- **After your first login, set `admin.applyPassword: false` and upgrade** — the chart then stops referencing the password secret, so you can delete it. The admin password applies only when the account is first created; change it in the Grafana UI thereafter.
- **The encryption-key secret must remain forever, and must never be rotated.** It is read on every boot to decrypt stored datasource credentials; deleting it wedges the workload and changing its payload makes every saved datasource secret undecryptable — back it up instead.
- **Don't point Grafana at Control Plane's built-in workload metrics** — those dashboards already exist in the console; this template is for your own datasources.
- **Scaling**: set `replicas >= 2` together with `redis.enabled: true` — the chart refuses to render multi-replica without Redis, which coordinates alerting so only one notification is sent per alert.
- **Dashboards you create persist in Postgres** and survive Grafana restarts and redeploys; **uninstall deletes the database volumesets** — enable backups if the data matters.
- **Grafana Live push updates are per-instance** in multi-replica mode — dashboard auto-refresh and alerting are unaffected.
- **This template ships Grafana OSS only** — Enterprise features (RBAC, reporting, query caching) are not available.

## Links

- [Grafana documentation](https://grafana.com/docs/grafana/latest/)
- [Provisioning datasources](https://grafana.com/docs/grafana/latest/administration/provisioning/#data-sources)
- [Alerting high availability](https://grafana.com/docs/grafana/latest/alerting/set-up/configure-high-availability/)
- [Configuration reference](https://grafana.com/docs/grafana/latest/setup-grafana/configure-grafana/)
- [Grafana HTTP API](https://grafana.com/docs/grafana/latest/developers/http_api/)
