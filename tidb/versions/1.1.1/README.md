# TiDB

TiDB is a distributed SQL database that provides horizontal scalability, strong consistency, and MySQL compatibility. It features a distributed architecture with separate components for storage (TiKV), computation (TiDB Server), and metadata management (PD), making it ideal for applications requiring massive scale, high availability, and seamless migration from MySQL.

## Configuration

To configure your TiDB cluster across multiple locations, update the `gvc.locations` section in the `values.yaml` file:

**Important:** For production deployments, it is recommended to run at least 3 replicas of both Placement Driver (PD) and TiKV, and at least 2 replicas of TiDB Server.

- TiDB’s PD and TiKV components rely on Raft quorum for high availability. To maintain quorum if a location becomes unavailable, deploy the cluster across a minimum of three independent locations (for example, three regions or zones). This ensures the cluster remains healthy and can continue serving requests even if one location fails.

### Resource Configuration

The default resource configuration in `values.yaml` is designed for **testing and development environments**. For production deployments, resources should be increased based on the following:

**Production Recommendations:**
- **PD (Placement Driver)**: 4-8 CPU cores, 8-16GB RAM
- **TiDB Server**: 8-16 CPU cores, 16-32GB RAM (scales with concurrent connections)
- **TiKV (Storage)**: 8-16 CPU cores, 32-64GB RAM (memory-intensive for caching)

### Database Initialization

To create a database with a user on initialization, configure the `database` section in your `values.yaml` file:

This will automatically create the specified database and user when the TiDB cluster is first deployed.

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

Replace:
- `<TIDB_SERVER_WORKLOAD_INTERNAL_NAME>` with the internal name of your TiDB server workload
- `<USER>` with your database username
- The `-p` flag will prompt you for the password

**Note:** Depending on the number of replicas and locations configured, TiDB can take up to 5 minutes to become ready for connections.

The cluster automatically handles data distribution and replication across your configured locations.

**Note on GVC Naming**

This template creates a GVC with a default name defined in the `values.yaml`. If you plan to deploy multiple instances of this template, you **must assign a unique GVC name** for each deployment.

### Supported External Services
- [TiDB Documentation](https://docs.pingcap.com/tidb/stable/)