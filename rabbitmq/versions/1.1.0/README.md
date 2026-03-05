## RabbitMQ

Creates a single-node RabbitMQ instance with a persistent volume on Control Plane.

### Configuration

**Credentials and listener** — set the default username, password, and AMQP port:
```yaml
rabbitmq_conf:
  listeners_tcp_default: 5672
  default_user: user
  default_pass: changeMe
```

**Resources** — adjust CPU and memory:
```yaml
cpu: 200m
memory: 250Mi
```

**Volume** — configure persistent storage for RabbitMQ data:
```yaml
volumeset:
  volume:
    initialCapacity: 10
    fileSystemType: ext4        # ext4 or xfs
    performanceClass: general-purpose-ssd  # general-purpose-ssd or high-throughput-ssd
```

**Firewall** — control which workloads can connect. Defaults to `same-gvc`:
```yaml
firewall:
  internal_inboundAllowType: same-gvc  # same-gvc or same-org
```

**Timeout** — request timeout in seconds:
```yaml
timeoutSeconds: 30
```

### Connecting

RabbitMQ is accessible internally to other workloads in the same GVC on port 5672.

By workload hostname:
```
RELEASE_NAME-rabbitmq.GVC_NAME.cpln.local:5672
```

By replica (for direct replica addressing):
```
RELEASE_NAME-rabbitmq-0.RELEASE_NAME-rabbitmq:5672
```

The management UI runs on port 15672 and is accessible at the same internal hostname.

### Supported External Services
- [RabbitMQ Documentation](https://www.rabbitmq.com/docs)
- [RabbitMQ Management Plugin](https://www.rabbitmq.com/docs/management)
