## MongoDB

Creates a single replica MongoDB database with a dedicated persistent volume.

### Warning

This application works only with a single replica, do not scale up the replicas.

### Configuration

**Database credentials** — set a username and password for the MongoDB root user:
```yaml
config:
  username: my-user
  password: my-password
```

**Resources** — adjust CPU and memory parameters:
```yaml
resources:
  minCpu: 100m
  minMemory: 128Mi
  maxCpu: 250m
  maxMemory: 264Mi
```

**Volume** — set the initial storage capacity (minimum 10 GiB). Optionally enable autoscaling to expand the volume automatically as it fills up:
```yaml
volumeset:
  capacity: 10
  autoscaling:
    enabled: true
    maxCapacity: 100
    minFreePercentage: 10
    scalingFactor: 1.2
```

**Internal access** — controls which workloads can reach MongoDB on port 27017. Use `same-gvc` to allow any workload in the same GVC, `same-org` for any workload in the org, or `workload-list` to specify exact workloads:
```yaml
internalAccess:
  type: workload-list
  workloads:
    - //gvc/my-gvc/workload/my-app
```

**Direct load balancer** — set to `true` to expose MongoDB externally via a dedicated load balancer IP:
```yaml
directLoadBalancer:
  enabled: false
```

### Connecting

Once deployed, MongoDB will be reachable at:

```
RELEASE_NAME-mongo.GVC_NAME.cpln.local:27017
```

### Supported External Services
- [MongoDB docs](https://www.mongodb.com/docs)