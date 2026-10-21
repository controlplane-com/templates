# Control Plane Task Runner — Maintainer Briefing

## What it is
- An **HTTP task queue and scheduler** in the shape of Google Cloud Tasks (`controlplanecorporation/cpln-task-runner`, Go, Alpine, ~6 MB binary). Ours, not third-party.
- One image, two roles selected by `MODE`: **api** (accepts enqueues, serves `/admin/*`) and **worker** (delivers tasks to their target URL, with retries, delays, a circuit breaker and per-client rate limits).
- Persists to a **bundled Redis + Sentinel** subchart (`redis` 3.4.2), reached at `{release}-sentinel…:26379` with master name `mymaster`.

## Common use cases
- Reliable webhook / callback delivery with retries and backoff, without running Cloud Tasks.
- Deferred and scheduled work offloaded from a request path.
- Per-tenant rate limiting of outbound calls (free / basic / premium / enterprise tiers).

## Architecture on cpln
| Resource | Purpose |
|---|---|
| workload `{release}-task-runner-api` (**serverless**, 1–3) | HTTP API on 8080. `public.enabled: false` by default since 1.3.0; internal `same-gvc` |
| workload `{release}-task-runner-worker` (**serverless**, 1–5) | Delivery. Internal only; outbound `0.0.0.0/0` |
| *(user-created)* dictionary secret, since 1.4.0 | Redis (`password`) + Sentinel (`sentinelPassword`) passwords, named by `redis.redis.auth.fromSecret.name` / `redis.sentinel.auth.fromSecret.name` (default both `my-cpln-task-runner-redis-credentials`). Read by the redis subchart AND the API/Worker env. Until 1.3.0 the chart created `task-runner-secrets` from plain values — **org-level and NOT release-prefixed**, so two 1.3.0 installs in one org collided on it |
| identity + policy | `reveal` on the Redis secret(s) **and** the admin-key secret |
| *(user-created)* opaque secret | The admin API key — payload IS the key |
| redis subchart | Redis + Sentinel workloads, volumes, their own identity/policy |

## Key knobs (shipped 1.4.0 defaults)
`image` (`controlplanecorporation/cpln-task-runner:0.4`) | `api.public.enabled` (**false** as of 1.3.0) | `api.admin.apiKeySecretName` (`my-cpln-task-runner-admin-key`, **must exist before install**) | `api.resources.cpu/memory` (500m / 512Mi) | `api.replicas` (1–3) | `worker.replicas` (1–5) | `worker.resources` (1 / 1Gi) | `worker.env.concurrency` (10) | `worker.env.taskTimeoutSec` (1800) | `worker.env.maxRetry` (5) | `worker.env.allowPrivateUrls` (false) | `redis.{redis,sentinel}.auth.fromSecret.name` (`my-cpln-task-runner-redis-credentials`, **must exist before install**) | `…passwordKey` (`password` / `sentinelPassword`) | `…fromSecret.enabled` (must stay `true`, chart fails otherwise) | `redis.{redis,sentinel}.persistence.enabled` (true)

## Troubleshooting / considerations
- **Security history — 1.2.x is the most exposed default in the 2026-08 audit (row 22).** `api.env.adminApiKey: ""` meant "disable admin auth", and `api.public.enabled` was `true`, so `/admin/*` — create/edit/delete clients and rate-limit tiers — was open to the internet on a default install. `redisPassword`/`sentinelPassword` were both the working value `mypassword`.
- **A GUARD, not a default flip, was the first 1.3.0 fix (superseded the same day: `public.enabled` was ALSO flipped to `false` after the enqueue finding below).** Flipping `public.enabled` to false would break the template's actual purpose (receiving task submissions from outside the GVC) while leaving an empty admin key legal. The chart instead makes the key a required prerequisite secret and **fails the render** when `apiKeySecretName` is empty while `public.enabled` is true. An empty key stays legal for an internal-only install, which is a deliberate act the user has to spell out.
- **Behaviour of an empty key is confirmed from the binary, not assumed.** The image was inspected via the registry API (Docker was broken on the build machine): the binary contains `Admin API key not configured - admin endpoints are unprotected`, plus `X-Admin-Key`, `ADMIN_API_KEY` and the routes `/v1/enqueue`, `/admin/clients{,/set,/get,/delete}`, `/admin/tiers`, `/health/{live,ready,detailed}`.
- **OPEN PRODUCT BUG — `/v1/enqueue` has NO authentication and AUTO-REGISTERS unknown clients. Fix belongs in the app, not this template.** An earlier draft of this briefing said enqueue "rejects an unregistered `client_id`, so the client ID is the whole access control". **Measured 2026-08-19 and that is false** — posting a never-seen ID returns `status: enqueued` *and creates the client*:

  ```
  POST /v1/enqueue {"client_id":"totally-unregistered-xyz",...}  → {"status":"enqueued",...}
  GET /admin/clients → that client now exists, created BY the enqueue
  ```

  So nothing gates the queue. With public access on, any stranger can make a worker issue arbitrary outbound HTTP with a method, headers and body of their choosing — and with `allowPrivateUrls: true`, at internal addresses. It also means the admin API's client management provides no security at all, since anyone can self-provision.

  **`api.public.enabled` therefore defaults to `false` as of 1.3.0.** That is a workaround, not a fix: receiving tasks from outside the GVC is the template's purpose, so the private default materially reduces what it is for.

  **`controlplanecorporation/cpln-task-runner` is OUR image**, so unlike a third-party limitation this is fixable at source: `/v1/enqueue` needs a per-client key checked against the existing client registry. **Maintainer decision 2026-08-19: keep the private default and fix the app.** Revisit `public.enabled: true` once enqueue authenticates. Related and pointing the same way: `/metrics` is also public and unauthenticated, and its labels enumerate every `client_id`.
- **1.4.0: the Redis + Sentinel passwords became a prerequisite secret (work item 5284, "no credential is ever a Helm value").** This reverses the 1.3.0 position that a bundled-Redis password could stay a value as internal plumbing. `createSecret`, `secretName`, `redis.redisPassword`, `redis.sentinelPassword` are removed and the chart `fail`s if any is present; it also refuses the name `task-runner-secrets` (the upgrade from 1.3.0 deletes the chart-created secret of that name). The redis chart (3.4.2) was NOT changed — its existing `auth.fromSecret` (name + passwordKey) carries it. Validation lives in `templates/validate/redis/auth.yaml` (deep path → renders before the subchart).
- **Upgrade from 1.3.0 must use the CURRENT passwords.** The redis subchart's Sentinel bootstraps `/etc/sentinel/sentinel.conf` once (`sentinel auth-pass` + `requirepass`) and, with `sentinel.persistence.enabled: true` (this chart's default), keeps it across restarts. So in-place rotation of the Redis/Sentinel password does not work — uninstall/reinstall. Admin-key rotation needs `force-redeployment` of the API.
- **A 1.3.0 `createSecret: false` release keeps its own secret**: the wizard's computed migrations carry its old `passwordKey` names (`redis-password` / `redis-sentinel-password`) — the defaults changed in 1.4.0. `redis.admin.fromSecret` was deleted with a `fail` guard: the admin key is now its own secret regardless of `createSecret`, so the two mechanisms no longer share one dictionary.
- **The admin key reaches the container as `ADMIN_API_KEY` = `cpln://secret/{name}.payload`** — the opaque-payload form pgdog proved. Nothing writes it to a config file, so there is no interpolation trap here.
- **`appVersion` was wrong** — 1.2.1 said `1.0.0` while the image is `:0.4`. Corrected to `0.4`.
- **Both workloads are `serverless`, so the 4:1 `cpu:minCpu` cap does not apply** and neither block exposes a reservation — hence the bare `cpu`/`memory` names, which is correct per the per-block naming rule.
- **The first `helm upgrade` after an install re-applies the bundled Redis** even with identical values, restarting it; the API errors for a minute or two. Catalog-wide behaviour, documented in the README so a tester does not diagnose it as a credential fault.
- **A missing prerequisite secret wedges silently** — zero lines from `cpln logs`; the only diagnostic is `status.versions[].message` from `cpln workload get-deployments` (plain `get` has no `versions` key).
- **`api.public.pathPrefix` has no routing effect.** The only thing it changes is whether `outboundAllowHostname: []` is rendered on the public firewall. The values comment and README said it set a route prefix; corrected 2026-10-01 (comment-only, render byte-identical). Removing or wiring the knob needs a new version.
- **No `aws::ReadOnlyAccess`** — the identity has no cloud bindings, so the catalog sweep had nothing to remove.

## Status
- **1.4.0 built 2026-10-21, not yet deploy-tested** (fresh install, upgrade from 1.3.0 with real passwords, removed-key refusals). **Deploy-tested at 1.3.0** (2026-08-19; the earlier "not yet deploy-tested" line here was stale). The pre-rewrite docs page records the live results: `/admin/clients` returned `401` with no header and with a wrong key and `200` with the correct one, over both the public endpoint and in-GVC DNS; with an empty key name it served the client list unauthenticated through a port-forward; the `createSecret: false` path worked with non-default key names; a missing admin secret self-healed (measured 8 min 43 s); disabling public access surfaces as `421`, not `403`.
- Not recorded anywhere that survives: the no-op `helm upgrade` drift gate result for both workloads. Treat it as owed.
