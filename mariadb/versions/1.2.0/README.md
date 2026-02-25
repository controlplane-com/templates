## MariaDB

Creates a single replica MariaDB database and an optional phpMyAdmin management interface.

### Warning

This application works only with a single replica, do not scale up the replicas.

### Configuration

**Database credentials** — set a secure root password and user password:
```yaml
config:
  db: my-database
  rootPassword: my-root-password
  user: my-user
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

**Internal access** — controls which workloads can reach MariaDB on port 3306. Use `same-gvc` to allow any workload in the same GVC, `same-org` for any workload in the org, or `workload-list` to specify exact workloads:
```yaml
internalAccess:
  type: workload-list
  workloads:
    - //gvc/my-gvc/workload/my-app
```

**phpMyAdmin** — set to `false` to skip deploying the phpMyAdmin workload:
```yaml
enablePhpMyAdmin: true
```

### Connecting

Once deployed, MariaDB will be reachable at:

```
RELEASE_NAME-maria.GVC_NAME.cpln.local:3306
```

### Supported External Services
- [MariaDB docs](https://mariadb.com/docs)