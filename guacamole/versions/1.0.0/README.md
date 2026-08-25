# Apache Guacamole

Apache Guacamole is a clientless remote desktop gateway: users open RDP, VNC, SSH and telnet sessions to internal machines in a plain browser tab, with no client, plugin or VPN. This template deploys the Guacamole web app, the `guacd` protocol daemon and a bundled PostgreSQL that holds users, connections, permissions and session history.

## Architecture

- **Gateway workload** — a `standard` workload (`{release}-guacamole`) running three containers and mounting no volumeset; pinned to one replica by design (see Important Notes).
  - `guacamole` — Tomcat serving the UI, REST API and the browser tunnel on HTTP `:8080`.
  - `guacd` — the protocol daemon, reached over loopback `:4822`. Its port is deliberately **not published**: guacd is unauthenticated, so nothing outside the replica can drive it.
  - `schema-init` — bootstraps the database on first boot (schema + admin account), then idles. Tomcat does not start until it finishes.
- **PostgreSQL** (`postgres` subchart) — every byte Guacamole persists: users, connections, connection parameters, permissions and session history.
- **Database credentials secret** — a dictionary secret (`username` / `password` / `database`) this template creates from `postgres.credentials.*` and hands to the bundled database by name. Nothing for you to create.
- **Start / init secrets** — two opaque secrets holding the shell scripts the containers run. They contain no credentials.
- **Identity + policy** — grants the workload `reveal` on exactly those secrets and nothing else. No cloud bindings.

## Prerequisites

- **An admin dictionary secret — create it BEFORE installing.** It holds exactly `username` and `password`, and replaces Guacamole's well-known `guacadmin`/`guacadmin` account before Tomcat ever serves a request. A missing secret wedges the deployment silently.

  ```bash
  cpln secret create-dictionary --name my-guacamole-admin \
    --entry username=admin --entry password='choose-a-strong-password'
  ```

- **Nothing else for a default install.** The database password is bundled plumbing no human types elsewhere, so this template creates that secret for you from `postgres.credentials.*`.

## Configuration

### Guacamole web application

```yaml
guacamole:
  image: guacamole/guacamole:1.6.0
  resources:
    minCpu: 500m
    maxCpu: 1000m
    minMemory: 1Gi
    maxMemory: 2Gi   # JVM heap defaults to ~1/4 of this
```

### guacd (protocol daemon)

```yaml
guacd:
  image: guacamole/guacd:1.6.0   # keep this tag equal to the guacamole tag
  resources:
    minCpu: 100m
    maxCpu: 1000m
    minMemory: 256Mi
    maxMemory: 1Gi   # raise for many concurrent RDP sessions
```

### Admin account and logging

```yaml
admin:
  secretName: my-guacamole-admin   # dictionary secret with username + password — MUST exist before install

logLevel: info   # trace | debug | info | error (applies to both containers)
```

### Access

```yaml
publicAccess:
  enabled: false  # false = internal only; true = UI on the auto-assigned *.cpln.app HTTPS endpoint
internalAccess:
  type: same-gvc  # none | same-gvc | same-org | workload-list
  workloads: []   # used only with workload-list
```

### PostgreSQL

```yaml
postgres:
  image: postgres:18            # also used by the schema-init sidecar, so psql matches the server
  credentials:                  # this template builds the DB credential secret from these
    username: guacamole
    password: change-me-guacamole-db   # change before installing
    database: guacamole
  config:
    # name of the dictionary secret this template CREATES and Postgres reads;
    # secret names are org-wide, so a second release on this name is refused at install
    credentialsSecretName: my-guacamole-db-credentials
  resources:
    minCpu: 250m
    maxCpu: 1000m
    minMemory: 512Mi
    maxMemory: 1Gi
  volumeset:
    capacity: 10                # GiB (minimum 10)
```

## Supported protocols

`guacd:1.6.0` has **RDP, VNC, SSH and telnet** compiled in. The Kubernetes protocol is not included.

A fresh install is empty and looks broken until an admin adds a connection: log in, open **Settings → Connections → New Connection**, pick the protocol, and set the target host and port. For a machine in the same GVC use the fully-qualified internal name (`{workload}.{gvc}.cpln.local`); a bare short name does not reliably resolve.

## Connecting

| Target | Address | Credentials |
|---|---|---|
| UI (default, private) | port-forward the workload, then `http://localhost:8080/` — see below | the `username` / `password` of your admin secret |
| UI (public, opt-in) | `https://<canonical>.cpln.app` after enabling `publicAccess` | same |
| Internal (same GVC) | `http://{release}-guacamole.{gvc}.cpln.local:8080` | same |
| PostgreSQL (same GVC) | `{release}-postgres.{gvc}.cpln.local:5432` | the keys of the secret named by `postgres.config.credentialsSecretName` |

With the default private install, reach the UI in your browser through a tunnel:

```bash
cpln port-forward {release}-guacamole 8080:8080 --gvc {gvc}
```

**To put the UI on the internet**, install privately, port-forward, confirm you can log in, then upgrade the release with `publicAccess.enabled=true`. The canonical `*.cpln.app` hostname then appears under `status.canonicalEndpoint` (`cpln workload get {release}-guacamole -o yaml`). Allow up to a few minutes for the firewall change to take effect before deciding it did not work.

## Backing up the bundled database

The bundled PostgreSQL is the `postgres` template, so **every backup option that template has is already available here** — nothing extra to install. It is off by default:

```yaml
postgres:
  backup:
    enabled: true
    schedule: "0 2 * * *"      # daily at 02:00 UTC
    provider: aws              # aws | gcp | minio
    aws:
      bucket: my-postgres-bucket
      region: us-east-1
      cloudAccountName: my-s3-cloud-account
      policyName: my-postgres-backup-policy   # bucket-scoped IAM policy
      prefix: postgres/backups
```

For the bucket, [cloud account](https://docs.controlplane.com/guides/create-cloud-account) and IAM policy setup — including the exact policy JSON per provider — follow the Storage setup section of the [`postgres` template README](../../../postgres).

## Important Notes

- **An upgrade does not drop the endpoint, but it does drop sessions.** A rolling upgrade served 112/112 requests with no failures, and a replica-down test served 204/204 — so the gateway itself stays reachable. Existing logins do not survive it: auth tokens are rejected afterwards and users must sign in again, and any open remote session ends. Reconnecting re-establishes it.
- **The admin secret must exist before install.** A missing one wedges the deployment *silently*: `cpln logs` returns zero lines because no container ever starts. The only diagnostic is `status.versions[].message` from `cpln workload get-deployments {release}-guacamole -o yaml`. It recovers on its own within about ten minutes of creating the secret (measured: 9 min 46 s), or immediately with a forced redeployment.
- **The admin password is applied on FIRST BOOT ONLY.** It seeds the database once, so rotating the secret afterwards does not change your login — verified by rotating it, forcing a redeployment, and confirming the original password still worked. Change the password in the Guacamole UI instead.
- **`guacadmin`/`guacadmin` is never valid here** — the stock account is renamed and re-hashed before Tomcat binds a port.
- **Single replica by design.** Guacamole keeps auth tokens in each Tomcat's memory with no cross-instance sharing, and the platform offers no session affinity, so a second replica would randomly log users out. Any restart — an upgrade, a replica reschedule, or rotating any referenced secret — **drops active desktop sessions and logs everyone out**. Nothing persisted is lost.
- **Public access is off by default.** This gateway fronts your internal machines, so expose it deliberately (see Connecting) rather than by default. Firewall changes take ~30 s to a few minutes to propagate.
- **Give each release its own `postgres.config.credentialsSecretName`.** Secret names are org-wide, so a second release left on the default name is refused at install.
- **Connections, users and history survive reinstall** in the Postgres volumeset; delete that volumeset to wipe everything.

## Links

- [Guacamole manual](https://guacamole.apache.org/doc/gug/)
- [Installing Guacamole with Docker (environment variables)](https://guacamole.apache.org/doc/gug/guacamole-docker.html)
- [PostgreSQL authentication](https://guacamole.apache.org/doc/gug/postgresql-auth.html)
- [Administration: users, connections and permissions](https://guacamole.apache.org/doc/gug/administration.html)
- [GitHub](https://github.com/apache/guacamole-client)
