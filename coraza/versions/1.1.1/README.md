## Coraza WAF App

Creates a Coraza Web Application Firewall (WAF) with OWASP Core Rule Set (CRS) integration that proxies traffic to a target workload, providing comprehensive security filtering and protection.

### Architecture

- **WAF workload** — Coraza with the OWASP Core Rule Set, listening on `WAFPort` and proxying to `targetWorkload`.
- **Secrets** — the startup script and a custom-rules secret for your own rules.
- **Identity and policy** — `reveal` on those secrets.

This template does not create a GVC. It sits in front of a workload you already run.

### Prerequisites

**The workload you intend to protect must already exist**, and `targetWorkload` must be its fully-qualified internal address (`WORKLOAD.GVC.cpln.local`) with `targetPort` set to the port it serves.

### Configuration

The following values can be configured in your values file:

- `targetWorkload`: The internal name of the workload to proxy traffic to (`WORKLOAD_NAME.GVC_NAME.cpln.local`)
- `targetPort`: The port of the target workload to proxy traffic to
- `WAFPort`: The port on the WAF workload to expose to the internet
- `resources`: Reserved resources for the workload
- `multiZone`: Deploys replicas across multiple zones
- `diskBodyInspection`: When `true` (default), request bodies exceeding the 512KB in-memory limit are buffered to disk at `/tmp/coraza` for full inspection up to 12.5MB. When `false`, all body inspection is kept in memory — bodies up to 12.5MB are held in memory rather than spilling to disk, which avoids disk I/O but increases memory pressure on large requests.

### Logging

All Coraza logging is currently sent to `/dev/stdout` to be readable in the Control Plane built-in logging interface. Logging can be redirected by using the existing environment variables in the workload configuration.

### Advanced Configuration

Coraza configuration is largely specified through environment variables and can be customized by the user once installed. You can modify these environment variables in the workload configuration to adjust Coraza's behavior, logging levels, and security policies according to your specific requirements.

### Usage

The Coraza WAF will act as a reverse proxy, filtering incoming requests before forwarding them to your target workload. Configure the `targetWorkload` and `targetPort` values to point to your application, then the WAF will be accessible on the specified `WAFPort`.

**Important**: The target workload must be configured with internal access set to `same-gvc`, `same-org`, or specifically allow this workload in order for the WAF to reach it.

### Security Features

Coraza provides web application firewall capabilities including:
- Automatic integration of OWASP Core Rule Set (CRS) for comprehensive protection
- Request filtering and validation
- Protection against common web attacks
- Custom rule configuration
- Traffic monitoring and logging

### Custom Rules

After installation, you can add custom rules by editing the created secret with the suffix `coraza-custom-rules`. The secret contains an example rule that blocks requests containing "attack" in the URI:

```
SecRule REQUEST_URI "@rx attack" "id:1001,phase:1,deny,msg:'Blocked attack attempt'"
```

**Note**: After modifying the custom rules secret, you must restart the workload replicas for the changes to take effect. See the Coraza and CRS documentation below for instructions on creating custom rules.

## Additional Resources

- [OWASP Coraza Docs](https://coraza.io/docs/tutorials/introduction/)
- [OWASP CRS Docs](https://coreruleset.org/docs/)
- [Coraza Caddy README](https://github.com/coreruleset/coraza-crs-docker#)

### Important Notes

- **This only protects traffic that goes through it.** The WAF is a proxy, so the workload behind it must not remain publicly reachable on its own endpoint, or requests will simply bypass inspection.
- **The image is pinned by digest**, so it does not drift. Bumping it is a deliberate values change.
- **`diskBodyInspection` trades memory for coverage.** With it off, request bodies above the in-memory limit are not inspected at all rather than being buffered.
- **Custom rules are applied on top of the Core Rule Set**, so a rule ID collision silently overrides a CRS rule.

### Connecting

| What | Value |
|---|---|
| Public | the WAF workload's endpoint on `WAFPort` — this is the address clients should use |
| Internal (same GVC) | `RELEASE_NAME-coraza.GVC_NAME.cpln.local:WAFPort` |
| Upstream | whatever you set as `targetWorkload` and `targetPort` |

Send traffic to the WAF, not to the workload behind it.
