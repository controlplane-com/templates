# NATS

NATS is a high-performance, lightweight messaging system for pub/sub, queueing and request/reply, with an optional built-in persistence layer (JetStream). This template deploys a NATS cluster into an existing GVC — one cluster per location, joined into a cross-region super cluster over NATS gateways when you configure more than one.

## Architecture

- **Stateful NATS workload** — one cluster per configured location, `replicas` servers each; routes join servers within a location, gateways join the locations.
- **Volume set** *(optional)* — per-replica JetStream storage, created only when `jetstream.enabled` is true.
- **Secret** — the startup script that generates each server's `nats.conf` at boot.
- **Secret** *(optional)* — `nats_extra_config`, appended verbatim to the generated config.
- **Identity** — the workload's identity.
- **Policy** — `reveal` on this release's secrets.
- **Policy** — `view` on the install GVC alone, so each server can check at boot that the GVC really has the locations it was configured for.

This chart does **not** create a GVC. It deploys into the one you install into.

## Prerequisites

None for a default install, beyond a GVC containing the location(s) you list in `locations`.

## Configuration

### Locations

```yaml
# Every location listed MUST already exist in the GVC you install into.
# One entry = one NATS cluster; `replicas` = servers in that cluster.
locations:
  - name: aws-us-east-1
    replicas: 3
```

The default is one location with three servers — the smallest shape that is both a real NATS cluster and installable on any single-location GVC. What cluster size buys you:

| Servers | Core NATS | JetStream |
|---|---|---|
| 1 | works | standalone; `R1` streams only, no fault tolerance |
| 2 | works | **refused by this chart** — quorum is 2 of 2, so losing either server takes JetStream down entirely; worse than one server |
| 3 | works | survives losing one server. NATS's recommended minimum |
| 5 | works | survives losing two servers |

Adding a **second location** does not change quorum arithmetic — it buys geographic locality. Each location is its own cluster, so clients connect to servers near them, and gateways forward only the traffic that has interested subscribers on the other side. JetStream's meta group spans the whole super cluster, so size the *total* server count against the table above, and give each location at least 3 servers if you want streams to survive losing a whole location.

### Image and resources

```yaml
image: nats:2.11.6-alpine # official NATS image tag — bump to upgrade NATS

resources:
  cpu: 100m
  memory: 256Mi
```

### Listeners

```yaml
nats_defaults:
  port: 4222 # client port
  cluster:
    port: 6222 # routes between replicas in the SAME location
  gateway:
    port: 7222 # gateways BETWEEN locations; unused with one location
  websocket:
    enabled: true # publishes the workload's public endpoint; Control Plane serves it on 443
    port: 8080
    compression: false
    noTls: true # Control Plane terminates TLS — leave true unless you supply certs
```

Monitoring is fixed on `8222` and is not published as a container port. The chart refuses at render time to bind a port Control Plane reserves, or to put two listeners on one port.

### Public access

```yaml
# Inbound public CIDRs for the WebSocket endpoint (Control Plane serves it on 443).
allowCIDR: []  # empty = no public access; see Important Notes before opening it
```

### JetStream

```yaml
jetstream:
  enabled: false # set to true for durable streams, consumers, K/V and object store

volumeset:
  capacity: 10 # initial capacity in GiB per replica (minimum is 10)
```

### Extra configuration

```yaml
# Appended verbatim to the generated server config at startup.
nats_extra_config: ""
```

### Internal access

```yaml
internalAccess:
  type: same-gvc # options: none, same-gvc, same-org, workload-list
  workloads: [] # only used when type is workload-list; the NATS workload is added automatically
  #- //gvc/GVC_NAME/workload/WORKLOAD_NAME
```

This list governs the route and gateway connections between the servers themselves, not just client traffic, so the chart always includes its own workload. `none` is refused for any multi-server deployment, because it would leave every server running alone.

## Connecting

| From | Address | Credentials |
|---|---|---|
| Another workload in the same GVC | `nats://RELEASE-nats.GVC.cpln.local:4222` | none — this chart configures no NATS authentication |
| The internet, over WebSocket | `wss://RELEASE-nats-GVCALIAS.cpln.app` | none, unless you add `authorization { … }` via `nats_extra_config` |
| A specific server (clustering, debugging) | `replica-N.RELEASE-nats.LOCATION.GVC.cpln.local:4222` | none |

Read the real public hostname from `status.canonicalEndpoint` in `cpln workload get RELEASE-nats --gvc GVC -o yaml` — never assemble it from parts, as its shape varies between GVCs.

## Migrating from 2.x

**Never `helm upgrade` a 2.x release onto 3.0.0.** 2.x created its own GVC; 3.0.0 does not. An in-place upgrade drops `kind: gvc` from the manifest, and Helm deletes what a chart no longer declares — which destroys that GVC and **every workload, volume set and identity inside it**, including your JetStream data. On a sibling template this was measured taking 6 seconds while Helm printed `upgraded successfully`.

The chart refuses to render if your values still carry the 2.x `gvc` key, so the usual path fails safely. Migrate like this instead:

1. Install 3.0.0 as a **new release** against an existing GVC, with `locations` set to that GVC's locations.
2. Point publishers and subscribers at the new release, or mirror the streams across with `nats stream ...` if you are using JetStream.
3. `cpln helm uninstall` the old release once nothing depends on it.

Values that moved or were removed in 3.0.0 — the chart names each one at render time rather than ignoring it:

| 2.x | 3.0.0 |
|---|---|
| `gvc.name` | gone; the chart deploys into the GVC you install into |
| `gvc.locations` | `locations` (top level) |
| `nats_defaults.cluster.listen` / `gateway.listen` | gone; derived as `0.0.0.0:<port>` |
| `nats_defaults.cluster.noAdvertise` | gone; it was never wired to anything |
| `locations[].replicas: 0` | not allowed; remove the location instead |

## Important Notes

- **`allowCIDR` is empty by default, so there is no public access.** This chart configures no NATS authentication, so opening it publishes an unauthenticated message bus — an anonymous client receives the cluster name, every server name and their private IPs. Add ranges only alongside an `authorization { … }` block in `nats_extra_config`. Reach a closed deployment with `cpln port-forward`.
- **Every location in `locations` must already exist in the GVC.** The platform accepts a location a GVC does not have without any error — the servers there simply never start. Each server checks this against the live GVC at boot: with JetStream enabled a fresh server refuses to start, and an already-initialised one warns and keeps serving rather than taking a live cluster down. Look for `[nats]` lines in the workload log.
- **Locations in the GVC that are not in `locations` run nothing.** Their deployment reads `This workload location is deactivated because maxScale is set to 0`. That is intended, not a failure.
- **JetStream state lives on the volume set.** Uninstalling deletes it. Streams default to `num_replicas: 1`, so a stream only survives a server loss if you set `num_replicas` to 3 or more when you create it — that is per-stream, in your application, not a setting in this template.
- **`nats_extra_config` is injected verbatim.** A syntax error there is a container that will not start, not a render failure.
- **A firewall change takes up to ~10 minutes to propagate.** After changing `allowCIDR` or `internalAccess`, keep re-testing rather than concluding the knob is broken.

## Links

- [NATS documentation](https://docs.nats.io/)
- [JetStream](https://docs.nats.io/nats-concepts/jetstream)
- [Clustering](https://docs.nats.io/running-a-nats-service/configuration/clustering)
- [Super clusters and gateways](https://docs.nats.io/running-a-nats-service/configuration/gateways)
- [Configuration reference](https://docs.nats.io/running-a-nats-service/configuration)
