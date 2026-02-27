## Redis Cluster App

This app creates a Redis Cluster with at least 6 nodes on Control Plane Platform.

### Configuration

**Replicas and resources** — minimum of 6 replicas required for a valid cluster (3 primaries + 3 replicas):
```yaml
replicas: 6
port: 6379
cpu: 200m
memory: 250Mi
```

**Authentication** — uncomment and set a password to enable auth on all nodes:
```yaml
redis:
  password: "your-secure-password-here"
```

When connecting to a password-protected cluster, pass the `-a` flag:
```
redis-cli -c -h {workload-name} -p 6379 -a {password} set mykey "test"
```

**Internal access** — controls which workloads can reach the cluster:
```yaml
internalAccess:
  type: same-gvc  # options: none, same-gvc, same-org, workload-list
  workloads:      # required when type is workload-list
    # - //gvc/GVC_NAME/workload/WORKLOAD_NAME
```

**Volume storage** — configure initial capacity and optional autoscaling:
```yaml
volumeset:
  capacity: 10         # initial capacity in GiB (minimum 10)
  autoscaling:
    enabled: false
    maxCapacity: 100   # GiB ceiling
    minFreePercentage: 10
    scalingFactor: 1.2
```

### Accessing redis-cluster

Workloads are allowed to access Redis Cluster based on the `firewallConfig` you specify. You can learn more about it in our [documentation](https://docs.controlplane.com/reference/workload#internal).

Important: To access workloads listening on a TCP port, the client workload must be in the same GVC. Thus, the Redis cluster is accessible to clients running within the same GVC.

#### Option 1:

Syntax: <WORKLOAD_NAME>

```
redis-cli -c -h {workload-name} -p 6379 set mykey "test"
redis-cli -c -h {workload-name} -p 6379 get mykey
```

#### Option 2: (By replica)

Syntax: <REPLICA_NAME>.<WORKLOAD_NAME>

```
redis-cli -c -h {workload-name}-0.{workload-name} -p 6379 set mykey "test"
redis-cli -c -h {workload-name}-1.{workload-name} -p 6379 get mykey
redis-cli -c -h {workload-name}-2.{workload-name} -p 6379 get mykey
redis-cli -c -h {workload-name}-3.{workload-name} -p 6379 get mykey
redis-cli -c -h {workload-name}-4.{workload-name} -p 6379 get mykey
redis-cli -c -h {workload-name}-5.{workload-name} -p 6379 get mykey
```

### Supported External Services
- [Redis Documentation](https://redis.io/docs/)
- [Redis Cluster Documentation](https://redis.io/docs/latest/operate/oss_and_stack/management/scaling/)