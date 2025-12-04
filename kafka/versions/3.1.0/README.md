## Kafka App

### How to connect to the cluster

You can connect to Kafka from the same GVC in which it's deployed using the following methods:

- To connect using the cluster's general address, use `{kafka-cluster-workload-name}:9092`.

- To connect to a specific replica, use one of the following addresses based on the replica you wish to connect to:
  - `{kafka-cluster-workload-name}-0.{kafka-cluster-workload-name}:9092`
  - `{kafka-cluster-workload-name}-1.{kafka-cluster-workload-name}:9092`
  - `{kafka-cluster-workload-name}-2.{kafka-cluster-workload-name}:9092`

- If you're configuring your Kafka for external access, you'll need to provide a domain name for the public address of the listener you want to use. Prerequisites:
  - Make sure the dedicated load balancer is enabled on the GVC. See [Configure Domain documentation](https://docs.controlplane.com/guides/configure-domain#dedicated-load-balancing).
  - Make sure to register your [Apex domain](https://docs.controlplane.com/reference/domain#apex-domain-considerations) name with Control Plane and set up a DNS record for the Kafka public address CNAME with the canonical GVC endpoint in your DNS provider.

### Test Kafka Cluster with Kafka Client

1. To activate the Kafka client, make sure `kafka_client` is uncommented in your values file. If necessary, reinstall the chart with the command:
   ```bash
   cpln helm install kafka-dev -f values-example.yaml
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
kafka-console-producer.sh --bootstrap-server {kafka-cluster-workload-name}:9092 --topic controlplane --producer.config ./client.properties

# Consume messages from the 'controlplane' topic
kafka-console-consumer.sh --bootstrap-server {kafka-cluster-workload-name}:9092 --topic controlplane --from-beginning --consumer.config ./client.properties
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

Full configuration Docs: https://ui.docs.kafbat.io/configuration/configuration-file

```YAML
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
```

### Release Notes
See [RELEASES.md](https://github.com/controlplane-com/templates/blob/main/kafka/RELEASES.md)
