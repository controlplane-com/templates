# Gitea

Lightweight self-hosted Git service — repositories, pull requests, issues, and a built-in package registry — backed by PostgreSQL. This template deploys a single Gitea server with persistent storage, a Postgres database, public HTTPS access, and optional Git-over-SSH.

## Architecture

- **Gitea workload** — stateful, single replica; serves the web UI, Git-over-HTTPS, and the package registry on port 3000, plus the built-in SSH server on 2222.
- **Volumeset** (`/var/lib/gitea`, 20 GiB) — repositories, LFS objects, attachments, and SSH host keys.
- **PostgreSQL** — backing database, provisioned from the `postgres` template as a subchart (not bundled).
- **Auth secret** (dictionary) — *not created by this template*; you create it before install and reference it by name. Holds the admin login and the three long-lived signing keys.
- **Database credentials secret** (dictionary) — built by *this* template from `postgres.credentials.*` and handed to the Postgres store by name. Nothing for you to create.
- **Bootstrap secret** (opaque) — admin-bootstrap wrapper script mounted into the container.
- **Identity + policy** — grant the workload `reveal` on exactly three secrets: your auth secret, the bootstrap script, and the database credentials secret.
- **Direct load balancer** (optional) — raw TCP port for Git-over-SSH, created only when `ssh.enabled` is true.

## Prerequisites

**One dictionary secret must exist BEFORE you install.** These are credentials and long-lived key material, so they are a prerequisite secret rather than values — a value would sit in plaintext in the Helm release for the life of the install, and the admin login is on a public endpoint.

Create it with exactly these six keys:

```bash
cpln secret create-dictionary --name my-gitea-auth \
  --entry adminUsername=gitea_admin \
  --entry adminEmail=admin@example.com \
  --entry adminPassword="$(openssl rand -hex 24)" \
  --entry secretKey="$(openssl rand -hex 32)" \
  --entry internalToken="$(openssl rand -hex 32)" \
  --entry jwtSecret="$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=')"
```

Then set `gitea.auth.secretName` to that name. Read it back later with `cpln secret reveal my-gitea-auth -o yaml` (the `-o yaml` is required — the default output does not show the values).

| Key | What it is |
|---|---|
| `adminUsername` / `adminPassword` / `adminEmail` | The first site-admin account, created at boot. The login form is on the public endpoint. |
| `secretKey` | Encrypts 2FA secrets, access tokens and mirror credentials. Any random string; 64 characters is what Gitea's own generator produces. |
| `internalToken` | Shared token for Gitea's internal API. Any random string. |
| `jwtSecret` | Signs OAuth2 tokens. **Must be base64url of exactly 32 bytes** — Gitea rejects any other length, which is why the command pipes through `tr`. |

**The three key material entries cannot be rotated.** Changing `secretKey` makes every existing 2FA secret, access token and mirror credential permanently unreadable; changing `jwtSecret` invalidates issued OAuth2 tokens. Set them once and keep them for the life of the install.

**If the secret does not exist at install time the deployment wedges silently.** `cpln logs` returns zero lines — the container never starts, so there is nothing to log. The only diagnostic is `status.versions[].message` in `cpln workload get-deployments <release>-gitea --gvc <gvc> -o yaml` (note **`get-deployments`** — plain `cpln workload get` has no `versions` key). Create the missing secret and it recovers on its own in roughly 6–8 minutes, or clear it immediately with `cpln workload force-redeployment <release>-gitea --gvc <gvc>` (~90 s).

**The database password is not a prerequisite** — it is bundled plumbing no human types elsewhere, so this template creates that secret for you from `postgres.credentials.*`.

## Configuration

### Image and resources

```yaml
image: gitea/gitea:1.27.1-rootless  # rootless variant: UID 1000, built-in SSH on 2222
resources:
  minCpu: 250m
  minMemory: 512Mi
  maxCpu: 1000m
  maxMemory: 1024Mi
```

### Storage

```yaml
volumeset:
  capacity: 20 # initial capacity in GiB (minimum is 10)
  autoscaling:
    enabled: false # set to true to enable volume autoscaling
    maxCapacity: 200 # maximum capacity in GiB when autoscaling is enabled
    minFreePercentage: 10 # minimum free percentage that triggers scaling
    scalingFactor: 1.2 # how much to grow the volume when scaling is triggered
```

### Gitea

```yaml
gitea:
  auth:
    secretName: my-gitea-auth   # PREREQUISITE dictionary secret — must exist BEFORE install
  disableRegistration: true     # true = admin-invite only; false = open self-registration
```

### Access

```yaml
publicAccess:
  enabled: true  # HTTPS web UI + Git-over-HTTPS on the auto *.cpln.app endpoint

ssh:
  enabled: false     # false = Git-over-HTTPS only (public web UI stays up); true = public SSH takes the endpoint
  externalPort: 22   # public port clients connect to (also advertised in SSH clone URLs)
  domain: ""         # advertised SSH host in clone URLs; empty = use the web domain

internalAccess: # internal firewall scope
  type: same-gvc # options: none, same-gvc, same-org, workload-list
  workloads:  # only used when type is same-gvc or workload-list
    #- //gvc/GVC_NAME/workload/WORKLOAD_NAME
```

Public access is **on** by default: Git-over-HTTPS clone and push from laptops and CI is the point of the service, and the admin login is a credential you created, not a published default. Set `publicAccess.enabled: false` to keep Gitea inside the GVC; reach the UI with `cpln port-forward {release}-gitea 3000:3000 --gvc {gvc}`. A firewall change takes 30 s to a few minutes to propagate, so re-test rather than trusting the first response.

### Backing database

Bundled plumbing — it serves Gitea only and is unreachable from outside the GVC, but the password is used as-is, so change it before installing.

```yaml
postgres:
  image: postgres:18
  credentials:       # this template builds the DB credential secret from these
    username: gitea
    password: change-me-gitea-db
    database: gitea
  config:
    # name of the dictionary secret this template CREATES and Postgres reads;
    # secret names are org-wide, so a second release on this name is refused at install
    credentialsSecretName: my-gitea-db-credentials
  resources:
    minCpu: 200m
    minMemory: 256Mi
    maxCpu: 500m
    maxMemory: 512Mi
  volumeset:
    capacity: 10 # initial capacity in GiB (minimum is 10)
    autoscaling:
      enabled: false
      maxCapacity: 100
      minFreePercentage: 10
      scalingFactor: 1.2
  internalAccess:
    type: same-gvc
```

## Connecting

| Access | Endpoint | Notes |
|---|---|---|
| Web UI + Git-over-HTTPS + registry | `https://<canonical>.cpln.app` | Auto-assigned when `publicAccess.enabled`; find it under `status.canonicalEndpoint` (`cpln workload get <release>-gitea -o yaml`). |
| Local access (public access off) | `cpln port-forward <release>-gitea 3000:3000 --gvc <gvc>` then open `http://localhost:3000` | Tunnels through Control Plane; independent of the firewall. |
| Git-over-SSH | direct-LB address on `ssh.externalPort` | Only when `ssh.enabled`; the reachable host is the `loadBalancer.direct` address from the workload status, not the web URL. |
| Internal (in-GVC) | `<release>-gitea.<gvc>.cpln.local:3000` | Reachable from other workloads per `internalAccess.type`. |
| Admin login | `adminUsername` / `adminPassword` | From your `gitea.auth.secretName` secret — `cpln secret reveal my-gitea-auth -o yaml`. |
| Database credentials | `username` / `password` / `database` | Keys of the secret named by `postgres.config.credentialsSecretName`, created by this template. |

## Upgrading from 1.1.0

The bundled Postgres moved to the `postgres` 3.4.1 template, which no longer takes
database credentials as values. Gitea absorbed that change rather than passing it on, so
**there is no new prerequisite** — only a rename:

| Removed key | Replacement |
|---|---|
| `postgres.config.username` | `postgres.credentials.username` |
| `postgres.config.password` | `postgres.credentials.password` |
| `postgres.config.database` | `postgres.credentials.database` |

Carrying an old key forward fails the render with the **Postgres template's** message,
which tells you to create a dictionary secret yourself. Ignore that advice here — this
template creates it. Move the three keys and you are done; the auth secret is unchanged.

## Upgrading from 1.0.0

The admin credentials and the three security values moved out of `values.yaml` into the prerequisite dictionary secret above. Carrying any of the old keys forward fails the render with a message naming its replacement; there are no compatibility fallbacks.

| Removed key | Now a key in the auth secret |
|---|---|
| `gitea.admin.username` / `.password` / `.email` | `adminUsername` / `adminPassword` / `adminEmail` |
| `gitea.security.secretKey` | `secretKey` |
| `gitea.security.internalToken` | `internalToken` |
| `gitea.security.jwtSecret` | `jwtSecret` |

**Put your EXISTING values into the secret — do not generate new ones.** The three security values cannot be rotated on a live install: a new `secretKey` makes every stored 2FA secret, access token and mirror credential unreadable, and a new `jwtSecret` invalidates issued OAuth2 tokens.

If your install is still carrying the published 1.0.0 defaults (`change-me-admin-pass` and the `REPLACE_WITH_…` security values), everything it has encrypted is protected by values printed in a public repository. Rotating them is destructive as described above, so the safe path is to stand up a fresh 1.1.0 install with new key material and migrate repositories to it, rather than swapping the keys under the existing one. At minimum, change the admin password in the Gitea UI immediately.

## Backing up the bundled database

The bundled PostgreSQL is the `postgres` template, so **every backup option that template has is
already available here** — there is nothing extra to install and no separate release to manage.
It is off by default:

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

Enabling it adds one `cron` workload that runs `pg_dumpall` and uploads a gzipped dump. The
bundled database's identity picks up the bucket-scoped policy automatically.

For the bucket, cloud account and IAM policy setup — including the exact policy JSON per
provider — follow the Storage setup section of the [`postgres` template README](../../../postgres).

**A zero-length backup object is a failed run, not a backup.** If the dump cannot reach the
database, the upload still writes a ~20-byte empty gzip under a normal timestamped filename.
Check the object size before restoring from one.

## Important Notes

- **Create the auth secret before installing.** A missing prerequisite secret leaves the workload waiting on something that does not exist, with zero log lines — see Prerequisites for how to diagnose it.
- **Give each gitea release its own `postgres.config.credentialsSecretName`.** Secret names are org-wide, so a second release left on the default name is **refused at install** — `The resource '…' cannot be updated because it is being managed by a different release` — and creates nothing. Nothing is shared or overwritten, and the first release is unaffected; you simply cannot install the second until you give it a distinct name.
- **Never rotate `secretKey` or `jwtSecret` after install** — changing them makes existing encrypted data (2FA secrets, tokens, mirror credentials) permanently unreadable and invalidates issued OAuth2 tokens.
- **Public SSH and the public web UI cannot share the endpoint — SSH is OFF by default.** A workload has one `*.cpln.app` canonical endpoint, and it is either the L7 HTTPS ingress (web UI + Git-over-HTTPS) or a raw-TCP load balancer (SSH), not both. Enable `ssh.enabled: true` only if you either (a) serve the web UI through a custom domain, or (b) only need Git-over-SSH — turning it on repoints the public endpoint to SSH on port 22 and the public web UI on 443 becomes unreachable.
- **Single replica only** — a rolling restart/upgrade incurs brief downtime. Do not raise the workload's scale above 1; replicas would each get separate repo volumes and corrupt state.
- **The first `helm upgrade` after an install re-applies the bundled Postgres**, so expect Gitea to be briefly unreachable while the database restarts; later upgrades do not do this.
- **Data lives on the volumeset** and survives redeploys under the same release name. Changing the admin password after first boot must be done in the Gitea UI — the data directory keeps the original account, so editing the secret does not change the login. To fully reset, `helm uninstall` (deletes the volumeset) then reinstall.

## Links

- [Gitea documentation](https://docs.gitea.com/)
- [Configuration cheat sheet](https://docs.gitea.com/administration/config-cheat-sheet)
- [Install with Docker](https://docs.gitea.com/installation/install-with-docker)
- [Package registry](https://docs.gitea.com/usage/packages/overview)
- [Gitea on GitHub](https://github.com/go-gitea/gitea)
