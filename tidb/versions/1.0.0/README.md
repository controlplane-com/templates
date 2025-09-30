# TiDB

TiDB is a distributed SQL database that provides horizontal scalability, strong consistency, and MySQL compatibility. It features a distributed architecture with separate components for storage (TiKV), computation (TiDB Server), and metadata management (PD), making it ideal for applications requiring massive scale, high availability, and seamless migration from MySQL.

## Configuration

To configure your TiDB cluster across multiple locations, update the `gvc.locations` section in the `values.yaml` file:

**Note:** It is recommended to have at least 3 replicas of Placement Driver (PD) and TiKV and at least 2 replicas of TiDB Server.

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

To connect to your TiDB cluster using the MySQL client, use the following command:

```bash
mysql -h <TIDB_SERVER_WORKLOAD_INTERNAL_NAME> -P 4000 -u <USER> -p
```

Replace:
- `<TIDB_SERVER_WORKLOAD_INTERNAL_NAME>` with the internal name of your TiDB server workload
- `<USER>` with your database username
- The `-p` flag will prompt you for the password

**Note:** Depending on the number of replicas and locations configured, TiDB can take up to 5 minutes to become ready for connections.

The cluster automatically handles data distribution and replication across your configured locations.

### Supported External Services
- [TiDB Documentation](https://docs.pingcap.com/tidb/stable/)