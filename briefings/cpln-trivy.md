# cpln-trivy — Maintainer Briefing

**What it is:** a first-party (not upstream) template that scans every image in the org's Control Plane registry with [Trivy](https://trivy.dev), renders an HTML report per image, stores it in the customer's own S3 bucket or Azure file share, and writes the report URL back onto the image as a `cpln/trivy-scan` tag — so vulnerability results show up where the image already lives, in the console. The three images (`cpln-trivy-daemon`, `cpln-trivy-trivy-api`, `cpln-trivy-web-server`) are ours; their source lives in the `cpln-trivy` repo, not here.

**Common use cases**
- Standing CVE visibility over an org's registry with no CI changes — it scans what is already pushed
- Compliance evidence: a dated HTML report per image, retained in the customer's own bucket
- Periodic re-scan so an image built months ago still reflects today's CVE feed (`rescanAfter`)

**Architecture on cpln**

| Resource | Purpose |
|---|---|
| Cron workload `daemon` | Runs on `schedule`; queries the registry for unscanned/stale images, drives the scans, tags the results |
| Sidecar `trivy-api` (on the daemon) | Wraps the Trivy CLI, returns HTML. The heavy container: 2 CPU / 4 GiB |
| Serverless workload `web-server` | Accepts report uploads on `POST /URL` (bearer-authenticated), writes them to S3 or the Azure share, serves them on GET |
| Identity + 3 policies | Cloud-account binding for storage; `reveal` on exactly the two prerequisite secrets; `manage` on images (to write tags); `pull`/`view` for the scanning service account |

**Key knobs (shipped defaults):** `storage.type: s3` (`s3` keyless via cloud account, or `azureFileshare`) · `postToken.secretName: my-cpln-trivy-post-token` (prerequisite **opaque** secret) · `trivyAuth.secretName: trivy-credentials` (prerequisite **opaque** secret holding the service-account key) · `serviceAccountName: trivy-service-account` · `schedule: "*/59 * * * *"` · `rescanAfter: 7d` (`""` = scan once) · `trivyApi.resources: 2 CPU / 4Gi` · `webServer.autoscaling: 1–3` · `webServer.firewall.inboundAllowCIDR: 0.0.0.0/0`

**Troubleshooting / considerations**
- **The two workloads talk over the PUBLIC internet, not the GVC.** The web-server ships `internal.inboundAllowType: none`, and the daemon posts to `https://web-server-${CPLN_GVC_ALIAS}.${REGION}.controlplane.us` (hard-coded in the daemon image's `run.sh`, not in the chart). This is the single most surprising fact about the template and it drives everything below.
- **Therefore `postToken` is a PREREQUISITE OPAQUE SECRET as of 1.2.0, not bundled plumbing.** It gates a publicly reachable write endpoint that stores attacker-supplied HTML in the customer's bucket and serves it from their report URLs. The bundled-credential exception is explicitly premised on the credential being unreachable from outside the GVC, which is exactly what this is not. Through 1.1.0 it shipped as `postToken: changeme` — a working, publicly documented token on an internet-facing endpoint.
- **Rotating the token needs BOTH workloads restarted.** They compare the same string; updating one leaves uploads failing 401 while every status surface reads healthy. Same trap on upgrade: an upgrader who generates a *new* token instead of reusing theirs breaks uploads silently.
- **Report reads are unauthenticated** — the URL's SHA-256 is the only secret. Narrowing `webServer.firewall.inboundAllowCIDR` to make reports private also cuts off the daemon, since the daemon reaches the web-server by the same public path. Fixing that properly means teaching the daemon image to use internal DNS; that is a change in the `cpln-trivy` repo, not here.
- **Workload names are hard-coded `daemon` and `web-server`** — not release-prefixed. Two installs in one GVC collide. Worth fixing, but it changes the report URL host, so existing tagged links would break.
- **The images policy grants `manage` on `target: all` images.** Broader than least-privilege likes, but tagging is the product; scoping it would need per-image target links that do not exist at install time.
- **GCP is not a storage option** — only AWS S3 (keyless) and Azure file share. Azure additionally needs the full storage-account resource ID in `storage.azureFileshare.scope`, which the chart `fail`s without.
- First run over a large registry is slow (~15–20 s per image, ~30 min per 100). `concurrencyPolicy: Forbid` means a long run just delays the next tick rather than stacking.
- `trivyApi` at 2 CPU / 4 GiB is the cost driver, and it only exists while the cron job runs.
