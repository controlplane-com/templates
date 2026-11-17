# Wazuh

Open-source endpoint security: Wazuh agents on your Linux, Windows and macOS hosts report to a Wazuh server, which detects intrusions and malware, watches file integrity, finds vulnerable packages and checks compliance. Alerts are stored in the Wazuh indexer and explored in the Wazuh dashboard. This template deploys all three, with agents connecting from anywhere over a public TCP load balancer.

## Architecture

- **Manager** (`RELEASE-wazuh-manager`, stateful, 1 replica) — the Wazuh server: receives agent events on TCP 1514, enrolls agents on 1515, serves the server API on 55000, runs analysis and vulnerability detection, and ships alerts to the indexer. Its volume set (`/var/ossec/queue`, 50 GiB) holds agent keys, server state, the alert log files, custom rules and about 7 GiB of vulnerability content, with daily snapshots.
- **Workers** (`RELEASE-wazuh-worker`, stateful, optional) — extra Wazuh server nodes that take agent traffic, so agents stay connected while the manager restarts. Each has its own volume set, with daily snapshots.
- **Indexer** (`RELEASE-wazuh-indexer`, stateful, 1 or 3+ nodes) — stores alerts and inventory (one volume set per node, daily snapshots) with its security plugin on (TLS and passwords). Only this release's workloads, and any you list, can reach it.
- **Dashboard** (`RELEASE-wazuh-dashboard`, standard) — the web UI on the workload's `*.cpln.app` HTTPS endpoint.
- **Certificate volume** (`RELEASE-wazuh-pki`, shared) — the manager creates a private CA and the TLS certificates at first boot; the indexer and dashboard read them from here. The CA key never leaves the manager's own volume.
- **Demo agent** (`RELEASE-wazuh-demo-agent`, optional) — a real agent inside the GVC that fills the dashboard right away.
- **Configuration secret, identity and policy** — the server configuration, and `reveal` on exactly that secret and your credentials secret.

Agents are the ingestion path: the template has no syslog listener. To collect syslog from network devices, run an agent on the host that receives it.

## Prerequisites

**A dictionary secret with six keys must exist BEFORE you install.** Create it with:

```bash
cpln secret create-dictionary --name my-wazuh-credentials \
  --entry indexerAdminPassword="Wz1.$(openssl rand -hex 16)" \
  --entry dashboardServerPassword="Wz2.$(openssl rand -hex 16)" \
  --entry apiPassword="Wz3.$(openssl rand -hex 16)" \
  --entry enrollmentPassword="Wz4.$(openssl rand -hex 16)" \
  --entry clusterKey="$(openssl rand -hex 16)" \
  --entry dashboardCookieSecret="$(openssl rand -hex 24)"
```

| Key | What it is |
|---|---|
| `indexerAdminPassword` | The indexer `admin` user: **your dashboard login** (username `admin`). |
| `dashboardServerPassword` | The indexer user the dashboard server connects with. |
| `apiPassword` | The Wazuh server API user `wazuh-wui` the dashboard calls the manager with. |
| `enrollmentPassword` | The password agents present on port 1515 to enroll. |
| `clusterKey` | Exactly 32 letters, digits or underscores, shared by the manager and workers. |
| `dashboardCookieSecret` | 32 or more characters; encrypts dashboard sessions. |

Passwords must be 8 to 64 characters, start with a letter, use only `A-Z a-z 0-9 . * + ? -`, and contain at least one upper-case letter, lower-case letter, digit and symbol (the `Wz1.` prefixes above take care of that). A workload whose password breaks the rules exits at start with `INVALID <key>` in its logs.

Read the values back with `cpln secret reveal my-wazuh-credentials -o yaml`. If the secret does not exist at install time, every workload waits and `cpln logs` shows nothing; the reason is in `status.versions[].message` of `cpln workload get-deployments RELEASE-wazuh-manager --gvc GVC -o yaml`.

## Configuration

The default is one node of each component. A restart of the manager or indexer pauses event processing; agents and the indexer shipper buffer and resend, so nothing is lost. Set `indexer.replicas: 3`, `manager.workers.replicas: 2` and `dashboard.replicas: 2` for near-zero-downtime upgrades. Each component also has an `image` and a `resources` block; keep all images on the same Wazuh version.

### Manager

```yaml
manager:
  logRetentionDays: 30 # delete dated alert/archive log files older than this; 0 = keep forever
  extraConfig: "" # raw <ossec_config>…</ossec_config> blocks appended to ossec.conf
  publicAccess:
    enabled: true # TCP 1514 (events) and 1515 (enrollment) on a public load balancer
    allowedCidrs:
      - 0.0.0.0/0 # narrow to the networks your agents connect from
    api: false # also expose the server API, as port 8443 on the load balancer
  internalAccess:
    type: same-gvc # same-gvc, same-org or workload-list (this release's workloads are always allowed)
  volumeset:
    capacity: 50 # GiB; agent keys, server state, alert log files, vulnerability content
    snapshots:
      schedule: "0 3 * * *" # daily at 3am UTC; at most hourly; "" turns scheduled snapshots off
      retentionDuration: 7d
```

Edits to `ossec.conf` made in the dashboard are reset on the next restart; put lasting changes in `extraConfig`. Custom rules, decoders and CDB lists made in the dashboard are kept. The manager volume holds every agent key and the CA key, so keep its snapshots on.

### Worker nodes

```yaml
manager:
  workers:
    replicas: 0 # 1+ adds worker nodes that take agent traffic
    volumeset:
      capacity: 20 # GiB per worker
      snapshots:
        schedule: "0 3 * * *"
        retentionDuration: 7d
```

Workers keep agents connected while the manager restarts. With workers on, point agents at the worker load balancer; workers pass enrollment on to the manager, and the server API stays on the manager.

### Indexer

```yaml
indexer:
  replicas: 1 # 1, or an odd number of 3 or more
  javaHeap: 2g # about half of resources.maxMemory
  retentionDays: 90 # delete alert indices older than this; 0 = keep forever
  internalAccess:
    workloads: [] # extra workloads allowed to query the indexer
  volumeset:
    capacity: 50 # GiB per node; roughly 2 GiB per agent per 90 days
    snapshots:
      schedule: "0 3 * * *"
      retentionDuration: 7d
```

Every volume set also takes `autoscaling` (`enabled`, `maxCapacity`, `minFreePercentage`, `scalingFactor`). Uninstalling the release deletes every volume set, with the stored alerts and every agent key; a final snapshot of each is kept for `retentionDuration`.

### Dashboard

```yaml
dashboard:
  replicas: 1 # 2+ keeps the UI up through restarts
  publicAccess:
    enabled: true # HTTPS UI on the *.cpln.app endpoint; false = reach it with cpln port-forward
  internalAccess:
    type: same-gvc # none, same-gvc, same-org or workload-list
    workloads: # used with workload-list
      #- //gvc/GVC_NAME/workload/WORKLOAD_NAME
```

### Demo agent

```yaml
demoAgent:
  enabled: false # a real agent in this GVC that fills the dashboard right away
```

## Connecting

| What | Address | Credentials |
|---|---|---|
| Dashboard | `status.canonicalEndpoint` of `RELEASE-wazuh-dashboard` (public), or `http://localhost:5601` through port-forward | `admin` / `indexerAdminPassword` |
| Agents (outside Control Plane) | the manager's load balancer host, ports 1514 and 1515 (the worker's when workers are on) | `enrollmentPassword` |
| Agents (inside the GVC) | `RELEASE-wazuh-manager.GVC.cpln.local`, ports 1514 and 1515 | `enrollmentPassword` |
| Server API | `https://RELEASE-wazuh-manager.GVC.cpln.local:55000` (the load balancer host on port 8443 with `manager.publicAccess.api: true`) | `wazuh-wui` / `apiPassword` |
| Indexer | `https://RELEASE-wazuh-indexer.GVC.cpln.local:9200` (this release's workloads and `indexer.internalAccess.workloads` only) | `admin` / `indexerAdminPassword` |

With `dashboard.publicAccess.enabled: false`, forward the dashboard and open `http://localhost:5601`:

```bash
cpln port-forward RELEASE-wazuh-dashboard 5601:5601 --gvc GVC
```

Find the agents' load balancer host:

```bash
cpln workload get RELEASE-wazuh-manager --gvc GVC -o json | jq -r '.status.loadBalancer[].url'
```

It prints `tcp://RELEASE-wazuh-manager-xxxx.yyyy.cpln.app:1514` and `…:1515`. Install the agent on a host with that name and the enrollment password, for example on Debian or Ubuntu after adding the Wazuh package repository:

```bash
sudo WAZUH_MANAGER="RELEASE-wazuh-manager-xxxx.yyyy.cpln.app" \
  WAZUH_REGISTRATION_PASSWORD="YOUR_ENROLLMENT_PASSWORD" \
  apt-get install wazuh-agent
sudo systemctl enable --now wazuh-agent
```

The dashboard's **Deploy new agent** page builds the same command for every operating system, with the host already filled in. The agent then appears under **Endpoints**.

## Important Notes

- **Agent ports are open to the whole GVC while the load balancer is on.** `manager.internalAccess` does not restrict 1514 and 1515 when `manager.publicAccess.enabled` is true; the enrollment password is the gate. It restricts them (and the API) once the load balancer is off.
- **Custom rules in `extraConfig`.** A `<ruleset>` block replaces the default one, so restate the default `decoder_dir`, `rule_dir` and `list` entries in it, or the default rules stop loading. Workers load rules synced from the master after a restart (`PUT /cluster/restart`).
- **Restarts can repeat alerts.** Agents resend events the manager had not acknowledged, so an alert can appear twice after a restart; the **Statistics** page returns errors for about an hour after a manager start.
- **Single location.** The template runs in one location; install it in a GVC with exactly one location.
- **Access changes take time.** After changing `manager.publicAccess.*` or `dashboard.publicAccess.enabled`, allow 30 seconds to about 10 minutes for the firewall and load balancer to apply.
- **Changing a password.** The secret is the source of truth on every start. Edit the key (`cpln secret edit my-wazuh-credentials`), then force a redeployment of the indexer, then the manager (and workers), then the dashboard, for example `cpln workload force-redeployment RELEASE-wazuh-indexer --gvc GVC`. A password changed only in the dashboard reverts on the next restart.
- **Certificates.** The manager creates the CA and certificates once (10-year life) and keeps the CA key on its own volume. If the manager's volume set is ever replaced, restart the indexer and dashboard afterwards so they pick up the new CA, and enroll the agents again.
- **Demo agent.** It enrolls under a new name each time it restarts, leaving the old entry disconnected. Turn it off once your own agents connect, and remove stale entries under **Endpoints**.
- **Removing indexer nodes** can lose the data they hold; scale the indexer up, not down.
- **Disk.** The indexer's disk watermarks are off (as upstream ships it), so a full volume stops indexing. Keep the retention values set or turn on volume autoscaling.

## Links

- [Wazuh documentation](https://documentation.wazuh.com/4.14/index.html)
- [Installing Wazuh agents](https://documentation.wazuh.com/4.14/installation-guide/wazuh-agent/index.html)
- [Wazuh Docker images](https://github.com/wazuh/wazuh-docker)
- [Wazuh server cluster](https://documentation.wazuh.com/4.14/user-manual/wazuh-server-cluster/index.html)
