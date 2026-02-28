# TiDB

TiDB is a distributed SQL database that provides horizontal scalability, strong consistency, and MySQL compatibility. It features a distributed architecture with separate components for storage (TiKV), computation (TiDB Server), and metadata management (PD), making it ideal for applications requiring massive scale, high availability, and seamless migration from MySQL.

## Configuration

To configure your TiDB cluster across multiple locations, update the `gvc.locations` section in the `values.yaml` file:

```yaml
gvc:
  name: my-tidb-gvc
  locations:
    - name: aws-us-east-1
      replicas: 1
    - name: aws-us-west-2
      replicas: 1
    - name: aws-eu-central-1
      replicas: 1
  pdReplicas: 3 # options: 3, 5, 7
```

The `replicas` value per location controls how many TiDB Server and TiKV replicas run in that location. The `pdReplicas` value controls how many Placement Driver replicas are distributed across all locations (must be 3, 5, or 7).

**Important:** TiDB's PD and TiKV components rely on Raft quorum for high availability. Deploy across a minimum of 3 locations to maintain quorum if one location becomes unavailable.

### Resource Configuration

The default resource configuration in `values.yaml` is designed for **testing and development environments**. For production deployments, resources should be increased based on the following:

**Production Recommendations:**
- **PD (Placement Driver)**: 4-8 CPU cores, 8-16GB RAM
- **TiDB Server**: 8-16 CPU cores, 16-32GB RAM (scales with concurrent connections)
- **TiKV (Storage)**: 8-16 CPU cores, 32-64GB RAM (memory-intensive for caching)

### Volume Storage

Configure initial storage capacity and optional autoscaling for TiKV (the data store). PD only holds cluster state and does not require autoscaling.

```yaml
volumeset:
  tikv:
    capacity: 10 # initial capacity in GiB (minimum is 10)
    autoscaling:
      enabled: false
      maxCapacity: 100       # maximum capacity in GiB
      minFreePercentage: 10  # scale when free space drops below this percentage
      scalingFactor: 1.2     # multiply current capacity by this factor when scaling
  pd:
    capacity: 10 # initial capacity in GiB
```

### Database Initialization

Enable `autoCreateDatabase` in `values.yaml` to automatically create a database and user on first install. An init workload is deployed to run the setup script, and can be removed once complete to save resources.

**Phase 1 — initial deploy:**
```yaml
autoCreateDatabase:
  enabled: true
  deployInitWorkload: true
  database:
    rootPassword: your-root-password
    user: myuser
    password: mypassword
    db: mydb
```

**Phase 2 — after initialization is complete**, upgrade with `deployInitWorkload: false` to remove the init workload and its secret while keeping the credentials available to the server:
```yaml
autoCreateDatabase:
  enabled: true
  deployInitWorkload: false
```

| Parameter | Description |
|-----------|-------------|
| `enabled` | Set to `true` to enable automatic database creation |
| `deployInitWorkload` | Set to `false` after the DB is initialized to remove the init workload and save resources |
| `database.rootPassword` | Root password for the TiDB cluster |
| `database.user` | Username for the new database user |
| `database.password` | Password for the new database user |
| `database.db` | Name of the database to create |

### Internal Access Configuration

To specify which workloads can access this TiDB cluster internally, configure the `internal_access` section in your `values.yaml` file:

**Access Types:**
- `same-gvc`: Allow access from all workloads in the same GVC
- `same-org`: Allow access from all workloads in the same organization
- `workload-list`: Allow access only from specific workloads listed in `workloads` and can be used in conjunction with `same-gvc`

Once deployed, TiDB will be available on Port 4000 (default)

### Connecting to TiDB

To connect to your TiDB cluster using a MySQL client, use the following command:

```bash
mysql -h <TIDB_SERVER_WORKLOAD_INTERNAL_NAME> -P 4000 -u <USER> -p
```

**Note:** Depending on the number of replicas and locations configured, TiDB can take up to 5 minutes to become ready for connections.

The cluster automatically handles data distribution and replication across your configured locations.

**Note on GVC Naming**

This template creates a GVC with a default name defined in the `values.yaml`. If you plan to deploy multiple instances of this template, you **must assign a unique GVC name** for each deployment.

### Supported External Services
- [TiDB Documentation](https://docs.pingcap.com/tidb/stable/)