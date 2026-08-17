# DBeaver CloudBeaver — Maintainer Briefing

## What it is
- CloudBeaver Community Edition: the browser version of DBeaver — a SQL client and database administration console for PostgreSQL, MySQL/MariaDB, MongoDB, Oracle, SQL Server, SQLite, Redis and ~90 other drivers.
- Apache 2.0, free to self-host, no registration and no key. (The paid Team/Enterprise editions add SSO, RBAC and secret managers — none of that is in what we ship.)
- Template ships `dbeaver/cloudbeaver:25.2.0`, a single stateful instance with a persistent workspace.

## Common use cases
- A shared, browser-based query console for the databases a team already runs in a GVC — no per-developer client install, no per-developer network path to the database.
- Ad-hoc inspection and data fixes against `postgres`, `mysql`, `mongodb` and friends from the catalog.
- Import/export and cross-engine data transfer through the UI.

## Architecture on cpln
| Resource | Purpose |
|---|---|
| workload `{release}-dbeaver` (stateful, 1 replica) | CloudBeaver server + UI, port 8978 (HTTP) |
| volumeset `{release}-dbeaver-vs` (10 GiB, ext4) | Workspace at `/opt/cloudbeaver/workspace` — server config, saved connections, users. Final snapshot kept 7 days |
| identity `{release}-dbeaver-identity` | Principal for the reveal grant |
| policy `{release}-dbeaver-policy` | `reveal` on **only** the user's admin-password secret |

- **The chart creates no secret of its own.** The single credential is a user-created prerequisite opaque secret (`admin.passwordSecretName`), read as `cpln://secret/{name}.payload`.
- Private by default: `publicAccess.enabled: false` → external `inboundAllowCIDR: []`; internal `same-gvc`.
- Egress is closed (`outboundAllowCIDR: []`) — inherited from 1.0.0 and deliberately left alone.

## Key knobs (shipped defaults)
`image` (`dbeaver/cloudbeaver:25.2.0`) | `admin.name` (`cbadmin`) | `admin.passwordSecretName` (`my-dbeaver-admin-password`, must exist before install) | `publicAccess.enabled` (**false**) | `internalAccess.type` (`same-gvc`) | `resources.cpu`/`.memory` (500m / 512Mi) | `volumeset.capacity` (10 GiB)

## Troubleshooting / considerations
- **The admin credentials are first-boot only.** `CB_ADMIN_NAME`/`CB_ADMIN_PASSWORD` are consumed when CloudBeaver initializes an empty workspace. Once `/opt/cloudbeaver/workspace` is configured on the volumeset, both are ignored — rotating the secret does nothing, and neither does changing `admin.name`. Change the password in the UI (Administration → Users), or uninstall (deleting the volumeset) and reinstall. If a user reports "I changed the secret and the old password still works", this is why.
- **Security history — 1.2.1 and earlier are dangerous.** They shipped `admin.password: Password123` in `values.yaml` and hardcoded `inboundAllowCIDR: [0.0.0.0/0]` with no knob: a known username/password on a database console that is public and cannot be made private. Anyone upgrading from ≤1.2.1 should treat the old admin password as compromised and change it in the UI (upgrading alone will not change it — see the first-boot note). This was tier 1 of the 2026-08-14 catalog secrets audit.
- **Egress is closed, so external databases are unreachable.** `outboundAllowCIDR: []` means CloudBeaver can only connect to hosts inside its own GVC. Managed databases (RDS, Cloud SQL, Atlas) will fail to connect with no obvious explanation. There is deliberately no knob for this yet — a user who needs it must widen the workload firewall by hand. Worth a knob if it comes up.
- **`CB_SERVER_URL` is the internal `cpln.local` address, always** — including when `publicAccess.enabled: true`. It has been that way since 1.0.0 and the UI works, because CloudBeaver's login flow uses relative URLs. If an SSO or absolute-link feature is ever added, this is the first thing to look at (and the fix is to derive it from `CPLN_GLOBAL_ENDPOINT` in a boot wrapper, per the grafana precedent — never to hand-build the hostname).
- **No probes.** The workload has no readiness or liveness probe, so `ready: true` means the container started, not that CloudBeaver is serving. Inherited from 1.0.0; a `GET /` readiness probe on 8978 is the obvious follow-up.
- **Autoscaling is `metric: cpu`, minScale 1 / maxScale 3, on a stateful workload with one volumeset.** Scaling past one replica has never been tested and CloudBeaver has no clustering — treat this template as single-instance regardless of what the autoscaling block says.
- **A workspace survives redeploys but not uninstall.** `cpln helm uninstall` deletes the volumeset and every saved connection with it; there is no backup feature.
- **Firewall changes take 30–150 s to propagate.** A user flipping `publicAccess` and testing immediately will see stale behavior.

## Two traps the 1.3.0 test round measured

- **The admin password cannot be rotated.** `CB_ADMIN_PASSWORD` is read only when an empty workspace
  initialises. Measured: after rotating the secret and restarting, the container held the NEW value
  (hash proven in-container) while the OLD password still logged in and the new one was rejected. So
  the prerequisite secret protects the *initial* credential only — the remedy is the CloudBeaver UI,
  or uninstall (which deletes the volume set) and reinstall.
- **CloudBeaver logs the submitted password hash at its default level, and the API accepts that hash
  in place of the password.** It appears in `cpln logs`. Anyone with log access to this workload can
  authenticate as admin — pass-the-hash. Upstream image behaviour, not chart-set, and NOT closed by
  moving the password to a prerequisite secret. Worth knowing before recommending this template to
  anyone with broad org log access.
- **Egress is closed** (`outboundAllowCIDR: []`, inherited since 1.0.0). Measured: `rc=35` at TLS
  handshake to public hosts while a control workload in the same GVC reached them fine. RDS, Cloud SQL
  and Atlas are unreachable, with no values knob. For a database GUI this rules out the most common
  use case — the obvious candidate for a follow-up version.
