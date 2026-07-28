# Gitea

Lightweight self-hosted Git service — repositories, pull requests, issues, and a built-in package registry — backed by PostgreSQL. This template deploys a single Gitea server with persistent storage, a Postgres database, public HTTPS access, and optional Git-over-SSH.

## Architecture

- **Gitea workload** — stateful, single replica; serves the web UI, Git-over-HTTPS, and the package registry on port 3000, plus the built-in SSH server on 2222.
- **Volumeset** (`/var/lib/gitea`, 20 GiB) — repositories, LFS objects, attachments, and SSH host keys.
- **PostgreSQL** — backing database, provisioned from the `postgres` template as a subchart (not bundled).
- **Env secret** (dictionary) — stable app secrets (`SECRET_KEY`, `INTERNAL_TOKEN`, `JWT_SECRET`) and admin credentials.
- **Bootstrap secret** (opaque) — admin-bootstrap wrapper script mounted into the container.
- **Identity + policy** — grant the workload `reveal` on exactly its two secrets plus the Postgres config secret.
- **Direct load balancer** (optional) — raw TCP port for Git-over-SSH, created only when `ssh.enabled` is true.

## Prerequisites

None for a default install. Change the admin password and the three security values before installing (see Important Notes).

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
    enabled: false
    maxCapacity: 200
    minFreePercentage: 10
    scalingFactor: 1.2
```

### Gitea admin and app secrets

```yaml
gitea:
  admin:
    username: gitea_admin
    password: change-me-admin-pass   # CHANGE before install — the first admin login
    email: admin@example.com
  security:
    # Stable per install — generate each with `gitea generate secret SECRET_KEY|INTERNAL_TOKEN|JWT_SECRET`.
    # Never rotate after install: changing SECRET_KEY makes existing encrypted data unreadable.
    secretKey: REPLACE_WITH_gitea_generate_secret_SECRET_KEY
    internalToken: REPLACE_WITH_gitea_generate_secret_INTERNAL_TOKEN
    jwtSecret: REPLACE_WITH_gitea_generate_secret_JWT_SECRET
  disableRegistration: true  # true = admin-invite only; false = open self-registration
```

### Access

```yaml
publicAccess:
  enabled: true  # HTTPS web UI + Git-over-HTTPS on the auto *.cpln.app endpoint

ssh:
  enabled: true      # false = Git-over-HTTPS only; no SSH port and the container SSH server is disabled
  externalPort: 22   # public port clients connect to (also advertised in SSH clone URLs)
  domain: ""         # advertised SSH host in clone URLs; empty = use the web domain

internalAccess:
  type: same-gvc # options: none, same-gvc, same-org, workload-list
  workloads:
    #- //gvc/GVC_NAME/workload/WORKLOAD_NAME
```

### Backing database

```yaml
postgres:
  image: postgres:18
  config:
    username: gitea
    password: change-me-db-pass
    database: gitea
  resources:
    minCpu: 200m
    minMemory: 256Mi
    maxCpu: 500m
    maxMemory: 512Mi
  volumeset:
    capacity: 10
  internalAccess:
    type: same-gvc
```

## Connecting

| Access | Endpoint | Notes |
|---|---|---|
| Web UI + Git-over-HTTPS + registry | `https://<canonical>.cpln.app` | Auto-assigned when `publicAccess.enabled`; find it under `status.canonicalEndpoint` (`cpln workload get <release>-gitea -o yaml`). |
| Git-over-SSH | direct-LB address on `ssh.externalPort` | Only when `ssh.enabled`; the reachable host is the `loadBalancer.direct` address from the workload status, not the web URL. |
| Internal (in-GVC) | `<release>-gitea.<gvc>.cpln.local:3000` | Reachable from other workloads per `internalAccess.type`. |
| Credentials | admin login | `gitea.admin.username` / `gitea.admin.password`. |

## Important Notes

- **Change `gitea.admin.password` and the three `gitea.security.*` values before installing** — the shipped defaults are illustrative placeholders and are insecure as-is.
- **Never rotate `gitea.security.secretKey` after install** — changing it makes all encrypted data (2FA secrets, tokens, mirror credentials) permanently unreadable. It is a value (not auto-generated) so `helm upgrade` keeps it stable.
- **SSH is optional.** Set `ssh.enabled: false` for Git-over-HTTPS only — no SSH port is exposed and the built-in SSH server is disabled. The advertised SSH host defaults to the web domain; set `ssh.domain` to a custom domain pointing at the direct LB for clean `git@` clone URLs.
- **Single replica only** — a rolling restart/upgrade incurs brief downtime. Do not raise the workload's scale above 1; replicas would each get separate repo volumes and corrupt state. HA is a planned follow-up.
- **Data lives on the volumeset** and survives redeploys under the same release name. Changing admin credentials after first boot must be done in the Gitea UI, not via values — the data directory keeps the original account. To fully reset, `helm uninstall` (deletes the volumeset) then reinstall.

## Links

- [Gitea documentation](https://docs.gitea.com/)
- [Configuration cheat sheet](https://docs.gitea.com/administration/config-cheat-sheet)
- [Install with Docker](https://docs.gitea.com/installation/install-with-docker)
- [Package registry](https://docs.gitea.com/usage/packages/overview)
- [Gitea on GitHub](https://github.com/go-gitea/gitea)
