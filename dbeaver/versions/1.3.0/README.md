# DBeaver CloudBeaver

CloudBeaver is a browser-based SQL client and administration console for PostgreSQL, MySQL, MongoDB, Oracle, SQL Server and many more. This template deploys a single CloudBeaver instance with a persistent workspace and an admin account bootstrapped from a secret you create.

## Architecture

- **Workload** (`stateful`) — CloudBeaver serving HTTP on port 8978.
- **Volume set** — 10 GiB `ext4` volume mounted at `/opt/cloudbeaver/workspace`, holding the server configuration, saved connections and users. A final snapshot is taken when the volume set is deleted and kept for 7 days; there are no scheduled snapshots.
- **Identity + policy** — grants the workload `reveal` on exactly the admin-password secret you created; nothing else.
- **No template-created secret** — the only credential lives in your own prerequisite secret.

## Prerequisites

**One opaque secret must exist BEFORE you install** — the deployment wedges waiting on it otherwise. Its value never passes through Helm values, so it never lands in the release.

**Admin password** (`admin.passwordSecretName`) — the password for the CloudBeaver admin login. Anyone who holds it can reach every database this console is connected to, so use your own strong password (8 characters or more):

```bash
printf '%s' 'YOUR-STRONG-PASSWORD' | cpln secret create-opaque --name my-dbeaver-admin-password --encoding plain -f -
```

Nothing else is required for a default install.

## Configuration

### Image

```yaml
image: dbeaver/cloudbeaver:25.2.0
```

### Admin login

```yaml
admin:
  name: cbadmin               # admin login name (not sensitive)
  passwordSecretName: my-dbeaver-admin-password # opaque secret holding the admin password; must EXIST BEFORE INSTALL
```

Both are applied only when the workspace is **first initialized** on the volume set. On later boots CloudBeaver reads the account it already stored, so changing either value has no effect — change the password in the CloudBeaver UI instead (Administration → Users).

### Access

```yaml
publicAccess:
  enabled: false              # true publishes the console, and its login, to the whole internet

internalAccess:
  type: same-gvc              # options: none, same-gvc, same-org, workload-list
  workloads: []               # used with workload-list, e.g. //gvc/GVC_NAME/workload/NAME
```

`publicAccess.enabled: false` is the default because this is a database administration console: with it off, the UI is reachable only from inside the GVC. Turn it on only if you accept a login form on the public internet, and give the admin account a strong password first.

### Resources and storage

```yaml
resources:
  cpu: 500m
  memory: 512Mi

volumeset:
  capacity: 10                # initial capacity in GiB (minimum is 10)
```

## Connecting

| Path | Address | Notes |
|---|---|---|
| Public UI | `https://<canonical-endpoint>` | Only when `publicAccess.enabled: true`. Read it from `status.canonicalEndpoint` in `cpln workload get <release>-dbeaver -o yaml`. |
| Internal UI / API | `http://<release>-dbeaver.<gvc>.cpln.local:8978` | Subject to `internalAccess.type`. |
| Admin credentials | `admin.name` (values) + the payload of your `admin.passwordSecretName` secret | The password is never stored in the Helm release. |

Add database connections from the UI after logging in. Point them at in-GVC hosts using internal DNS, e.g. `my-postgres.<gvc>.cpln.local:5432`.

## Important Notes

- **Create the admin-password secret before installing** — the workload wedges waiting on a secret that does not exist.
- **The admin password is only read at first boot.** Rotating the secret afterwards does nothing; change the password in the CloudBeaver UI, or uninstall (which deletes the volume set) and reinstall to re-bootstrap.
- **`publicAccess.enabled: true` puts a database console on the internet.** Anyone reaching it needs only the admin password to query every connected database. Prefer leaving it off and reaching the UI from inside the GVC.
- **Egress is closed.** The workload's outbound firewall is empty, so CloudBeaver can only connect to databases inside its own GVC — external or managed databases (RDS, Cloud SQL) are not reachable without editing the workload's firewall.
- **CloudBeaver logs the submitted password hash, and that hash is enough to log in.** At its default log level the hash appears in `cpln logs`, and the API accepts it in place of the password — so anyone who can read this workload's logs can authenticate as the admin. This is upstream behaviour, not something the chart sets; treat log access to this workload as equivalent to database access.
- **Access changes take up to a couple of minutes** to propagate after a `publicAccess` or `internalAccess` change (measured: 107-129 s).
- **The first `helm upgrade` after an install restarts the workload**, taking the UI down for roughly 30-60 seconds even when nothing about it changed. Later upgrades that change nothing do not.
- **Connections and users live on the volume set** and survive redeploys; `cpln helm uninstall` deletes it, taking every saved connection with it. There is no scheduled-backup feature — the only snapshot is the one taken on delete, kept 7 days.

## Links

- [CloudBeaver documentation](https://dbeaver.com/docs/cloudbeaver/)
- [Server configuration](https://dbeaver.com/docs/cloudbeaver/Server-configuration/)
- [Initial data configuration](https://dbeaver.com/docs/cloudbeaver/Initial-data-configuration/)
- [Admin password recovery](https://dbeaver.com/docs/cloudbeaver/Admin-Password-Recovery/)
- [CloudBeaver on GitHub](https://github.com/dbeaver/cloudbeaver)
