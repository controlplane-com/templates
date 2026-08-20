# Jenkins on Control Plane

Jenkins CI server with the [Control Plane cloud plugin](https://github.com/controlplane-com/cpln-jenkins-plugin) built in. Build agents are provisioned as Control Plane workloads on demand and deleted once idle, so you pay for build capacity only while builds run.

## Architecture

- **Workload** (`stateful`) — the Jenkins controller, HTTP on port 8080, pinned to a single replica.
- **Volume set** — `ext4` volume mounted at `/var/jenkins_home`, holding jobs, build history and plugin state. A final snapshot is kept for 7 days when the volume set is deleted.
- **Cloud configuration secret** — created by this chart from your values and read by Jenkins at boot as Configuration as Code.
- **Identity + policy** — grants the controller `reveal` on exactly the secrets it mounts.
- **Agent workloads** — created and deleted by Jenkins itself at build time, not by this chart.

The controller is configured entirely from code. It boots straight to a login screen with no setup wizard.

## Prerequisites

**Two `opaque` secrets must exist BEFORE you install.** A missing one leaves the workload waiting on something that does not exist, with **zero log lines** — see [Diagnosing a stuck install](#diagnosing-a-stuck-install).

**1. Admin password** (`admin.passwordSecretName`)

```bash
printf '%s' 'YOUR-STRONG-PASSWORD' | cpln secret create-opaque \
  --name my-jenkins-admin-password --encoding plain -f -
```

**2. Control Plane API key** (`cloud.apiKeySecretName`) — Jenkins uses this to create and delete agent workloads.

```bash
cpln serviceaccount add-key my-service-account --description jenkins
# copy the `key` value from the output, then:
printf '%s' 'THE-KEY-VALUE' | cpln secret create-opaque \
  --name my-jenkins-cpln-api-key --encoding plain -f -
```

The service account needs `view`, `create` and `delete` on workloads in the agent GVC, plus `view` on GVCs, identities and volume sets. A key with no policy bindings authenticates but cannot provision anything.

**The agent GVC must have exactly ONE location.** The plugin only accepts single-location GVCs; agents are one replica each and cannot be placed across locations.

Secret names are organization-wide, so give each Jenkins release its own names.

## Configuration

### Image

```yaml
image: ghcr.io/controlplane-com/cpln-jenkins:2.0.1
```

### Admin login

```yaml
admin:
  username: admin                                 # login name (not sensitive)
  passwordSecretName: my-jenkins-admin-password   # opaque secret; must EXIST BEFORE INSTALL
```

Applied on every boot, so changing the secret and redeploying does change the password — unlike a first-boot-only bootstrap.

### Control Plane cloud

```yaml
cloud:
  enabled: true
  apiKeySecretName: my-jenkins-cpln-api-key  # opaque secret; must EXIST BEFORE INSTALL
  gvc: ""                    # agent GVC; empty = the GVC Jenkins runs in. ONE location only
  agentWorkload: jenkins-agent  # name prefix for provisioned agent workloads
  agentImage: jenkins/inbound-agent:latest
  labels: cpln               # space-separated; jobs target these
  allowJobsWithoutLabels: true  # false = only jobs requesting a label above
  useUniqueAgents: true      # one dedicated agent per queued job
  executors: 1               # concurrent builds per agent
  cpu: 300                   # millicores per agent (minimum 50)
  memory: 512                # MiB per agent (minimum 128)
  retentionMins: 5           # delete an idle agent after this long
  provisioningCooldownSecs: 60  # gap between provisions; prevents over-scaling
```

The organization and controller URL are derived at runtime from the platform's own values, so they cannot drift from where the workload actually runs.

### Controller resources and storage

```yaml
resources:
  minCpu: 500m
  maxCpu: 1000m
  minMemory: 1Gi
  maxMemory: 2Gi

volumeset:
  capacity: 10               # GiB (minimum 10); holds JENKINS_HOME
```

### Access

```yaml
publicAccess:
  enabled: false             # true publishes the Jenkins login to the internet

internalAccess:
  type: same-gvc             # none | same-gvc | same-org | workload-list
  workloads: []              # used with workload-list
```

`publicAccess` defaults to off. Reach a private controller with a tunnel:

```bash
cpln port-forward RELEASE_NAME-jenkins 8080:8080 --gvc GVC_NAME
# then open http://localhost:8080
```

## Connecting

| Path | Address | Notes |
|---|---|---|
| Public UI | `https://<canonical-endpoint>` | Only when `publicAccess.enabled: true`. Read it from `status.canonicalEndpoint` in `cpln workload get RELEASE_NAME-jenkins -o yaml`. |
| Internal UI | `http://RELEASE_NAME-jenkins.GVC_NAME.cpln.local:8080` | Subject to `internalAccess.type`. Use the full name; the short one does not always resolve. |
| Admin login | `admin.username` + the payload of your `admin.passwordSecretName` secret | Never stored in the Helm release. |

## Running builds on Control Plane agents

Give a job the label from `cloud.labels`:

```groovy
pipeline {
    agent { label 'cpln' }
    stages {
        stage('Build') {
            steps { sh 'echo building on a Control Plane agent' }
        }
    }
}
```

An agent workload appears in the GVC within about 30 seconds, runs the build, and is deleted once `cloud.retentionMins` elapses. With `allowJobsWithoutLabels: true` (the default), unlabelled jobs also run on Control Plane agents.

## Diagnosing a stuck install

A missing prerequisite secret produces **no log output at all** — the container never starts, so there is nothing to log. `cpln logs` returns zero lines and the deployment simply looks slow.

```bash
cpln workload get-deployments RELEASE_NAME-jenkins --gvc GVC_NAME -o yaml
```

Read `status.versions[].message`; it names the missing secret. Note this is `get-deployments` — plain `cpln workload get` has no `versions` field. Creating the secret repairs it on its own within roughly 5.5 to 10.5 minutes, or force a redeployment to skip the wait.

If Jenkins starts but no agents appear, the API key is the usual cause. Querying the controller's logs shows `Failed to list workloads: 403` when the key lacks workload permissions — the Jenkins UI shows only an idle cloud, so the log is the place to look.

## Important Notes

- **Create both secrets before installing** — a missing one wedges the deployment silently.
- **The agent GVC must have exactly one location.** Multi-location GVCs are rejected by the plugin.
- **An API key with no policy bindings authenticates but provisions nothing** — it needs workload `view`/`create`/`delete` in the agent GVC.
- **`publicAccess.enabled: true` puts a Jenkins login on the internet.** Set a strong admin password first, or use a port-forward tunnel instead.
- **Agent CPU and memory have floors** (50 millicores, 128 MiB). The chart refuses to render below them, because the agent JVM fails to start or is OOM-killed.
- **Jobs, build history and installed plugins live on the volume set** and survive redeployment; uninstalling the release deletes it.
- **Access changes take up to a couple of minutes to propagate** after toggling `publicAccess` or `internalAccess`.

## Links

- [Control Plane Jenkins plugin](https://github.com/controlplane-com/cpln-jenkins-plugin)
- [Jenkins documentation](https://www.jenkins.io/doc/)
- [Jenkins Configuration as Code](https://www.jenkins.io/projects/jcasc/)
- [Jenkins pipeline syntax](https://www.jenkins.io/doc/book/pipeline/syntax/)
