## PostGIS

Creates a single replica PostGIS database with a dedicated persistent volume. PostGIS extends PostgreSQL with support for geographic objects and spatial queries.

### Warning

This application works only with a single replica, do not scale up the replicas.

### Configuration

**Database credentials** — set a username, password, and database name:
```yaml
config:
  username: username
  password: password
postgres:
  database: database
```

**Resources** — adjust CPU and memory per replica:
```yaml
resources:
  cpu: 500m
  memory: 1024Mi
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

**Internal access** — controls which workloads can reach PostGIS on port 5432. Use `same-gvc` to allow any workload in the same GVC, `same-org` for any workload in the org, or `workload-list` to specify exact workloads:
```yaml
internalAccess:
  type: workload-list
  workloads:
    - //gvc/my-gvc/workload/my-app
```

### Connecting

Once deployed, PostGIS will be reachable at:

```
RELEASE_NAME-postgis.GVC_NAME.cpln.local:5432
```

### Supported External Services
- [PostGIS Documentation](https://postgis.net/documentation/)
- [PostgreSQL Documentation](https://www.postgresql.org/docs/)
