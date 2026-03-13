## Redis Multi-Location

Creates a Redis Sentinel cluster spread across multiple locations on Control Plane. Each location runs in a single GVC with replicas distributed per location via `localOptions`, and Sentinel provides automatic leader election and failover across locations.

### Configuration

**GVC and locations** — set the GVC name and define each location with its replica count. Minimum 2 locations required:
```yaml
gvc:
  name: my-redis-gvc
  locations:
    - name: aws-eu-central-1
      replicas: 2
    - name: aws-us-west-2
      replicas: 2
    - name: aws-us-east-1
      replicas: 2
```

**Resources** — set CPU and memory for Redis and Sentinel independently:
```yaml
redis:
  resources:
    cpu: 200m
    memory: 256Mi

sentinel:
  resources:
    cpu: 200m
    memory: 256Mi
```

**Authentication** — uncomment to enable passwords. Apply the same Redis password under `sentinel` if you want Sentinel auth as well:
```yaml
redis:
  # password: your-redis-password

sentinel:
  # password: your-sentinel-password
```

**Volumeset** — configure initial storage per Redis replica and optional autoscaling:
```yaml
redis:
  volumeset:
    initialCapacity: 20 # GiB
    autoscaling:
      enabled: false
      maxCapacity: 100  # GiB
      minFreePercentage: 10
      scalingFactor: 1.2
```

**Firewall** — controls which workloads can reach the cluster:
```yaml
firewall:
  internalAllowType: same-gvc # options: same-gvc, same-org, workload-list
  # workloads:
  #   - //gvc/GVC_NAME/workload/WORKLOAD_NAME
```

**Sentinel quorum** — must be less than the total number of sentinel instances (one per location). For 3 locations a quorum of 2 is recommended:
```yaml
sentinel:
  quorum: 2
```

### Connecting

Redis replica `0` is always the initial master. All replicas are accessible within the GVC on port `6379`, and Sentinel on port `26379`.

#### Option 1: via workload name (load-balanced)
```
redis-cli -h {release-name}-redis -p 6379 set mykey "test"
redis-cli -h {release-name}-redis -p 6379 get mykey
```

#### Option 2: directly to a replica
```
redis-cli -h {release-name}-redis-0.{release-name}-redis -p 6379 set mykey "test"
redis-cli -h {release-name}-redis-1.{release-name}-redis -p 6379 get mykey
```

#### Routing writes to the current master via Sentinel
```bash
# Query Sentinel for the current master
MASTER_INFO=$(redis-cli -h {release-name}-sentinel -p 26379 SENTINEL get-master-addr-by-name mymaster)
MASTER_HOST=$(echo $MASTER_INFO | cut -d' ' -f1)
MASTER_PORT=$(echo $MASTER_INFO | cut -d' ' -f2)

# Write to the master
redis-cli -h $MASTER_HOST -p $MASTER_PORT SET my-key "Hello world"

# Read from any replica
redis-cli -h {release-name}-redis -p 6379 GET my-key
```

### Supported External Services
- [Redis Documentation](https://redis.io/docs/)
- [Redis Sentinel Documentation](https://redis.io/docs/latest/operate/oss_and_stack/management/sentinel/)
