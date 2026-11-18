# Wazuh — Maintainer Briefing

## What it is
- Wazuh 4.14.10: open-source endpoint security (XDR + SIEM). Agents on hosts report to a Wazuh server (the manager); alerts land in the Wazuh indexer (an OpenSearch fork) and show in the Wazuh dashboard.
- Licence: GPLv2 (copyleft: free to run; anyone who redistributes modified code must share it) for the manager and agent, Apache-2.0 for the indexer and dashboard. Nothing is paid or gated.

## Common use cases
- Intrusion and malware detection on Linux, Windows and macOS servers and laptops.
- File integrity monitoring and CIS benchmark audits (security configuration assessment).
- Vulnerability detection of installed packages across every agent.
- PCI DSS / HIPAA / GDPR evidence dashboards; the endpoint half of a Datadog Cloud SIEM replacement (pair with `opensearch` for the log half).

## Architecture on cpln
| Resource | Purpose |
|---|---|
| `{r}-wazuh-manager` (stateful ×1) | the master: agents in on TCP 1514/1515 (direct LB), API 55000, makes the certificates |
| `{r}-wazuh-worker` (stateful ×N, optional) | extra server nodes that take agent traffic |
| `{r}-wazuh-indexer` (stateful ×1, or odd ≥ 3) | stores alerts; security plugin on; reachable only by this release's workloads plus a list |
| `{r}-wazuh-dashboard` (standard) | web UI on the `*.cpln.app` endpoint, login `admin` |
| `{r}-wazuh-pki` (shared volumeset) | hands the TLS certificates from the manager to the others; the CA key stays on the manager volume |
| `{r}-wazuh-demo-agent` (optional) | a real agent so the dashboards fill immediately |

- One prerequisite: a dictionary secret with six keys (four passwords, a 32-char cluster key, a cookie secret).
- Agent ports 1514/1515 are public to `0.0.0.0/0` by default (maintainer ruling); the wizard asks for the allowed CIDRs. No syslog listener (ruling): agents are the ingestion path.
- Single location. Availability is opt-in: workers, a 3-node indexer and 2 dashboards. The default single shape delays data during a restart but does not lose it (agents and filebeat buffer).

## Key knobs
`credentialsSecretName` · `manager.publicAccess.{enabled,allowedCidrs,api}` · `manager.internalAccess` · `manager.workers.replicas` · `indexer.replicas` · `indexer.retentionDays` · `manager.logRetentionDays` · `manager.extraConfig` · `indexer.internalAccess.workloads` · `dashboard.replicas` · `dashboard.publicAccess.enabled` · `demoAgent.enabled`

## How it works (the non-obvious parts)
- The manager volume mounts at `/var/ossec/queue` (Wazuh's cluster sync refuses paths that resolve outside it); the other persistent directories live under `queue/.cpln-persist` behind relative symlinks (the daemons chroot into `/var/ossec`).
- `ossec.conf` is rendered into a chart secret and written by the start script on every boot; UI edits to it are reset, so lasting changes go in `manager.extraConfig`.
- Keys on the PKI volume: indexer and admin keys `root:1001` 0640 (the indexer runs with fsGroup 1001); the dashboard (uid 1000, no fsGroup) can read the certificates (all 0644) but no private keys.

## Troubleshooting / considerations
- Nothing starts and the logs are empty → the credentials secret is missing or misnamed; read `status.versions[].message` via `cpln workload get-deployments`.
- A workload exits with `INVALID <key>` → a password breaks the rules (8-64 chars, starts with a letter, only `A-Z a-z 0-9 . * + ? -`, one of each kind).
- The secret is applied on every start: after editing it, force-redeploy the indexer, then the manager (and workers), then the dashboard.
- The indexer logs `RECONCILE FAILED` and retries every 60 s until passwords and the retention policy apply; `reconcile done` means it finished.
- The demo agent re-enrolls under a new name on every restart; an old copy can show "disconnected".
- Vulnerability Detection is empty for 2 h or more after install (content download); findings appeared after one manager restart.
- Disk: about 7 GiB of vulnerability content on the manager plus logs; the indexer needs about 2 GiB per agent per 90 days, and its disk watermarks are off upstream.
- The platform logs harmless "Lifecycle Hook Failed" events for the manager and workers.

## Follow-ups
- F2 forward alerts into the `opensearch` template; F3 Wazuh 5.0 as a major version; F4 syslog listener if wanted; F5 AWS/GCP modules with a cloud identity; F6 indexer snapshots; F7 SMTP alerts as values; F8 multi-location.
