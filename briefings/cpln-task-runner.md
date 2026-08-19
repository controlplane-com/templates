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
| workload `{release}-task-runner-api` (**serverless**, 1–3) | HTTP API on 8080. `public.enabled: true` by default |
| workload `{release}-task-runner-worker` (**serverless**, 1–5) | Delivery. Internal only; outbound `0.0.0.0/0` |
| secret `task-runner-secrets` (dictionary, optional) | Bundled Redis + Sentinel passwords, from values |
| identity + policy | `reveal` on the Redis secret(s) **and** the admin-key secret |
| *(user-created)* opaque secret | The admin API key — payload IS the key |
| redis subchart | Redis + Sentinel workloads, volumes, their own identity/policy |

## Key knobs (shipped 1.3.0 defaults)
`image` (`controlplanecorporation/cpln-task-runner:0.4`) | `api.public.enabled` (**true**) | `api.admin.apiKeySecretName` (`my-cpln-task-runner-admin-key`, **must exist before install**) | `api.resources.cpu/memory` (500m / 512Mi) | `api.replicas` (1–3) | `worker.replicas` (1–5) | `worker.resources` (1 / 1Gi) | `worker.env.concurrency` (10) | `worker.env.taskTimeoutSec` (1800) | `worker.env.maxRetry` (5) | `worker.env.allowPrivateUrls` (false) | `createSecret` (true) | `secretName` (`task-runner-secrets`) | `redis.redisPassword` / `redis.sentinelPassword` (`change-me-cpln-task-runner-redis` / `-sentinel`)

## Troubleshooting / considerations
- **Security history — 1.2.x is the most exposed default in the 2026-08 audit (row 22).** `api.env.adminApiKey: ""` meant "disable admin auth", and `api.public.enabled` was `true`, so `/admin/*` — create/edit/delete clients and rate-limit tiers — was open to the internet on a default install. `redisPassword`/`sentinelPassword` were both the working value `mypassword`.
- **A GUARD, not a default flip, is the 1.3.0 fix — and that was a deliberate choice.** Flipping `public.enabled` to false would break the template's actual purpose (receiving task submissions from outside the GVC) while leaving an empty admin key legal. The chart instead makes the key a required prerequisite secret and **fails the render** when `apiKeySecretName` is empty while `public.enabled` is true. An empty key stays legal for an internal-only install, which is a deliberate act the user has to spell out.
- **Behaviour of an empty key is confirmed from the binary, not assumed.** The image was inspected via the registry API (Docker was broken on the build machine): the binary contains `Admin API key not configured - admin endpoints are unprotected`, plus `X-Admin-Key`, `ADMIN_API_KEY` and the routes `/v1/enqueue`, `/admin/clients{,/set,/get,/delete}`, `/admin/tiers`, `/health/{live,ready,detailed}`.
- **OPEN PRODUCT BUG — `/v1/enqueue` has NO authentication and AUTO-REGISTERS unknown clients. Fix belongs in the app, not this template.** An earlier draft of this briefing said enqueue "rejects an unregistered `client_id`, so the client ID is the whole access control". **Measured 2026-08-19 and that is false** — posting a never-seen ID returns `status: enqueued` *and creates the client*:

  ```
  POST /v1/enqueue {"client_id":"totally-unregistered-xyz",...}  → {"status":"enqueued",...}
  GET /admin/clients → that client now exists, created BY the enqueue
  ```

  So nothing gates the queue. With public access on, any stranger can make a worker issue arbitrary outbound HTTP with a method, headers and body of their choosing — and with `allowPrivateUrls: true`, at internal addresses. It also means the admin API's client management provides no security at all, since anyone can self-provision.

  **`api.public.enabled` therefore defaults to `false` as of 1.3.0.** That is a workaround, not a fix: receiving tasks from outside the GVC is the template's purpose, so the private default materially reduces what it is for.

  **`controlplanecorporation/cpln-task-runner` is OUR image**, so unlike a third-party limitation this is fixable at source: `/v1/enqueue` needs a per-client key checked against the existing client registry. **Maintainer decision 2026-08-19: keep the private default and fix the app.** Revisit `public.enabled: true` once enqueue authenticates. Related and pointing the same way: `/metrics` is also public and unauthenticated, and its labels enumerate every `client_id`.
- **The bundled Redis password stays a value on purpose.** It is internal plumbing for a datastore bundled with one app — the user never types it — which is exactly the exception in CLAUDE.md. It only had to stop being a *working* value, hence the `change-me-…` prefix. Do not "upgrade" it to a prerequisite secret without a reason; the standalone-datastore ruling does not apply to a subchart nobody connects to directly.
- **The bring-your-own-secret path already existed** (`createSecret: false` + `redis.*.auth.fromSecret`) and is untouched. `redis.admin.fromSecret` was deleted with a `fail` guard: the admin key is now its own secret regardless of `createSecret`, so the two mechanisms no longer share one dictionary.
- **The admin key reaches the container as `ADMIN_API_KEY` = `cpln://secret/{name}.payload`** — the opaque-payload form pgdog proved. Nothing writes it to a config file, so there is no interpolation trap here.
- **`appVersion` was wrong** — 1.2.1 said `1.0.0` while the image is `:0.4`. Corrected to `0.4`.
- **Both workloads are `serverless`, so the 4:1 `cpu:minCpu` cap does not apply** and neither block exposes a reservation — hence the bare `cpu`/`memory` names, which is correct per the per-block naming rule.
- **The first `helm upgrade` after an install re-applies the bundled Redis** even with identical values, restarting it; the API errors for a minute or two. Catalog-wide behaviour, documented in the README so a tester does not diagnose it as a credential fault.
- **A missing prerequisite secret wedges silently** — zero lines from `cpln logs`; the only diagnostic is `status.versions[].message` from `cpln workload get-deployments` (plain `get` has no `versions` key).
- **No `aws::ReadOnlyAccess`** — the identity has no cloud bindings, so the catalog sweep had nothing to remove.

## Status
- **NOT yet deploy-tested at 1.3.0.** Verified at build: bare render, `createSecret: false` render, the private + empty-key render, every `fail` guard, the policy target list in all paths, and both README secret commands run against the live org.
- A test round owes: the API reaching `ready: true` with the key mounted, `/admin/clients` returning 401/403 without `X-Admin-Key` and succeeding with it (the one thing only a deploy can settle — the binary's routing was read, not exercised), an end-to-end enqueue and delivery, and the no-op `helm upgrade` drift gate on both workloads.
