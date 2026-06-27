# Redpanda

Redpanda is a Kafka-compatible streaming platform written in C++. It implements the Kafka wire protocol natively, so any Kafka client, SDK, or tool works with it without modification. This template deploys a stateful Redpanda broker cluster with SASL authentication, Schema Registry, and an optional web console on Control Plane.

## Configuration

**Cluster size and resources** — set the number of replicas and the CPU/memory for each broker. The `smp` value controls how many CPU threads Seastar uses and should match the floor of your CPU limit:

```yaml
redpanda:
  replicas: 3
  cpu: 1500m
  memory: 4Gi
  minCpu: 500m
  minMemory: 2Gi
  smp: 1
  reserveMemory: 1G  # memory reserved for the OS; Redpanda uses (memory - reserveMemory)
```

**Storage** — each broker gets its own persistent volume. For production workloads with high throughput, switch to `high-throughput-ssd` (minimum 200 GiB):

```yaml
redpanda:
  volume:
    initialCapacity: 10  # in GiB
    performanceClass: general-purpose-ssd  # or high-throughput-ssd
    fileSystemType: xfs
```

Optional volume encryption via AWS KMS:

```yaml
redpanda:
  volume:
    customEncryption:
      enabled: true
      region: aws-us-east-2
      keyId: arn:aws:kms:us-east-2:1234567890:key/your-key-id
```

After deploying with custom encryption enabled, navigate to each created volume in the Control Plane console, click `spec`, and follow the **AWS Custom Encryption Instructions** to complete the setup.

**Authentication** — SASL is always enabled. Add users under `redpanda.auth.users`. The first user in the list is automatically created as a superuser. Additional superusers can be added under `redpanda.auth.superusers`:

```yaml
redpanda:
  auth:
    saslMechanism: SCRAM-SHA-256  # or SCRAM-SHA-512
    users:
      - username: admin
        password: "your-admin-password"
      - username: app-user
        password: "your-app-password"
    superusers:
      - another-admin
```

**ACLs** — ACL enforcement is on by default. With `allowEveryoneIfNoAclFound: false`, clients without an explicit ACL are denied. Set to `true` to allow unauthenticated access when no ACL exists for a resource:

```yaml
redpanda:
  acl:
    allowEveryoneIfNoAclFound: false
```

**Extra broker configuration** — pass any Redpanda broker property directly:

```yaml
redpanda:
  extra_configurations:
    auto_create_topics_enabled: false
    log_retention_ms: 604800000
    log_segment_size: 134217728
```

## Connecting

Redpanda is accessible internally from any workload in the same GVC:

| Listener | Address | Port |
|---|---|---|
| Kafka | `{clusterName}.{gvc}.cpln.local` | `9092` |
| Admin API | `{clusterName}.{gvc}.cpln.local` | `9644` |
| Schema Registry | `{clusterName}.{gvc}.cpln.local` | `8081` |

To connect to a specific broker replica directly:
```
{clusterName}-0.{clusterName}.{gvc}.cpln.local:9092
{clusterName}-1.{clusterName}.{gvc}.cpln.local:9092
```

Connect with SASL using `rpk`:

```bash
rpk topic list \
  -X brokers={clusterName}.{gvc}.cpln.local:9092 \
  -X sasl.mechanism=SCRAM-SHA-256 \
  -X user=admin \
  -X pass=your-admin-password
```

## Redpanda Console

The Redpanda Console is a web UI for browsing topics, inspecting messages, managing consumer groups, and viewing Schema Registry schemas. It is enabled by default and can be accessed via the workload's Control Plane URL.

To expose the console on a custom domain, set `redpanda_console.domain`:

```yaml
redpanda_console:
  domain: console.your-domain.com
```

This creates a Control Plane domain resource that routes HTTPS traffic to the console workload. The same DNS prerequisites apply as for any CPLN domain (ownership TXT record and CNAME to the GVC alias).

## External Access

Redpanda brokers can be exposed over the internet via TLS using a public domain. Each broker advertises a per-replica subdomain and Control Plane routes clients to the correct broker using SNI.

### Prerequisites

1. **A domain you control** with DNS managed by your registrar (e.g. Cloudflare)
2. **Dedicated Load Balancer** enabled on your GVC — required for external TCP routing. Enable this under your GVC settings in the Control Plane console. See [Configure Domain documentation](https://docs.controlplane.com/guides/configure-domain#dedicated-load-balancing).
3. **DNS records** added before deploying. **Disable proxying** (e.g. Cloudflare's orange cloud) — TCP traffic must pass through directly:

| Type | Name | Value |
|------|------|-------|
| TXT | `_cpln.your-domain.com` | your Control Plane org name or org ID |
| CNAME | `@` | `{gvcAlias}.cpln.app` |
| CNAME | `_acme-challenge` | `_acme-challenge.cpln.app` |
| CNAME | `{clusterName}-0-{location}` | `{gvcAlias}.cpln.app` |
| CNAME | `{clusterName}-1-{location}` | `{gvcAlias}.cpln.app` |
| CNAME | `{clusterName}-N-{location}` | `{gvcAlias}.cpln.app` |

Add one CNAME per broker replica. The `_acme-challenge` record is required for Control Plane to issue the TLS certificate via DNS-01. The per-replica CNAMEs must point to the GVC gateway (`{gvcAlias}.cpln.app`), not to direct replica addresses.

Your GVC alias is visible under GVC settings in the Control Plane console.

### Configuration

```yaml
redpanda:
  listeners:
    kafka:
      external:
        directReplicaRouting:
          containerPort: 9094
          publicAddress: your-domain.com
```

### Connecting Externally

Each broker advertises its own subdomain in the format `{clusterName}-{ordinal}-{location}.{domain}`. Use all broker addresses as the bootstrap list:

```bash
rpk topic list \
  -X brokers=new-cluster-0-aws-us-east-1.your-domain.com:9094,new-cluster-1-aws-us-east-1.your-domain.com:9094,new-cluster-2-aws-us-east-1.your-domain.com:9094 \
  -X tls.enabled=true \
  -X sasl.mechanism=SCRAM-SHA-256 \
  -X user=admin \
  -X pass=your-admin-password
```

For Kafka clients, use:
```
security.protocol=SASL_SSL
sasl.mechanism=SCRAM-SHA-256
bootstrap.servers=new-cluster-0-aws-us-east-1.your-domain.com:9094,...
```

### Supported External Services
- [Redpanda Documentation](https://docs.redpanda.com/)
- [Redpanda Console Documentation](https://docs.redpanda.com/current/console/)
- [rpk CLI Reference](https://docs.redpanda.com/current/reference/rpk/)
