# MinIO Distributed Object Storage

MinIO is a high-performance, S3-compatible object storage system. This template deploys MinIO in distributed mode with erasure coding, which improves durability, fault tolerance, and scalability by spreading data across multiple replicas.

## Configuration Requirements

- `replicas` must be an even number.

- **Minimum required**: 4 replicas.

- **Recommended for production**: 6 or more replicas.

### Warning

If deploying 6 or more replicas, you will need to request a quota increase for replicas per workload if your org is at the default quotas.

## Connecting to MinIO

If connecting from a separate workload which has internal access to this workload using the MinIO Client (mc):

```sh
mc alias set minio http://WORKLOAD_NAME:9000 $USERNAME $PASSWORD
```

## Additional Resources

- [MinIO README](https://github.com/minio/minio?tab=readme-ov-file#minio-quickstart-guide)
- [MinIO Distributed Quickstart Guide](https://fossies.org/linux/minio-RELEASE/docs/distributed/README.md)