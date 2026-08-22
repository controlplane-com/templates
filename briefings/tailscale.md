# Tailscale — maintainer briefing

**What it is.** A Tailscale subnet router / gateway that joins a GVC to the user's tailnet, so workloads are
reachable over WireGuard from their laptops and other tailnet devices without exposing anything publicly.

**Common use cases.** Private admin access to internal-only workloads, connecting a GVC to on-prem or another
cloud, and giving a small team direct access to databases and dashboards that have no public endpoint.

## Architecture

| Resource | Notes |
|---|---|
| workload `-tailscale` (standard) | the `tailscale/tailscale` container running as a subnet router, pinned to `location` |
| workload `-httpbin` *(optional)* | a demo target, created when `deployHttpbinExample: true` |
| identity + policy | `reveal` on the user's prerequisite auth-key secret |

The chart creates **no secret of its own** from 1.3.0.

## Key knobs (shipped defaults)

| Knob | Default | Notes |
|---|---|---|
| `location` | `aws-us-east-1` | a **single** location in your GVC |
| `authKeySecretName` | `my-tailscale-authkey` | **prerequisite** `opaque` secret (1.3.0+) |
| `image.tag` | `v1.102.3` | pinned in 1.3.0; was the floating `stable` |
| `extraEnv[].TS_HOSTNAME` | `cpln-tailscale` | the name advertised on the tailnet |
| `locationDNS` | map | per-location resolver, used for split DNS |
| `deployHttpbinExample` | `true` | demo workload |

## Troubleshooting traps

- **The auth key is a prerequisite `opaque` secret from 1.3.0**, referenced as `cpln://secret/{name}` with no
  key suffix. Through 1.2.1 it was `AuthKey` in values, so it sat in the Helm release; an upgrade still
  carrying `AuthKey` is refused at render. Unlike a database password, a Tailscale auth key only authorizes
  the device at join time, so rotating it is safe and does not disturb a joined node.
- **`TS_HOSTNAME` used to default to `cpln-test-new`** — a leftover from testing that became the tailnet name
  of every install. Fixed in 1.3.0; if you see `cpln-test-new` on a tailnet, it is a pre-1.3.0 deployment.
- **`image.tag: stable` floated.** Two installs a month apart ran different Tailscale builds. Pinned in 1.3.0.
- **A missing prerequisite secret wedges the deployment silently** — `cpln logs` returns zero lines; read
  `status.versions[].message` from `cpln workload get-deployments RELEASE_NAME-tailscale`.
- **Auth keys expire.** Tailscale's default is 90 days, and a reusable/ephemeral key is a separate choice at
  generation time. A node that silently drops off the tailnet months later is usually an expired key, not a
  template problem — regenerate and update the secret.
- **`location` is single-valued on purpose.** A subnet router advertising the same routes from several
  locations gives Tailscale competing paths; run one, or give each its own hostname and routes.
