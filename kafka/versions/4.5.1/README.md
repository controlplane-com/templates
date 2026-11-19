## Kafka App

### Architecture

- **Stateful Kafka workload** — KRaft-mode brokers; the first nodes take the combined controller and broker roles, the rest are brokers only.
- **Volume sets** — per-broker log directories.
- **Secrets** — the broker configuration (including SASL/JAAS), the startup script that substitutes runtime values into it, and the cluster credentials.
- **Identity and policy** — `reveal` on those secrets, and on your credentials secret when `kafka.credentialsSecretName` is set.
- **Kafbat UI workload** *(optional)* — a web console for the cluster.
- **REST Proxy workload** *(optional)* — HTTP access to produce and consume.
- **Connectors workload** *(optional)* — Kafka Connect, optionally reading connector credentials from your Control Plane secrets.
- **Domain** *(optional)* — created for public listener access.

This template does not create a GVC.

### Prerequisites

- **Recommended: a credentials secret** for the broker passwords (`kafka.credentialsSecretName`, see [Credentials](#credentials)). Without it the passwords are plain values in the release.
- **Recommended while the REST Proxy is on (the default): a JAAS file secret** (`kafka_rest_proxy.jaas_conf_secret`, see [REST Proxy credentials](#rest-proxy-credentials)).
- The Kafbat UI (on by default) waits for its configuration secret; see [Kafbat configuration example](#kafbat-configuration-example).
- **Recommended for each Kafka Connect group: a REST API users secret** (`rest_auth_secret`, see [Kafka Connect REST API authentication](#kafka-connect-rest-api-authentication)). Without it the REST API has no authentication.
- **With `kafka_connectors[].secrets`: those secrets**, created before install (by hand or synced by the ESS template), and `rest_auth_secret`, which is then required. See [Connector credentials](#connector-credentials).

Public listener access needs a domain you control and a dedicated load balancer on the GVC. Backups need a bucket and a Control Plane [cloud account](https://docs.controlplane.com/guides/create-cloud-account).

### Credentials

Every broker password can come from one **dictionary** secret instead of values. Create it before you install: while it is missing the brokers wait and `cpln logs` shows nothing; `status.versions[].message` in `cpln workload get-deployments RELEASE_NAME-cluster --gvc GVC_NAME -o yaml` names it.

```yaml
kafka:
  credentialsSecretName: my-kafka-credentials # "" = the inline passwords are used
  listeners:
    client:
      sasl:
        admin:
          username: admin # usernames stay in values; their passwords come from the secret
        users: "user"
```

The secret holds `inter-broker-password`, `controller-password`, and one `<listener>-<username>-password` key for each SASL admin and user, where `<listener>` is the listener's `name` in lower case. For the default listeners:

```bash
cpln secret create-dictionary --name my-kafka-credentials \
  --entry inter-broker-password="$(openssl rand -hex 24)" \
  --entry controller-password="$(openssl rand -hex 24)" \
  --entry client-admin-password="$(openssl rand -hex 24)" \
  --entry client-user-password="$(openssl rand -hex 24)"
```

- When `credentialsSecretName` is set it wins over `sasl.admin.password`, `sasl.passwords`, `secrets.inter_broker_password` and `secrets.controller_password`, which are then ignored. The health sidecar, the Kafka exporter and the deprecated Kafka UI read the admin password from the secret too.
- The brokers resolve the passwords through Kafka's `env` config provider. If you set `config.providers` in `kafka.extra_configurations`, keep `env` in the list.
- **Moving a running cluster to the secret:** put the passwords the cluster uses today in the secret, then upgrade with `credentialsSecretName` set. The brokers restart once.
- **Changing a password:** update the secret, then run `cpln workload force-redeployment RELEASE_NAME-cluster --gvc GVC_NAME`. Running brokers keep the old password until they restart, and clients that log in with it need the new one.
- Inline passwords keep working: with `credentialsSecretName: ""` the brokers are configured exactly as in 4.3.0.

#### REST Proxy credentials

The REST Proxy's JAAS file holds a Kafka password. Put the whole file in an **opaque** secret and name it in `kafka_rest_proxy.jaas_conf_secret`; it then replaces `jaas_conf`. Basic auth users work the same way through `password_properties_secret`:

```yaml
kafka_rest_proxy:
  jaas_conf_secret: my-kafka-rest-jaas # "" = jaas_conf is used
  password_properties_secret: "" # e.g. my-kafka-rest-users: one "user: password,role" line per user
```

```bash
cat > kafka-rest.jaas.conf <<'EOF'
KafkaClient {
  org.apache.kafka.common.security.plain.PlainLoginModule required
  username="admin"
  password="THE_CLIENT_ADMIN_PASSWORD";
};
KafkaRest {
  org.eclipse.jetty.security.jaas.spi.PropertyFileLoginModule required
  debug="true"
  file="/etc/kafka-rest/password.properties";
};
EOF
cpln secret create-opaque --name my-kafka-rest-jaas --encoding plain -f kafka-rest.jaas.conf
```

After changing either secret, run `cpln workload force-redeployment RELEASE_NAME-rest-proxy --gvc GVC_NAME`.

#### Connector credentials

List Control Plane secrets under `secrets` and the chart mounts each one on the Kafka Connect workers under `/opt/kafka/secrets` and turns on Kafka's `dir` config provider (`DirectoryConfigProvider`). Worker properties and plugin configs then read a value with a placeholder, and the connector configs in the REST API, the Kafka UI and Connect's config topic show only the placeholder (REST API users can still read the values, see **Security** below):

| Secret type | Mounted as | Placeholder |
|---|---|---|
| dictionary | a directory, one file per key | `${dir:/opt/kafka/secrets/NAME:KEY}` |
| opaque | one file | `${dir:/opt/kafka/secrets:NAME}` |

```yaml
kafka_connectors:
  - name: cluster
    rest_auth_secret: my-connect-rest-users # required with secrets
    secrets:
      - name: my-connector-credentials
      - name: my-keystore-password
    connector_properties:
      sasl.jaas.config: "org.apache.kafka.common.security.plain.PlainLoginModule required username=\"admin\" password=\"${dir:/opt/kafka/secrets/my-connector-credentials:kafka-admin-password}\";"
    plugins:
      - name: clickhouse-sink
        config:
          "password": "${dir:/opt/kafka/secrets/my-connector-credentials:clickhouse-password}"
          "ssl.truststore.password": "${dir:/opt/kafka/secrets:my-keystore-password}"
```

In a plugin's `config`, quote with single quotes (`username='admin' password='${dir:…}'`): plugin values are placed into the connector's JSON as they are, and a double quote breaks it.

**From AWS Secrets Manager (or any provider of the [ESS template](https://docs.controlplane.com/template-catalog/templates/ess)):** let ESS keep the Control Plane secret in sync. A JSON secret becomes a dictionary with `dictionaryFromJson`; nested JSON keys use dots (`db.host`), and a value that is not a JSON object lands under the key `__raw`:

```yaml
# ESS sync.yaml excerpt
secrets:
  - name: my-connector-credentials
    provider: my-aws-secrets-manager
    dictionaryFromJson: /prod/kafka-connect # {"kafka-admin-password": "...", "clickhouse-password": "..."}
```

**By hand:** a value must not end with a newline, because Kafka passes it on as part of the value (the worker log warns about one):

```bash
cpln secret create-dictionary --name my-connector-credentials \
  --entry kafka-admin-password=THE_KAFKA_PASSWORD --entry clickhouse-password=THE_CLICKHOUSE_PASSWORD
printf '%s' 'THE_KEYSTORE_PASSWORD' | cpln secret create-opaque --name my-keystore-password --encoding plain -f -
```

**Moving from literal values:** create the secret, add it to `secrets`, replace each literal with its placeholder, upgrade, then run `cpln workload force-redeployment RELEASE_NAME-connect-cluster --gvc GVC_NAME`. `GET /connectors/CONNECTOR/config` (with REST credentials) then shows `${dir:…}`. Rotate the old credential at its source: it is still in the Helm release history and in Connect's config topic.

**Changing a value:** update the secret (or let ESS sync it), then run `cpln workload force-redeployment RELEASE_NAME-connect-cluster --gvc GVC_NAME`. Running workers keep the value they read at start; the redeployment restarts them one at a time and they read the new one. A `helm upgrade` that changes the worker properties, the plugin configs or the plugin downloads restarts the workers by itself.

**When something is wrong:**
- **A secret that does not exist** keeps the new replica from starting, and `cpln logs` shows nothing. `cpln workload get-deployments RELEASE_NAME-connect-cluster --gvc GVC_NAME -o yaml` shows in `status.versions[].message` that the secret does not exist and that workload updates are paused until it is added.
- **A key the secret does not have, or the wrong placeholder form** (a dictionary read as opaque, or the reverse): Kafka would pass the placeholder text on as the value, so the chart checks every reference at start. A connector with a bad reference is not created or updated, and the `kafka-connect` log names the secret, the key and the keys the secret has (never a value). In a worker property it stops the worker with `FATAL`.
- **A placeholder naming a secret not in `secrets`, one without a key or secret name, or a path outside `/opt/kafka/secrets`,** is refused when you install or upgrade.

**Security:**
- `rest_auth_secret` is required with `secrets`, and must not itself be listed in `secrets`. **Every REST API user can read every mounted secret**, for example by creating a connector or by validating a config (`PUT /connector-plugins/…/config/validate` returns resolved values). Give REST credentials only to people who may see all of them.
- **Kafka prints the resolved value of every setting that is not a password type in the worker log** (for example `client.id`, or a connector's own string settings such as `source.cluster.alias`), so anyone who can read the workload's logs sees it. Use placeholders only in password settings (`sasl.jaas.config`, `*.password`).
- **Connectors cannot load config providers of their own.** The workers start with `-Dorg.apache.kafka.automatic.config.providers=none`, so a connector config that declares `config.providers` for the clients it configures (`producer.override.*`, `consumer.override.*`, `admin.override.*`, or MirrorMaker's `source.*` and `target.*`) fails with `… is not allowed`. The worker's own providers (`dir`, and any you list in `connector_properties`) keep working.
- The `dir` provider reads only under `/opt/kafka/secrets` (`allowed.paths`); the chart sets it and refuses `config.providers.dir.*` in `connector_properties`. A `FileConfigProvider` or `DirectoryConfigProvider` you add yourself, with or without `secrets`, is limited to `/opt/kafka/secrets` and the `extraVolumes` paths, and `config.providers.*.param.allowed.paths` is refused.
- `allowed.paths` needs Kafka 3.8 or later: `secrets` is refused with an image tag before 3.8. With a digest or a custom tag the chart cannot tell the version, so make sure the image is Kafka 3.8 or later (`apache/kafka:3.9.1` is).
- Worker property names cannot hold spaces, `\`, `=` or `:`, and values cannot hold a line break, a `\u` escape or a trailing `\` (nor any `\` in a `config.providers*` value): the worker reads its properties file with Java's escape rules, so these would reach it as a different property. They are refused for every Kafka Connect group.
- A connector that derives a value from a secret may store the derived value in its task config.

**The `${env:VAR}` option** still works: add an `env` entry that references the secret (the chart grants the worker `reveal` on it) and use `${env:VAR}` in `connector_properties` or a plugin's `config`:

```yaml
kafka_connectors:
  - name: cluster
    env:
      - name: CONNECT_ADMIN_PASSWORD
        value: cpln://secret/my-kafka-credentials.client-admin-password
    connector_properties:
      config.providers: env
      config.providers.env.class: org.apache.kafka.common.config.provider.EnvVarConfigProvider
      sasl.jaas.config: "org.apache.kafka.common.security.plain.PlainLoginModule required username=\"admin\" password=\"${env:CONNECT_ADMIN_PASSWORD}\";"
```

The chart limits every `env` config provider of the worker with `allowlist.pattern=(?!CPLN_).*`, so `${env:CPLN_…}` never resolves: `CPLN_TOKEN` is the workload's Control Plane API token. Every other variable still resolves. Setting `config.providers.*.param.allowlist.pattern` yourself is refused, because a pattern can always be written to reopen `CPLN_`.

#### Kafka Connect REST API authentication

Without it, any client that reaches a worker's port 8083 can read every connector's config, including the credentials in it, and create, change or delete connectors. Required when `secrets` is set. To require basic auth, put one `username: password` line per user in an **opaque** secret and name it in `rest_auth_secret`:

```bash
cat > connect-rest-users.properties <<'EOF'
admin: THE_ADMIN_PASSWORD
kafka-ui: THE_KAFKA_UI_PASSWORD
EOF
cpln secret create-opaque --name my-connect-rest-users --encoding plain -f connect-rest-users.properties
```

```yaml
kafka_connectors:
  - name: cluster
    rest_auth_secret: my-connect-rest-users # "" = no authentication
```

- The chart enables Kafka's `BasicAuthSecurityRestExtension`. Every request then needs basic auth, including `GET /`; a missing or wrong password gets `401`.
- The chart's own connector setup logs in as the **first** user in the file. For every user: one line each, ASCII only (Kafka reads the file as ISO-8859-1), no spaces in the username, and no `\` (a trailing one joins the next line onto the password). Don't add roles: everything after `:` is the password. If the setup cannot log in, the worker log says so.
- Other REST clients need credentials too. For the Kafka UI, add `username` and `password` to the `kafkaConnect` entry in its configuration secret:

  ```yaml
  kafka:
    clusters:
      - name: my-cluster
        kafkaConnect:
          - name: cluster
            address: http://RELEASE_NAME-connect-cluster.GVC_NAME.cpln.local:8083
            username: kafka-ui
            password: THE_KAFKA_UI_PASSWORD
  ```

- Workers read the users file once at start. After you change the secret, run `cpln workload force-redeployment RELEASE_NAME-connect-cluster --gvc GVC_NAME`.
- Requests between workers keep working: a request forwarded to the leader carries the caller's credentials, and Kafka signs its internal task requests itself.
- With `rest_auth_secret` set, the chart refuses these worker properties: `rest.extension.classes` (the secret sets it), a `connect.protocol` other than `sessioned` (the default; the others leave the workers' internal endpoints open), and a non-empty `admin.listeners` (the admin listener has no authentication). It also refuses `java.security.auth.login.config` in a `KAFKA_OPTS` env var: put the Kafka client login in `sasl.jaas.config`.

### How to connect to the cluster

You can connect to Kafka from the same GVC in which it's deployed using the following methods:

- To connect using the cluster's general address, use the fully-qualified internal hostname `{kafka-cluster-workload-name}.{gvc}.cpln.local:9092`.

- To connect to a specific replica, use one of the following addresses based on the replica you wish to connect to:
  - `{kafka-cluster-workload-name}-0.{kafka-cluster-workload-name}:9092`
  - `{kafka-cluster-workload-name}-1.{kafka-cluster-workload-name}:9092`
  - `{kafka-cluster-workload-name}-2.{kafka-cluster-workload-name}:9092`

- If you're configuring your Kafka for external access, you'll need to provide a domain name for the public address of the listener you want to use. Prerequisites:
  - Make sure the dedicated load balancer is enabled on the GVC. See [Configure Domain documentation](https://docs.controlplane.com/guides/configure-domain#dedicated-load-balancing).
  - Make sure to register your [Apex domain](https://docs.controlplane.com/reference/domain#apex-domain-considerations) name with Control Plane and set up a DNS record for the Kafka public address CNAME with the canonical GVC endpoint in your DNS provider.

### Test Kafka Cluster with Kafka Client

1. To activate the Kafka client, make sure `kafka_client` is uncommented in your values file, then upgrade the release with it:
   ```bash
   cpln helm upgrade RELEASE_NAME ./kafka/versions/4.5.1 --gvc GVC_NAME --dependency-update -f values.yaml
   ```

2. To connect to the `kafka-client` workload, navigate through the UI to the appropriate GVC and select the `kafka-client` workload. In the workload details, find and use the **Connect** feature to establish a connection, which can be done either via the UI or by utilizing the CLI command provided there.

3. Once connected, you can write and consume messages through the `kafka-client` workload. If it's `PLAINTEXT`, producer and consumer configurations should be omitted below:

```BASH
# Change to bin directory
cd /opt/kafka/bin

# Create client.properties
echo "security.protocol=SASL_PLAINTEXT
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username=\"admin\" password=\"your-admin-password\";" > ./client.properties

# Produce messages to the 'controlplane' topic
kafka-console-producer.sh --bootstrap-server {kafka-cluster-workload-name}.{gvc}.cpln.local:9092 --topic controlplane --producer.config ./client.properties

# Consume messages from the 'controlplane' topic
kafka-console-consumer.sh --bootstrap-server {kafka-cluster-workload-name}.{gvc}.cpln.local:9092 --topic controlplane --from-beginning --consumer.config ./client.properties
```

### Public Listener Domain Configuration

When configuring Kafka for external access via a public listener, you can choose between two domain routing modes:

#### **Direct Replica Routing Mode (Recommended)**

The recommended approach with automatic replica endpoint generation:

```yaml
kafka:
  listeners:
    public:
      protocol: SASL_PLAINTEXT
      name: PUBLIC
      directReplicaRouting:
        enabled: true
        containerPort: 9095  # ports 9091, 9093 and 9094 are reserved
        publicAddress: kafka.example.com
      sasl:
        users: "public-user"
        passwords: "your-password"
```

**Behavior:**
- Single domain configuration with the specified container port
- DNS01 certificate challenge for automatic SSL
- Platform automatically generates replica-specific subdomains in format: `{replica-name}-{location}.{publicAddress}`
- Replica-aware routing reduces cross-zone traffic costs in multi-zone deployments
- Connection endpoints (auto-generated examples): 
  - `kafka-cluster-0-aws-us-east-1.kafka.example.com:9095`
  - `kafka-cluster-1-aws-us-east-1.kafka.example.com:9095`
  - `kafka-cluster-2-aws-us-east-1.kafka.example.com:9095`

**Prerequisites for Direct Routing:**
- DNS provider must support CNAME records
- Create DNS records for each replica and the ACME challenge record:
  1. `CNAME kafka-cluster-0-aws-us-east-1.kafka.example.com → kafka-cluster-<gvcAlias>-0.aws-us-east-1.controlplane.us`
  2. `CNAME kafka-cluster-1-aws-us-east-1.kafka.example.com → kafka-cluster-<gvcAlias>-1.aws-us-east-1.controlplane.us`
  3. `CNAME kafka-cluster-2-aws-us-east-1.kafka.example.com → kafka-cluster-<gvcAlias>-2.aws-us-east-1.controlplane.us`
  4. `CNAME _acme-challenge.kafka → _acme-challenge.cpln.app` (for certificate validation)

#### **Multi-Port Routing**

Each replica gets its own port. Not recommended for multi-zone clusters:

```yaml
kafka:
  listeners:
    public:
      protocol: SASL_PLAINTEXT
      name: PUBLIC
      publicAddress: kafka.example.com
      sasl:
        users: "public-user"
        passwords: "your-password"
```

**Behavior:**
- Creates ports 3000, 3001, 3002 (one per replica)
- Each port routes to a specific replica
- Custom TLS cipher suites configuration
- Connection format: `kafka.example.com:3000`, `kafka.example.com:3001`, etc.
- **Note**: Not recommended for multi-zone deployments as cross-zone traffic charges may occur

**Which Mode to Use:**
- Use **Direct Replica Routing** for new deployments that require automatic SSL with zone-aware routing and per-replica hostnames
- Avoid using **Multi-Port Routing** unless you have specific use cases or existing clients configured with port numbers (3000-300X)

**Configuration Rules:**
- Cannot use both `publicAddress` and `directReplicaRouting.enabled: true` in the same listener
- When `directReplicaRouting.enabled: true`, both `containerPort` and `publicAddress` must be specified within the `directReplicaRouting` section
- Only one listener can have a public address configured across all listeners
- Direct Replica Routing automatically creates DNS entries in format: `{replica-name}-{location}.{publicAddress}:{containerPort}`

### Enable Custom Encryption using AWS Key Management Service (KMS)

Custom encryption for volumes can be configured by setting the values under `kafka.volumes.customEncryption`.

A key must be created in AWS before proceeding with the template.

In the values file, set `enabled` to `true` and add the proper `region` and `keyId`.

**Important** - To finish configuring in AWS once the template is installed:

1. Navigate in the console to the created volume
2. Click on `spec`
3. Follow the `AWS Custom Encryption Instructions`
4. Repeat for each encrypted volume created

### Kafbat configuration example

Kafbat UI reads its configuration from the **opaque** secret named by `kafbat_ui.configuration_secret` (default `kafka-kafbat-ui-config`), which the chart mounts as the file `/etc/config.yaml`. This is Kafbat's own configuration file, not chart values, and the secret must exist before you install. Full configuration docs: https://ui.docs.kafbat.io/configuration/configuration-file

```bash
cat > kafbat-config.yaml <<'EOF'
kafka:
  clusters:
    - name: "apache-kafka"
      bootstrapServers: "kafka-dev-cluster.kafka-dev.cpln.local:9092"
      kafkaConnect:
        - name: kafka-dev-connect-connect-cluster
          address: http://kafka-dev-connect-connect-cluster.kafka-dev.cpln.local:8083
      properties:
        security.protocol: "SASL_PLAINTEXT"
        sasl.mechanism: "PLAIN"
        sasl.jaas.config: "org.apache.kafka.common.security.plain.PlainLoginModule required username=\"admin\" password=\"your-admin-password\";"

management:
  health:
    ldap:
      enabled: false

auth:
  type: "LOGIN_FORM"
spring:
  security:
    user:
      name: "admin"
      password: "adminPassword"

server:
  port: 8080
EOF

cpln secret create-opaque --name kafka-kafbat-ui-config --encoding plain -f kafbat-config.yaml
```

### Rack Awareness (reduce cross-zone traffic)

In a multi-zone cluster, a consumer that reads from the partition leader may be pulling data across an availability zone, which incurs cross-zone data-transfer charges. Rack awareness ([KIP-392](https://cwiki.apache.org/confluence/display/KAFKA/KIP-392%3A+Allow+consumers+to+fetch+from+closest+replica)) lets a consumer read from an in-sync replica in its **own** zone instead.

It is **disabled by default** and is **AWS-only** (it depends on the `AWS_ZONE_ID` env var, which is present only on AWS locations). Enable it on an AWS, multi-zone cluster:

```yaml
kafka:
  multiZone: true # spread brokers across zones so there's a same-zone replica to read from
  rackAwareness:
    enabled: true
```

**How it works:**

- Each broker advertises its AWS availability-zone ID as `broker.rack`. The value comes from the `AWS_ZONE_ID` env var (e.g. `usw2-az2`), which Control Plane injects into the broker pod from the node's `topology.k8s.aws/zone-id` label. The init script applies it at startup.
- The brokers run the `RackAwareReplicaSelector`, so a consumer whose `client.rack` matches a replica's rack is served by that same-zone replica.

**Client-side requirement (your responsibility):** consumers must set `client.rack` to their own AWS zone ID for the routing to take effect. For example, add to the consumer config:

```properties
client.rack=usw2-az2
```

Consumers running on Control Plane can source their own zone ID from the same `AWS_ZONE_ID` env var. A consumer that does not set `client.rack` (or sets a rack with no matching replica) simply falls back to reading from the leader, exactly as before.

**Notes and scope:**

- Only **consumer fetch** traffic becomes zone-local. Producer writes always go to the leader, and inter-broker replication is unchanged — those cross-zone flows are inherent to Kafka's replication model.
- Rack awareness is only beneficial when brokers are actually spread across zones (`kafka.multiZone: true`) so that a same-zone replica exists.
- **AWS-only.** On non-AWS locations `AWS_ZONE_ID` is absent, so `broker.rack` stays unset and `RackAwareReplicaSelector` is dead config — the brokers fall back to leader-only fetches. If you enable it there anyway, the broker init script logs an `INFO` line noting that `broker.rack` was left unset. Keep `kafka.rackAwareness.enabled: false` (the default) on non-AWS locations.

### Importing Externally-Managed Volume Sets

By default the chart creates one volume set per entry in `kafka.logDirs`, named `<release-name>-logs-<index>` (e.g. `kafka-logs-0`, `kafka-logs-1`), manages their settings, and mounts them on the broker workload.

Sometimes a cluster's data lives in volume sets that were created or renamed **outside** the chart — for example volume sets given a `-fresh` suffix during incident recovery. You cannot simply let the chart create volume sets under those names: adopting a volume set the chart didn't create fails on the `cpln/release` ownership tag, and even if it didn't, you don't want the chart overwriting an already-configured volume set's settings.

`kafka.volumes.logs.externalVolumeSets` **imports** such volume sets instead. For each non-empty entry the chart does **not** emit a `kind: volumeset` resource — it only points the broker workload's mount at that existing volume set by name, leaving its data and settings untouched:

```yaml
kafka:
  logDirs: /opt/kafka/logs-0,/opt/kafka/logs-1
  volumes:
    logs:
      externalVolumeSets:
        - kafka-logs-0-fresh
        - kafka-logs-1-fresh
```

- The named volume sets must already exist in the GVC (they are managed outside this chart). The chart references them but never creates, updates, or deletes them.
- Provide **exactly one entry per `kafka.logDirs` entry, in the same order**. Use an empty string (`""`) for any log dir you still want the chart to create and manage normally.
- If the list length doesn't match the number of log dirs, rendering fails with an explicit error — this prevents a partial list from silently leaving a log dir chart-managed and mounting a new empty volume set for it.
- Omit `externalVolumeSets` (the default empty list) to have the chart create and manage all log volume sets under the default `<release-name>-logs-<index>` names.

### Custom Tags for Kafka Connectors

You can now add custom tags to the kafka-connector workload by specifying a `tags` map in the connector entry. For example, to tag a connector with `cpln/largeDisk`:

```yaml
kafka_connectors:
  - name: cluster
    image: apache/kafka:3.9.1
    tags:
      cpln/largeDisk: 'true'
    # ... rest of config
```

These tags are applied to the connector **workload** resource only. Other connector-related resources (secrets, identity, volumeset, policy) continue to use the common chart tags.

### Kafka Connect plugins

The `plugins-downloader` container downloads every artifact of each plugin that has `enabled: true`. It stages each artifact on the plugin volume, verifies it, and then moves it into `<plugins_folder>/<plugin>/<key>/` in one step, so in a normal start Kafka Connect never sees a half-written file (a degraded start, below, is the exception). Kafka Connect scans the plugins folder only once per start, so it waits until every artifact is in place before it starts. An installed artifact is never downloaded again, so a restart takes seconds.

```yaml
kafka_connectors:
  - name: cluster
    plugins_wait_timeout_seconds: 900 # How long Kafka Connect waits for plugin downloads; 0 = wait forever
    plugins_wait_timeout_action: start # start = start without the missing plugins (logged as WARNING) / restart = exit and wait again
    plugins_redownload_token: "" # Change to any new value to download every plugin again on the next restart
    downloader_image: busybox:1.37.0-musl # Needs busybox sh, wget, nc (-e), ssl_client, setsid, stat, unzip, tar, sha256sum, sed, base64, tr, head, mktemp and the standard busybox tools (grep, cut, cat, date, mv, touch, sleep)
    downloader_cpu: 80m # Set 250m for artifacts of 50 MB or more: about 3x faster than 80m
    plugins:
      - name: snowflake-sink
        enabled: true # Required for a download; without it the connector is still created
        artifacts:
          - type: jar # jar, zip, tar, tgz or tar.gz
            url: https://repo1.maven.org/maven2/com/snowflake/snowflake-kafka-connector/3.1.1/snowflake-kafka-connector-3.1.1.jar
            sha256: <64 hex characters> # Optional: verified before install
```

- **`enabled: true` is required for a download.** A plugin without it is not downloaded, but its connector is still created. That is how you use a plugin you placed in the plugins folder yourself.
- **Removing `enabled: true` from an installed plugin** deletes the artifacts the chart downloaded for it once the next download pass succeeds. Its connector stays (with no `enabled` key) or is deleted (with `enabled: false`).
- **Set `sha256` on every artifact.** The downloader does not verify TLS certificates, so the checksum is the integrity check. On a mismatch the artifact is not installed and the download is retried.
- **Each artifact gets its own directory**, so a plugin with several `jar` artifacts keeps all of them, and they load in one classloader.
- **The chart deletes only artifacts it downloaded.** After you change an artifact URL, remove a plugin or set `enabled: false`, those artifacts are deleted once the next download pass succeeds. Nothing is deleted while any artifact has a configuration error (an unsupported type, a missing URL, an invalid plugin name). Files the chart did not download are never deleted; the downloader lists them at each start (`left untouched`).
- **If an artifact is still missing at the timeout**, `start` starts Kafka Connect without it and the `kafka-connect` log shows `WARNING: connector plugins not ready … WITHOUT:` with the list. When the download later succeeds, the downloader logs that the worker must be restarted: run `cpln workload force-redeployment`. Until then, a restart of only the `kafka-connect` container starts at once without waiting, and still loads both the old and the new copy of a changed plugin, because cleanup waits for a new replica.
- **Volume space:** every installed artifact, plus room to download and unpack the largest one. When an artifact URL changes, the old and new copies both stay until the pass succeeds.
- **Credentials in an artifact URL are sent only to that URL's host.** A redirect to another host (such as a presigned storage URL) is followed without them. TLS certificates are not validated, so the credentials are only as private as the network path: use `sha256` and trusted networks. Percent-encode `/`, `?`, `#` and `@` inside the user name or password.
- **A custom `downloader_image`** must provide the busybox applets listed above, including `nc` with `-e`, `ssl_client` and `setsid` (used for URLs with credentials), and a `head -c` that reads exactly the requested bytes from a shared descriptor, as busybox's does.
- **Credentials in artifact URLs are redacted in the logs** (`***@`, `?<redacted>`). They are still readable in the `-download` secret. Connector configs are never logged, only their key names; `verbose: true` adds downloader detail (skips, keys, sizes) and nothing secret.

#### Upgrading from 4.2.x or earlier

- The first start after the upgrade downloads every plugin again, once per replica, while Kafka Connect waits. Expect connectors to be down for about one full download. Later restarts take seconds.
- Files the chart did not download are never deleted. The chart's old `<plugin>/<plugin>.jar` files are moved to `.cpln-downloads/retired/` in the plugins folder, for plugins that still have a `jar` artifact; a file you placed at exactly that path is moved too, and can be moved back.
- Directories that earlier versions extracted from `zip`, `tar` or `tgz` artifacts stay in place, and Kafka Connect still loads them beside the new copy. Once your connectors are `RUNNING`, remove them on each replica (named `RELEASE_NAME-connect-CONNECTOR_NAME-0`, `-1`, …) and restart the workload. Do not remove `.cpln-downloads` or directories you placed yourself:
  ```bash
  cpln workload exec RELEASE_NAME-connect-CONNECTOR_NAME --gvc GVC_NAME --location LOCATION --replica REPLICA_NAME --container plugins-downloader -- ls -A /opt/kafka/plugins
  cpln workload exec RELEASE_NAME-connect-CONNECTOR_NAME --gvc GVC_NAME --location LOCATION --replica REPLICA_NAME --container plugins-downloader -- rm -rf /opt/kafka/plugins/OLD_DIRECTORY
  cpln workload force-redeployment RELEASE_NAME-connect-CONNECTOR_NAME --gvc GVC_NAME
  ```
- Rolling back to 4.2.x works and connectors keep running, but 4.2.x writes its `<plugin>/<plugin>.jar` files again beside the 4.3.0 directories (both load in one classloader) and its 60-second startup race returns. Upgrading to 4.3.0 again retires those files.

### Broker and Kafka Connect Logs

For official `apache/kafka:3.x.y` images the chart sets `KAFKA_LOG4J_ROOT_LOGLEVEL=INFO`. The main broker log then goes to stdout only (`cpln logs`), instead of also to `/opt/kafka/logs/server.log`. That copy was never deleted and eventually filled the container's ephemeral storage. The small controller, state-change, request, log-cleaner and authorizer logs and the size-capped GC log still go to `/opt/kafka/logs`, as before. To use a different level, set a non-empty `KAFKA_LOG4J_ROOT_LOGLEVEL` in `kafka.env`, on 3.x images only: on a 4.x image this variable removes every output from the root logger, including stdout.

Kafka Connect workers on `apache/kafka:3.x` images (4.4.1) drop `connectAppender` from the root logger of `connect-log4j.properties`, so the worker log goes to stdout only, instead of also to `/opt/kafka/logs/connect.log`, which was never deleted and filled the container's ephemeral storage.

### Release Notes
See [RELEASES.md](https://github.com/controlplane-com/templates/blob/main/kafka/RELEASES.md)

### Important Notes

- **Never turn `kafka.multiZone` or a connector's `multiZone` off once it has been on.** Each replica's volume stays in the zone it was created in, so with multi-zone off a replica whose volume is in another zone cannot be scheduled and the rollout stops at it. Turning one on later is safe. `cpln helm upgrade` does not reuse earlier values, so keep the setting in your values file on every upgrade. To recover, upgrade again with it on, then force a redeployment of the affected workload.
- **`kafka.replicas` sets the cluster size, and the first nodes take the controller role.** Shrinking a running cluster below the controller quorum will make it unavailable.
- **Set `kafka.credentialsSecretName` to keep the broker passwords out of the Helm release.** Inline passwords still work but are stored in the release values; their defaults are non-working placeholders.
- **A changed password in a credentials secret takes effect only after `cpln workload force-redeployment`** of the workloads that read it.
- **The Kafbat UI and REST Proxy images are unpinned** (`:latest`), so a redeploy may pick up newer builds of either.
- **Replication factor is derived from `kafka.replicas`** unless you override it in `extra_configurations`. A single-broker cluster cannot replicate, so topics created there survive nothing.
- **Uninstalling deletes the volume sets**, and with them every topic's log.
- **A connector that is `FAILED` with "Failed to find any class" after its plugin arrived late needs a worker restart** (`cpln workload force-redeployment`). A REST restart does not rescan the plugins folder.
- **After changing a secret a connector reads, run `cpln workload force-redeployment`** on its Connect workload; running workers keep the value they read at start.
- **The Kafka Connect workload reports ready while it waits for plugins.** Read the `kafka-connect` container log for `Waiting for plugin downloads` or `WARNING: connector plugins not ready`.
- **Connectors cannot declare config providers of their own (4.5.1).** The workers start with `-Dorg.apache.kafka.automatic.config.providers=none`; a connector whose config sets `config.providers` for its clients (`producer.override.*`, `consumer.override.*`, `admin.override.*`, MirrorMaker `source.*`/`target.*`) fails with `… is not allowed`. Declare providers in `connector_properties` instead.

### Links

- [Apache Kafka documentation](https://kafka.apache.org/documentation/)
- [KRaft mode](https://kafka.apache.org/documentation/#kraft)
- [Kafbat UI](https://github.com/kafbat/kafka-ui)
