## Coraza WAF App

Creates a Coraza Web Application Firewall (WAF) with OWASP Core Rule Set (CRS) integration that proxies traffic to a target workload, providing comprehensive security filtering and protection.

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