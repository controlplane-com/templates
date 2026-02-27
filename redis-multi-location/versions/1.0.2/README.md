## Redis Sentinel App

This app creates a Redis sentinel cluster, in multiple locations, on Control Plane Platform.

### Accessing redis

Workloads are allowed to access Redis based on the `firewallConfig` you specify. You can learn more about it in our [documentation](https://docs.controlplane.com/reference/workload#internal).

#### Option 1:

Syntax: <WORKLOAD_NAME>
```
redis-cli -h {workload-name} -p 6379 set mykey "test"
redis-cli -h {workload-name} -p 6379 get mykey
```
#### Option 2: (By replica)

Syntax: <REPLICA_NAME>.<WORKLOAD_NAME>
```
redis-cli -h {workload-name}-0.{workload-name} -p 6379 set mykey "test"
redis-cli -h {workload-name}-1.{workload-name} -p 6379 get mykey
```

#### To get the master node for write, you can query sentinel
```
# Connect to Redis Sentinel to get the master address
redis-cli -h {sentinel-workload-node} -p 26379 sentinel get-master-addr-by-name mymaster

# Then, connect to the master node and set a key:
redis-cli -h {master-workload-node} -p 6379 SET test_key "Hello world"

# Then, connect to any redis node and get the key
redis-cli -h {redis-workload-node} -p 6379 GET test_key
```

#### To get the master node for write, you can query sentinel
```bash
# First, query Sentinel to get the current master address
MASTER_INFO=$(redis-cli -h {sentinel-workload-name} -p 26379 SENTINEL get-master-addr-by-name mymaster)
MASTER_HOST=$(echo $MASTER_INFO | cut -d' ' -f1)
MASTER_PORT=$(echo $MASTER_INFO | cut -d' ' -f2)

# Then, connect to the master node and set a key
redis-cli -h $MASTER_HOST -p $MASTER_PORT SET test_key "Hello world"

# You can then connect to any redis node to get the key
redis-cli -h {workload-name} -p 6379 GET test_key
```