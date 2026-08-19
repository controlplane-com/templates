# PgDog — Maintainer Briefing

## What it is
- A **PostgreSQL connection pooler, load balancer and read/write splitter** (`ghcr.io/pgdogdev/pgdog`, Rust). It speaks the full Postgres wire protocol on **port 6432**, so applications change only their connection string.
- **It deploys no Postgres.** It points at an existing `postgres` / `postgres-highly-available` deployment or any external endpoint. Stateless: no volumeset, `type: standard`.
- Parses queries to route writes to `primary` backends and `SELECT`s to `replica` backends; several `[[databases]]` entries sharing a `name` form one cluster.

## Common use cases
- Cutting backend connection count for an app that opens far more connections than Postgres can serve.
- Read/write splitting across a primary and its replicas without app changes.
- One stable endpoint in front of a failover-capable Postgres.

## Architecture on cpln
| Resource | Purpose |
|---|---|
| workload `{release}-pgdog` (**standard**, 1 replica) | The proxy. Container command is `/bin/bash /scripts/start.sh`, not the image CMD |
| secret `{release}-pgdog-config` (opaque, plain) | The **static half** of `pgdog.toml`: `[general]` + every `[[databases]]` block. Mounted read-only at `/etc/pgdog/pgdog.base.toml` |
| secret `{release}-pgdog-startup` (opaque, plain) | Assembles `/tmp/pgdog/{pgdog,users}.toml` at boot, then `exec`s pgdog with `--config`/`--users` |
| identity + policy | `reveal` on the two chart secrets, the admin-password secret, and **one target per pooled user's credentials secret** (deduped, sorted) |
| *(user-created)* dictionary secret per pooled user | `username` + `password` |
| *(user-created)* opaque secret | The admin-database password |

## Key knobs (shipped 1.1.0 defaults)
`image` (`ghcr.io/pgdogdev/pgdog:v0.1.45`) | `resources.minCpu`/`.minMemory`/`.maxCpu`/`.maxMemory` (100m / 128Mi / 500m / 256Mi) | `replicas` (1) | `pooling.mode` (`transaction`) | `pooling.defaultPoolSize` (10) | `databases[]` (`my-pgdog-database` @ `my-postgres-workload:5432`, `primary`) | `users[].credentialsSecretName` (`my-pgdog-user-credentials`, **must exist before install**) | `users[].database` | `admin.passwordSecretName` (`my-pgdog-admin-password`, **must exist before install**) | `auth.type` (`scram`) | `publicAccess.enabled` (false) | `internalAccess.type` (`same-gvc`)

## Troubleshooting / considerations
- **Security history — 1.0.0 is dangerous.** It shipped `users[].password: mypassword` **and** `admin.password: changeme` as values defaults, published in this repo. Tier 2 of the 2026-08-14 catalog secrets audit. PgDog is the thing applications put in their connection strings, so the standalone-datastore ruling applies squarely and the bundled-plumbing exception does not.
- **THE LIST PROBLEM, and the shape chosen for it.** `users` is variable-length, so no fixed-key dictionary fits. 1.1.0 gives **each entry its own `credentialsSecretName`** naming a dictionary secret with `username` + `password`; the routing target (`database`) stays a value. Adding a pooled user = one more secret + one more entry, and the policy target list grows with it. The rejected alternative — one secret with keys like `myuser_password` — makes the key names depend on values, so renaming a user silently orphans a key and the policy/README cannot be stated concretely. **If another list-shaped credential comes up in the catalog, copy this.**
- **The username lives IN the secret, not in values.** That follows the catalog's take-username-with-password rule, and it buys something specific here: PgDog authenticates clients with that pair *and* opens backend connections with it, so it must be a real Postgres role — meaning you can point `credentialsSecretName` straight at the same secret the backing `postgres` template already uses.
- **PgDog has NO environment-variable interpolation** and reads credentials only from `pgdog.toml` / `users.toml` on disk. That is why 1.1.0 assembles those files in a startup script instead of rendering them into a secret. Confirmed against the docs and the upstream Dockerfile; do not "simplify" it back to a rendered `users.toml`.
- **The startup script assumes bash, and that assumption is READ FROM THE UPSTREAM DOCKERFILE, not measured.** `docker/Dockerfile.base-runtime` at tag `v0.1.45` is `ubuntu:latest` plus `postgresql-client`, so bash and psql should both be present — but the image was never run locally (Docker would not start on the build machine). First test round should confirm it before trusting anything else. A future distroless rebase upstream would break the script outright, so re-check the base on any version bump.
- **`[admin]` is appended AFTER `[[databases]]`** in the assembled `pgdog.toml`. Valid TOML (tables may appear in any order), and verified by parsing the generated file. It looks wrong at a glance; it is not.
- **TOML escaping is real, and `exit` inside `$(...)` is not.** Passwords may contain `"` or `\`, so every value goes through a `toml_str` escaper; a first draft validated inside that function, where `exit 1` only left the command substitution and execution continued with an empty value. Validation lives in `require()`, called before `toml_str`. Round-tripped through `tomllib` with `"` and `\` in both admin and user passwords.
- **A trailing newline is a hard failure, on purpose.** `echo "$pw" | cpln secret create-opaque` produces `"pass\n"`, which cannot be a single-line TOML value and would otherwise become a proxy that silently rejects every admin login. The script fails at boot naming the secret and telling the user to use `printf`. The README's command uses `printf '%s'`.
- **`cpu:minCpu` is 5:1 (500m:100m), inherited from 1.0.0.** Fine because the workload is `standard` — the 4:1 cap is stateful-only. **Never flip this workload to `stateful`**; the same numbers become a hard install failure.
- **Credential rotation needs a redeployment.** The config files are assembled once at container start, so editing a secret's contents changes nothing until `cpln workload force-redeployment`.
- **A missing prerequisite secret wedges silently** — zero lines from `cpln logs`; the only diagnostic is `status.versions[].message` from `cpln workload get-deployments` (plain `get` has no `versions` key). Documented in the README.
- **No `aws::ReadOnlyAccess` here** — the identity has no cloud bindings at all, so the catalog-wide sweep had nothing to remove.

## Status
- **NOT yet deploy-tested at 1.1.0.** Verified at build: bare render, a two-user render (both users resolve, both are policy targets), every `fail` guard, the startup script executed locally against the rendered base config with special characters and both failure paths, both generated TOML files parsed, and every README command run against the live org.
- A test round still owes, first of all, **that the image runs the script at all** (bash present, `--config`/`--users` accepted at v0.1.45) — then: the workload reaching `ready: true` with the assembled config, a client login through the pooler with a real backend, the admin database over `psql`, `publicAccess`, and the no-op `helm upgrade` drift gate (the workload is `standard`, so `rolloutOptions.maxUnavailableReplicas` should be **retained** — read back the stored spec rather than trusting that).
