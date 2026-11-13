# Apache Artemis

Apache Artemis, the successor to ActiveMQ Classic, is a message broker for JMS, AMQP 1.0, MQTT, STOMP and OpenWire clients. This template runs one broker in one location, a primary and a backup broker in one location (`ha.enabled`), or one broker in each of two locations kept in sync by a two-way asynchronous AMQP mirror, either active-passive (one location serves clients and the other takes over when it is down) or active-active (both serve clients).

## Architecture

- **Workload** — a `stateful` workload running the official `apache/artemis` image, one broker in each location listed in `locations` (nothing runs in the GVC's other locations). Each broker gets a stable per-location address (`replica-0.…`).
- **Volume set** — one volume per broker at `/var/lib/artemis-instance`, holding the broker configuration and the message journal, with daily snapshots.
- **High availability (`ha.enabled`, one location)** — two brokers, `replica-0` (primary) and `replica-1` (backup), share one `shared` volume at `/var/lib/artemis-data` holding the journal, bindings, paging and large messages. The broker holding the lock on it serves clients; the other waits and takes it over within seconds when the active broker stops. No snapshots (shared volumes take none).
- **Identity + policies** — `reveal` on exactly your credentials secret; with two locations, also `view` on the install GVC, so each broker can check at start that its peer's location exists.
- **Mirror (two locations)** — each broker copies every message, acknowledgement and queue creation or deletion to the other over port 61617. A restarted broker refuses clients until it has caught up from its peer.
- **Mirror mode** — `active-passive` (default): the primary location serves clients; the other broker keeps its client ports closed, opens them when the primary broker has been unreachable for `mirror.takeoverSeconds`, and closes them again once the primary is back and caught up. `active-active`: both brokers serve clients.
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

**Set `locations` to your GVC's location(s).** A listed location the GVC does not have (a typo, or the unchanged default `aws-us-east-1`) runs nothing: the platform accepts it silently, and the deployment message reads `maxScale is set to 0`. With two locations, a new broker whose peer location is missing stops with `FATAL: the mirror peer's location '…' is not in GVC '…'`.

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
# REQUIRED PREREQUISITE SECRET — CREATE IT BEFORE YOU INSTALL.
credentialsSecretName: my-artemis-credentials
```

### High availability

```yaml
ha:
  enabled: false  # true: a primary and a backup broker in your ONE location share a volume; the backup takes over in seconds
                  # choose at install: changing it later is not supported, and messages do not carry over to a new release
```

### Mirror

```yaml
# Two locations only (ignored with one):
mirror:
  mode: active-passive        # active-passive: the primary serves clients, the other location takes over when it is down
                              # active-active: both locations serve clients (consume each queue in one location only)
  primary: ""                 # active-passive: the location that serves clients; "" = the first entry in `locations`
  takeoverSeconds: 60         # active-passive: how long the primary broker must be unreachable before the other location opens
  catchUpTimeoutSeconds: 180  # a restarted broker opens client ports once caught up from its peer, or after this long
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
  capacity: 10  # GiB per broker (minimum 10); with ha.enabled one shared volume holds both brokers' data
  snapshots:                # not taken with ha.enabled (shared volumes have no snapshots)
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
| `ha.enabled` (AMQP, qpid-jms) | `failover:(amqp://replica-0.RELEASE-artemis.LOCATION.GVC.cpln.local:61616,amqp://replica-1.RELEASE-artemis.LOCATION.GVC.cpln.local:61616)?failover.maxReconnectAttempts=-1` |
| Web console (private) | `cpln port-forward RELEASE-artemis 8161:8161 --gvc GVC`, then `http://localhost:8161/console` |
| Web console (public) | `status.canonicalEndpoint` from `cpln workload get RELEASE-artemis --gvc GVC -o yaml` |

The message ports are reachable only from inside Control Plane, as `internalAccess` allows; they are never public. Port 61617 carries the mirror between locations; do not point clients at it.

### Client failover (two locations)

Give every client both brokers in a failover URL, **primary first** in active-passive mode: the client connects to the first broker that accepts it and moves when that broker goes away or closes its client ports.

- **AMQP 1.0 / JMS with qpid-jms** — tries the brokers in the order listed:
  ```text
  failover:(amqp://replica-0.RELEASE-artemis.LOCATION_A.GVC.cpln.local:61616,amqp://replica-0.RELEASE-artemis.LOCATION_B.GVC.cpln.local:61616)?failover.maxReconnectAttempts=-1&failover.nested.amqp.idleTimeout=10000
  ```
- **OpenWire** (ActiveMQ clients) — the same shape; add `randomize=false`, or the client picks a broker at random: `failover:(tcp://replica-0.…:61616,tcp://replica-0.…:61616)?randomize=false`.
- **Core clients** — a `(tcp://a,tcp://b)` connection list does not move a live connection to the other broker; reconnect in your application.
- **Failover is manual for now** — `RELEASE-artemis.GVC.cpln.local` reaches the broker in the client's own location and does not move to the other location while that broker is down or, in active-passive mode, standing by. For clients that must keep working through a location outage, use a failover URL as above, or point them at the other location's broker yourself.
- Delivery is at least once: consumers that move on failover must tolerate a redelivered message.

## Choosing a mirror mode

| | `active-passive` (default) | `active-active` |
|---|---|---|
| Serves clients | The primary; the other location only while the primary is down | Both locations |
| Typical use | Disaster recovery: a standby copy in a second region | Producers writing near them in both regions |
| Consuming a queue | One location at a time, enforced by the brokers | One location at a time, enforced by your clients: consuming one queue in both locations at once delivers messages twice |
| Client setup | Failover URL, primary first | Failover URL, or per-location queues (`orders.east` / `orders.west`) |

Neither mode offers more than two locations (mirroring more than two brokers duplicates messages), synchronous mirroring, or a retained log with replay (use the `kafka` template).

The mirror is asynchronous: a broker that crashes can lose the messages it had not yet copied to its peer, and only if its volume is lost too.

## Important Notes

- **Create the credentials secret first.** Without it the deployment waits and `cpln logs` is empty; `cpln workload get-deployments RELEASE-artemis --gvc GVC -o yaml` shows the missing secret in `status.versions[].message`. After creating the secret, run `cpln workload force-redeployment RELEASE-artemis --gvc GVC`.
- **An upgrade that changes the workload restarts the brokers in every location at the same time**, so clients are refused until they are back. With `ha.enabled` the two brokers restart one at a time instead, which causes one or two short handovers.
- **Choose `ha.enabled` at install.** A volume set's type cannot be changed in place, so turning it on or off for an existing release is not supported; to switch, install a new release. Messages on the old release do not carry over.
- **`ha.enabled` supports AMQP failover clients only**, with the URL above listing both brokers; the workload address can reach the waiting broker, and Core and OpenWire clients are not supported for failover. A message in flight during a takeover can be delivered again.
- **`ha.enabled` trades send speed for availability:** every persistent write is synced to a shared network filesystem, so a producer sends persistent messages roughly ten times more slowly than to a single broker; run producers in parallel for more throughput.
- A restarted broker refuses clients until it has caught up from its peer, or until `mirror.catchUpTimeoutSeconds` has passed.
- **Active-passive takeover and failback.** When the primary broker has been unreachable for `mirror.takeoverSeconds`, the other broker opens and failover clients move to it. A primary that restarts within that time (a crash restart usually does) is not taken over: clients wait for it to come back, and a primary that is up but still catching up is not taken over either. When the primary returns, it catches up from the other broker, opens, and the other broker closes again, which moves clients back. Messages the primary had not yet copied when it went down are delivered after it returns, so consumers must tolerate a redelivered message. If the link between the locations breaks while both brokers are up, the other broker also opens after the takeover delay, and both serve clients until the link is back.
- While one location is down, the other broker keeps every message to copy to it, so its volume grows with traffic for as long as the outage lasts; consider `volumeset.autoscaling`.
- Adding a second location later does not copy existing messages; only messages sent after the upgrade are mirrored.
- **Removing a location keeps its volume.** Adding that location back starts its broker on the old messages, which the mirror never reconciles: consumers there receive messages already consumed elsewhere and miss the ones sent while it was gone. Before adding it back, delete the old volume and wait until it is gone from `cpln volumeset volume get RELEASE-artemis-vs --gvc GVC`:
  ```bash
  cpln volumeset volume delete RELEASE-artemis-vs --location LOCATION --volume-index 0 --gvc GVC
  ```
  The returning broker then starts empty and receives only messages sent after it is back.
- The brokers apply the secret on every start. After rotating it, run `cpln workload force-redeployment RELEASE-artemis --gvc GVC`. Rotate the password and keep the username: a new username adds a second admin, and the old one keeps working.
- Changes to `internalAccess` and `publicAccess` take a few minutes to apply.

## Links

- [Apache Artemis documentation](https://artemis.apache.org/components/artemis/documentation/latest/)
- [Broker connections and mirroring](https://artemis.apache.org/components/artemis/documentation/latest/amqp-broker-connections.html)
- [Configuration index](https://artemis.apache.org/components/artemis/documentation/latest/configuration-index.html)
- [Qpid JMS failover configuration](https://qpid.apache.org/releases/qpid-jms-2.7.0/docs/index.html#failover-configuration-options)
- [apache/artemis on Docker Hub](https://hub.docker.com/r/apache/artemis)
