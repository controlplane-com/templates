# Grafana Multi Location

Grafana OSS spread across locations — a UI/API tier in every location behind one georouted HTTPS
endpoint, one stretched PostgreSQL cluster holding all app state, and a choice of two alerting shapes:
a single dedicated evaluator (default) or Redis-coordinated evaluation on every instance. Losing a
region loses that region's instances; the endpoint keeps serving from the rest. For a single-location
Grafana, use the `grafana` template instead.

## Architecture

- **No GVC** — this chart deploys into the GVC you install it into. Every location in
  `global.locations` must already exist there; both Grafana tiers check that at boot and log a
  warning naming any mismatch.
- **Grafana UI workload** (`{release}-grafana`, standard) — `replicas` instances per location, HTTP :3000, public by default. Alert execution is off here by default, and on in every instance when alerting HA is enabled.
- **Alert evaluator workload** (`{release}-grafana-alerting`, standard) — the same image, **exactly one replica**, in `alerting.location` only, never public. This is the only instance that evaluates rules. Optional: not created when `alerting.highAvailability.enabled` is true, or when `alerting.enabled` is false.
- **Identity and policies** — one identity shared by every Grafana workload, with `reveal` on exactly the secrets they mount (identical in both alerting modes), plus a second policy granting `view` on the one install GVC so the boot check can read its location list.
- **Datasource secret** (`{release}-grafana-datasources`) — the provisioning file, mounted by every Grafana workload. Optional (`datasources.definitions`).
- **App database** (`postgres-multi-location` subchart) — one Patroni cluster stretched across the same locations, with its own HAProxy tier per location and an etcd consensus store.
- **Alerting coordination** (`redis-multi-location` subchart) — one Redis and one Sentinel per location, coordinating exactly-once notification delivery. Optional: **only** when `alerting.highAvailability.enabled` is true.

Grafana is stateless here: users, dashboards, datasources, alert rules, alert state and sessions all
live in the shared database. There is no volume, no session affinity and nothing to hand over.

## Prerequisites

1. **An existing GVC with at least 2 locations** (3 for automatic database failover, and 3 is the
   minimum for alerting HA). This chart does **not** create one — it deploys into the GVC you install
   into, and every entry in `global.locations` must already be one of that GVC's locations. The
   platform does not validate that: a location the GVC lacks is stored verbatim and is simply inert,
   so nothing runs there and no deployment reports a failure. Both Grafana tiers read the GVC at boot
   and log a warning naming the mismatch — see [Important Notes](#important-notes).

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

   **Alerting HA needs no extra secrets** — the Redis tier ships authless behind the GVC firewall. To
   authenticate it anyway, see [Authenticating the Redis tier](#authenticating-the-redis-tier).

4. **For database backups only** — a bucket and, for AWS or GCP, a Control Plane
   [cloud account](https://docs.controlplane.com/guides/create-cloud-account). Supported providers:
   **AWS S3**, **Google Cloud Storage**, and **MinIO / any S3-compatible endpoint**. See
   [Storage setup](#storage-setup).

## Migrating from 1.x

**1.x created its own GVC. 2.0.0 does not — it deploys into the GVC you install it into.**

**Never `helm upgrade` a 1.x release onto 2.0.0.** The upgrade drops `kind: gvc` from the release
manifest, and Helm deletes what a chart no longer declares — which destroys that GVC and **every
workload, volume set and identity inside it**: both Grafana tiers, the whole Patroni cluster and its
data volumes, the etcd store behind it, and the Redis coordination tier. Measured on a sibling
template: **6 seconds, while printing `upgraded successfully`.**

The chart therefore **refuses to render** if your values still carry the 1.x `global.gvc` key. Two
things to know about that guard:

- It cannot fire on an upgrade run with *no* values at all, which sees only 2.0.0's defaults. The
  procedure below is the safety; the guard is a backstop.
- The error you actually see usually names **`etcd-multi-location`** or **`postgres-multi-location`**,
  not this chart. Helm renders the deepest subchart first and every chart in the stack carries the same
  guard on the same key, so a subchart's copy aborts the render first. The remedy is identical.

Migrate to a **new release** instead:

1. Back up the 1.x database — `postgresML.backup.mode: logical`, or a manual `pg_dumpall` through the
   old release's `{release}-postgres-proxy` endpoint.
2. In your values, rename `global.gvc.locations` to `global.locations` and delete `global.gvc.name`.
   Every location you list must already exist in the GVC you are installing into.
3. Install 2.0.0 as a **new release** into an **existing** GVC — not the GVC the 1.x release created,
   which is still owned by that release and goes away when you uninstall it.
4. Restore the dump into the new cluster — `postgres-multi-location`'s **Restoring a backup** section
   has the exact command, run from a client workload in the same GVC (neither the Grafana image nor the
   Patroni image is where you run it from). Grafana's dashboards, users, datasources, alert rules and
   alert state all live in that database, so restoring it moves everything. Reuse the **same**
   `admin.secretKeySecretName` secret: it decrypts the datasource credentials stored in the dump, and a
   different key makes every saved datasource credential unreadable.
5. Point your users at the new release's canonical endpoint and `cpln helm uninstall` the old release,
   which takes the GVC it created with it.

Values that changed:

| 1.x | 2.0.0 |
|---|---|
| `global.gvc.name` | removed — the GVC comes from where you install |
| `global.gvc.locations` | `global.locations` |
| `postgresML` pinned at 1.0.3 | pinned at **2.0.0** (no GVC of its own) |
| `redisML` pinned at 2.1.0 | pinned at **3.0.0** (no GVC of its own; adds `redisML.engine`) |

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

**`alerting.highAvailability.enabled: true` requires at least 3 locations** and the chart refuses to
render below that. Its Redis tier elects a master by a majority of locations (one Sentinel each), so at
2 locations losing either one leaves no quorum — the exact event the knob exists to survive.

## Configuration

### Locations

```yaml
# This chart deploys into the GVC you install into — it does NOT create one.
# Every location listed here MUST already exist in that GVC. The platform does
# not validate that: a location the GVC lacks is stored verbatim and is simply
# inert, so nothing runs there and no deployment reports a failure. Both Grafana
# tiers read the GVC at boot and log a warning naming the mismatch. Extra
# locations in the GVC are fine — nothing here runs in them.
#
# Lives under `global` so BOTH subcharts get the same list automatically — the
# postgres-multi-location database (and its own etcd, two levels down) and the
# optional redis-multi-location alerting coordinator. Never maintain two lists.
#
# Minimum 2 locations, and minimum 3 with alerting HA enabled below. The
# database tier needs 3 for automatic failover and 5 to survive losing two —
# see the survival table in the README.
# `replicas` here sets the POSTGRES members in that location, and nothing else.
# Every other tier ignores it and has its own count:
#   etcd     — always exactly 1 per location, not configurable. Quorum is a
#              majority of LOCATIONS, so a second member in one buys nothing.
#   Grafana  — the top-level `replicas` below, applied to every location.
#   Redis    — redisML.redis.replicasPerLocation (alerting HA only).

global:
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

replicas: 1 # Grafana UI instances PER LOCATION

resources:
  maxCpu: 1000m
  maxMemory: 1Gi
  minCpu: 500m
  minMemory: 512Mi

database:
  maxOpenConn: 10 # per instance; see the README budget
```

The connection budget is enforced at render time against an 80-connection ceiling. It is
`(replicas × locations + 1) × maxOpenConn`, the `+ 1` being the dedicated evaluator — dropped when
there isn't one, i.e. with alerting HA **on** or `alerting.enabled: false`. Exceed it and
the chart refuses to install, telling you the arithmetic — raising `replicas` past that point means
lowering `maxOpenConn`.

With alerting HA on, rule evaluation runs on this tier rather than on a workload of its own, so a large
rule set may need `resources.maxCpu` raised above the default.

### Alerting

```yaml
alerting:
  # false = rules can still be created and viewed, nothing evaluates them.
  enabled: true
  # false = a dedicated single-replica evaluator in `location` (the default).
  # true  = every UI instance evaluates and a stretched Redis coordinates the
  #         send. Needs 3+ locations and MULTIPLIES DATA-SOURCE QUERY LOAD by
  #         (locations × replicas) — read the Alerting section before enabling.
  highAvailability:
    enabled: false
  # Dedicated-evaluator mode ONLY — where the one evaluator runs. Required in
  # that mode, must be one of global.locations, IGNORED when HA is on.
  location: aws-us-east-1
  # Dedicated-evaluator mode ONLY — in HA mode the UI tier's `resources` apply.
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
  secretKeySecretName: my-grafana-secret-key # opaque secret; encrypts datasource passwords AT REST
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
  #   # Substitute BOTH parts: the workload name AND the GVC. A leftover
  #   # placeholder resolves to nothing and the panel shows only
  #   # "upstream connect error ... connection timeout".
  #   url: http://YOUR_WORKLOAD.YOUR_GVC.cpln.local:9095
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
notification is lost, with the only signal a log line in whichever workload does the sending.
Hosted relays are unaffected; a plain in-GVC relay is not. Leave `smtp.user`
empty to send unauthenticated against such a relay.
</Note>

Whichever instance evaluates is what actually sends: the dedicated evaluator by default, or the
coordinating UI instance when alerting HA is on.

```yaml
smtp:
  enabled: false
  host: smtp.example.com:587 # host:port
  user: "" # empty = unauthenticated SMTP. IF YOU SET THIS, the relay MUST offer
  # STARTTLS or TLS: Grafana refuses to send credentials over an unencrypted
  # connection ("failed to send email: unencrypted connection") and every
  # notification is then lost, with the only signal a log line in the
  # sending workload. Hosted relays (SES, SendGrid, Mailgun, M365, Gmail)
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
  # Only used when type is workload-list. This chart's OWN workloads (the UI
  # tier and, when it renders, the alert evaluator) are added automatically —
  # the list also governs the in-GVC path the README's silence procedure uses,
  # so a list naming only clients would deny it. List your clients here; do not
  # list this release's workloads.
  workloads: []
  # workloads:
  #   - //gvc/GVC_NAME/workload/WORKLOAD_NAME
```

The two subcharts keep their **own** firewall lists and add only their own workloads. Switching
`postgresML.internalAccess.type` or `redisML.firewall.internalAllowType` to `workload-list` without
listing the Grafana workloads would cut Grafana off from its database or its alerting coordinator, so
the chart refuses to render in that state and prints the exact links to add.

`publicAccess` applies to the UI tier only. The dedicated alert evaluator is never reachable from the
internet; it honours `internalAccess` so you can reach it inside the GVC. With alerting HA on there is
no evaluator workload, and the Redis tier is in-GVC only.

### App database (subchart)

```yaml
postgresML:
  postgres:
    credentialsSecretName: my-grafana-db-credentials

  # The database tier's own internal firewall. Leave it at same-gvc unless you
  # have a reason not to: this chart's Grafana workloads are NOT added to the
  # subchart's list automatically (a parent cannot inject a rendered name into a
  # subchart's values), so switching to workload-list without listing them cuts
  # Grafana off from its own database. The chart refuses to render in that state
  # and prints the exact links to add.
  internalAccess:
    type: same-gvc # options: same-gvc, same-org, workload-list
    workloads: []

  # Preferred location for the database primary. Keep it aligned with
  # alerting.location so the hot path has no cross-region hop. With alerting HA
  # on, this also decides which Grafana location runs the schema migrations.
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

### Alerting-HA coordination (subchart)

Rendered **only** when `alerting.highAvailability.enabled` is true; ignored entirely otherwise.

```yaml
redisML:
  # Which server the coordination tier runs. `redis` changes nothing. `valkey`
  # runs BOTH the Redis and Sentinel tiers on valkeyImage — the BSD-licensed
  # fork of Redis 7.2, which ships redis-server/redis-cli/redis-sentinel
  # compatibility symlinks, so Grafana's Sentinel client is unchanged. Chosen at
  # INSTALL time: a data directory cannot be moved between engines.
  engine: redis # redis | valkey
  valkeyImage: valkey/valkey:8.1.9 # used for both tiers when engine is valkey

  # Same rule as postgresML.internalAccess above: Grafana is not added to this
  # list automatically, and blocked from Sentinel it boots fine and every
  # instance sends its own copy of every alert. The chart refuses to render if
  # you set workload-list without listing the Grafana workloads.
  firewall:
    internalAllowType: same-gvc # options: same-gvc, same-org, workload-list
    workloads: []

  redis:
    # OPTIONAL, off by default. Opaque secret (encoding: plain) whose payload is
    # the password — see "Authenticating the Redis tier" below.
    passwordSecretName: ""
    image: redis:7.4
    replicasPerLocation: 1 # Redis members per location; 1 is plenty for alert coordination
    resources:
      cpu: 200m
      memory: 256Mi
    volumeset:
      initialCapacity: 10 # GiB per member (platform minimum); coordination data is tiny
  sentinel:
    # Independent of the Redis password — Sentinel is what Grafana asks for the
    # current master.
    passwordSecretName: ""
    image: redis:7.4
    resources:
      cpu: 200m
      memory: 256Mi
```

#### Authenticating the Redis tier

**Off by default: enabling alerting HA is one flag and needs no extra secrets.** The tier is reachable
only from inside the GVC, and the same-GVC firewall is the boundary it relies on.

**Since 2.0.0 that GVC is yours, not this chart's** — it is the GVC you installed into, and it very
likely already holds other workloads. Weigh the default accordingly: write access to an authless Redis
is enough to **suppress your alert notifications**, because a hostile or simply buggy neighbour can
claim another peer already sent them. Alert coordination is precisely the thing you do not want failing
quietly. Turn authentication on unless you control everything in the GVC.

Create either or both secrets **before installing**, then name them:

```bash
printf '%s' "$(openssl rand -hex 32)" | cpln secret create-opaque --name my-grafana-redis-password --encoding plain -f -
printf '%s' "$(openssl rand -hex 32)" | cpln secret create-opaque --name my-grafana-sentinel-password --encoding plain -f -
```

```yaml
redisML:
  redis:
    passwordSecretName: my-grafana-redis-password
  sentinel:
    passwordSecretName: my-grafana-sentinel-password
```

The two are independent — setting one without the other is valid. Grafana authenticates with
`ha_redis_password` and `ha_redis_sentinel_password`, reading the **same secrets** the Redis tier
reads, so the two sides cannot drift apart.

**A name that does not resolve stops the Grafana UI, not just alerting**, because Grafana mounts the
same secret. `cpln helm install` still reports **success**; the Redis, Sentinel and Grafana UI tiers
then sit at 0 replicas with no containers and therefore no logs. The explanation is on each workload's
`status.versions[].message` — not the top-level `status.message`, which is empty — and reads `The
secret <name> no longer exists. Workload updates are paused until the secret is added or the reference
to the secret removed.` Create the missing secret and it recovers on its own in about 5-6 minutes; no
helm action, and re-running the upgrade does not speed it up.

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

   **The endpoint must be reachable from EVERY location in the GVC.** In `wal-g` mode every member
   runs `restore_command`, so a MinIO workload that exists in only one location leaves the members in
   the other locations in a permanent restart loop — and it is silent, because the leader stays healthy
   and writes keep succeeding. Run your S3-compatible endpoint in every location, or use S3/GCS, which
   are global.
3. Create the credentials secret and set `postgresML.backup.minio.credentialsSecretName`:

   ```bash
   cpln secret create-dictionary --name my-grafana-minio-credentials \
     --entry accessKey=MINIO_ACCESS_KEY \
     --entry secretKey=MINIO_SECRET_KEY
   ```

## Alerting

`alerting.enabled: false` turns rule evaluation off entirely: no evaluator workload is created and no
instance executes rules, so rules and contact points can still be created and viewed but nothing ever
fires. Everything below concerns the two shapes available while alerting is on.

Grafana's memberlist alerting HA coordinates instances over a UDP gossip channel that is not available
between workloads on this platform. Grafana's **Redis-backed** coordination needs no peer port at all,
and that is what `alerting.highAvailability.enabled` turns on. Pick a mode:

| | `highAvailability.enabled: false` (default) | `highAvailability.enabled: true` |
|---|---|---|
| Who evaluates rules | the dedicated `{release}-grafana-alerting` workload — 1 replica, 1 location | **every UI instance**, in every location |
| Exactly-once delivery | a property of the topology: there is only one evaluator | Redis-coordinated: peers order themselves and share a notification log |
| Extra tier | none | 1 Redis + 1 Sentinel **per location** |
| Losing a location | alert evaluation **stops** until you repoint `alerting.location` and upgrade | evaluation **continues** in the surviving locations |
| Minimum locations | 2 | **3** — the chart refuses to render below that |
| **Data-source query load** | **1×** | **(locations × replicas)×** |
| Silences | expected not to propagate reliably — see the workaround below (untested here) | expected to propagate through the shared peer (upstream behaviour, untested here) |

### Read this before enabling HA

**Turning HA on multiplies your data-source query load by the number of Grafana instances.** Every
instance evaluates every rule against your Prometheus, Mimir or SQL server; Redis dedupes the
**notification**, never the **query**. At the default 3 locations × 1 replica that is **3× the queries,
permanently**. If your data source is already the bottleneck, that is a **worse trade than losing alert
evaluation when a region dies** — leave the knob off.

The other costs, at 3 locations and defaults: **+6 containers and +6 × 10 GiB volumes** for the Redis
tier (minus the one evaluator container), constant cross-region heartbeat traffic to whichever location
holds the Redis master, and rule evaluation landing on the UI tier's `resources` rather than on
`alerting.resources`, which is unused in this mode.

**When Redis is unhealthy, alerting keeps working and DUPLICATES — it never goes silent.** Each
instance's member list expires after a minute, every peer falls back to position 0, and the shared
notification log stops propagating, so each instance sends its own copy. "We're getting every alert
twice" therefore points at the `{release}-redis` / `{release}-sentinel` workloads, not at the alert
rules. Grafana also boots fine with Redis down and converges when it arrives.

### Dedicated-evaluator mode (the default)

Rule execution is disabled on the UI tier and enabled on a separate workload pinned to one replica in
`alerting.location`. Nothing is elected at runtime, and no value of `replicas` can produce a second
evaluator. Two consequences:

- **Losing the evaluator's replica self-heals** — the platform reschedules it and evaluation resumes
  with no operator action. **Losing that whole location does not.** Alert evaluation stops until you
  run `helm upgrade --set alerting.location=<surviving-location>`, and the UI is completely unaffected
  in the meantime — dashboards look perfectly healthy while nothing is being evaluated. This is the
  failure `alerting.highAvailability.enabled` exists to remove.
  **This silent shape only happens AFTER the cluster is initialised.** If `alerting.location` is
  missing from the GVC at install time you find out immediately and loudly: it must also appear in
  `global.locations`, and etcd and Patroni refuse to bootstrap on a fresh data directory for any
  location the GVC lacks, so the whole stack crash-loops with a named error rather than coming up
  half-working (measured 2026-08-29).
- **Silences are not expected to propagate between instances** (untested here). A silence created against the UI tier is not
  guaranteed to be honoured by the evaluator. Create silences against the evaluator directly, from a
  workload in the same GVC:
  `curl -u admin:PASSWORD http://{release}-grafana-alerting.{gvc}.cpln.local:3000/api/alertmanager/grafana/api/v2/silences`
  lists them; creating one is a POST with a body. The API requires credentials — unauthenticated returns 401.
  **That address only answers from inside `alerting.location`** — the name resolves to the GVC VIP
  everywhere, but there is no local upstream in the other locations, so they get a 503. Run the
  command from a workload in the alerting location.

`alerting.enabled: false` renders no evaluator at all: rules can be created and viewed, and are never
evaluated. Combining it with `highAvailability.enabled: true` is a contradiction and fails at render
time; with HA on, `alerting.location` and `alerting.resources` are ignored.

## Connecting

| What | Where |
|---|---|
| Grafana UI / API (public) | `status.canonicalEndpoint` of `{release}-grafana` — `cpln workload get {release}-grafana --gvc {gvc} -o yaml` |
| Grafana UI / API (internal) | `{release}-grafana.{gvc}.cpln.local:3000` |
| Alert evaluator (internal only) | `{release}-grafana-alerting.{gvc}.cpln.local:3000` — dedicated-evaluator mode only |
| App database | `{release}-postgres-proxy.{gvc}.cpln.local:5432` — always the current primary |
| Alerting Redis (internal only) | `replica-0.{release}-redis.{location}.{gvc}.cpln.local:6379` — alerting HA only |
| Alerting Sentinel (internal only) | `replica-0.{release}-sentinel.{location}.{gvc}.cpln.local:26379`, master name `mymaster` — alerting HA only |
| Admin login | `admin.user`, and the password in the secret named by `admin.passwordSecretName` — `cpln secret reveal <name> -o json` |

## Important Notes

- **There is no upgrade path from 1.x.** 1.x created its own GVC; 2.0.0 deploys into an existing one, and a `helm upgrade` across that boundary deletes the old GVC and everything in it — the database volume sets included. The chart refuses to render on the 1.x `global.gvc` key, but the guard cannot see an upgrade run with no values at all. Follow [Migrating from 1.x](#migrating-from-1x): new release, restore the database, uninstall the old one.
- **Create the admin password, encryption key and database credentials secrets before installing.** The chart does not create them; without them the deployment waits forever on secrets that do not exist.
- **Every location in `global.locations` must already exist in the GVC you install into.** The platform accepts one that does not, stores it, and runs nothing there with no failed deployment to see. Both Grafana tiers log `[grafana] WARNING: locations declared in global.locations are not in GVC ...` at boot — `cpln logs '{gvc="YOUR_GVC", workload="RELEASE-grafana"}' | grep '\[grafana\]'` is the check.
- **A missing `alerting.location` is the one mismatch with no visible symptom.** In dedicated-evaluator mode the `{release}-grafana-alerting` workload then holds zero replicas everywhere and not one alert rule is ever evaluated, while every dashboard looks healthy. The boot warning names it explicitly.
- **Never rotate or delete the encryption key.** It encrypts datasource passwords at rest in the shared database — it protects nothing in transit, which is TLS's job via the datasource URL. Rotating it makes every stored credential unreadable in every location, and each alert rule that queries them fails silently.
- **Any `helm upgrade` interrupts service in every location.** Database writes fail for about
  **117 s**, but the Grafana tier is unavailable for longer than that because reads fail too —
  measured recovery took about **4 minutes**, with one location down for **5-6 minutes**. The bundled database members do not restart one at a time — the platform does not retain the field that would limit the rollout — so all of them go down together (**~117 s** measured on an upgrade that changed nothing). Both Grafana tiers return errors for that window. Treat every upgrade as a planned outage, not a rolling one.
- **Alert evaluation stops if you lose `alerting.location`, and the UI will not show it.** Repoint the knob and upgrade; that restarts only the evaluator. Set `alerting.highAvailability.enabled: true` to remove that failure — read the cost in [Alerting](#alerting) first, because it multiplies data-source query load by the instance count.
- **The alerting-HA Redis tier is unauthenticated by default**, reachable only from inside the GVC
  you install into — which since 2.0.0 is a GVC you own and may share with other workloads.
  Authenticate it unless you control everything in that GVC: write access to it is enough to suppress
  alert notifications. See
  [Authenticating the Redis tier](#authenticating-the-redis-tier).
- **If you do set `redisML.*.passwordSecretName`, a wrong name stops the Grafana UI too**, because
  Grafana reads the same secret — and `helm install` still reports success. If a tier sits at 0
  replicas after install, read `status.versions[].message` on the workload.
- **Use the canonical `*.cpln.app` endpoint, not the per-location ones.** Grafana is configured with a
  single absolute `root_url` (the canonical endpoint). On a per-location hostname the UI and dashboard
  layout load, but the POST that fetches panel data is rejected — you get a dashboard with empty panels
  and no error anywhere. Observed behaviour; the mechanism was never confirmed, which is why no
  `csrf_trusted_origins` knob is exposed. The canonical endpoint is georouted and already serves from
  the nearest location.
- **A provisioned datasource that reports `upstream connect error ... connection timeout` is almost
  always an unsubstituted placeholder in its URL**, not a network or firewall problem. Check the GVC
  segment of `datasources.definitions[].url` first — a name that does not resolve times out rather
  than failing fast, and nothing in the Grafana UI names the cause.
- **Turning alerting HA on or off changes which workloads exist.** Enabling it deletes the `{release}-grafana-alerting` workload and adds a Redis and a Sentinel workload per location; disabling it does the reverse. It is a normal `helm upgrade`, but treat it as a planned change, not a toggle to flip while investigating an incident.
- **Alerting HA is blocked below 3 locations, on purpose.** Sentinel elects a master by a majority of locations, so at 2 locations losing either one leaves no quorum — the exact event the knob exists for.
- **With alerting HA on, an unhealthy Redis means DUPLICATE notifications, never silence.** Check the `{release}-redis` and `{release}-sentinel` workloads before suspecting your alert rules.
- **Every location except the database primary's pays a cross-region round trip per query.** Grafana has no read/write splitting, so a dashboard load in a distant region is slower by the inter-region latency (measured 96 ms us-east ↔ eu-central, up to 236 ms worst case). Set `postgresML.primaryLocation` where most of your users are.
- **Scaling `replicas` has no alerting-related restriction** — it applies to the UI tier only, in every location including `alerting.location`. Watch the connection budget instead.
- **On a cold start some instances restart once.** Grafana takes a non-blocking database lock to run migrations and exits if another instance holds it; the platform restarts it and the next attempt succeeds. A single `Failed to lock database` line during a fresh install or a tier restart is expected.
- **Grafana Live has no HA engine here**, so a live-streamed message reaches only the browsers connected to the same instance. Interval-refreshing dashboards, queries, alerting, provisioning, login and the API are unaffected.
- **Never suspend a location.** Suspending and resuming one permanently withdraws its endpoints from the other locations' service discovery while every status surface still reads healthy. To remove a location, remove it from `global.locations` and from the GVC.
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
  With alerting HA off the evaluator migrates first and each location follows 15 s behind it; with
  alerting HA on there is no evaluator, so the location matching `postgresML.primaryLocation` goes
  first at zero delay and the rest follow at 15 s intervals. Either way this removes those restarts at
  the default one replica per location. Two replicas in the SAME location still start together, so a
  few remain at `replicas: 2` — 2 were measured across three locations. They clear themselves;
  nothing needs doing.
- **If the database primary does not land in `postgresML.primaryLocation`, the first install is
  noisy.** That knob is a preference with a 90-second bound, not a guarantee — if the preferred
  location is slow to start, another bootstraps instead and says so in its log. Grafana's schema
  migrations then run cross-region at roughly **215 ms per statement instead of 5 ms**, so the
  713-migration run takes minutes rather than seconds and instances restart while it finishes.
  Measured: 11 m 41 s and 15 restarts in that case, against 4 m 19 s and 2 with the primary in
  place. It converges on its own and needs no action, but if you want the fast path, check the
  Patroni leader landed where you asked before judging the install.
- **A first install takes 4-6 minutes**, most of it the stretched database electing a primary. Grafana waits for it rather than crash-looping, and logs what it is waiting for on every poll.
- **The FIRST `helm upgrade` after an install re-applies every tier once**, even a no-op, and the database is briefly in recovery while it comes back — measured **4 m 43 s** to reconverge on a 3-location cluster. Later upgrades report `Unchanged` and cost nothing. With alerting HA on, that first upgrade bounces the Redis tier too, so expect a brief duplicate-notification window alongside it.

- **An upgrade delivers duplicate notifications for 80-95 seconds when HA is on — including an upgrade
  that changes nothing.** The platform stamps a release tag on every resource it touches, so a
  byte-identical no-op still rolls every workload; the chart cannot render its way out of it. While the
  Redis tier is patched, coordination lapses and several instances notify for the same firing (4 extra
  notifications measured over a 93 s window). It re-converges on its own — ~40 s after Redis returns —
  and it never goes silent.
- **After a location is lost, hand-off is not instant.** Redis peer keys carry a 5-minute TTL, so a
  dead location's peers hold their positions until it expires. Alerting continues from the survivors
  throughout; what varies is which instance sends.
- **The notification does not necessarily come from `alerting.location` when HA is on, and which
  location sends is not pinnable.** The sender is chosen by sorted peer name, and a standard workload's
  name carries a ReplicaSet hash that changes on every rollout — the elected sender moved from
  `us-east-1` to `us-west-2` between two installs of the same chart. Do not build routing, filtering or
  egress-IP allowlisting on the assumption that a particular location sends.
- **Restarting the evaluator with HA OFF re-notifies.** Anything currently firing is delivered again
  when the single evaluator comes back.

## Links

- [Grafana high availability setup](https://grafana.com/docs/grafana/latest/setup-grafana/set-up-for-high-availability/)
- [Grafana configuration reference](https://grafana.com/docs/grafana/latest/setup-grafana/configure-grafana/)
- [Alerting high availability](https://grafana.com/docs/grafana/latest/alerting/set-up/configure-high-availability/)
- [Datasource provisioning](https://grafana.com/docs/grafana/latest/administration/provisioning/)
- [Grafana alerting](https://grafana.com/docs/grafana/latest/alerting/)
