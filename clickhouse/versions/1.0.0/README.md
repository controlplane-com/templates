## ClickHouse App

This app creates a ClickHouse cluster with ClickHouse Keeper coordination on Control Plane Platform.

ClickHouse is a columnar database management system designed for real-time analytical data processing and data warehousing. This deployment includes both ClickHouse Server and ClickHouse Keeper components for distributed coordination.

### Configuration

Before installing, update the values file with your desired configuration:

- **Database settings**: Configure database name and password in the `database` section
- **Resources**: Adjust CPU and memory for both server and keeper workloads
- **Locations**: Configure replica counts per location (affects server workload only)
- **GVC name**: Set your desired GVC name

### Important Notes

- **Keeper Replicas**: ClickHouse Keeper always runs with 3 total replicas (1 per location) for proper raft coordination, use minimum 3 locations for high availability between Keeper nodes.
- **Multi-location**: This deployment supports multiple locations for high availability
- **Ports**: 
  - ClickHouse Server: 8123 (HTTP for client), 9000 (TCP), 9009 (HTTP between server nodes)
  - ClickHouse Keeper: 9181 (TCP for servers), 9234 (TCP between keeper nodes)

### Supported External Services

[ClickHouse Documentation](https://clickhouse.com/docs/).