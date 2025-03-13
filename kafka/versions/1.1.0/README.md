## Kafka App

### How to connect to the cluster

You can connect to Kafka from the same GVC in which it's deployed using the following methods:

- To connect using the cluster's general address, use `{kafka-cluster-workload-name}:9092`.

- To connect to a specific replica, use one of the following addresses based on the replica you wish to connect to:
  - `{kafka-cluster-workload-name}-0.{kafka-cluster-workload-name}:9092`
  - `{kafka-cluster-workload-name}-1.{kafka-cluster-workload-name}:9092`
  - `{kafka-cluster-workload-name}-2.{kafka-cluster-workload-name}:9092`

### Test Kafka Cluster with Kafka Client

1. To activate the Kafka client, make sure `kafka_client` is uncommented in your values file. If necessary, reinstall the chart with the command:
   ```bash
   cpln helm install kafka-dev-cluster -f values-kafka-dev.yaml
   ```

2. To connect to the `kafka-client` workload, navigate through the UI to the appropriate GVC and select the `kafka-client` workload. In the workload details, find and use the **Connect** feature to establish a connection, which can be done either via the UI or by utilizing the CLI command provided there.

3. Once connected, you can write and consume messages through the `kafka-client` workload. If it's `PLAINTEXT`, producer and consumer configurations should be omitted below:

```BASH
# Change to bin directory
cd /opt/bitnami/kafka/bin

# Create client.properties
echo "security.protocol=SASL_PLAINTEXT
sasl.mechanism=PLAIN
sasl.jaas.config=org.apache.kafka.common.security.plain.PlainLoginModule required username=\"kafka-admin\" password=\"fkor3Dro52oodA\";" > ./client.properties

# Produce messages to the 'controlplane' topic
kafka-console-producer.sh --bootstrap-server {kafka-cluster-workload-name}:9092 --topic controlplane --producer.config ./client.properties

# Consume messages from the 'controlplane' topic
kafka-console-consumer.sh --bootstrap-server {kafka-cluster-workload-name}:9092 --topic controlplane --from-beginning --consumer.config ./client.properties
```