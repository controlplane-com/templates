## NATS Super Cluster

### Overview
NATS is an open-source, high-performance, lightweight messaging system optimized for cloud-native architectures. It supports pub/sub, queueing and request/reply patterns, and its Supercluster architecture replicates data and balances load across one or multiple regions for global scalability, fault tolerance and low latency. This template creates one GVC with a super cluster configuration that can span across any regions of your GVC. By default it exposes a Websocket interface. Make sure you modify the CIDR groups to just the IPs you wish to accept connections from. 

You can also add any valid NATS configuration in the values file under nats_extra_config

**Note on GVC Naming**

This template creates a GVC with a default name defined in the `values.yaml`. If you plan to deploy multiple instances of this template, you **must assign a unique GVC name** for each deployment.

### Supported External Services
- [NATS Documentation](https://docs.nats.io/)
