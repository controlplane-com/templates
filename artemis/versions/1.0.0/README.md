# Apache Artemis

Apache Artemis, the successor to ActiveMQ Classic, is a message broker for JMS, AMQP 1.0, MQTT, STOMP and OpenWire clients. This template runs one broker in one location, or one broker in each of two locations kept in sync by a two-way asynchronous AMQP mirror.

## Architecture

- **Workload** — a `stateful` workload running the official `apache/artemis` image, one broker in each location listed in `locations` (nothing runs in the GVC's other locations). Each broker gets a stable per-location address (`replica-0.…`).
- **Volume set** — one volume per broker at `/var/lib/artemis-instance`, holding the broker configuration and the message journal, with daily snapshots.
- **Identity + policies** — `reveal` on exactly your credentials secret; with two locations, also `view` on the install GVC, so each broker can check at start that its peer's location exists.
- **Mirror (two locations)** — each broker copies every message, acknowledgement and queue creation or deletion to the other over port 61617. A restarted broker refuses clients until it has caught up from its peer.
- **Web console** (optional public access) — the Artemis console on port 8161, published over HTTPS only when `publicAccess.enabled` is `true`.

## Prerequisites

**A `dictionary` secret with the broker's admin login.** It is the web console login, the login your clients use and, with two locations, the login the mirror uses between them. Create it **before you install**, with a hex password (no spaces, quotes or backslashes):

```bash
cpln secret create-dictionary \
  --name my-artemis-credentials \
  --entry username=admin \
  --entry password="$(openssl rand -hex 24)"
```

Read the password back with `cpln secret reveal my-artemis-credentials -o yaml`.

**Set `locations` to your GVC's location(s).** A listed location the GVC does not have (a typo, or the unchanged default `aws-us-east-1`) runs nothing: the platform accepts it silently, and the deployment message reads `maxScale is set to 0`.

## Configuration

### Locations

```yaml
# REQUIRED — list the location(s) of the GVC you install into (this chart never creates a GVC).
# One entry: one broker. Two entries: one broker per location, kept in sync by a two-way
# AMQP mirror. More than two is refused: mirroring more than two brokers duplicates messages.
# The GVC's other locations run nothing.
# A listed location the GVC does not have runs nothing — replace the example below.
locations:
  - name: aws-us-east-1
#  - name: aws-us-west-2   # add a second location for a broker that survives a region loss
```

### Credentials

```yaml
credentialsSecretName: my-artemis-credentials
```

### Mirror

```yaml
mirror:
  catchUpTimeoutSeconds: 180  # two locations: a restarted broker opens client ports once caught up from its peer, or after this long
```

### Image and resources

```yaml
image: apache/artemis:2.57.0  # official image; runs as uid 1001

resources:
  cpu: 1000m
  memory: 2Gi  # Mi or Gi, at least 1Gi; the JVM heap is half of this
```

### Storage

```yaml
volumeset:
  capacity: 10  # GiB per broker (minimum 10)
  snapshots:
    schedule: "0 3 * * *"   # daily at 3am UTC; at most hourly; "" turns them off
    retentionDuration: 7d   # how long each snapshot is kept
  autoscaling:
    enabled: false          # grows the volume — useful if a location can be down for long
    maxCapacity: 100        # GiB
    minFreePercentage: 10
    scalingFactor: 1.2
```

### Network access

```yaml
internalAccess:
  type: same-gvc  # options: same-gvc, same-org, workload-list
  workloads: []   # for workload-list: //gvc/GVC_NAME/workload/NAME — this release's broker is added automatically

publicAccess:
  enabled: false  # true publishes the web console (8161) over HTTPS; message ports always stay internal
```

## Connecting

Log in with the `username` and `password` from your credentials secret. `RELEASE` is your release name, `GVC` your GVC and `LOCATION` a listed location.

| What | Address |
|---|---|
| All protocols (Core, AMQP, OpenWire, STOMP, MQTT) | `RELEASE-artemis.GVC.cpln.local:61616` |
| AMQP 1.0 | `RELEASE-artemis.GVC.cpln.local:5672` |
| STOMP | `RELEASE-artemis.GVC.cpln.local:61613` |
| MQTT | `RELEASE-artemis.GVC.cpln.local:1883` |
| One location's broker | `replica-0.RELEASE-artemis.LOCATION.GVC.cpln.local:61616` |
| Web console (private) | `cpln port-forward RELEASE-artemis 8161:8161 --gvc GVC`, then `http://localhost:8161/console` |
| Web console (public) | `status.canonicalEndpoint` from `cpln workload get RELEASE-artemis --gvc GVC -o yaml` |

The message ports are reachable only from inside Control Plane, as `internalAccess` allows; they are never public.

### Client failover (two locations)

- **AMQP 1.0 / JMS with qpid-jms** — list both brokers in a failover URL; a client moves to the other location when its broker goes away:
  ```text
  failover:(amqp://replica-0.RELEASE-artemis.LOCATION_A.GVC.cpln.local:61616,amqp://replica-0.RELEASE-artemis.LOCATION_B.GVC.cpln.local:61616)?failover.maxReconnectAttempts=-1&failover.nested.amqp.idleTimeout=10000
  ```
- **OpenWire** (ActiveMQ clients) — the same shape: `failover:(tcp://replica-0.…:61616,tcp://replica-0.…:61616)`.
- **Core clients** — a `(tcp://a,tcp://b)` connection list does not move a live connection to the other broker; reconnect in your application.
- **No client setup** — `RELEASE-artemis.GVC.cpln.local` reaches the local broker and falls back to the other location while the local one is down. A returning broker refuses clients while it catches up, and this name can route to it in that window; a failover URL avoids the gap.
- Delivery is at least once: consumers that move on failover must tolerate a redelivered message.

## Active-active: what is and isn't supported

| Supported | Not supported |
|---|---|
| Writes in both locations | Consuming one shared queue in both locations at once (duplicates) |
| Per-location queues (`orders.east` / `orders.west`) | More than two locations: mirroring more than two brokers duplicates messages |
| One consuming location | Synchronous mirroring |
| Consumers moving on failover | A retained log or replay (use the `kafka` template) |

The mirror is asynchronous: a broker that crashes can lose the messages it had not yet copied to its peer, and only if its volume is lost too.

## Important Notes

- **Create the credentials secret first.** Without it the deployment waits and `cpln logs` is empty; `cpln workload get-deployments RELEASE-artemis --gvc GVC -o yaml` shows the missing secret in `status.versions[].message`. It recovers on its own once the secret exists, or run `cpln workload force-redeployment RELEASE-artemis --gvc GVC`.
- **An upgrade that changes the workload restarts the brokers in every location at the same time**, so clients are refused until they are back.
- A restarted broker refuses clients until it has caught up from its peer, or until `mirror.catchUpTimeoutSeconds` has passed.
- While one location is down, the other broker keeps every message to copy to it, so its volume grows with traffic for as long as the outage lasts; consider `volumeset.autoscaling`.
- Adding a second location later does not copy existing messages; only messages sent after the upgrade are mirrored.
- The brokers apply the secret on every start. After rotating it, run `cpln workload force-redeployment RELEASE-artemis --gvc GVC`.
- Changes to `internalAccess` and `publicAccess` take a few minutes to apply.

## Links

- [Apache Artemis documentation](https://artemis.apache.org/components/artemis/documentation/latest/)
- [Broker connections and mirroring](https://artemis.apache.org/components/artemis/documentation/latest/amqp-broker-connections.html)
- [Configuration index](https://artemis.apache.org/components/artemis/documentation/latest/configuration-index.html)
- [Qpid JMS failover configuration](https://qpid.apache.org/releases/qpid-jms-2.7.0/docs/index.html#failover-configuration-options)
- [apache/artemis on Docker Hub](https://hub.docker.com/r/apache/artemis)
