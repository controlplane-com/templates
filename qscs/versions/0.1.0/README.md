# QSCS on Control Plane

Deploy your own CDN across your chosen regions. QSCS distributes eligible HTTP application state across authenticated nodes. Start without a Spook Systems account, then optionally register to claim the existing deployment (https://spooksystems.io/) manage and monitor it centrally on Spook Systems platform. Node, domain and origin quantities are unlimited on both Free and Enterprise, for production workloads please register an account and upgrade to Enterprise at https://spooksystems.io/. This unlocks central configuration management, Unlimited Telemetry collection, API Caching, and Supports SLA's.

See the [QSCS documentation](https://spooksystems.io/documentation/) for origin configuration, API Caching, identity gates and administration.

## Before deploying

- Use an existing GVC, or create one with your chosen regions directly in the marketplace deployment form. This template uses explicit static GVC locations.
- Have a reachable HTTP(S) upstream application. Use its base URL, for example `https://origin.example.net`, or a bare hostname/IP with an optional port, such as `203.0.113.110:80`. Bare addresses use HTTP; use `https://` explicitly for HTTPS, even on port 443. Do not include credentials, a path prefix, query or fragment.
- Allow outbound access to the upstream, plus HTTPS to `spooksystems.org` (enrollment and management) and `monitoring.spooksystems.org` (telemetry). The template permits outbound connections and restricts internal inbound traffic to this workload.
- Budget storage **per replica**. The default is one 10 GiB XFS volume per node: two nodes allocate 20 GiB in total, before snapshots or provider billing overhead.

The public image is `spooksystems/qscs:latest`. Select locations compatible with the image's published platform; the image tested for this candidate is Linux x86-64. No Docker Hub credential is needed to pull the public image, subject to registry rate limits.

## Deploy

1. On the **Release** step, select an existing GVC or choose **Create GVC**, name it and select your regions. Then enter the **Origin address**.
2. Choose the **Initial location**. Replica zero there establishes the deployment; other replicas securely join it. This is a bootstrap choice, not the only location clients can use.
3. Leave **Additional nodes** empty for one node. Add one entry per extra node: a different region for geographic separation, or repeat a region for multiple replicas there. For a two-node deployment, add one entry.
4. Review CPU, memory and storage, then deploy.
5. Open the generated workload HTTPS endpoint after the nodes start serving.

Only the selected locations run nodes. Other locations in the GVC have zero replicas for this workload, and adding a GVC location alone does not add QSCS capacity. The template creates a stateful workload and a volume set, and gives each replica its own identity/state volume. Keep the release name, GVC, initial location and those volumes stable across ordinary upgrades.

You do not need to prepare a GVC in advance. Control Plane provides the embedded GVC creation form, so the same template can use either a new or an existing GVC. A new GVC is independent of the Helm release and remains after uninstall. For CLI deployment, use `cpln gvc create --org YOUR_ORG --name YOUR_GVC --location REGION_ONE --location REGION_TWO` before `cpln helm install`, choosing the regions in your node values. Use one `--location` for a single region. [Control Plane marketplace wizard](https://github.com/controlplane-com/templates/blob/0c37a7546dc51574fd0b0ffc45d8d4e224bce145/WIZARD_AUTHORING.md#141-syntax).

Control Plane terminates public HTTPS and forwards application requests to port 8080. The image discovers the generated global frontend hostname automatically. Set **Frontend hostname** only when using an explicit hostname, and configure its Control Plane domain routing separately. Changing the QSCS setting alone does not create DNS ownership or a TLS certificate.

The readiness probe uses the private HTTP endpoint `8081/readyz`. During bootstrap it can accept the join callback before the application is fully serving; `8081/serving` confirms the serving phase. Neither endpoint is exposed as a public container port. A Ready indication is not proof that all cached state has synchronized.

The peer listener on TCP 4443 and the join listener on HTTP 4444 are required for node communication. Public application traffic uses the generated HTTPS route; do not create public peer hostnames or route unauthenticated traffic to the join listener. The template configures private replica routing and same-workload access.

## Available settings

| Value | Default | Meaning |
| --- | --- | --- |
| `origin` | Required application address | HTTP(S) URL or bare hostname/IP with an optional port, such as `203.0.113.110:80` (HTTP); replace the example in the default values |
| `initialLocation` | `aws-eu-central-1` | Bootstrap location; must be in the selected GVC |
| `additionalNodes` | `[]` | One location entry per extra node; repeated locations create additional replicas there |
| `frontend` | Empty | Discover the `.cpln.app` hostname; override with a bare hostname if needed |
| `upstream` | Empty | Optional upstream Host header override; HTTPS connection/SNI validation still uses the origin URL |
| `image` | `spooksystems/qscs:latest` | Public image; an immutable digest can be used for controlled releases |
| `resources.cpu` | `500m` | CPU reservation per node |
| `resources.memory` | `512Mi` | Memory per node; size for the application and cached state |
| `publicCIDRs` | `["0.0.0.0/0"]` | Permitted public client networks |
| `storage.capacityGiB` | `10` | Initial capacity per node; increasing it is subject to provider expansion support |
| `storage.fileSystemType` | `xfs` | XFS or ext4; immutable once storage exists |
| `storage.retainOnUninstall` | `true` | Keep the volume set and node state when uninstalling the release |
| `storage.createFinalSnapshot` | `true` | Request final snapshots when storage is deleted |
| `storage.snapshotRetention` | `7d` | Final snapshot retention |
| `claimedDeployment` | `false` | Deprecated compatibility setting; ignored |

GVC/org/workload/replica metadata, security IDs, ports and bootstrap environment variables are supplied by the template/platform. Inheriting custom GVC environment variables is not required. No privileged init container, mounted API token or user-written startup command is needed.

## Prometheus metrics in Control Plane

QSCS exposes node, request, cache, origin-health and replication metrics for Control Plane's native Prometheus collector. Collection works before or after claiming a deployment and is independent of SpookVis: scraping does not consume queued SpookVis telemetry or require a Spook account. Retention in Control Plane follows your Control Plane organization's settings.

### Enable collection

The template leaves this optional listener and collection disabled by default. For an existing deployment:

1. Select the GVC and workload, then open **Containers → qscs → Env Vars**. Add `QSCS_METRICS_LISTEN` with the value `0.0.0.0:9464`.
2. In the same container's **Metrics** settings, set **Path** to `/metrics` and **Port** to `9464`.
3. Keep `9464` out of the exposed **Ports** list, public load-balancer mappings and custom domains. Retain the template's internal firewall restriction to the QSCS workload.
4. Save the changes and allow the workload rollout to finish. Control Plane then collects from every replica automatically; no extra collector workload or API token inside QSCS is needed.

For YAML configuration, merge these fields into the existing `qscs` entry under `spec.containers`. Append the environment variable to its existing `env` list, preserving the origin, bootstrap settings, ports, probes and volumes:

```yaml
env:
  - name: QSCS_METRICS_LISTEN
    value: "0.0.0.0:9464"
metrics:
  path: /metrics
  port: 9464
```

These are **workload fields**, not additional Helm values supported by this chart. For a Helm-managed deployment, keep them in your maintained copy of `templates/workload.yaml` and upgrade with your complete values file, or reapply the Console settings after an upgrade that removes them. Editing the workload directly does not update the chart.

The separate metrics listener has no HTTP authentication or TLS of its own; keep it private to the platform collector. The application listener's `/qscs/metrics` endpoint on port 8080 remains localhost-only and should not be used as the native collector target. Leaving the extra port unexposed preserves the workload's application and peer routing. See [Control Plane's firewall rules](https://docs.controlplane.com/reference/workload/firewall).

### View the collected metrics

Open the workload's **Metrics** page, clear the existing query and run:

```promql
qscs_node_info{gvc="YOUR_GVC", workload="YOUR_WORKLOAD"}
```

Use the deployed workload name, normally `<release>-qscs`. Control Plane scrapes each replica every 30 seconds with a five-second timeout and adds placement labels, including `gvc`, `location` and `replica`. Allow the rollout and the next scrape to complete, then check that recent samples cover your expected nodes. These series are also available for dashboards in the organization's Grafana. See [Control Plane's custom metrics guide](https://docs.controlplane.com/reference/workload/custom-metrics).

Useful queries, with the same GVC and workload substitutions:

| Measurement | PromQL |
| --- | --- |
| Recorded request events per second, per replica | `sum by (location, replica) (rate(qscs_http_requests_total{gvc="YOUR_GVC", workload="YOUR_WORKLOAD"}[5m]))` |
| Cache hits per second, per replica | `sum by (location, replica) (rate(qscs_cache_hits_total{gvc="YOUR_GVC", workload="YOUR_WORKLOAD"}[5m]))` |
| Measured client body bytes saved per second, per region | `sum by (location) (rate(qscs_client_saved_bytes_total{gvc="YOUR_GVC", workload="YOUR_WORKLOAD"}[5m]))` |
| Age of the latest node-info sample, in seconds | `time() - timestamp(qscs_node_info{gvc="YOUR_GVC", workload="YOUR_WORKLOAD"})` |

Generate some application traffic before checking activity counters; some series appear only after relevant activity. Counters reset when a daemon restarts, so use `rate()` or `increase()` for comparisons. Consult each metric's `HELP` text for its accounting scope: request events include stream updates, and client savings measure smaller response bodies rather than all network overhead. Historical samples alone do not establish that a node is currently running.

## Claim, manage and add nodes

Claiming is optional. Free deployments can enroll and add nodes without purchasing seats. Authenticated membership is still required: unlimited quantities do not permit unauthorized joins.

To manage the existing deployment:

1. Create or sign into your Spook Systems account and choose **Claim existing deployment**.
2. Read the temporary account handle from `qscs status` in the **unclaimed administrator node** via connect in the controlplane workload options, normally replica zero in the initial location. The container already runs as the node user; it does not need `sudo`.
3. Enter that handle and follow discovery. Approve the short-lived, account-bound proof on that administrator node using the exact command presented by the portal.
4. Review the discovered nodes and finish the claim. Knowing a handle or UUID alone never authorizes a claim.

The existing UUIDs, substrate membership, configuration and retained monitoring history remain associated with the deployment. Claiming does not by itself change origins or the node roles. Anonymous and Free telemetry has 30-day retention. Free accounts retain access to monitoring, alerts and cluster management; Enterprise adds unlimited telemetry retention while subscribed and early access to features such as API Boost. See [pricing](https://spooksystems.io/pricing/) for current terms.

Monitoring delivery is asynchronous; temporary telemetry unavailability does not stop normal application delivery. Enrollment and membership renewal still need the authority service.

Node quantities are unlimited. Enable any new region in the GVC first, add one entry to `additionalNodes` for each additional replica, and upgrade the **same release with the full values file**. The chart does not change GVC placement during upgrades. Its initializer must be available to authorize joining. The authority still verifies membership. A different release is independent: a new release creates a separate deployment, not an implicit join to an existing substrate.

Moving or replacing a node, adding a separately named workload, or joining from another provider requires the normal authorized invitation/assignment workflow. A shared origin URL, account handle or substrate ID is not a join credential.

## Upgrade, restart and removal

Persistent state preserves identity and saved state across restarts and replacements that retain the same replica volume. Never clone a live identity volume into another node. Do not change the bootstrap location, release identity, mount path or volume set as a way to redeploy an existing cluster. Removing replicas retains their volume data; unregister intentionally retired nodes through the platform and separately decide whether to remove their storage.

`latest` is a mutable image tag, not a running-container update mechanism. Automatic dynamic-tag updates are disabled. For a repeatable upgrade, resolve the desired image digest, update `image` and upgrade the release. A chart rollback does not undo externally stored enrollment state or guarantee binary/data-format compatibility; preserve the state volumes and use a supported image rollback.

Uninstalling normally removes the workload but **retains storage**. Retained disks and snapshots may continue to cost money. For disposable environments only, set both storage retention switches to false before uninstalling and verify resource deletion. Deleting volumes destroys the corresponding persistent identities and saved state. 

The template is a deployment package, not an alternative identity or licensing service. Existing QSCS security, origin eligibility, role and policy rules continue to apply.

The GVC itself is not deleted by a chart uninstall. Remove it separately only after inspecting its contents and deciding what to do with all retained resources.
