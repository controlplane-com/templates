# Apache Artemis — Maintainer Briefing

## What it is
- Apache Artemis 2.57.0: a JMS / AMQP 1.0 / MQTT / STOMP / OpenWire message broker, the successor to ActiveMQ Classic. Apache-2.0 (permissive open-source license, nothing paid or gated). It speaks AMQP 1.0, not RabbitMQ's 0-9-1, so RabbitMQ client libraries do not work with it.
- Image: the official `apache/artemis:2.57.0` (Ubuntu, Temurin 25 JRE, uid/gid 1001, multi-arch). The old `apache/activemq-artemis` repo stops at 2.44.0. The chart depends on the binary, not the image's `docker-run.sh`: it runs `artemis create` itself with quoted arguments.

## Common use cases
- A JMS broker for Java services (replaces ActiveMQ Classic / Amazon MQ).
- A broker that keeps taking writes when a whole region goes down (two locations).
- Per-region work queues (`orders.east` / `orders.west`) with cross-region DR (disaster recovery, a copy elsewhere).
- An MQTT device ingest bridged to AMQP services.

## Architecture on cpln
| Resource | Purpose |
|---|---|
| `{release}-artemis` stateful workload | one broker per listed location (replicaDirect = stable per-location address `replica-0.…`) |
| `{release}-artemis-vs` volumeset | journal + config, one volume per location, daily snapshots |
| identity + policies | reveal the credentials secret; with two locations, view the GVC (boot check that the peer location exists) |

- The user lists the GVC's locations: 1 = single broker, 2 = two-way async AMQP mirror (each broker copies every send/ack/queue change to the other in under a second). 0 is refused, and 3+ is refused because mirroring more than two brokers duplicates messages. Unlisted GVC locations run nothing (`defaultOptions` 0 + `localOptions` 1 per listed location).
- **Boot (inline script, no template secret):** location guard → (two locations) GVC read over bash `/dev/tcp` HTTP/1.1 (no curl in the image; fail-open on a failed read, FATAL only on a fresh instance) → first-boot `artemis create` → on every boot re-apply the secret's user (`artemis mask --hash` into `artemis-users.properties`, `amq` role) and the heap (half of `resources.memory`) → write `/tmp/artemis/broker.properties` (0600) → run the broker as a child of bash with SIGTERM forwarded.
- Client ports open only after a restarted broker has caught up from its peer (the "gate": the peer's `$ACTIVEMQ_ARTEMIS_MIRROR_to_<me>` queue has a consumer and 0 messages, or `mirror.catchUpTimeoutSeconds`); readiness is on the mirror port 61617. One location opens at once.

**Key knobs:** `credentialsSecretName` (required dictionary `username`/`password`) · `locations` (required, 1–2, default `aws-us-east-1`) · `mirror.catchUpTimeoutSeconds` (180) · `resources.memory` (heap = half, ≥ 1Gi) · `volumeset.*` · `internalAccess` (same-gvc / same-org / workload-list; own workload auto-added) · `publicAccess` (console only, 8161 over HTTPS).

**Availability:** one location = a restart is a short outage. Two locations = a region loss is survived (failover-URL clients move over). An upgrade currently restarts both regions together; a platform rollout fix is in progress, and row A3-R re-tests it. In-location HA is a follow-up.

## Troubleshooting / considerations
- Nothing starts, and the deployment message says `maxScale is set to 0`: a listed location is not in the GVC (often the unchanged default `aws-us-east-1`, or a typo — the platform accepts it silently).
- Two locations, peer location missing from the GVC: a fresh broker exits `FATAL: the mirror peer's location '…' is not in GVC '…', which has: …`; an initialised one WARNs and keeps serving.
- Missing secret: no logs at all; check `cpln workload get-deployments … -o yaml` → `status.versions[].message`.
- Two regions consuming the SAME queue get duplicates. Supported: per-region queues, or one consuming region. Not Kafka: no replay (point them to `kafka`).
- Asked for three regions? Not possible: a three-broker mesh was measured to duplicate (brokers pass mirrored copies on to each other). Only revisited if upstream adds loop prevention.
- "Refused for a while after a region came back" is the gate catching up. The plain internal name can route there during that window until internal routing (5354) lands; a failover URL avoids it.
- A Core client `(tcp://a,tcp://b)` list is NOT failover; use qpid-jms (the AMQP 1.0 JMS client) `failover:` or reconnect in code.
- A long outage of one region grows the survivor's disk (queued mirror events); suggest volume autoscaling.
- Adding a second location later does not copy existing messages.
- Readiness must stay on 61617: readiness on a client port deadlocks catch-up (measured).
- Never test with `suspend` (ruling: parked); use min/max 0 or SIGKILL.
- The image's default password is `artemis`; the chart always overrides it from the secret, which is re-applied on every start (rotate the secret, then force-redeployment).
