# Redpanda — Maintainer Briefing

## What it is
- A **Kafka-compatible event streaming platform** (`redpandadata/redpanda`, C++/Seastar, no ZooKeeper). Speaks the Kafka wire protocol natively, so any Kafka client works unchanged.
- Ships the broker cluster **plus** Schema Registry (8081), an optional HTTP Proxy / pandaproxy (8082), the Admin API (9644), and **Redpanda Console** as a separate workload.
- Stateful: 1, 3 or 5 brokers (Raft quorum), one block volume each, peer discovery via `replicaDirect` per-replica DNS.

## Common use cases
- A Kafka drop-in for event streaming with a much smaller resource footprint than Kafka + ZooKeeper.
- CDC / event pipelines inside a GVC, with Schema Registry for Avro/Protobuf contracts.
- External producers/consumers over TLS via per-replica public subdomains (SNI routing).

## Architecture on cpln
| Resource | Purpose |
|---|---|
| workload `{release}-cluster` (**stateful**, `replicas` brokers) | The brokers. Container command is `/bin/bash /scripts/redpanda-init.sh`, not the image CMD |
| volumeset `{release}-data` | Topic data, one volume per broker. **No `snapshots` block** (unlike `kafka`) |
| secret `{release}-init` (opaque, plain) | Assembles `/etc/redpanda/redpanda.yaml` at boot from injected credentials, then `exec`s redpanda |
| workload `{release}-console` (**standard**, optional) | Redpanda Console UI on 8080. Command is `/bin/sh /scripts/console-init.sh` |
| secret `{release}-console-init` (opaque, plain) | Assembles `/tmp/redpanda-console/config.yaml` at boot, then `exec`s `/app/console` |
| identity + policy | `reveal` on the two script secrets plus **one target per user credentials secret** (deduped) |
| *(user-created)* dictionary secret per SASL user | `username` + `password` |
| domain (optional) | Only when external Kafka access or `redpanda_console.domain` is set |

## Key knobs (shipped 1.1.0 defaults)
`redpanda.replicas` (3; 1/3/5 only) | `redpanda.image` (`redpandadata/redpanda:v26.1.9`) | `cpu`/`memory`/`minCpu`/`minMemory` (1500m / 4Gi / 500m / 2Gi) | `smp` (1) | `reserveMemory` (1G) | `volume.initialCapacity` (10 GB) / `performanceClass` (`general-purpose-ssd`) / `fileSystemType` (`xfs`) | `auth.saslMechanism` (`SCRAM-SHA-256`) | `auth.users[].credentialsSecretName` (`my-redpanda-admin-credentials`, **must exist before install**) | `auth.superusers` (`[]`) | `acl.allowEveryoneIfNoAclFound` (false) | `listeners.pandaproxy.enabled` (false) | `firewall.internal_inboundAllowType` (`same-gvc`) | `redpanda_console.enabled` (true) | console `external_inboundAllowCIDR` (**commented out = closed**)

## Troubleshooting / considerations
- **Security history — 1.0.x is dangerous on two counts.** It shipped `auth.users[].password: "your-admin-password"` (a working value, banned `your-…` prefix) *and* published the console to `0.0.0.0/0`. Rows 18 of the 2026-08 catalog secrets audit.
- **The console has NO LOGIN in the build we ship, and that is a licensing fact, not a config gap.** Console authentication (OIDC and basic) and RBAC are Redpanda **Enterprise** features; unlicensed, Console runs in "static service account (no login)" mode — "There is no login screen. All users share the same access level." That shared session carries the **cluster superuser's** SASL credentials, so a visitor can create/delete topics, read and publish messages, and manage ACLs. There is no way to wire up a login in this chart; the only correct default is a closed firewall + `cpln port-forward`. Do not "add console auth" without a licence knob and a plan for it.
- **Credentials are prerequisite secrets, and `users` is a LIST** — so it copies pgdog's shape: one `credentialsSecretName` per entry naming a dictionary secret with `username` + `password`. `users[0]` is the cluster superuser that the console, the Schema Registry client and pandaproxy authenticate as.
- **Both credential paths are FILE paths, not env paths.** Redpanda reads SASL credentials from `redpanda.yaml`, and Console from its config file; neither file can interpolate a `cpln://` reference. Both files are therefore assembled by a startup script from injected env vars (`REDPANDA_USER_{i}_USERNAME|PASSWORD`, `REDPANDA_CONSOLE_USERNAME|PASSWORD`). Console *does* document env-var overrides of every config key, but the script needs no assumption about how a nested key maps to an env name — deliberate choice, do not "simplify" it back to a rendered config secret.
- **Credentials are emitted as single-quoted YAML scalars** via a `yaml_str` helper (`'` doubled), and `require()` rejects an empty or newline-bearing value at boot, naming the secret and key. Verified locally by running both rendered scripts with `ad'min: #x` / `p@ss"w:ord#{}` and parsing the generated YAML.
- **The 1.0.1 console workload set a `REDPANDA_CONSOLE_PASSWORD` env var that nothing read** — the password was rendered into the config file instead. Removed in 1.1.0; do not read the old env var as evidence Console consumes env credentials.
- **SASL users live in cluster metadata, not in the config.** They are created by the `postStart` hook on broker 0 (`rpk security user create … || true`). Editing a credentials secret afterwards does **not** rotate the user — it only changes what the internal clients present, which will then fail to authenticate. Rotate with `rpk security user update` and update the secret to match.
- **The broker Admin API (9644) is unauthenticated for READS AND WRITES** and open to the whole GVC under the default `same-gvc` firewall. Measured 2026-08-19: a neighbouring workload with no credentials **created and deleted a SASL user** through it. Any workload in the GVC is effectively a cluster admin. The readiness probe, the `postStart` hook and Console all rely on that. Turning on `http_basic` there would need probe/hook credentials too — a real follow-up, not a quiet edit.
- **`maxUnavailableReplicas` was REMOVED from the broker workload in 1.1.0.** The API silently drops it on a `stateful` workload, so 1.0.x had permanent rendered-vs-stored drift *and* implied a serialized rolling restart that was never in force. A rolling upgrade can restart brokers together — say so rather than promising otherwise.
- **`cpu:minCpu` is 3:1 (1500m:500m)** on a stateful workload, inside the 4:1 cap. Anyone raising `cpu` must raise `minCpu` with it.
- **The volumeset has no snapshot schedule** (kafka's log volumesets ship `schedule: 0 0 * * *`). Flagged by the knobs audit; deliberately NOT fixed in 1.1.0 to keep the security diff readable.
- **A missing prerequisite secret wedges silently** — zero lines from `cpln logs`; the only diagnostic is `status.versions[].message` from `cpln workload get-deployments` (plain `get` has no `versions` key). Documented in the README.
- **No `aws::ReadOnlyAccess`** — the identity has no cloud bindings at all, so the catalog-wide sweep had nothing to remove here.

## Status
- **NOT yet deploy-tested at 1.1.0.** Verified at build: bare render, a three-entry/duplicate-secret render (policy targets deduped), every `fail` guard, both rendered startup scripts executed locally (`bash -n`, `sh -n`, then run) with hostile credentials and both failure paths, generated broker and console YAML parsed, and every README command run against the live org.
- A test round owes: brokers reaching `ready: true` with the assembled config, `rpk` login end to end, Schema Registry basic auth, pandaproxy, Console reached over `cpln port-forward` and actually connecting to the brokers (this is the highest-risk item — `/bin/sh` and `/app/console` are read from the image config, not measured), a second SASL user, and the no-op `helm upgrade` drift gate on both workloads.
