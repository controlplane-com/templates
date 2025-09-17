# CockroachDB

CockroachDB is a distributed SQL database built on a transactional and strongly-consistent key-value store. It provides automatic replication, distribution, and survivability across multiple locations with minimal latency and maximum throughput. CockroachDB offers ACID transactions, horizontal scalability, and built-in fault tolerance, making it ideal for applications requiring global data distribution and high availability.

## Configuration

To configure your CockroachDB cluster across multiple locations, update the `gvc.locations` section in the `values.yaml` file:

## Access

Once deployed, CockroachDB will be available on:
- **SQL Port**: 26257 (default)
- **HTTP Port**: 8080 (for admin UI)

The cluster automatically handles data distribution and replication across your configured locations.
