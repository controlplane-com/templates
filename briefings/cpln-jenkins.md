# cpln-jenkins — Maintainer Briefing

## What it is
- Jenkins LTS controller with our own [Control Plane cloud plugin](https://github.com/controlplane-com/cpln-jenkins-plugin) baked in. Jenkins provisions each build agent as a Control Plane workload on demand and deletes it once idle.
- Ships `ghcr.io/controlplane-com/cpln-jenkins:2.0.1` (appVersion `2.0.1`), built and published by that repo's `publish-image.yml` on merge to main. **We own the image**, unlike most templates — a plugin fix means a new image tag, then an `image:` bump here.
- Configured entirely through Configuration as Code. No setup wizard: it boots to a login screen.

## Common use cases
- CI for teams already on Control Plane who want build capacity that costs nothing between builds.
- Bursty pipelines — one dedicated agent per queued job (`useUniqueAgents`, on by default).
- Replacing a always-on static agent pool with per-build workloads.

## Architecture on cpln
| Resource | Purpose |
|---|---|
| workload `{release}-jenkins` (stateful, 1 replica) | The controller, HTTP 8080 |
| volumeset `{release}-jenkins-vs` (ext4, 10 GiB) | `/var/jenkins_home` — jobs, history, plugin state |
| secret `{release}-jenkins-cloud` (opaque, plain) | The JCasC cloud block, rendered by the chart, mounted at `/var/jenkins_conf/20-cloud.yaml` |
| identity + policy | `reveal` on exactly: the admin secret, the API key secret, the cloud secret |
| agent workloads | Created and deleted **by Jenkins**, not by this chart |

- Two REQUIRED prerequisite secrets: the admin password and a Control Plane API key. Both are `opaque`.
- Private by default (`publicAccess.enabled: false`); reach it with `cpln port-forward`, which works because Jenkins listens on container loopback.

## Key knobs (shipped 1.0.0 defaults)
`image` | `admin.username` (admin) / `admin.passwordSecretName` (`my-jenkins-admin-password`, **must exist before install**) | `cloud.enabled` (true) | `cloud.apiKeySecretName` (`my-jenkins-cpln-api-key`, **must exist before install**) | `cloud.gvc` (`""` = the GVC Jenkins runs in) | `cloud.labels` (`cpln`) | `cloud.useUniqueAgents` (true) | `cloud.allowJobsWithoutLabels` (true) | `cloud.executors` (1) | `cloud.cpu` (300) / `cloud.memory` (512) | `cloud.retentionMins` (5) | `resources.*` (500m-1000m / 1-2Gi) | `volumeset.capacity` (10) | `publicAccess.enabled` (**false**) | `internalAccess.type` (`same-gvc`)

## Troubleshooting / considerations
- **`securityOptions.filesystemGroupId: 1000` is load-bearing — do not remove it.** The image runs as `jenkins` (uid/gid 1000) but a freshly provisioned volumeset mounts root-owned. Without it, `JENKINS_HOME` is unwritable, the container exits 1 in a loop, and the only clue is a bare `Permission denied`. Same pattern as `n8n` and `sftpgo`.
- **The API key env var must NOT start with `CPLN_`.** The platform reserves that prefix and rejects the workload at apply with `Environment variable names starting with CPLN_ are reserved for system use`. It is called `CONTROLPLANE_API_KEY` for that reason, not for style. This is invisible to `helm template`.
- **`org` and `gvc` in the cloud config come from `${CPLN_ORG}` and the release, not from values.** Measured 2026-08-20: `CPLN_ORG` is a **bare name** (`jacob-cox`), unlike `CPLN_WORKLOAD`/`CPLN_LOCATION`, which are full resource links. That is why the user never supplies an org.
- **`jenkinsControllerUrl` must be the fully-qualified internal name.** Agents dial back over WebSocket; the short workload name is not reliably resolvable. Rendered as `{release}-jenkins.{gvc}.cpln.local:8080`.
- **The agent GVC must have exactly ONE location.** The plugin rejects multi-location GVCs. Not enforceable at render — documented only.
- **An API key with no policy bindings authenticates but provisions nothing.** It fails as `Failed to list workloads: 403` in the controller log; the Jenkins UI just shows an idle cloud. This is the most likely support question. The key needs workload `view`/`create`/`delete` in the agent GVC plus `view` on GVCs, identities and volumesets.
- **The admin password is applied on EVERY boot**, not just the first. Changing the secret and redeploying does change the login — unlike a first-boot bootstrap. Worth knowing before telling a user their password is fixed.
- **Agent CPU/memory floors (50m / 128Mi) are enforced at render**, because below them the agent JVM fails to start or is OOM-killed. Upstream documents the floors; the chart makes them a hard failure.
- Drift gate clean: first no-op upgrade reported `Updated` on three resources, but the stored specs differed only in the release tag and platform-computed health fields; the second upgrade was fully `Unchanged`.
