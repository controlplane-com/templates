# NATS — maintainer briefing

**What it is.** A NATS super cluster — one cluster per location, joined by gateway connections — with
optional JetStream persistence. **This template creates its own GVC.**

**Common use cases.** Low-latency service-to-service messaging across regions, request/reply between
services, and durable streams via JetStream where a full Kafka deployment is more than the workload needs.

## Architecture

| Resource | Notes |
|---|---|
| **gvc** | created by the chart, named by `gvc.name` |
| workloads (stateful) | one per location; clients on `4222`, cluster routes on `6222`, gateways on `7222` |
| volumesets | JetStream storage per node, when JetStream is enabled |
| secret | the generated NATS configuration, including super-cluster gateway routes |
| identity + policy | `reveal` on the configuration secret |

Each location forms its own cluster; the gateways join those clusters into a super cluster, so a client
connects locally and messages cross regions only when a subscriber is there.

## Key knobs (shipped defaults)

| Knob | Default | Notes |
|---|---|---|
| `gvc.name` | `nats-gvc` | **unique per install** — the chart creates this GVC |
| `gvc.locations[]` | 3 locations × 2 replicas | us-east-1, us-west-2, eu-central-1 |
| `image` | `nats:2.11.6-alpine` | pinned; bump to upgrade NATS |
| `resources` | `100m` / `256Mi` | small — raise for real throughput |
| `jetstream` | — | persistence; off means messages are in-flight only |
| `nats_extra_config` | `""` | injected verbatim into the generated config |
| `internalAccess` | — | also governs how nodes reach each other |

## Troubleshooting traps

- **It creates a GVC, so it can destroy one.** Never point `gvc.name` at an existing shared GVC — a
  `createsGvc` chart adopts one that already exists and `helm uninstall` then deletes it, taking every
  unrelated workload with it. Uninstall against the GVC you **installed into**, not the one the resources
  live in, or the policy hook blocks the cleanup.
- **`internalAccess: none` breaks clustering, not just clients.** Nodes reach each other over the same
  internal path, so locking it down fully leaves isolated single-node clusters that still look healthy.
- **JetStream durability is only as good as the volumeset**, and uninstall deletes it. Without JetStream
  there is no persistence at all — an unsubscribed message is simply gone.
- **`nats_extra_config` is injected verbatim.** A syntax error there surfaces as a container that will not
  start, not as a render failure, so it is easy to mistake for an infrastructure problem.
- **Three locations is the shipped shape and it is not free.** Gateway traffic between regions is billed;
  a single-location install is a legitimate configuration if you do not need the spread.
