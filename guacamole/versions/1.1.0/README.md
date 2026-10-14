# Apache Guacamole

Apache Guacamole is a clientless remote desktop gateway: users open RDP, VNC, SSH and telnet sessions to internal machines in a plain browser tab, with no client, plugin or VPN. This template deploys the Guacamole web app, the `guacd` protocol daemon and a bundled PostgreSQL that holds users, connections, permissions and session history.

## Architecture

- **Gateway workload** — a `standard` workload (`{release}-guacamole`) running three containers and mounting no volumeset; pinned to one replica by design (see Important Notes).
  - `guacamole` — Tomcat serving the UI, REST API and the browser tunnel on HTTP `:8080`.
  - `guacd` — the protocol daemon, reached over loopback `:4822`. Its port is deliberately **not published**: guacd is unauthenticated, so nothing outside the replica can drive it.
  - `schema-init` — bootstraps the database on first boot (schema + admin account), then idles. Tomcat does not start until it finishes.
- **PostgreSQL** (`postgres` subchart) — every byte Guacamole persists: users, connections, connection parameters, permissions and session history.
- **Database credentials secret** — a dictionary secret (`username` / `password` / `database`) *not created by this template*; you create it before install. Postgres initializes from it, and Guacamole and its `schema-init` sidecar connect with it.
- **Start / init secrets** — two opaque secrets holding the shell scripts the containers run. They contain no credentials.
- **Identity + policy** — grants the workload `reveal` on exactly four secrets — your admin and database secrets, and the two script secrets — and nothing else. No cloud bindings.

## Prerequisites

**Two dictionary secrets must exist BEFORE you install.** They are credentials, so they are prerequisite secrets rather than values — a value would sit in plaintext in the Helm release for the life of the install.

**1. Database credentials** — the bundled Postgres initializes with these, and Guacamole connects with them:

```bash
cpln secret create-dictionary --name my-guacamole-db-credentials \
  --entry username=guacamole \
  --entry password="$(openssl rand -hex 24)" \
  --entry database=guacamole
```

Set `postgres.config.credentialsSecretName` to that name. Postgres reads it only when its data directory is first initialized; to change the password later, run `ALTER ROLE` first, then update the secret and force a redeployment of both workloads.

**2. Admin login** — exactly `username` and `password`. It replaces Guacamole's well-known `guacadmin`/`guacadmin` account before Tomcat ever serves a request:

```bash
cpln secret create-dictionary --name my-guacamole-admin \
  --entry username=admin --entry password='choose-a-strong-password'
```

Set `admin.secretName` to that name.

**If either secret does not exist at install time the deployment wedges silently.** `cpln logs` returns zero lines — the container never starts, so there is nothing to log. The only diagnostic is `status.versions[].message` in `cpln workload get-deployments {release}-guacamole --gvc {gvc} -o yaml` (the database secret also wedges `{release}-postgres`). Create the missing secret and it recovers on its own within about ten minutes, or immediately with `cpln workload force-redeployment`.

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
  config:
    credentialsSecretName: my-guacamole-db-credentials  # PREREQUISITE dictionary secret (username, password, database) — must exist BEFORE install
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
| UI (public, opt-in) | the canonical endpoint — read `status.canonicalEndpoint` (below) after enabling `publicAccess` | same |
| Internal (same GVC) | `http://{release}-guacamole.{gvc}.cpln.local:8080` | same |
| PostgreSQL (same GVC) | `{release}-postgres.{gvc}.cpln.local:5432` | from your `postgres.config.credentialsSecretName` secret |

With the default private install, reach the UI in your browser through a tunnel:

```bash
cpln port-forward {release}-guacamole 8080:8080 --gvc {gvc}
```

**To put the UI on the internet**, install privately, port-forward, confirm you can log in, then upgrade the release with `publicAccess.enabled=true`. The canonical `*.cpln.app` hostname then appears under `status.canonicalEndpoint` (`cpln workload get {release}-guacamole --gvc {gvc} -o yaml`). Allow up to a few minutes for the firewall change to take effect before deciding it did not work.

## Upgrading from 1.0.0

`postgres.credentials` was removed: the database credentials are now a prerequisite secret, the same one the `postgres` template requires on its own. Carrying the old key forward fails the render.

1.0.0 created the database secret itself, so **this upgrade deletes it**. Before upgrading, create a secret under a **new** name holding the values your database was initialized with — not new ones, or Guacamole loses its database connection:

```bash
cpln secret create-dictionary --name {release}-guacamole-db \
  --entry username=guacamole --entry password=YOUR_CURRENT_PASSWORD --entry database=guacamole
```

Then upgrade with `postgres.config.credentialsSecretName` set to that name and `postgres.credentials` removed. Your current values are in `postgres.credentials` of the 1.0.0 release, and also in the old secret (`cpln secret reveal my-guacamole-db-credentials -o yaml`, or the name you gave it) until the upgrade deletes it.

The new version of a workload may then wait about 10 minutes with `is not allowed to reveal the secret` in `get-deployments`, while access to the new secret propagates. The previous version keeps serving meanwhile, and it clears by itself. The admin secret is unchanged.

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

For the bucket, [cloud account](https://docs.controlplane.com/guides/create-cloud-account) and IAM policy setup — including the exact policy JSON per provider — follow the Backup Prerequisites section of the [`postgres` template docs](https://docs.controlplane.com/template-catalog/templates/postgres#backup-prerequisites).

## Important Notes

- **An upgrade does not drop the endpoint, but it does drop sessions.** A rolling upgrade served 112/112 requests with no failures, and a replica-down test served 204/204 — so the gateway itself stays reachable. Existing logins do not survive it: auth tokens are rejected afterwards and users must sign in again, and any open remote session ends. Reconnecting re-establishes it.
- **Create both secrets before installing.** A missing one wedges the deployment *silently*: `cpln logs` returns zero lines because no container ever starts. The only diagnostic is `status.versions[].message` from `cpln workload get-deployments {release}-guacamole --gvc {gvc} -o yaml`. It recovers on its own within about ten minutes of creating the secret (measured: 9 min 46 s), or immediately with a forced redeployment.
- **The admin password is applied on FIRST BOOT ONLY.** It seeds the database once, so rotating the secret afterwards does not change your login — verified by rotating it, forcing a redeployment, and confirming the original password still worked. Change the password in the Guacamole UI instead.
- **`guacadmin`/`guacadmin` is never valid here** — the stock account is renamed and re-hashed before Tomcat binds a port.
- **Single replica by design.** Guacamole keeps auth tokens in each Tomcat's memory with no cross-instance sharing, and the platform offers no session affinity, so a second replica would randomly log users out. Any restart — an upgrade, a replica reschedule, or rotating any referenced secret — **drops active desktop sessions and logs everyone out**. Nothing persisted is lost.
- **Public access is off by default.** This gateway fronts your internal machines, so expose it deliberately (see Connecting) rather than by default. Firewall changes take ~30 s to a few minutes to propagate.
- **Rotating the database secret needs `ALTER ROLE` first and a forced redeployment** (`cpln workload force-redeployment`) of both workloads — a running workload keeps the values it started with.
- **Connections, users and history survive reinstall** in the Postgres volumeset; delete that volumeset to wipe everything.

## Links

- [Guacamole manual](https://guacamole.apache.org/doc/gug/)
- [Installing Guacamole with Docker (environment variables)](https://guacamole.apache.org/doc/gug/guacamole-docker.html)
- [PostgreSQL authentication](https://guacamole.apache.org/doc/gug/postgresql-auth.html)
- [Administration: users, connections and permissions](https://guacamole.apache.org/doc/gug/administration.html)
- [GitHub](https://github.com/apache/guacamole-client)
