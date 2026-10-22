# NATS — maintainer briefing

**What it is.** A NATS cluster — one cluster per location, joined into a super cluster by NATS gateways
when more than one location is configured — with optional JetStream persistence. NATS is Apache-2.0;
clustering, gateways and JetStream are all in the free product, nothing is enterprise-gated.

**3.0.0 is the GVC-removal conversion.** 2.x created its own GVC; 3.0.0 deploys into the GVC you install
into and refuses to render if the 2.x `gvc` key is still present. It is standalone — nothing vendors it,
and it vendors nothing.

**3.1.0 adds optional authentication** (`auth.credentialsSecretName`, default off). One username/password
from a user-created dictionary secret guards clients, WebSocket, routes and gateways; the credential never
reaches the Helm release. Auth off renders byte-identical to 3.0.0 apart from the chart-version tags.

**Common use cases.** Low-latency service-to-service messaging, request/reply between services, and
durable streams via JetStream where a full Kafka deployment is more than the workload needs.

## Architecture on cpln

| Resource | Notes |
|---|---|
| `workload` (stateful) `{release}-nats` | One NATS cluster per location; `replicaDirect: true`, which the peer DNS depends on |
| `volumeset` `{release}-nats-vs` | `/data/nats` JetStream store, per replica. Only when `jetstream.enabled` |
| `secret` `{release}-nats-secret` | `start.sh` — generates each server's `nats.conf` at boot |
| `secret` `{release}-nats-extra-data` | Only when `nats_extra_config` is non-empty |
| `identity` + `policy` `{release}-nats-policy` | `reveal` on this release's secrets, plus the user's credentials secret when auth is on |
| `policy` `{release}-nats-gvc-policy` | **New in 3.0.0.** `view` on exactly the one install GVC, for the boot-time location check. Never `target: all` |

- **No `kind: gvc`.** `createsGvc: false`; every resource lands in `.Values.global.cpln.gvc`.
- Ports: `4222` clients, `6222` routes (within a location), `7222` gateways (between locations, published
  only for a multi-location release), `8080` WebSocket, `8222` monitoring (bound but not published).
  All TCP — NATS clustering is not gossip, so the platform's no-UDP limit never comes into it.
- Peers are addressed as `replica-N.{workload}.{location}.${CPLN_GVC}.cpln.local`. **The GVC comes from
  the runtime built-in now, not from Helm**, so it cannot drift from where the workload actually runs.
- **No probes**, as in 2.x. Note the consequence: `ready: true` says nothing about whether routes formed.

## Key knobs (shipped defaults)

| Knob | Default | Notes |
|---|---|---|
| `locations[]` | 1 × `aws-us-east-1`, `replicas: 3` | **Was `gvc.locations`, 3 locations × 2, in 2.x.** Must already exist in the GVC |
| `image` | `nats:2.11.6-alpine` | Pinned. **No curl in this image** — the boot GVC check uses busybox wget |
| `resources` | `100m` / `256Mi` | Small; raise for real throughput |
| `nats_defaults.*.port` | 4222 / 6222 / 7222 / 8080 | Validated at render against reserved ports and collisions |
| `allowCIDR` | `[]` | Closed by default — no public WebSocket exposure until ranges are added. See the security note below |
| `jetstream.enabled` | `false` | Off means in-flight only; an unsubscribed message is gone |
| `volumeset.capacity` | `10` GiB per replica | Only used when JetStream is on |
| `auth.credentialsSecretName` | `""` | Off. A dictionary secret with `username`, `password`; prerequisite, created by the user |
| `nats_extra_config` | `""` | Injected verbatim; stored in the release, so never credentials |
| `internalAccess.type` | `same-gvc` | Also governs how servers reach each other |

## The three-layer GVC defence (3.0.0)

1. **Render-time `fail`** if `.Values.gvc` is present — makes the destructive 2.x→3.0.0 upgrade impossible.
2. **`defaultOptions.minScale/maxScale: 0`**, with `localOptions` supplying the real per-location counts,
   so an undeclared GVC location starts nothing.
3. **Boot-time GVC read** (`$CPLN_ENDPOINT/org/$CPLN_ORG/gvc/$CPLN_GVC`) for the direction the platform
   does not validate at all — a `localOptions` location the GVC lacks is stored and inert.

## How authentication is wired (3.1.0)

- The secret's keys arrive as env vars `NATS_AUTH_USER`/`NATS_AUTH_PASSWORD` (`cpln://secret/...`); `start.sh`
  writes them into `nats.conf` as **escaped double-quoted strings**, then unsets them. **Not `$VAR` config
  references**: nats-server re-parses a referenced env value as config — measured on 2.11.6, `123456` and `12k`
  crash it (nil pointer), a space or `}` fails to parse, and `#` silently truncates the password.
- The same credential goes in the top-level, `cluster` and `gateway` `authorization` blocks, AND
  percent-encoded into every route and gateway URL. **Routes do not fall back to the cluster block's
  credentials** — with bare URLs every route was refused `Authentication Failure` (measured). Without route
  auth, a rogue server dialling 6222 received published messages (measured with auth off; refused with it on).
- WebSocket inherits the top-level authorization (no separate block needed; measured).
- Boot refuses (FATAL) a missing/empty key, a newline, or a bcrypt-looking (`$2…$`) password — servers must
  present the plain password to each other.
- Render-time `fail` (`nats.validateAuth`) refuses an `authorization`/`accounts` block in `nats_extra_config`
  while auth is on. With auth off such a block still works (pre-3.1.0 behaviour) — the wizard only advises.
- Single user by design for v1: one shared credential, full permissions. Per-user permissions/accounts (or
  nkeys/JWT) would be the next step and need an accounts design, not a list knob.

## Troubleshooting traps

- **Never `helm upgrade` a 2.x release onto 3.0.0.** The upgrade drops `kind: gvc` and Helm prunes it,
  destroying the GVC and everything in it — measured at 6 s on a sibling template, while printing
  `upgraded successfully`. The render-time guard blocks the normal path; migrate to a new release instead.
- **`internalAccess` governs route and gateway traffic, not just clients.** A `workload-list` naming only
  clients cuts the cluster off from itself: routes never establish, JetStream loses its meta group, and
  every replica still reports `ready: true`. The chart adds its own workload to the list automatically.
  `internalAccess: none` is refused outright for any multi-server deployment.
- **JetStream on exactly 2 servers is refused at render.** Quorum is 2 of 2, so losing either takes
  JetStream down completely — strictly worse than one standalone server. Use 1, or 3 or more.
  A 3-server roster with one location missing from the GVC becomes this shape at runtime; the startup
  script warns when it sees exactly 2 servers present.
- **The boot check is asymmetric by design.** With JetStream ON, a *fresh* server exits on a missing
  location and an *initialised* one only warns. With JetStream OFF it only ever warns — a stateless server
  is rescheduled routinely, and exiting would take a live, working bus offline the next time a replica
  moved. Check A (running in a location that is not configured at all) always exits.
- **Auth is off and `allowCIDR` is `[]` by default**, so a default install is closed. Adding ranges without
  auth publishes an unauthenticated bus — measured handing an anonymous client the cluster name, every server
  name and their private IPs. The wizard blocks that on install (warning) and advises on upgrade.
- **Missing credentials secret = silent wedge** (no logs); `get-deployments` → `status.versions[].message`.
  Turning auth on during an upgrade adds a new reveal grant, so the CLAUDE.md edge-cache stall may apply
  (wait ~5 min, then `force-redeployment`) — not yet measured on nats.
- **Rotating the password needs `cpln workload force-redeployment`**; until then the old one keeps working.
- **`nats_extra_config` is injected verbatim.** A syntax error there is a container that will not start,
  not a render failure, so it is easy to mistake for an infrastructure problem.
- **Cross-region gateway traffic is billed.** A single-location install is the default for that reason.

## Resolved: the public-access default

2.x shipped `allowCIDR: [0.0.0.0/0]` with no NATS authentication, so a default install published an open
message bus. 3.0.0 ships `allowCIDR: []` (the shipped `values.yaml`); the README and the `values.yaml`
comment tell users to add ranges only with authentication on — since 3.1.0 via `auth.credentialsSecretName`
(earlier versions pointed at an `authorization` block in `nats_extra_config`, which put the password in the release).
