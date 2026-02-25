## RabbitMQ App

This app creates a single node RabbitMQ on Control Plane Platform.

### Accessing RabbitMQ

Workloads are allowed to access Rabbitmq based on the `firewallConfig` you specify. You can learn more about it in our [documentation](https://docs.controlplane.com/reference/workload#internal).

#### Option 1:

Syntax: <WORKLOAD_NAME>:<PORT>
```
{workload-name}.{gvc-name}.cpln.local:5672
```
#### Option 2: (By replica)

Syntax: <REPLICA_NAME>.<WORKLOAD_NAME>
```
{workload-name}-0.{workload-name}:5672
```