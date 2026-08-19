# Redpanda

Redpanda is a Kafka-compatible streaming platform written in C++. It implements the Kafka wire protocol natively, so any Kafka client, SDK, or tool works with it without modification. This template deploys a stateful Redpanda broker cluster with SASL authentication, Schema Registry, an optional HTTP Proxy, and an optional web console.

## Architecture

- **Broker cluster** — a `stateful` workload of 1, 3, or 5 Redpanda brokers forming a Raft quorum, each with its own persistent volume
- **Volume set** — one block volume per broker, holding the topic data directory
- **Startup-script secret** — assembles `redpanda.yaml` inside the container from the injected SASL credentials
- **Console** (optional, on by default) — Redpanda Console web UI, closed to the internet by default
- **Console startup-script secret** (optional) — assembles the console config inside the container
- **Identity + policy** — grants the workloads `reveal` on exactly the secrets they mount
- **Domain** (optional) — created only when external Kafka access or a console domain is configured

## Prerequisites

**Create the SASL credential secrets BEFORE you install.** Every entry in `redpanda.auth.users` names a `dictionary` secret holding the keys `username` and `password`. If a named secret does not exist, the deployment wedges silently — see Important Notes for how to diagnose that.

The first entry is the cluster superuser: the console, the Schema Registry client and (when enabled) the HTTP Proxy all authenticate to the brokers as it.

```sh
cpln secret create-dictionary \
  --name my-redpanda-admin-credentials \
  --entry username=admin \
  --entry password='CHOOSE-A-STRONG-PASSWORD'
```

Add one secret per additional user, and one `credentialsSecretName` entry per secret.

Read a secret back in plaintext with `-o yaml` — without it the values are redacted:

```sh
cpln secret reveal my-redpanda-admin-credentials -o yaml
```

Use `printf`, not `echo`, if you pipe a generated password in from elsewhere: `echo` appends a newline, which Redpanda cannot carry in a config value. The startup script detects that and fails with a message naming the secret and key, rather than starting a cluster that rejects every login.

Nothing else is required for a default install. External Kafka access over the internet additionally needs a domain you control and a dedicated load balancer — see External Kafka Access.

## Configuration

**Cluster size and resources** — `smp` is the number of Seastar reactor threads and must match the floor of the CPU limit:

```yaml
redpanda:
  name: cluster              # broker workload is named {release}-{name}
  image: redpandadata/redpanda:v26.1.9
  env: []                    # extra environment variables for the broker container
  replicas: 3                # 1, 3, or 5 — Raft needs an odd number for quorum
  cpu: 1500m
  memory: 4Gi
  minCpu: 500m
  minMemory: 2Gi
  smp: 1                     # Seastar reactor threads; floor of the cpu limit
  reserveMemory: 1G          # held back for the OS; Redpanda uses (memory - reserveMemory)
  multiZone: false
```

**Storage** — each broker gets its own persistent volume. For high-throughput production workloads switch to `high-throughput-ssd` (minimum 200 GiB):

```yaml
redpanda:
  volume:
    initialCapacity: 10                     # in GB
    performanceClass: general-purpose-ssd   # or high-throughput-ssd
    fileSystemType: xfs                     # xfs / ext4
    # customEncryption:                     # optional AWS KMS volume encryption
    #   enabled: true
    #   region: aws-us-east-2
    #   keyId: arn:aws:kms:us-east-2:1234567890:key/your-key-id
```

After deploying with custom encryption enabled, open each created volume in the Control Plane console, click `spec`, and follow the **AWS Custom Encryption Instructions** to finish the setup.

**Authentication** — SASL is always enabled. Each user's credentials are a prerequisite secret (see Prerequisites); the first entry becomes the cluster superuser:

```yaml
redpanda:
  auth:
    saslMechanism: SCRAM-SHA-256          # SCRAM-SHA-256 / SCRAM-SHA-512
    users:
      - credentialsSecretName: my-redpanda-admin-credentials
      # - credentialsSecretName: my-redpanda-app-credentials
    superusers: []                        # extra usernames created outside this chart
```

**Listeners** — the Kafka, Admin API, Schema Registry and (optional) HTTP Proxy ports:

```yaml
redpanda:
  listeners:
    kafka:
      internal:
        port: 9092
      # external:                          # see External Kafka Access below
      #   directReplicaRouting:
      #     containerPort: 9094
      #     publicAddress: redpanda.example.com
    adminApi:
      port: 9644
    schemaRegistry:
      port: 8081
    pandaproxy:
      enabled: false                       # HTTP Proxy (REST) for produce/consume
      port: 8082
```

**ACLs** — with `allowEveryoneIfNoAclFound: false`, a client with no matching ACL is denied:

```yaml
redpanda:
  acl:
    allowEveryoneIfNoAclFound: false
```

**Cluster identity and extra broker properties**:

```yaml
redpanda:
  secrets:
    cluster_id: ""                         # empty = generated on first boot
  extra_configurations: {}
    # auto_create_topics_enabled: false
    # log_retention_ms: 604800000
```

**Broker firewall** — comment a rule out to disable that traffic entirely:

```yaml
redpanda:
  firewall:
    internal_inboundAllowType: "same-gvc"  # same-org / same-gvc
    # external_inboundAllowCIDR: 0.0.0.0/0
    # inboundAllowWorkload:
    #   - //gvc/my-gvc/workload/my-app
    # external_outboundAllowCIDR: "0.0.0.0/0"
```

**Console** — the web UI. External inbound is closed by default; see Redpanda Console:

```yaml
redpanda_console:
  enabled: true
  name: console
  image: redpandadata/console:v3.7.4
  cpu: 200m
  memory: 256Mi
  minCpu: 50m
  minMemory: 64Mi
  replicas: 1
  timeoutSeconds: 30
  # domain: console.example.com               # requires opening external inbound below
  firewall:
    # internal_inboundAllowType: "same-gvc"
    # external_inboundAllowCIDR: "0.0.0.0/0"  # publishes an unauthenticated admin UI
    external_outboundAllowCIDR: "0.0.0.0/0"
```

## Connecting

| What | Address | Credentials |
|---|---|---|
| Kafka API | `{release}-cluster.{gvc}.cpln.local:9092` | SASL, from your credentials secret |
| Admin API | `{release}-cluster.{gvc}.cpln.local:9644` | none — unauthenticated inside the GVC |
| Schema Registry | `{release}-cluster.{gvc}.cpln.local:8081` | HTTP basic, same SASL credentials |
| HTTP Proxy (if enabled) | `{release}-cluster.{gvc}.cpln.local:8082` | HTTP basic, same SASL credentials |
| Console (if enabled) | tunnel with `cpln port-forward` — see below | none — see Redpanda Console |

A specific broker replica is addressable directly:

```
{release}-cluster-0.{release}-cluster.{gvc}.cpln.local:9092
{release}-cluster-1.{release}-cluster.{gvc}.cpln.local:9092
```

Connect with `rpk` from a workload in the same GVC:

```bash
rpk topic list \
  -X brokers={release}-cluster.{gvc}.cpln.local:9092 \
  -X sasl.mechanism=SCRAM-SHA-256 \
  -X user=admin \
  -X pass=YOUR-PASSWORD
```

## Redpanda Console

Console has **no login of its own in this build**: authentication (OIDC and basic login) and role-based authorization are Redpanda Enterprise features, so an unlicensed console runs in "static service account" mode — there is no login screen, all users share the same access level, and that session carries the cluster superuser's SASL credentials. Anyone who can reach the console can browse and publish messages, create and delete topics, and manage consumer groups and ACLs.

External inbound is therefore closed by default. Reach the UI through a tunnel:

```bash
cpln port-forward {release}-console 8080:8080 --gvc {gvc}
# then open http://localhost:8080
```

To publish it anyway — only behind your own authenticating proxy, or to an IP range you control — uncomment `redpanda_console.firewall.external_inboundAllowCIDR`, narrowed to your own CIDR rather than `0.0.0.0/0`. Setting `redpanda_console.domain` also requires external inbound to be open. Firewall changes take roughly 30 seconds to a few minutes to propagate.

## External Kafka Access

Brokers can be exposed over the internet with TLS via a public domain. Each broker advertises a per-replica subdomain and Control Plane routes clients to the correct broker using SNI.

**Requirements**

1. **A domain you control**, with DNS at your registrar.
2. **Dedicated Load Balancer** enabled on the GVC — required for external TCP routing. See [Configure Domain](https://docs.controlplane.com/guides/configure-domain#dedicated-load-balancing).
3. **DNS records added before deploying.** Disable proxying (e.g. Cloudflare's orange cloud) — TCP traffic must pass through directly:

| Type | Name | Value |
|------|------|-------|
| TXT | `_cpln.your-domain.com` | your Control Plane org name or org ID |
| CNAME | `@` | `{gvcAlias}.cpln.app` |
| CNAME | `_acme-challenge` | `_acme-challenge.cpln.app` |
| CNAME | `{release}-cluster-0-{location}` | `{gvcAlias}.cpln.app` |
| CNAME | `{release}-cluster-N-{location}` | `{gvcAlias}.cpln.app` |

Add one CNAME per broker replica, pointing at the GVC gateway rather than at a direct replica address. The `_acme-challenge` record lets Control Plane issue the certificate via DNS-01. The GVC alias is under GVC settings in the Control Plane console.

```yaml
redpanda:
  listeners:
    kafka:
      external:
        directReplicaRouting:
          containerPort: 9094
          publicAddress: your-domain.com
```

Each broker advertises `{release}-cluster-{ordinal}-{location}.{domain}`; use them all as the bootstrap list:

```bash
rpk topic list \
  -X brokers=my-cluster-0-aws-us-east-1.your-domain.com:9094,my-cluster-1-aws-us-east-1.your-domain.com:9094 \
  -X tls.enabled=true \
  -X sasl.mechanism=SCRAM-SHA-256 \
  -X user=admin \
  -X pass=YOUR-PASSWORD
```

For Kafka clients: `security.protocol=SASL_SSL`, `sasl.mechanism=SCRAM-SHA-256`, and the same bootstrap list.

## Upgrading from 1.0.x

Two behaviours change, both deliberately:

- **SASL credentials moved out of values.** `redpanda.auth.users[].username` and `.password` no longer exist; each entry now takes a `credentialsSecretName` naming a `dictionary` secret with `username` and `password`. An install that still sets the old keys fails immediately with a message naming the replacement. Create the secret with the username and password the cluster already uses — SASL users live in the cluster's own metadata on disk, so changing this value does **not** change the password of an existing cluster.
- **The console is no longer published to the internet.** 1.0.x defaulted `redpanda_console.firewall.external_inboundAllowCIDR` to `0.0.0.0/0`; 1.1.0 leaves it commented out. If you were reaching the console at its public URL, that URL now returns 403 — use `cpln port-forward`, or set the value back explicitly, knowing the UI has no login.

## Important Notes

- A missing prerequisite secret wedges the deployment **silently**: `cpln logs` returns zero lines because the container never starts. The only diagnostic is `cpln workload get-deployments {release}-cluster --gvc {gvc} -o yaml` → `status.versions[].message`, which names the missing secret. After creating it, recovery takes 5.5–8.5 minutes, or run `cpln workload force-redeployment {release}-cluster --gvc {gvc}` to cut that to about 90 seconds.
- Anyone who can reach the console acts as the cluster superuser — there is no login. Keep external inbound closed unless the console sits behind your own authenticating proxy.
- The broker Admin API (port 9644) is unauthenticated and reachable from the whole GVC under the default `same-gvc` firewall. Narrow it with `redpanda.firewall.inboundAllowWorkload` if that matters to you.
- SASL users are created on first boot of broker 0 and then live in the cluster's metadata. Editing a credentials secret afterwards does not rotate the user — update the user with `rpk security user update` and change the secret to match.
- `replicas` must be 1, 3, or 5; an even count cannot form a Raft quorum and is rejected at install. Changing it changes broker membership, so treat it as a deliberate cluster operation.
- The topic-data volume set has no snapshot schedule. Data survives reschedules and reinstalls of the same release, but there is no point-in-time backup — use tiered storage or a mirroring job if you need one.
- A rolling upgrade is not serialized by the platform for a stateful workload, so brokers may restart together. Configure producers and consumers to retry.

## Links

- [Redpanda documentation](https://docs.redpanda.com/)
- [Redpanda Console documentation](https://docs.redpanda.com/current/console/)
- [Console authentication (Enterprise)](https://docs.redpanda.com/current/console/config/security/authentication/)
- [rpk CLI reference](https://docs.redpanda.com/current/reference/rpk/)
- [Redpanda cluster configuration properties](https://docs.redpanda.com/current/reference/properties/cluster-properties/)
