## Redis Sentinel

Creates a Redis Sentinel cluster on Control Plane with automatic leader election and failover.

### Configuration

**Redis and Sentinel** — set replicas, resources, and timeouts for each. Sentinel replicas must be an odd number for quorum:
```yaml
redis:
  replicas: 2
  resources:
    minCpu: 80m
    minMemory: 128Mi
    cpu: 200m
    memory: 256Mi

sentinel:
  replicas: 3
  quorumAutoCalculation: true  # calculates as (replicas/2)+1
```

**Authentication** — enable one method. Apply the same config under both `redis.auth` and `sentinel.auth`:
```yaml
redis:
  auth:
    password:
      enabled: true
      value: your-password
    # fromSecret:
    #   enabled: true
    #   name: my-redis-secret
    #   passwordKey: password
```

**Persistence** — disabled by default. Enable to attach a persistent volume to Redis:
```yaml
redis:
  persistence:
    enabled: true
    volumes:
      data:
        initialCapacity: 10
        performanceClass: general-purpose-ssd  # or high-throughput-ssd (min 1000 GiB)
        fileSystemType: ext4
```

**Firewall** — set the internal access scope for both Redis and Sentinel:
```yaml
firewall:
  internal_inboundAllowType: same-gvc  # same-gvc, same-org, or workload-list
```

### Connecting

Redis is accessible internally on port 6379:
```
RELEASE_NAME-redis.GVC_NAME.cpln.local:6379
```

Sentinel is accessible on port 26379:
```
RELEASE_NAME-sentinel.GVC_NAME.cpln.local:26379
```

To route writes to the current master:
```bash
MASTER_INFO=$(redis-cli -h RELEASE_NAME-sentinel.GVC_NAME.cpln.local -p 26379 SENTINEL get-master-addr-by-name mymaster)
MASTER_HOST=$(echo $MASTER_INFO | cut -d' ' -f1)
MASTER_PORT=$(echo $MASTER_INFO | cut -d' ' -f2)
redis-cli -h $MASTER_HOST -p $MASTER_PORT SET my-key "value"
```

### Supported External Services
- [Redis Documentation](https://redis.io/docs/)
- [Redis Sentinel Documentation](https://redis.io/docs/latest/operate/oss_and_stack/management/sentinel/)

### Release Notes
See [RELEASES.md](https://github.com/controlplane-com/templates/blob/main/redis/RELEASES.md)
