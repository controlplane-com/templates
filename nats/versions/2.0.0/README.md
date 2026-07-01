## NATS Super Cluster

### Overview

NATS is an open-source, high-performance, lightweight messaging system optimized for cloud-native architectures. It supports pub/sub, queueing, and request/reply patterns. This template creates a GVC with a super cluster configuration that can span across any regions, with each location running independent replicas. By default it exposes a WebSocket interface on port 443 via Control Plane's TLS termination.

**Note on GVC Naming** — if you plan to deploy multiple instances of this template, you must assign a unique GVC name for each deployment.

### Configuration

**Image** — defaults to the official NATS Alpine image. Bump the tag to upgrade NATS:
```yaml
image: nats:2.11.6-alpine
```

**GVC and locations** — set the GVC name and the locations where NATS will run. Each location entry requires a `replicas` count:
```yaml
gvc:
  name: nats-gvc
  locations:
    - name: aws-us-east-1
      replicas: 3
    - name: aws-us-west-2
      replicas: 2
```

**Resources** — adjust CPU and memory per replica:
```yaml
resources:
  cpu: 100m
  memory: 256Mi
```

**Inbound CIDR** — restrict which IPs can connect to the WebSocket port. Defaults to open; change this to limit exposure:
```yaml
allowCIDR:
  - 0.0.0.0/0
```

**Internal access** — controls which workloads can reach NATS internally on the cluster/gateway ports:
```yaml
internalAccess:
  type: same-gvc # options: none, same-gvc, same-org, workload-list
  workloads:
    - //gvc/my-gvc/workload/my-app
```

**WebSocket** — enabled by default on port 8080. Control Plane handles TLS termination and exposes it externally on port 443:
```yaml
websocket:
  enabled: true
  port: 8080
  noTls: true
```

**JetStream** — enables NATS's persistent streaming layer. When enabled, each replica gets its own dedicated persistent volume (`/data/nats`) and the server is configured to store streams, consumers, and K-V data there:
```yaml
jetstream:
  enabled: true

volumeset:
  capacity: 10 # GiB per replica
  autoscaling:
    enabled: false
    maxCapacity: 100
    minFreePercentage: 10
    scalingFactor: 1.2
```

When `jetstream.enabled` is `false` (the default), NATS runs in pure pub/sub mode with no persistence and no volume is provisioned.

**Extra NATS config** — any additional valid NATS configuration appended to the server config at startup:
```yaml
nats_extra_config: |
  max_payload: 8MB
```

### Connecting

**Internally** (from other workloads in the same GVC), connect on the standard NATS port:

```
nats://RELEASE_NAME-nats.GVC_NAME.cpln.local:4222
```

**Externally** via WebSocket, connect through the Control Plane endpoint on port 443:

```
wss://RELEASE_NAME-nats.GVC_NAME.cpln.app
```

### Supported External Services
- [NATS Documentation](https://docs.nats.io/)
