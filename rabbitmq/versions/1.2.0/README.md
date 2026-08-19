# RabbitMQ

RabbitMQ is a message broker that queues, routes and delivers messages between your services over AMQP 0-9-1. This template deploys a single-node broker with the management plugin, backed by a persistent volume so queues and messages survive a restart.

## Architecture

- **Workload** — a `stateful` RabbitMQ workload running the official `rabbitmq:3-management` image, serving AMQP on 5672, the management UI on 15672 and Prometheus metrics on 15692.
- **Volume set** — persistent storage mounted at `/var/lib/rabbitmq` holding the message store, queue definitions, the user database and the Erlang cookie.
- **Config secret** — an `opaque` secret rendered into `/etc/rabbitmq/rabbitmq.conf` carrying the AMQP listener port.
- **Identity + policy** — a workload identity granted `reveal` on exactly the config secret and your credentials secret, and nothing else.

## Prerequisites

**A `dictionary` secret holding the RabbitMQ default user.** These are not just the management-UI login — they are the AMQP credentials every producer and consumer puts in its connection string, so they never belong in a values file. Create the secret **before you install**:

```bash
cpln secret create-dictionary \
  --name my-rabbitmq-credentials \
  --entry username=rabbitmq \
  --entry password="$(openssl rand -hex 24)"
```

Read the generated password back with `cpln secret reveal my-rabbitmq-credentials -o yaml` — plain `reveal` prints only the metadata table.

Then set `credentialsSecretName` to that name. Nothing else is required for a default install.

## Configuration

**Credentials** — names the prerequisite secret above:
```yaml
credentialsSecretName: my-rabbitmq-credentials  # dictionary secret with `username` and `password`
```

**Image**:
```yaml
image:
  repository: rabbitmq:3-management
```

**Resources** — CPU and memory limits for the broker:
```yaml
memory: 250Mi
cpu: 200m

timeoutSeconds: 30 # inbound request timeout in seconds
```

**Internal access** — which workloads may reach the broker. External inbound is always closed:
```yaml
internalAccess:
  type: same-gvc # options: none, same-gvc (recommended), same-org
```

**RabbitMQ configuration** — rendered into `rabbitmq.conf`:
```yaml
rabbitmq_conf:
  listeners_tcp_default: 5672 # AMQP listener port

env:
  RABBITMQ_CONFIG_FILE: /etc/rabbitmq/rabbitmq.conf
```

**Storage** — the persistent volume backing `/var/lib/rabbitmq`:
```yaml
volumeset:
  volume:
      initialCapacity: 10 # In Gigabytes. For high-throughput-ssd minimum is '1000'
      fileSystemType: ext4 # ext4 / xfs
      performanceClass: general-purpose-ssd # high-throughput-ssd / general-purpose-ssd
```

## Connecting

| What | Where | Credentials |
|---|---|---|
| AMQP | `amqp://USERNAME:PASSWORD@RELEASE_NAME-rabbitmq.GVC_NAME.cpln.local:5672/` | `username` / `password` from your credentials secret |
| Management UI | `http://RELEASE_NAME-rabbitmq.GVC_NAME.cpln.local:15672` | same |
| Prometheus metrics | `http://RELEASE_NAME-rabbitmq.GVC_NAME.cpln.local:15692/metrics` | none |
| Public endpoint | not exposed — internal only | — |

The short name `RELEASE_NAME-rabbitmq` also resolves inside the same GVC.

To open the management UI in a browser from your laptop, tunnel to it — no public exposure required:

```bash
cpln port-forward RELEASE_NAME-rabbitmq 15672:15672 --gvc GVC_NAME
# then browse http://localhost:15672
```

## Important Notes

- The credentials secret must exist **before** you install. If it does not, the deployment wedges **silently** — `cpln logs` returns zero lines. The only diagnostic is `cpln workload get-deployments RELEASE_NAME-rabbitmq --gvc GVC_NAME -o yaml`, under `status.versions[].message`. Once you create the secret the deployment recovers on its own in roughly 5.5–8.5 minutes (measured 8 min 16 s here), or in about 90 seconds if you force a redeployment of the workload.
- The default user is written into the RabbitMQ database on **first boot only**. Changing the secret afterwards does not change the broker's credentials — rotate with `rabbitmqctl change_password`, or uninstall (which deletes the volume set and all messages) and reinstall.
- This broker is reachable inside the GVC only; there is no public-access knob. Use `cpln port-forward` for the management UI.
- A change to `internalAccess.type` takes up to a couple of minutes to propagate — re-test before concluding it did not apply.
- Single node, single replica: an upgrade or a reschedule is a short outage for every connected client, so give your producers and consumers a reconnect policy.
- Queue data lives on the volume set and survives redeploys; `cpln helm uninstall` deletes it.

## Links

- [RabbitMQ documentation](https://www.rabbitmq.com/docs)
- [Configuration reference (`rabbitmq.conf`)](https://www.rabbitmq.com/docs/configure)
- [Management plugin](https://www.rabbitmq.com/docs/management)
- [Prometheus metrics plugin](https://www.rabbitmq.com/docs/prometheus)
- [Official Docker image](https://hub.docker.com/_/rabbitmq)
