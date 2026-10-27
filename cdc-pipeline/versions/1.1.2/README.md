# CDC Pipeline

A complete change data capture pipeline in one install: a highly available PostgreSQL cluster as the
source, Apache Kafka as the transport, and Debezium Server streaming every insert, update and delete
from the database into Kafka topics.

## Architecture

An umbrella chart. It deploys and wires together three existing templates rather than reimplementing them;
each component's own README is the reference for its knobs, storage and backups:

- **`postgres-highly-available`** — the CDC source: three Patroni-managed PostgreSQL members with
  `wal_level = logical`, etcd, and an HAProxy endpoint that always reaches the leader.
- **`kafka`** — the transport: a three-broker KRaft cluster with SASL users, the `debezium` user among its
  super users, and a client workload. Its SASL passwords come from the credentials secret. Kafbat UI is
  available but off (optional).
- **`debezium-server`** — the connector: reads the replication stream through HAProxy and writes each
  change to the topic `<serverName>.<schema>.<table>`. Its offsets live on a volume set.

The chart itself creates one policy, letting the Kafka brokers read the credentials secret, and checks the
components' values against each other at render.

## Prerequisites

**One `dictionary` secret must exist BEFORE you install.** PostgreSQL initializes with it, the Kafka brokers
take their SASL passwords from it, and Debezium connects with it, so it holds eight keys:

```bash
DB_PASSWORD="$(openssl rand -hex 24)"
cpln secret create-dictionary --name RELEASE_NAME-cdc-credentials \
  --entry username=cdc_user \
  --entry password="$DB_PASSWORD" \
  --entry sourcePassword="$DB_PASSWORD" \
  --entry database=cdcdb \
  --entry kafkaSaslPassword="$(openssl rand -hex 24)" \
  --entry kafkaAdminPassword="$(openssl rand -hex 24)" \
  --entry kafkaInterBrokerPassword="$(openssl rand -hex 24)" \
  --entry kafkaControllerPassword="$(openssl rand -hex 24)"
```

- `sourcePassword` must equal `password` (Debezium reads that key), and `username`/`database` must equal
  `debezium-server.source.database.user`/`.name`. `database` is used unquoted, so keep it to lowercase
  letters, digits and underscores.
- `kafkaSaslPassword` is the password of Kafka's `debezium` user, on the broker side and in Debezium alike.
  `kafkaAdminPassword` is the Kafka `admin` user's; the other two secure the brokers' own connections. Keep
  the Kafka passwords to letters and digits, as generated above: they are placed inside Kafka's login
  configuration, where a `"` or `;` breaks it.
- The secret's name appears in six values: `postgres-highly-available.config.credentialsSecretName`,
  `debezium-server.credentialsSecretName` and the four `kafka.kafka.env` entries (see Kafka below). **All six
  must name the same secret**; the chart refuses anything else. Secret names are org-wide, so give each
  release its own, and do not use `RELEASE_NAME-debezium-credentials`, which Debezium creates itself.

**If the secret does not exist at install time, the deployment wedges silently.** `cpln logs` returns zero
lines — the containers never start. The only diagnostic is `status.versions[].message` in
`cpln workload get-deployments RELEASE_NAME-postgres-ha --gvc GVC_NAME -o yaml` (and `RELEASE_NAME-cluster`,
`RELEASE_NAME-debezium`);
plain `cpln workload get` has no `versions` key. Create the secret and it recovers on its own, but it can take
up to about 12 minutes to serve again — poll rather than giving up — or skip the wait with
`cpln workload force-redeployment`.

## Configuration

### Credentials

```yaml
postgres-highly-available:
  walLevel: logical # Debezium's pgoutput decoding needs it; the chart refuses anything else
  config:
    credentialsSecretName: my-cdc-pipeline-credentials # REQUIRED prerequisite secret, must exist BEFORE install
debezium-server:
  credentialsSecretName: my-cdc-pipeline-credentials # the SAME secret
kafka:
  kafka:
    env: # the SAME secret again, in all four entries; keep the variable names and keys
      - name: CDC_KAFKA_ADMIN_PASSWORD
        value: cpln://secret/my-cdc-pipeline-credentials.kafkaAdminPassword
      - name: CDC_KAFKA_DEBEZIUM_PASSWORD
        value: cpln://secret/my-cdc-pipeline-credentials.kafkaSaslPassword
      - name: CDC_KAFKA_INTER_BROKER_PASSWORD
        value: cpln://secret/my-cdc-pipeline-credentials.kafkaInterBrokerPassword
      - name: CDC_KAFKA_CONTROLLER_PASSWORD
        value: cpln://secret/my-cdc-pipeline-credentials.kafkaControllerPassword
```

### PostgreSQL highly available

```yaml
postgres-highly-available:
  replicas: 3
  resources: { minCpu: 500m, minMemory: 1Gi, maxCpu: 1, maxMemory: 2Gi }
  image: controlplanecorporation/patroni-postgres:0.8 # pgvector 0.8.7 (CVE-2026-103484); tags 0.1-0.7 are refused
  volumeset:
    capacity: 10 # GiB per member; a quarter of it caps the WAL a replication slot may hold back
  proxy:
    enabled: true # Debezium connects through the HAProxy leader endpoint; keep it on
  backup:
    enabled: false # logical dumps or WAL-G; see the postgres-highly-available README
```

### Kafka

Every Kafka password is a `${env:VAR}` reference, never the password: the broker resolves it from one of
the `CDC_KAFKA_*` variables above (Kafka's `EnvVarConfigProvider`). The chart refuses a plain password.

```yaml
kafka:
  kafka:
    replicas: 3
    listeners:
      client:
        sasl:
          admin: { username: admin, password: "${env:CDC_KAFKA_ADMIN_PASSWORD}" } # the secret's kafkaAdminPassword
          users: "debezium"
          passwords: "${env:CDC_KAFKA_DEBEZIUM_PASSWORD}" # the secret's kafkaSaslPassword
    acl:
      superUsers: "User:admin;User:debezium" # keep User:debezium: the chart cannot grant ACLs
      allowEveryoneIfNoAclFound: false
    secrets:
      kraft_cluster_id: "change-me-cdc-pipeline-kraft-cluster-id" # set to `kafka-storage.sh random-uuid` output; fixed after first start
      inter_broker_password: "${env:CDC_KAFKA_INTER_BROKER_PASSWORD}" # the secret's kafkaInterBrokerPassword
      controller_password: "${env:CDC_KAFKA_CONTROLLER_PASSWORD}" # the secret's kafkaControllerPassword
    extra_configurations:
      config.providers: env # keep both provider lines: they resolve the references
      config.providers.env.class: org.apache.kafka.common.config.provider.EnvVarConfigProvider
  kafka_orchestrator: false # keep off: needs the admin password as a plain value
  kafka_exporter: false # keep off: needs the admin password as a plain value
  kafbat_ui:
    enabled: false # see Kafbat UI below
```

To add another Kafka user, put its password in the credentials secret under a new key, add a `kafka.kafka.env`
entry reading it (`cpln://secret/SECRET_NAME.NEW_KEY`), and append the user and `${env:THAT_VARIABLE}` to
`users` and `passwords`.

### Debezium Server

```yaml
debezium-server:
  source:
    database:
      name: cdcdb # = the secret's database
      user: cdc_user # = the secret's username
    serverName: "dbserver1" # topic prefix: events go to dbserver1.<schema>.<table>
    tableIncludeList: "" # e.g. "public.orders,public.customers"; empty captures every table
    postgres:
      slotName: "debezium"
      slotFailover: true # replicas keep a synchronized copy, so the slot survives a database switchover
      heartbeatIntervalMs: 5000 # keeps a quiet database's slot advancing so it does not hold WAL back
  sink:
    kafka:
      saslUsername: "debezium" # must be a client-listener user and a Kafka super user
  volumeset:
    capacity: 10 # offsets; deleting it makes the connector snapshot every table again
```

### Kafbat UI (optional)

Off by default: it mounts a Kafbat configuration file from an opaque secret you create first, and it is
public when on. Write the config (see the kafka README's example, with
`bootstrapServers: RELEASE_NAME-cluster.GVC_NAME.cpln.local:9092` and the Kafka admin user; the admin
password is the credentials secret's `kafkaAdminPassword`, from `cpln secret reveal SECRET_NAME -o yaml`), then:

```bash
cpln secret create-opaque --name RELEASE_NAME-kafbat-ui-config --encoding plain -f kafbat-config.yaml
```

```yaml
kafka:
  kafbat_ui:
    enabled: true
    configuration_secret: RELEASE_NAME-kafbat-ui-config
    firewall:
      external_inboundAllowCIDR: "203.0.113.0/24" # default 0.0.0.0/0 is the whole internet
```

## Connecting

| What | Where | Credentials |
|---|---|---|
| Change events | Kafka topics `<serverName>.<schema>.<table>` at `RELEASE_NAME-cluster.GVC_NAME.cpln.local:9092` (SASL_PLAINTEXT, PLAIN) | `admin` with the secret's `kafkaAdminPassword`, or another user of `kafka.kafka.listeners.client.sasl` |
| Source database | `RELEASE_NAME-postgres-ha-proxy.GVC_NAME.cpln.local:5432` | `username`/`password`/`database` of the credentials secret |

## Upgrading from 1.1.1 or earlier

1.1.2 moves the database to `controlplanecorporation/patroni-postgres:0.8`, which carries pgvector 0.8.7
(CVE-2026-103484). Nothing limits the rollout of a stateful workload, so expect a short database outage
while the members and the proxy restart, and upgrade in a quiet window. Debezium resumes on the new leader
from its failover replication slot, and changes around a leader change can be delivered twice. Existing data needs nothing. If you pinned
`postgres-highly-available.image`, set it to the `0.8` tag: tags `0.1` to `0.7` are refused at render. The
pipeline does not use the `vector` extension; if you created it in your database, run
`ALTER EXTENSION vector UPDATE;` there, which only updates the version `\dx` reports.

## Upgrading from 1.0.4

1.0.4 never delivered change events (`wal_level` was `replica` and Debezium had no Kafka permissions), so
**a fresh install of 1.1.0 is the simplest path**: install it as a new release, move any data the database
holds, then uninstall the old release. To upgrade in place instead:

1. 1.0.4 created the database secret itself, and **this upgrade deletes it**; it also kept Kafka's passwords
   as values, which 1.1.0 reads from the secret instead. **Before upgrading**, create the new secret under a
   **new** name holding the values the database and the Kafka cluster run with today, not new ones — the
   running cluster keeps its passwords, and nothing changes on it:

   ```bash
   cpln secret reveal my-cdc-pipeline-db-credentials -o yaml   # database: username, password, database (postgres-highly-available.config.credentialsSecretName)
   cpln secret reveal RELEASE_NAME-secrets -o yaml             # Kafka: client-admin-password, inter-broker-password, controller-password
   cpln secret reveal RELEASE_NAME-debezium-credentials -o yaml # Debezium's Kafka password: kafka-sasl-password
   cpln secret create-dictionary --name RELEASE_NAME-cdc-credentials \
     --entry username=YOUR_CURRENT_USERNAME --entry password=YOUR_CURRENT_PASSWORD \
     --entry sourcePassword=YOUR_CURRENT_PASSWORD --entry database=YOUR_CURRENT_DATABASE \
     --entry kafkaSaslPassword=CURRENT_KAFKA_SASL_PASSWORD \
     --entry kafkaAdminPassword=CURRENT_CLIENT_ADMIN_PASSWORD \
     --entry kafkaInterBrokerPassword=CURRENT_INTER_BROKER_PASSWORD \
     --entry kafkaControllerPassword=CURRENT_CONTROLLER_PASSWORD
   ```

2. In your values, delete the `database:` block, `debezium-server.source.database.password` and
   `debezium-server.sink.kafka.saslPassword`; set both `credentialsSecretName` keys to the new name; and if
   you changed `kafka.kafka.acl.superUsers`, add `User:debezium`. Replace every Kafka password with its
   reference and add the `kafka.kafka.env` entries and provider lines exactly as in [Kafka](#kafka) and
   [Credentials](#credentials), naming the new secret; delete any `kafka.kafka_exporter` block (1.1.0 runs no
   Kafka exporter or health sidecar). The chart refuses the old keys and any plain Kafka password at render.
3. **Before upgrading**, switch the running cluster to `wal_level = logical` — 1.0.4 created it with
   `replica`, and 1.1.0's replicas refuse to start on a `replica` cluster, which stalls the upgrade. The same
   command tells Patroni to leave logical slots alone and removes the install-time password 1.0.4 stored in
   the cluster configuration (`"authentication":null`; without it this command prints that password back to
   you). Then restart the members in place, the replicas first and the leader last (`patronictl` does not
   work on 1.0.4's cluster, so this uses Patroni's API; `LOCATION` is your GVC's location):

   ```bash
   pgx() { cpln workload exec RELEASE_NAME-postgres-ha --gvc GVC_NAME --location LOCATION \
     --container patroni-postgres --replica "RELEASE_NAME-postgres-ha-$1" -- "${@:2}"; }
   pgx 0 curl -s -XPATCH -d '{"postgresql":{"parameters":{"wal_level":"logical"},"authentication":null},"ignore_slots":[{"type":"logical"}]}' localhost:8008/config
   # wait until every member shows "pending_restart": true; note which one is the "leader"
   pgx 0 curl -s localhost:8008/cluster
   # for each replica N, then the leader last:
   pgx N curl -s -XPOST -d '{"restart_pending": true}' localhost:8008/restart
   ```

   Run the `cluster` call again: every member should be `running` or `streaming` with no `pending_restart`.
4. Upgrade. The upgrade restarts the bundled PostgreSQL too (it now reads the new secret), so Debezium can
   briefly lose its database; it reconnects by itself. The Kafka brokers restart as well, now reading their
   passwords from the secret. The new version of a workload can also wait about
   10 minutes with `is not allowed to reveal the secret` in `get-deployments`, while access to the new secret
   propagates; the previous version keeps serving meanwhile, and it clears by itself.
5. Confirm Debezium's slot is a failover slot: `pgx N psql -h 127.0.0.1 -d postgres -c "SELECT slot_name, failover FROM
   pg_replication_slots"` on the leader shows `failover = t`. If it shows `f` (1.0.4's Debezium created it), convert it
   with the `ALTER_REPLICATION_SLOT` command in the debezium-server README.

The bundled components move too: postgres-highly-available 2.5.0 → 2.8.0 (its README's notes on the
Patroni timeouts and the password stored in the cluster configuration apply), Kafka 4.0.1 → 4.3.0 (the
brokers roll, which also applies the new super user), and Kafbat UI keeps the setting your release runs with.

## Rotating the database password in HA mode

The HA database (`postgres-highly-available`) needs its own order. The replication role `repl` shares the password, and a member that restarts with the old password can be promoted to leader, which splits the cluster. Move the leader to member `-0` first, so it restarts last, after every other member already has the new password. `pgx` runs a command in one member (`LOCATION` is your GVC's location, `DB_USERNAME` the secret's `username`):

```bash
pgx() { cpln workload exec RELEASE_NAME-postgres-ha --gvc GVC_NAME --location LOCATION \
  --container patroni-postgres --replica "RELEASE_NAME-postgres-ha-$1" -- "${@:2}"; }
# 1. Find the leader ("role": "leader"); the other two must be "streaming" on the same "timeline"
pgx 0 curl -s localhost:8008/cluster
# 2. If the leader is not RELEASE_NAME-postgres-ha-0, move it there (N = current leader), then repeat step 1
pgx 0 curl -s -XPOST -d '{"leader":"RELEASE_NAME-postgres-ha-N","candidate":"RELEASE_NAME-postgres-ha-0"}' localhost:8008/switchover
# 3-5. Back to back: change BOTH roles on -0, put the new password in the secret as BOTH password and sourcePassword, restart the members
pgx 0 psql -h 127.0.0.1 -d postgres -c "ALTER ROLE DB_USERNAME PASSWORD 'NEW_PASSWORD'; ALTER ROLE repl PASSWORD 'NEW_PASSWORD';"
cpln secret edit SECRET_NAME
cpln secret reveal SECRET_NAME -o yaml   # confirm password AND sourcePassword hold the new value BEFORE redeploying
cpln workload force-redeployment RELEASE_NAME-postgres-ha --gvc GVC_NAME
# 6. After ~5-7 minutes, confirm one leader and two "streaming" replicas on one timeline (repeat step 1).
#    -0 restarts last, so the leader moves once more, to another member.
# 7. Optional, for a release upgraded from 1.0.4 that skipped "authentication":null in its upgrade:
#    remove the install-time password Patroni kept in its cluster config
pgx 0 curl -s -XPATCH -d '{"postgresql":{"authentication":null}}' localhost:8008/config
```

The procedure moves the leader twice (step 2 and step 5). Debezium's replication slot is a failover slot that
every replica keeps a synchronized copy of, so it resumes on each new leader from where it stopped; changes
around a leader change can be delivered twice. The database drops connections for roughly 10–60 s at each
leader change. Debezium fails to authenticate from the `ALTER ROLE` until you have edited the secret: its
container then restarts by itself and reads the new `sourcePassword`, so it needs no redeploy of its own. If
it still logs `password authentication failed` a few minutes after the edit, run
`cpln workload force-redeployment RELEASE_NAME-debezium --gvc GVC_NAME`.

**Any `helm upgrade` after the secret has been edited restarts `RELEASE_NAME-postgres-ha`,
`RELEASE_NAME-cluster` and `RELEASE_NAME-debezium` again** (one more rolling restart of the database, with
its leader changes), even when no value changed, because they are rolled whenever the secret they read has
changed since the last upgrade. Plan the next upgrade into the same window. If a member stays `starting`, or `running` without `streaming` for several minutes, re-copy it from the leader. This copies the whole database, so it costs network traffic in proportion to its size:

```bash
pgx N curl -s -XPOST -d '{"force": true}' localhost:8008/reinitialize
```

## Rotating the Kafka passwords

All four Kafka passwords live only in the credentials secret, so a rotation is a secret edit and two
redeployments, with no `helm upgrade`. The brokers and Debezium keep the passwords they started with until
they restart, so run the steps back to back: a broker that restarts on its own in between comes back with
passwords its peers do not have yet.


```bash
cpln secret edit SECRET_NAME                    # 1. new values for any of kafkaSaslPassword, kafkaAdminPassword, kafkaInterBrokerPassword, kafkaControllerPassword
cpln secret reveal SECRET_NAME -o yaml          # 2. confirm the new values BEFORE redeploying
cpln workload force-redeployment RELEASE_NAME-cluster --gvc GVC_NAME    # 3. the brokers restart with the new passwords
cpln workload force-redeployment RELEASE_NAME-debezium --gvc GVC_NAME   # 4. only when kafkaSaslPassword changed; right after step 3
```

The brokers restart one at a time. When `kafkaInterBrokerPassword` or `kafkaControllerPassword` changed, a
restarted broker cannot rejoin the brokers still on the old passwords, so partway through the roll Kafka
refuses writes for several minutes until the last broker has restarted; rotate those two in a quiet window.
Debezium is refused from step 3 until step 4, then resumes from its replication slot, so nothing is lost and
events around the switch can be delivered twice. Any other client that logs in as `admin` or `debezium`
needs the new password too.

## Important Notes

- **Rotating the database password in HA mode needs a leader switchover first** — follow [Rotating the database password in HA mode](#rotating-the-database-password-in-ha-mode). A plain redeploy can promote a member still holding the old password and split the cluster.
- **Rotating a Kafka password needs both redeployments** — edit the secret, then redeploy `RELEASE_NAME-cluster` and `RELEASE_NAME-debezium` as in [Rotating the Kafka passwords](#rotating-the-kafka-passwords), straight after the edit.
- **This template runs no Kafka exporter, health sidecar or REST Proxy** (`kafka.kafka_exporter`, `kafka.kafka_orchestrator` stay `false`, `kafka.kafka_rest_proxy.enabled` stays `false`); broker metrics come from the JMX exporter. Kafka Connect (`kafka.kafka_connectors`) is refused at render: its worker login and plugin configs take credentials inline, and Debezium Server is this pipeline's connector — install the `kafka` template on its own to run Kafka Connect.
- **A replication slot is left behind when the connector is removed.** PostgreSQL retains WAL for it until `max_slot_wal_keep_size` (a quarter of the volume) invalidates it; drop it explicitly (`SELECT pg_drop_replication_slot('debezium');`).
- **Debezium's replication slot follows a database switchover.** It is a PostgreSQL 17 failover slot (`debezium-server.source.postgres.slotFailover`), so every replica holds a synchronized copy and Debezium resumes on the new leader; changes around a leader change can be delivered twice, so consumers must tolerate duplicates.
- **Dependency versions are pinned in `Chart.yaml`** and move only with a new version of this template.
- **Uninstalling deletes every volume set** (database, Kafka topics, Debezium offsets); final snapshots are kept for seven days.

## Links

- [Debezium PostgreSQL connector](https://debezium.io/documentation/reference/stable/connectors/postgresql.html)
- [Debezium Server](https://debezium.io/documentation/reference/stable/operations/debezium-server.html)
- [PostgreSQL logical decoding](https://www.postgresql.org/docs/current/logicaldecoding.html)
- [Apache Kafka documentation](https://kafka.apache.org/documentation/)
