# Redis Multi-Location — Maintainer Briefing

## What it is

- **One** Redis master-replica cluster stretched across locations, with **Redis Sentinel** running one instance per location to monitor the master and vote a replacement when it is lost. Not a sharded Redis Cluster, and not one independent Redis per region.
- Redis is **BSD-3 / RSALv2+SSPLv1** depending on version; the shipped `redis:7.4` image is free to self-host with nothing to buy or register. `redis.serverCommand` exists so the same chart runs a Valkey image.
- The single-location `redis` template is untouched and remains the right choice for one location. This chart **requires ≥2 locations** and says so in the validation message.

## Common use cases

- A cache or session store that must survive losing a whole region.
- The Redis dependency of a multi-location app — from 2.1.0 it is consumable **as a subchart**, which is why the version exists (`grafana-multi-location` will consume it).
- A cross-region pub/sub or queue backend where a few seconds of failover is acceptable.

## Architecture on cpln

| Resource | Purpose |
|---|---|
| `gvc` (suppressed as a subchart via `.Chart.IsRoot`) | Multi-location GVC pinned to `global.gvc.locations`, `staticPlacement` sorted alphabetically |
| `workload` (stateful) `{release}-redis` | `redis.replicasPerLocation` instances in EVERY location, `replicaDirect: true` |
| `workload` (stateful) `{release}-sentinel` | Exactly 1 per location — the count is not a knob |
| `workload` (cron) `{release}-redis-backup` | Nightly RDB → S3/GCS, suspended everywhere except the FIRST location. Optional |
| `volumeset` ×2 | `/data` (20 GiB, autoscalable) and `/etc/sentinel` (10 GiB — Sentinel's own rewritten config) |
| `domain` ×2 | One TCP port per replica (`6380+i`, `26380+i`). Optional, needs a dedicated LB on the GVC |
| `identity` + `policy` ×2 | `reveal` on exactly the config secret plus whichever password secrets are in use |

- No probes on either tier, deliberately — a readiness probe failing during an election would withdraw the instance from discovery exactly when Sentinel needs it. Nothing to declare for probe drift as a result.
- Master election is resolved at container start: each Redis instance asks **any** Sentinel for the current master, and boots as master if that address is its own, else as `--replicaof`. Sentinel persists the elected master via `CONFIG REWRITE`, which is what the Sentinel volume set is for.

## Key knobs (defaults as shipped in 2.1.0)

| Knob | Default | Meaning |
|---|---|---|
| `global.gvc.name` | `redis-multi-location-gvc` | The GVC everything lands in — **not** `global.cpln.gvc`, which this chart ignores |
| `global.gvc.locations[]` | 3 AWS locations, `name` only | ≥2 required; **`replicas` here is rejected at render** |
| `redis.replicasPerLocation` | `2` | Redis instances in every location; total = this × locations |
| `redis.image` / `sentinel.image` | `redis:7.4` | |
| `redis.resources.cpu` / `.memory` | `200m` / `256Mi` | Limits only — bare names are correct per the 2026-08-06 ruling |
| `redis.passwordSecretName` | `""` | OPTIONAL prerequisite **opaque** secret; payload IS the password |
| `sentinel.passwordSecretName` | `""` | Same, independent — guards Sentinel itself |
| `redis.publicAccess.enabled` / `.address` | `false` / `redis.my-domain.com` | Raw TCP per replica through a `domain`; needs a **dedicated LB** (paid) |
| `firewall.internalAllowType` | `same-gvc` | Applies to both tiers |
| `backup.*` | disabled, `aws` | Bucket + cloud account + bucket-scoped IAM policy; see the README's Storage setup |

- `global.gvc` sits under `global` **on purpose**: it is the only channel that reaches an aliased subchart. `.Chart.IsRoot` gates `gvc.yaml` so a standalone install creates its GVC and a parent release renders exactly one. A Helm without `IsRoot` returns nil (falsy) and would silently render NO GVC — verify on `cpln helm` specifically.
- **Redis deliberately does NOT read `global.gvc.locations[].replicas`.** That shared field already means "Patroni members per location" to `postgres-multi-location`; letting Redis read it too would give one field two meanings in a single release. Setting it fails at render with that explanation.

## Troubleshooting / considerations

- **Passwords are prerequisite secrets, not values (new in 2.1.0).** They are appended to the config at container start from `cpln://secret/{name}.payload`, never written into the chart's own config secret — a password in `values.yaml` would sit in the Helm release, and this chart can put Redis on the public internet. **Rotating a secret takes effect only on restart**; restart Sentinel first, then Redis.
- **Two locations give NO automatic failover.** The Sentinel vote needs a majority of one-per-location instances, so 2 survives 0 losses, 3 survives 1, 5 survives 2. "Why didn't it fail over" usually has an arithmetic answer.
- **Never use `localOptions[].suspend` to simulate a location outage.** It permanently withdraws that location's endpoints from the other locations' service discovery while every status surface reads healthy, and only deleting and recreating the workload fixes it. Genuine crashes and replica reschedules recover in ~15–23 s.
- **A `helm upgrade` restarts every replica in every location at once** — the API drops `rolloutOptions.maxUnavailableReplicas` on a stateful workload, so nothing limits the rollout. Treat an upgrade as a planned write outage.
- **Allow ~2 minutes of cross-region convergence** after a cold deploy before believing a replica is unreachable; firewall changes take a further 30–150 s.
- **`--set global.gvc.locations[0].name=…` replaces the list wholesale.** Test list-shaped values with a `-f` values file, or you will trip the ≥2-locations guard instead of the guard you meant to test.
- **`createsGvc: true`.** Pointing a standalone install at an existing GVC makes Helm adopt it, and `helm uninstall` then **deletes** that GVC and everything in it.
- **Uninstall deletes the volume sets**, so data does not survive a reinstall under a new release name.

## Status

2.1.0 is a conventions + subchart-consumability release: `global.gvc` (clean break from `.Values.gvc`, no fallback shim), the `.Chart.IsRoot` GVC gate, prerequisite password secrets, sorted `locationLinks`, `terminationGracePeriodSeconds: 90`, `aws::ReadOnlyAccess` dropped from the backup identity, service-scoped placeholders, and a rewritten README. **Not yet deployed** — the failover, backup, public-access and drift rows all come from the pending test round, so treat the measured-behaviour numbers above as inherited from sibling multi-location templates rather than measured here.
