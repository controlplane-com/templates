# Tyk — Maintainer Briefing

## What it is
- Tyk Gateway, the open-source (MPL-2.0) API gateway: reverse-proxies APIs and adds auth, rate limiting, quotas, versioning and analytics in front of them. Free to self-host, no registration, no key.
- Template ships `tykio/tyk-gateway:v5.10.0` (appVersion `5.10.0`) — the **gateway only**. Tyk Dashboard and Tyk Pump are commercial/separate and are not here, so there is no UI: everything is driven by JSON files and the Control API.
- API definitions and policies are **file-driven from Control Plane secrets the user creates**, not from a database. That is the template's defining design choice.

## Common use cases
- One public entry point in front of several in-GVC services, with per-consumer API keys and rate limits.
- Rate limiting / quota enforcement for an internal API that has none of its own.
- Key issuance and revocation via the Control API (`/tyk/keys`) from a CI job or an internal tool.

## Architecture on cpln
| Resource | Purpose |
|---|---|
| workload `{release}-tyk-api-gateway` (standard, autoscale 1-3 on CPU) | Tyk Gateway, HTTP on `listenPort` (8080) |
| workload `{release}-redis` (subchart `redis` 3.4.2, 2 replicas, persistent) | Token / rate-limit / quota / analytics store |
| workload `{release}-sentinel` (subchart, 3 replicas, persistent) | Redis failover; the gateway connects **through Sentinel**, not Redis |
| identity `{release}-tyk-identity` + policy `{release}-tyk-api-gateway-policy` | `reveal` on exactly: the user's admin secret, API secret, policy secret, and the two subchart Redis passwords |

- **The chart creates no credential secret of its own** as of 1.3.0. The admin key is a user-created prerequisite opaque secret read as `cpln://secret/{name}.payload`.
- Private by default (1.3.0): `externalAccess: false` → external `inboundAllowCIDR: []`; internal `same-gvc`.
- Egress is closed (`outboundAllowCIDR: []`) — inherited from 1.0.0 and deliberately left alone.

## Key knobs (shipped 1.3.0 defaults)
`image` (`tykio/tyk-gateway:v5.10.0`) | `listenPort` (8080) | `adminSecretName` (`my-tyk-admin-secret`, **must exist before install**) | `apiSecretName` (`my-tyk-apis`) | `policySecretName` (`my-tyk-policies`) | `allowMasterKeys` (**false**) | `resources.cpu`/`.memory` (50m / 128Mi) | `autoscaling` (1-3, cpu, target 100) | `multiZone` (false) | `externalAccess` (**false**) | `internalAccess.type` (`same-gvc`) | `redis.redis.auth.password.value` / `redis.sentinel.auth.password.value` (`change-me-tyk-redis` / `change-me-tyk-sentinel`)

## Troubleshooting / considerations
- **Security history — 1.2.1 and earlier are dangerous.** They shipped `adminSecret: mysecret` as a values default, `externalAccess: true`, and `TYK_GW_ALLOWMASTERKEYS: 'true'` hardcoded — a publicly-reachable admin API behind a word from our public repo, where a key minted with no `access_rights` reached every API. The README mentioned none of the three. Tier 1 of the 2026-08-14 catalog secrets audit. Anyone on ≤1.2.1 should treat the admin key as compromised and rotate every issued API key, not just upgrade.
- **`allowMasterKeys` is a real behaviour change in 1.3.0.** Upstream Tyk defaults `allow_master_keys` to `false` (Go zero value; no default tag in `config/config.go`), and `gateway/api.go` returns `Master keys not allowed` when a key arrives with no `access_rights`. Anyone whose workflow relied on `POST /tyk/keys` with a bare session object will start getting that error on 1.3.0 and must either add `access_rights` (correct) or set `allowMasterKeys: true` (deliberate).
- **The admin API is not separable from the data plane.** Tyk Gateway serves `/tyk/*` on the same `listenPort` as the proxied APIs; there is no separate control port in the OSS gateway. So `externalAccess: true` publishes the admin API, full stop — that is why the default flipped rather than being papered over with a note.
- **Egress is closed, so external upstreams are unreachable.** `outboundAllowCIDR: []` means `target_url` must point at an in-GVC `*.cpln.local` host. Pointing an API definition at a public upstream fails with no obvious explanation. Deliberately left as-is in 1.3.0 (it is the pre-existing shape); a `outboundAllowHostname` knob is the obvious follow-up and is probably the single most likely support question.
- **Definitions and policies load at boot.** Editing `apiSecretName` / `policySecretName` does nothing until the workload redeploys or `/tyk/reload` is called. Both are mounted with `recoveryPolicy: retain`.
- **Redis credentials stay values on purpose.** The Redis+Sentinel pair is bundled plumbing serving only this gateway, is `same-gvc` internal, and no human ever types the password — so CLAUDE.md's internal-plumbing exception applies and the fix was `change-me-…` placeholders, not a prerequisite secret. Note the subchart *does* support `auth.fromSecret.{enabled,name,passwordKey}` if that is ever revisited.
- **Resource-knob naming.** The gateway block exposes only a limit, so bare `cpu`/`memory` is correct. 1.3.0 dropped the `minCpu`/`minMemory` lines from the `redis:`/`sentinel:` passthrough blocks — they duplicated the subchart's own defaults exactly (render is byte-identical), and their presence beside `cpu` was the R13 lint failure. Do **not** rename these to `maxCpu`/`maxMemory`: they are the redis subchart's key names (still `cpu`+`minCpu` as of redis 3.5.0) and renaming silently drops the override.
- **No probes.** The workload has no readiness or liveness probe, so `ready: true` means the container started, not that Tyk is serving. Inherited from 1.0.0; `GET /hello` on `listenPort` is the obvious follow-up.
- **Firewall changes take 30-150 s to propagate.** A user flipping `externalAccess` and testing immediately sees stale behaviour.
- **The first `helm upgrade` after an install re-applies the bundled Redis** and bounces it, briefly breaking rate-limit and key lookups. Catalog-wide behaviour, not tyk-specific.
