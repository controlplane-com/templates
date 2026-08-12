# Grafana Multi Location

Grafana OSS spread across locations — a UI/API tier in every location behind one georouted HTTPS
endpoint, a single alert evaluator, and one stretched PostgreSQL cluster holding all app state. Losing
a region loses that region's instances; the endpoint keeps serving from the rest. For a
single-location Grafana, use the `grafana` template instead.

## Architecture

- **GVC** — multi-location, pinned to `global.gvc.locations`. **Created by this chart**, always.
- **Grafana UI workload** (`{release}-grafana`, standard) — `replicas` instances per location, HTTP :3000, public by default. Alert execution is off here.
- **Alert evaluator workload** (`{release}-grafana-alerting`, standard) — the same image, **exactly one replica**, in `alerting.location` only, never public. This is the only instance that evaluates rules. Optional (`alerting.location: ""`).
- **Identity and policy** — one identity shared by both workloads, with `reveal` on exactly the secrets they mount.
- **Datasource secret** (`{release}-grafana-datasources`) — the provisioning file, mounted by both workloads. Optional (`datasources.definitions`).
- **App database** (`postgres-multi-location` subchart) — one Patroni cluster stretched across the same locations, with its own HAProxy tier per location and an etcd consensus store.

Grafana is stateless here: users, dashboards, datasources, alert rules, alert state and sessions all
live in the shared database. There is no volume, no session affinity and nothing to hand over.

## Prerequisites

1. **A GVC name that is not yet taken.** This chart creates the GVC named in `global.gvc.name`.
   Helm **adopts** a GVC that already exists and `helm uninstall` then **deletes** it, along with
   every unrelated workload in it. Point `global.gvc.name` at a name nothing else uses.

2. **Three secrets, all created BEFORE installing.** Missing any of them wedges the deployment
   waiting on a secret reference that never resolves, which looks like a broken install.

   ```bash
   # First-boot admin password (opaque, encoding plain)
   printf '%s' "$(openssl rand -hex 24)" \
     | cpln secret create-opaque --name my-grafana-admin-password --encoding plain -f -

   # Datasource encryption key (opaque, encoding plain) — PERMANENT, never rotate it
   printf '%s' "$(openssl rand -hex 32)" \
     | cpln secret create-opaque --name my-grafana-secret-key --encoding plain -f -

   # App database credentials (dictionary) — exactly these three keys
   cpln secret create-dictionary --name my-grafana-db-credentials \
     --entry username=grafana \
     --entry password="$(openssl rand -hex 24)" \
     --entry database=grafana
   ```

   Read any of them back with `cpln secret reveal <name> -o json` (without `-o json` the output is a table containing no secret data). Use plain identifiers for `username` and
   `database` — they are used unquoted when the database is created.

3. **Optional secrets**, if you use those features: a `dictionary` secret per entry in
   `datasources.credentialSecrets`, and an opaque secret for `smtp.passwordSecretName`.

4. **For database backups only** — a bucket and, for AWS or GCP, a Control Plane
   [cloud account](https://docs.controlplane.com/guides/create-cloud-account). Supported providers:
   **AWS S3**, **Google Cloud Storage**, and **MinIO / any S3-compatible endpoint**. See
   [Storage setup](#storage-setup).

## How many locations do you need?

The database's consensus store commits a write only when a **majority** of its members agree, and it
runs one member per location. That arithmetic decides what survives — the Grafana tier itself has no
quorum of its own.

| Locations | Location losses survived | What a user sees when one location is lost |
|---|---|---|
| **2** | **0** | Dashboards still render, but logins, saves and alert-state writes fail — the survivor holds current data and is read-only until you promote it by hand. |
| **3** | **1** | Automatic database failover; the UI keeps serving from the two surviving locations. |
| **5** | **2** | Survives losing two locations. |

With N locations you survive `floor((N-1)/2)` losses, so an even count buys nothing over the odd
count below it. Losing the location named in `alerting.location` is a separate matter — see
[Alerting](#alerting).

## Configuration

### GVC and locations

```yaml
global:
  gvc:
    # This chart CREATES this GVC. It must NOT already exist: Helm adopts a GVC
    # that does, and `helm uninstall` then DELETES it and everything in it.
    name: grafana-multi-location-gvc
    # Minimum 2 locations. The database tier needs 3 for automatic failover and
    # 5 to survive losing two — see the survival table in the README.
    # `replicas` here is DATABASE members per location. Grafana's own count per
    # location is the top-level `replicas` below.
    locations:
      - name: aws-us-east-1
        replicas: 1
      - name: aws-eu-central-1
        replicas: 1
      - name: aws-us-west-2
        replicas: 1
```

### Grafana UI tier

```yaml
image: grafana/grafana:13.1.3

replicas: 1 # Grafana UI instances PER LOCATION; scale freely, alerting is a separate workload

resources:
  maxCpu: 1000m
  maxMemory: 1Gi
  minCpu: 500m
  minMemory: 512Mi

database:
  maxOpenConn: 10 # per instance; (replicas × locations + 1) × this must stay at 80 or less
```

The `maxOpenConn` budget is enforced at render time, and the `+ 1` is the alert evaluator. Exceed it
and the chart refuses to install, telling you the arithmetic — raising `replicas` past that point
means lowering `maxOpenConn`.

### Alerting

```yaml
alerting:
  location: aws-us-east-1 # must be one of global.gvc.locations; "" = no evaluator workload, alerting disabled
  resources:
    maxCpu: 1000m
    maxMemory: 1Gi
    minCpu: 500m
    minMemory: 512Mi
```

### Admin bootstrap and encryption

```yaml
admin:
  user: admin # initial admin login name (not sensitive)
  applyPassword: true # set false after your first login to stop referencing the password secret
  passwordSecretName: my-grafana-admin-password # opaque secret holding the first-boot admin password
  secretKeySecretName: my-grafana-secret-key # opaque secret holding the encryption key
```

The password applies only when the admin account is **first created**; change it in the UI afterwards
and set `applyPassword: false`. The secret key has a different lifecycle: every instance in every
location reads it on every boot to decrypt datasource credentials stored in the shared database.
Never delete it and never rotate it.

### Datasources as code

```yaml
datasources:
  definitions: []
  # - name: Prometheus
  #   type: prometheus
  #   access: proxy
  #   url: http://RELEASE-prometheus.GVC.cpln.local:9095
  #   isDefault: true
  credentialSecrets: []
  # - name: my-grafana-ds-credentials
  #   keys: [PG_PASSWORD]
```

`definitions` renders into a plaintext provisioning file, so put datasource passwords in a
pre-created `dictionary` secret and write `$KEY` in the definition. Every `$KEY` needs an entry in
`credentialSecrets`.

### SMTP for alert emails

<Note>
Authenticated SMTP requires a relay offering **STARTTLS or TLS**. Grafana will not send
credentials over an unencrypted connection — it fails with `unencrypted connection` and every
notification is lost, with the only signal a log line in the alerting workload, which is not
publicly reachable. Hosted relays are unaffected; a plain in-GVC relay is not. Leave `smtp.user`
empty to send unauthenticated against such a relay.
</Note>

```yaml
smtp:
  enabled: false
  host: smtp.example.com:587 # host:port
  user: "" # empty = unauthenticated SMTP. IF YOU SET THIS, the relay MUST offer
  # STARTTLS or TLS: Grafana refuses to send credentials over an unencrypted
  # connection ("failed to send email: unencrypted connection") and every
  # notification is then lost, with the only signal a log line in the
  # alerting workload. Hosted relays (SES, SendGrid, Mailgun, M365, Gmail)
  # are fine; a plain in-GVC relay is not — leave this empty for those.
  passwordSecretName: "" # opaque secret (encoding: plain) with the SMTP password; create BEFORE install
  fromAddress: grafana@example.com
  fromName: Grafana
```

### Access

```yaml
publicAccess:
  enabled: true # UI on the canonical *.cpln.app HTTPS endpoint

internalAccess:
  type: same-gvc # options: none, same-gvc, same-org, workload-list
  workloads: [] # used with workload-list
  # workloads:
  #   - //gvc/GVC_NAME/workload/WORKLOAD_NAME
```

`publicAccess` applies to the UI tier only. The alert evaluator is never reachable from the internet;
it honours `internalAccess` so you can reach it inside the GVC.

### App database (subchart)

```yaml
postgresML:
  postgres:
    credentialsSecretName: my-grafana-db-credentials

  # Preferred location for the database primary. Keep it aligned with
  # alerting.location so the hot path has no cross-region hop.
  primaryLocation: aws-us-east-1

  resources:
    minCpu: 500m
    minMemory: 1Gi
    maxCpu: 1
    maxMemory: 2Gi

  volumeset:
    capacity: 10 # initial capacity in GiB per member (minimum is 10)

  proxy:
    minReplicas: 2 # HAProxy leader-routing tier, per location
    maxReplicas: 2

  backup: # optional database backups — see Storage setup in the README
    enabled: false
    mode: logical # logical or wal-g
    location: aws-us-east-1 # logical mode only: the ONE location the nightly job runs in
    resources:
      cpu: 100m
      # 512Mi, matching postgres-multi-location's own default. At 128Mi the GCP
      # path OOMs with NO log output: logical jobs merely report `failed` and the
      # wal-g sidecar loops on OOMKilled while WAL archives with no base backup.
      # Do not lower this without re-testing the GCS path.
      memory: 512Mi
    logical:
      image: ghcr.io/controlplane-com/backup-images/postgres-backup:17.1.0
      schedule: "0 2 * * *"
    walg:
      intervalSeconds: 21600
    provider: aws # options: aws, gcp, minio
    aws:
      bucket: my-grafana-bucket
      region: us-east-1
      cloudAccountName: my-s3-cloud-account
      policyName: my-grafana-backup-policy
      prefix: grafana/backups
    gcp:
      bucket: my-grafana-bucket
      cloudAccountName: my-gcs-cloud-account
      prefix: grafana/backups
    minio:
      endpoint: http://my-minio-workload:9000
      bucket: my-grafana-bucket
      credentialsSecretName: my-grafana-minio-credentials
      prefix: grafana/backups
```

Grafana has **no read/write splitting** — every query, including every dashboard load, goes to the
single primary. Put `primaryLocation` where most of your users are; everyone else pays one
cross-region round trip per query. Everything the database tier can do (pooling, restores, emergency
quorum recovery) is documented in the `postgres-multi-location` template.

## Storage setup

Only needed with `postgresML.backup.enabled: true`.

### AWS S3

1. Create the bucket. Set `postgresML.backup.aws.bucket` and `.region`.
2. Create a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account)
   for the AWS account holding the bucket, and set `postgresML.backup.aws.cloudAccountName`.
3. Create an IAM policy scoped to exactly that bucket (replace `YOUR_BUCKET_NAME`) and set
   `postgresML.backup.aws.policyName` to its name. The identity gets this policy and `cpln-connector`
   only — no broad managed policy.

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:PutObject",
                "s3:DeleteObject",
                "s3:ListBucket",
                "s3:GetObjectVersion",
                "s3:DeleteObjectVersion"
            ],
            "Resource": [
                "arn:aws:s3:::YOUR_BUCKET_NAME",
                "arn:aws:s3:::YOUR_BUCKET_NAME/*"
            ]
        }
    ]
}
```

### Google Cloud Storage

1. Create the bucket. Set `postgresML.backup.gcp.bucket`.
2. Create a [cloud account](https://docs.controlplane.com/guides/create-cloud-account) for the GCP
   project and set `postgresML.backup.gcp.cloudAccountName`.
3. Grant that cloud account's service account the **Storage Admin** (`roles/storage.admin`) role on
   the project. The chart additionally binds `roles/storage.objectAdmin` on exactly the bucket.

### MinIO / S3-compatible

No cloud account is needed.

1. Create the bucket and set `postgresML.backup.minio.bucket`.
2. Set `postgresML.backup.minio.endpoint` to the S3 API address including the port — for the `minio`
   template in the same GVC that is `http://WORKLOAD_NAME:9000`.
3. Create the credentials secret and set `postgresML.backup.minio.credentialsSecretName`:

   ```bash
   cpln secret create-dictionary --name my-grafana-minio-credentials \
     --entry accessKey=MINIO_ACCESS_KEY \
     --entry secretKey=MINIO_SECRET_KEY
   ```

## Alerting

Grafana's memberlist alerting HA coordinates instances over a UDP gossip channel that is not
available between workloads on this platform, so if every instance evaluated rules you would get one
notification per instance. Grafana also supports a Redis-backed alerting HA path, which **would**
work here — it is deferred to a later version because it needs a stretched Redis tier, not because
alerting HA is impossible on Control Plane. This template instead makes exactly-once evaluation a property of the
**topology**: rule execution is disabled on the UI tier and enabled on a separate workload that is
pinned to one replica in `alerting.location`. Nothing is elected at runtime, and no value of
`replicas` can produce a second evaluator.

Two consequences worth knowing before you rely on it:

- **Losing the evaluator's replica self-heals** — the platform reschedules it and evaluation resumes
  with no operator action. **Losing that whole location does not.** Alert evaluation stops until you
  run `helm upgrade --set alerting.location=<surviving-location>`, and the UI is completely unaffected
  in the meantime — dashboards look perfectly healthy while nothing is being evaluated.
- **Silences do not propagate between instances.** A silence created against the UI tier is not
  guaranteed to be honoured by the evaluator. Create silences against the evaluator directly, from a
  workload in the same GVC:
  `curl -u admin:PASSWORD http://{release}-grafana-alerting.{global.gvc.name}.cpln.local:3000/api/alertmanager/grafana/api/v2/silences`
  lists them; creating one is a POST with a body. The API requires credentials — unauthenticated returns 401.
  **That address only answers from inside `alerting.location`** — the name resolves to the GVC VIP
  everywhere, but there is no local upstream in the other locations, so they get a 503. Run the
  command from a workload in the alerting location.

Setting `alerting.location: ""` renders no evaluator at all: rules can be created and viewed, and are
never evaluated.

## Connecting

| What | Where |
|---|---|
| Grafana UI / API (public) | `status.canonicalEndpoint` of `{release}-grafana` — `cpln workload get {release}-grafana --gvc {global.gvc.name} -o yaml` |
| Grafana UI / API (internal) | `{release}-grafana.{global.gvc.name}.cpln.local:3000` |
| Alert evaluator (internal only) | `{release}-grafana-alerting.{global.gvc.name}.cpln.local:3000` |
| App database | `{release}-postgres-proxy.{global.gvc.name}.cpln.local:5432` — always the current primary |
| Admin login | `admin.user`, and the password in the secret named by `admin.passwordSecretName` — `cpln secret reveal <name> -o json` |

## Important Notes

- **Resource names no longer carry the `-ml` infix, and that is a FRESH-INSTALL-ONLY change.** Both Grafana workloads, the identity, policy and datasource secret are now named `{release}-grafana…` instead of `{release}-grafana-ml…`, and the bundled database tier renamed the same way — including its **volume set**. Running `helm upgrade` over an install created before this change creates a **new, empty volume set** and leaves the old one behind holding your dashboards, users and alert rules (and still billing). There is no in-place upgrade path: back up the database, uninstall, reinstall, restore, then delete the orphaned volume set.
- **Create the admin password, encryption key and database credentials secrets before installing.** The chart does not create them; without them the deployment waits forever on secrets that do not exist.
- **The GVC in `global.gvc.name` must not already exist.** Helm adopts an existing one and deletes it on uninstall, taking every unrelated workload with it.
- **Never rotate or delete the encryption key.** It decrypts every stored datasource credential, in every location. Rotating it makes them all unreadable and every alert rule that queries them fails silently.
- **Any `helm upgrade` interrupts service in every location.** Database writes fail for about
  **117 s**, but the Grafana tier is unavailable for longer than that because reads fail too —
  measured recovery took about **4 minutes**, with one location down for **5-6 minutes**. The bundled database members do not restart one at a time — the platform does not retain the field that would limit the rollout — so all of them go down together (**~117 s** measured on an upgrade that changed nothing). Both Grafana tiers return errors for that window. Treat every upgrade as a planned outage, not a rolling one.
- **Alert evaluation stops if you lose `alerting.location`, and the UI will not show it.** Repoint the knob and upgrade; that restarts only the evaluator.
- **Every location except the database primary's pays a cross-region round trip per query.** Grafana has no read/write splitting, so a dashboard load in a distant region is slower by the inter-region latency (measured 96 ms us-east ↔ eu-central, up to 236 ms worst case). Set `postgresML.primaryLocation` where most of your users are.
- **Scaling `replicas` has no alerting-related restriction** — it applies to the UI tier only, in every location including `alerting.location`. Watch the connection budget instead.
- **On a cold start some instances restart once.** Grafana takes a non-blocking database lock to run migrations and exits if another instance holds it; the platform restarts it and the next attempt succeeds. A single `Failed to lock database` line during a fresh install or a tier restart is expected.
- **Grafana Live has no HA engine here**, so a live-streamed message reaches only the browsers connected to the same instance. Interval-refreshing dashboards, queries, alerting, provisioning, login and the API are unaffected.
- **Never suspend a location.** Suspending and resuming one permanently withdraws its endpoints from the other locations' service discovery while every status surface still reads healthy. To remove a location, remove it from `global.gvc.locations`.
- **Allow up to about four minutes after changing an access knob** before believing it did not work, and about two minutes after a cold install before believing a location is unreachable.

- **With `publicAccess.enabled: false`, links in alert notifications point at the internal GVC address** (`…cpln.local:3000`) and will not open from a browser outside the GVC. Give the UI tier a public endpoint, or expect notification links to be unusable off-network.

- **An upgrade that adds a new secret reference can pause the rollout for about 9-10 minutes while
  Helm reports success.** Affected locations log `The identity … is not allowed to reveal the secret …`
  even though the policy grant is already in place and visible in `cpln secret access-report`. It
  **self-heals with no action** (measured 9 m 0 s - 9 m 30 s); do not re-run the upgrade or start
  editing policies. This is platform-side propagation, not a chart setting.

- **`replicas: 2` or higher lengthens the cold install.** A single-replica 3-location install reaches
  ready in about 5 minutes; at `replicas: 2` expect roughly 7 minutes for every location to report
  ready and up to ~12 minutes for every individual replica. Nothing is wrong — there is simply more
  to schedule.

- **UI instances start a few seconds apart on purpose.** Grafana runs its schema migrations under a
  non-blocking lock with no retry, so instances arriving together make the losers exit and restart.
  The alert evaluator migrates first and each location follows 15 s behind it, which removes those
  restarts at the default one replica per location. Two replicas in the SAME location still start
  together — expect one self-healing restart per extra replica.
- **A first install takes 4-6 minutes**, most of it the stretched database electing a primary. Grafana waits for it rather than crash-looping, and logs what it is waiting for on every poll.
- **The FIRST `helm upgrade` after an install re-applies every tier once**, even a no-op, and the database is briefly in recovery while it comes back — measured **4 m 43 s** to reconverge on a 3-location cluster. Later upgrades report `Unchanged` and cost nothing.

## Links

- [Grafana high availability setup](https://grafana.com/docs/grafana/latest/setup-grafana/set-up-for-high-availability/)
- [Grafana configuration reference](https://grafana.com/docs/grafana/latest/setup-grafana/configure-grafana/)
- [Alerting high availability](https://grafana.com/docs/grafana/latest/alerting/set-up/configure-high-availability/)
- [Datasource provisioning](https://grafana.com/docs/grafana/latest/administration/provisioning/)
- [Grafana alerting](https://grafana.com/docs/grafana/latest/alerting/)
