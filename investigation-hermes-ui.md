# Investigation: hermes-agent 1.1.0 — slow dashboard, 2-minute login, Anthropic failure

Date: 2026-09-01 · Fresh run · org `jacob-cox` / gvc `test-gvc`
Image `nousresearch/hermes-agent:v2026.7.7.2` · template read-only, nothing modified.

Releases used:
- `test-hermes` — defaults, **dummy** Anthropic key (secret `test-hermes-secret`, created by me)
- `test-hreal` — defaults, **real** Anthropic key (secret `test-hermes-key`, supplied by the user)

---

## Bottom line

**None of the four reported symptoms reproduced.** Login is 0.36 s, all 73 dashboard
routes return in under 1.9 s, and real Anthropic inference works.

**But the mechanism that produces exactly those symptoms was found and proven:**

> The dashboard runs ~160 `async def` handlers on a **single asyncio event loop**, and it
> uses the **synchronous** `httpx.Client` — 12 call sites, and **zero** uses of
> `httpx.AsyncClient`. Two of those synchronous calls sit directly inside an `async def`
> route handler. While one of them is waiting on the network, **the entire dashboard is
> frozen** — every route, every user, every tab.

Measured directly: with nothing in flight `/login` returns in **0.00 s**; with one blocking
outbound call in flight the very next `/login` took **7.78 s**, matching the blocking call's
8.08 s duration almost exactly, after which service resumed instantly.

**The freeze lasts exactly as long as the outbound call takes to time out.** That is the
"blocking until a timeout, not merely slow" signature the brief asked me to chase, and it
explains all three UI symptoms at once — spinner, slow login, pages that never load — plus
why extra CPU and memory changed nothing (a stalled event loop is not resource-bound) and
why the workload never restarted (the process is alive and healthy, just not running the loop).

What I could **not** establish is which specific outbound call hung for ~2 minutes in the
teammate's environment. The trigger I proved is bounded at 8–10 s. See "The remaining gap".

---

## Symptom-by-symptom

| # | Reported | Measured here | Verdict |
|---|---|---|---|
| 1 | Dashboard extremely slow, spinner | all 73 GET routes < 1.9 s | did not reproduce |
| 2 | Login > 2 minutes | login POST **0.36 s** (dummy AND real key) | did not reproduce |
| 3 | Some pages never load | every route returned; none timed out | did not reproduce |
| 4 | Anthropic inference did not work | works — `finish_reason: stop`, correct content | did not reproduce |

---

## Step 0 — gates

| Check | Result |
|---|---|
| `test-gvc` empty before start | yes — `items: []` |
| Default-render gate (only the gvc set, no other `--set`) | **PASS** — exit 0, 225 lines, no `Error:`/`fail` |
| Install | success in 3.0 s |
| Ready | 64 s (dummy) / 42 s (real key), `restarts: None` throughout |
| Boot monkey-patch applied | yes — `middleware.py` + `routes.py` mtime `Sep 1 14:32`; every other file in `dashboard_auth/` still `Jul 8 03:11` |

---

## Step 1 — reproduction, with numbers

Reached over the top-level `port-forward` command on 9119 (ports positional).

| Request | HTTP | Total |
|---|---|---|
| `GET /health` on 8642 (control, known-fast) | 200 | 0.30–0.81 s |
| `GET /` unauth | 302 → `/login?next=%2F` | 0.60 s |
| `GET /login` unauth (10 044 B) | 200 | 0.34 s |
| **`POST /auth/password-login`, correct creds** | 200 `{"ok":true,"next":"/"}` | **0.36 s** |
| `GET /` authenticated (SPA shell, 642 B) | 200 | 0.28 s |
| `/assets/index-…js` (1 957 880 B) | 200 | 0.86 s |

**All 73 parameterless GET routes** were swept with `--max-time 150`. All 73 returned;
none timed out. Slowest: `/api/tools/toolsets` 1.86 s, `/api/dashboard/plugins/hub` 1.30 s,
`/api/skills/hub/sources` 1.11 s, `/api/status` (cold) 2.33 s.

WebSocket endpoints (`/api/ws`, `/api/events`, `/api/console`) reject in **0.27–0.29 s**
without a ticket — a fast rejection, so the WS transport is carrying request and response
fine; not a blackhole.

**A valid API key changed nothing.** Login on the real-key release was **0.36 s**, identical
to the dummy-key release. So the dummy key did not mask the problem, and a working model does
not fix it — the "invalid key blocks on the login path" theory is dead in both directions.

---

## Step 2 — the root-cause mechanism, proven

### The finding

Read from the running image:

- `web_server.py` — 16 926 lines, one FastAPI app, one `uvicorn.Server`, no `workers=`.
- **160 of 166 route handlers are `async def`** (6 sync).
- **`httpx.Client(` appears 12 times. `httpx.AsyncClient(` appears 0 times.**

`httpx.Client` is the blocking client. Mapping every site to its enclosing function, ten are
inside plain `def` helpers (`_nous_poller`, `_codex_full_login_worker`, `_do_xai_device_request`,
…) which are run off-loop. **Two are directly inside an `async def` route handler:**

```
L5981  with httpx.Client(timeout=httpx.Timeout(8.0)) as client:
L6001  with httpx.Client(timeout=httpx.Timeout(10.0)) as client:
   both inside →  L5953  async def validate_provider_credential(body, request)
   route        →  @app.post("/api/providers/validate")
```

### The experiment

Run entirely in-container on loopback (no tunnel), against an **unroutable** IP so the
failure mode is a genuine TCP connect hang rather than an instant NXDOMAIN:

```
POST /api/providers/validate  {"key":"OPENAI_BASE_URL","value":"http://10.255.255.1:81"}
```

while probing `/login` concurrently.

```
=== CONTROL: no blocking call in flight ===
  [control] probe1 /login    0.00s  200
  [control] probe2 /login    0.00s  200
  [control] probe3 /login    0.00s  200
=== TEST: blocking validate (unroutable IP, connect hang) in flight ===
  [during]  probe1 /login    7.78s  200      <-- frozen
  [during]  probe2 /login    0.00s  200
  [during]  probe3 /login    0.00s  200
  ... probes 4-8 all 0.00s
  [validate] 8.08s -> 200 {"ok":false,"reachable":false,
                           "message":"Could not reach http://10.255.255.1:81/models."}
```

Both controls behave: probes are 0.00 s with nothing in flight, and the freeze is bounded
by — and equal to — the blocking call's own timeout. **An unrelated request was stalled
7.78 s by one outbound call it had nothing to do with.**

### Corroborating signal

A 24-request concurrent burst (what a browser SPA boot looks like) degraded every route
about 10x, with no route doing more work:

| | Solo | At 24 concurrent |
|---|---|---|
| `/api/dashboard/plugins/hub` | 1.30 s | **5.49 s** |
| `/api/model/info` | 0.35 s | **5.41 s** |
| `/api/tools/toolsets` | 1.86 s | **5.39 s** |
| `/api/system/stats` | 0.38 s | **4.07 s** |

That is queueing behind a serialized loop, not proportional work.

### The outbound destinations that can hang it

```
_CREDENTIAL_PROBES = {
  "OPENROUTER_API_KEY": ("https://openrouter.ai/api/v1/key", "bearer"),
  "OPENAI_API_KEY":     ("https://api.openai.com/v1/models", "bearer"),
  "XAI_API_KEY":        ("https://api.x.ai/v1/models", "bearer"),
  "GEMINI_API_KEY":     ("https://generativelanguage.googleapis.com/v1beta/models", "query"),
}
```

Four probes at 10 s each, plus the `OPENAI_BASE_URL` path at 8 s. If a settings page
validates several providers, those freezes are **sequential on the loop** and add up:
4 x 10 s = 40 s of total dashboard unavailability from a single page interaction, with
every other tab and route frozen alongside it.

Note `ANTHROPIC_API_KEY` is **not** in the table — validating an Anthropic key makes no
network call at all and returns `{"ok": true, "reachable": false}`.

---

## Hypotheses eliminated, and how

| Hypothesis | Verdict | Evidence |
|---|---|---|
| **Password hashing at a high cost factor** | **RULED OUT** | The login POST is 0.36 s and `/auth/login`, `/`, `/login` all return in **0.00 s** in-container. Nothing is CPU-bound; there is no window in which CPU could be pinned. |
| **Session write to SQLite on the network volumeset** | **RULED OUT** | Measured in-container: `/opt/data` (ext4 network block) fsync **median 2.9 ms / p95 3.2 ms**, SQLite **5.0 ms per committed insert**. Against `/dev/shm`: 0.2 ms and 0.3 ms. So the volumeset is ~15x slower *relatively* but 5 ms *absolutely* — reaching 2 minutes would take ~24 000 commits. The databases are tiny: `state.db` 208 KiB, `kanban.db` 116 KiB, `response_store.db` 20 KiB. |
| **Our boot-time monkey-patch** | **RULED OUT** | Patch verified applied (both idempotency markers present exactly once; the two files' mtimes differ from the rest of the directory). All three auth entry paths return in **0.00 s**. `GET /` produces a single clean `302 → /login?next=%2F` — no redirect loop. `dashboard-auth.log` records `login_success` for every attempt. The patch only *adds an early return that skips work*, so it cannot add latency. |
| **A mesh hop the dashboard makes to itself or to 8642** | **RULED OUT** | The dashboard (`hermes dashboard`, PID 105/120) and the gateway (`hermes gateway run`, PID 139/158) are **separate processes**. Both answer on loopback in **0.01 s**. Nothing in the dashboard's request path crosses the mesh. |
| **Blocking outbound call hanging until timeout** | **CONFIRMED as the mechanism** | See the experiment above — 7.78 s freeze of an unrelated route. |
| **Double `anthropic/` prefix breaking inference** | **RULED OUT as a functional break** | See below — it is a real template defect but inference still works and still uses the right model. |

---

## Step 3 — the Anthropic symptom

### Inference works

Driven through the gateway API with the real key:

| Test | Result |
|---|---|
| Default install (`model.name: ""`) | HTTP 200, 6.7 s, `finish_reason: "stop"`, content `"PONG"` |
| Agent log truth (`model=` line) | `model=claude-opus-4-6` — 0 occurrences of `failed` |

The seeded config is correct:

```
model:
  default: anthropic/claude-opus-4.6
  provider: anthropic
  base_url: https://api.anthropic.com
```

`ANTHROPIC_API_KEY` is present in the container and resolved from the secret (value not
printed); `HERMES_INFERENCE_PROVIDER=anthropic`.

**For contrast, this is what a genuine model failure looks like** — captured accidentally
when a test seeded an empty model name, and worth recording because it confirms the
README's warning:

```
HTTP 200  finish=error  content='HTTP 400: model: String should have at least 1 character'
hermes={'completed': False, 'failed': True, 'error': 'HTTP 400: model: ...'}
```

HTTP **200** with the failure inside the body. Any client checking only the status code
reads this as success.

### The double-prefix defect — REAL, but not the cause

`hermes-agent.modelDefault` unconditionally prefixes:

```
{{- if eq .Values.model.provider "anthropic" -}}
{{- printf "anthropic/%s" .Values.model.name -}}
```

Rendered and then **confirmed in the live container's config**:

| `model.name` | Seeded `model.default` |
|---|---|
| `claude-opus-4.6` | `anthropic/claude-opus-4.6` |
| `anthropic/claude-opus-4.6` | **`anthropic/anthropic/claude-opus-4.6`** |

There is **no validation** in `hermes-agent.validate` against a user-supplied prefix, and a
user is actively led into it: the container's own `/opt/data/config.yaml` displays the model
in prefixed form, and the README's own OpenRouter example writes `name: anthropic/claude-sonnet-4-5`.

**But it does not break inference.** Both arms tested against the real key, with a
distinctive model to detect a silent fallback:

| Seeded `model.default` | Agent log `model=` | Result |
|---|---|---|
| `anthropic/claude-haiku-4-5-20251001` | `claude-haiku-4-5-20251001` | 200, `stop`, `OK` |
| `anthropic/anthropic/claude-haiku-4-5-20251001` | `anthropic/claude-haiku-4-5-20251001` | 200, `stop`, `OK` |

The image strips one redundant prefix. Critically, **it is still haiku** in the double-prefix
arm — no silent fallback to the default opus, so there is no hidden cost surprise either.

**Conclusion: the double prefix is a cosmetic template defect that should be guarded, but it
is not why the teammate's inference failed.** Worth fixing (a `fail` in the validation helper,
or strip a leading `{provider}/`), but it does not explain symptom 4.

---

## The remaining gap — stated plainly

I proved the **mechanism** (one blocking call freezes the whole dashboard) but not the
**trigger** in the teammate's environment. The trigger I demonstrated is bounded at 8–10 s
per call; reaching ~120 s needs either a dozen sequential probes or a slower-failing
destination. Both are plausible and neither is observed.

What would close it, in order of value:

1. **Ask him what he was doing when it hung.** If he was on a settings/providers page, or had
   just entered an API key, `POST /api/providers/validate` is the answer and the arithmetic
   works out (4 probes x 10 s, repeated).
2. **His egress.** Every freeze equals an outbound timeout. If `openrouter.ai`, `api.x.ai` or
   `generativelanguage.googleapis.com` were slow or blackholed from his GVC while
   `api.anthropic.com` was fine, each probe burns its full 10 s. That is the single most
   likely difference between his environment and mine, and it is cheap for him to check.
3. **Whether his resource increase actually applied.** On a `stateful` workload the platform
   rejects a `cpu:minCpu` ratio above 4:1. If he raised `maxCpu` without raising `minCpu`, the
   apply is refused — and per the known platform behaviour a rejected apply can surface as an
   apparently successful command. "It changed nothing" may mean it never took effect. Worth
   confirming against the **stored** spec rather than his values file.

---

## Template defects found (both real, neither is the UI cause)

### 1. `model.name` is unconditionally re-prefixed, with no validation
Described above. `anthropic/X` becomes `anthropic/anthropic/X`. Tolerated by this image
version, but it is an unguarded footgun that a future image need not tolerate.

### 2. The README's dashboard command does not work
The Connecting table documents reaching the dashboard with a `workload port-forward`
subcommand carrying a `-p 9119:9119` flag. Two errors: port-forward is a **top-level** cpln
command, not a `workload` subcommand, and there is **no `-p` flag** — the ports argument is
positional. As shipped, the only documented route to the dashboard fails for anyone who
copy-pastes it. The working form is the top-level command with `9119:9119` passed positionally.

---

## Note on the dummy key

The dummy Anthropic key affected nothing observable in the UI: login, every dashboard route
and the auth paths were identical on the dummy-key and real-key releases. Its only effect was
on inference itself, which was then re-tested end to end with the real key.

---

## Cleanup

| Action | Verification |
|---|---|
| `helm uninstall test-hermes` | re-read GVC: workloads `[]`, volumesets `[]` |
| `helm uninstall test-hreal` | re-read GVC: workloads `[]`, volumesets `[]`, identities `[]` |
| Deleted secret `test-hermes-secret` (the dummy-key one **I** created) | gone from the org secret list |
| **Did NOT delete `test-hermes-key`** (the user's real-key secret — I did not create it) | **confirmed still present after the janitor sweep** |
| Policies with my release prefixes | `[]` (listed with `--max 0` to avoid the 50-record truncation) |
| GVC shape | never reshaped; spec re-read and diffed against the pre-run capture — **byte-identical**, still `aws-us-east-1`, `endpointNamingFormat: org` |
| Janitor | `== test-gvc is clean ✓` |

No leftovers. The template directory was not modified.

---

## Round 2 — live session with the maintainer, 2026-09-01 (final resolution)

**Login hang: SOLVED — wedged client connection state, not the server, not extensions.**
DevTools showed the login POST pending forever at 0.0 kB while the page GET completed in 66 ms
and the identical POST via curl through the same tunnel returned 200 in 0.7 s. Reproduced with
ALL extensions disabled. Eliminated with controls: extensions (incl. iCloud Passwords and two
others caught injecting), oversized cookies (32 KB fine), 50 distinct cookies, stale session
cookies from prior releases, tunnel connection reuse (GET+POST on one connection: both 200),
WebSocket upgrades, session eviction (logins do not evict each other). **Fix: fully quit the
browser (Cmd+Q) and reopen** — flushes the per-profile socket pools that dead port-forward
tunnels had wedged. Incognito/fresh profiles have their own network context, which is why they
always worked.

**Models/MCP blank pages: same class.** Fresh browser contexts rendered 4/4 with identical
request lists; blank mounts reproduce only on reused/aged sessions (including a same-tab
re-navigation in the probe), with zero exceptions and zero failed requests. Reload fixes.

**RETRACTION: "MCP is blank because the empty list has no empty state" was WRONG.** The page
has a proper empty state ("Your MCP servers (0) — No MCP servers configured"), proven by a
later run rendering it. The earlier conclusion came from one run per arm. Single runs are not
proof.

**RETRACTION (earlier, reaffirmed): the port-forward concurrency claim** was confounded by a
concurrent agent reinstalling the workload; connection reuse and parallel curls now measure
clean against a stable tunnel.

**Chromium: NOT in the image.** No binary anywhere; `doctor.py` installs via
`npx playwright install chromium` on first browser use (needs egress). README claim corrected.

**Still standing from round 1:** the upstream sync-httpx event-loop freeze (12 call sites,
`/login` 0.00 → 7.78 s during one blocking call) — real, upstream's to fix, plausible cause of
the teammate's 2-minute login in an egress-restricted environment, unproven for his specific
case. The `anthropic/` double-prefix template gap (needs a version bump to guard at render).

**Shipped:** PR #530 — in-place docs truth on 1.1.0 (real port-forward command, API-only
endpoint / 404-by-design, browser-state troubleshooting note, Chromium truth, hyphenated model
IDs), briefing updated with the full record. Render verified byte-identical.
