## Tailscale Gateway App

This app creates a workload in your Control Plane GVC that connects to your tailscale network. It publishes routes for other workloads running on Control Plane as well as for the internal dns servers so that workloads can be accessed from anywhere using the `cpln.local` endpoint.

Any workload that allows access from this tailscale workload will be able to be reached when connected to the tailscale network.

### Architecture

- **Tailscale workload** — a subnet router that joins your tailnet and advertises the GVC's internal routes, pinned to a single `location`.
- **Identity and policy** — `reveal` on the auth-key secret you create.
- **Example httpbin workload** *(optional)* — a demo target, created when `deployHttpbinExample: true`.

This template creates no secret of its own and does not create a GVC.

### Prerequisites

**One `opaque` secret must exist BEFORE you install.** It holds your Tailscale auth key, which authorizes a
device onto your tailnet — so it is not a value: a value would leave the key in the Helm release.

Generate a key in the Tailscale admin console under **Settings → Keys → Generate auth key**, then:

```bash
printf '%s' 'tskey-auth-YOUR-KEY-HERE' | cpln secret create-opaque --name my-tailscale-authkey --encoding plain -f -
```

Set `authKeySecretName` to the name you used. Secret names are organization-wide, so give each release its own.

**If the secret does not exist at install time, the deployment wedges silently.** `cpln logs` returns
**zero lines** — the container never starts, so it has nothing to log. Read `status.versions[].message`:

```bash
cpln workload get-deployments RELEASE_NAME-tailscale --gvc GVC_NAME -o yaml
```

Note this is `get-deployments` — plain `cpln workload get` has no `versions` field.

<b>Upgrading from 1.2.x:</b> delete `AuthKey` from your values and create the secret instead. An upgrade that
still carries `AuthKey` is refused at render. Give the new secret a name other than `RELEASE_NAME-tailscale`
(the upgrade deletes that chart-owned secret). Reuse the same key or generate a new one.

### Configure Tailscale

1. Create an auth key in the Tailscale [admin console](https://login.tailscale.com/admin/settings/keys) with both **Reusable** and **Ephemeral** enabled, and store it as described in Prerequisites. The gateway keeps no Tailscale state, so it rejoins with this key on every container start.

2. In your [tailnet policy file](https://login.tailscale.com/admin/acls/file), add an `autoApprovers` block for the three routes the gateway advertises: `192.168.0.0/16`, `240.240.0.0/16`, and a `/32` to the internal DNS server of `location` (its `locationDNS` entry). This example is for the default `aws-us-east-1`:

   ```json
   {
     "autoApprovers": {
       "routes": {
         "192.168.0.0/16": ["autogroup:member"],
         "240.240.0.0/16": ["autogroup:member"],
         "172.20.0.10/32": ["autogroup:member"]
       }
     }
   }
   ```

   For another location, replace `172.20.0.10/32` with that location's `locationDNS` entry. Without `autoApprovers`, approve the routes by hand on the [Machines page](https://login.tailscale.com/admin/machines) (**Edit route settings**).

3. On the Tailscale [DNS page](https://login.tailscale.com/admin/dns), add a custom nameserver restricted to `cpln.local`, set to the `locationDNS` IP of your `location` (`172.20.0.10` for `aws-us-east-1`):

   <img src="images/addCustomNameserver.png" alt="custom-nameserver" width="400"/>

### Verify the gateway

1. Install the template. The workload runs only in `location` and is suspended everywhere else, so the console shows it as `Partially Suspended`.

2. On the [Machines page](https://login.tailscale.com/admin/machines), confirm the gateway (its `TS_HOSTNAME`, `cpln-tailscale` by default) is connected and its routes are approved:

   <img src="images/selectEditRouteSettings.png" alt="route-settings" width="400"/>

   <img src="images/verifyRoutesApproved.png" alt="routes-approved" width="400"/>

3. From a device on the same tailnet, call the example workload:

   ```bash
   curl http://RELEASE_NAME-httpbin.GVC_NAME.cpln.local/headers
   ```

   A JSON response proves the routes, split DNS and gateway all work. If not, check the gateway's output:

   ```bash
   cpln logs '{gvc="GVC_NAME", workload="RELEASE_NAME-tailscale"}' --limit 50 --since 10m
   ```

4. To reach your own workloads, allow `//gvc/GVC_NAME/workload/RELEASE_NAME-tailscale` in each target's internal firewall (`firewallConfig.internal`, `inboundAllowType: workload-list`).

### Configuration

```yaml
location: aws-us-east-1 # a SINGLE location in your GVC
image:
  repository: tailscale/tailscale
  tag: v1.102.3 # pinned: `stable` floats, so installs are not reproducible
resources:
  cpu: 500m
  memory: 128Mi
extraEnv:
  - name: TS_HOSTNAME
    value: cpln-tailscale # the name this device advertises on your tailnet
deployHttpbinExample: true
authKeySecretName: my-tailscale-authkey # see Prerequisites — must exist before install
```

`locationDNS` maps each Control Plane location to its internal DNS server. The entry for `location` becomes the advertised `/32` route and the split-DNS address, so `location` must have an entry (a missing one renders a bare `/32`). Leave the map as shipped unless your location is missing from it.

### Connecting

| What | Value |
|---|---|
| From a tailnet device | `WORKLOAD_NAME.GVC_NAME.cpln.local:PORT`, once the routes are approved, split DNS is set and the target allows the gateway |
| Example workload | `RELEASE_NAME-httpbin.GVC_NAME.cpln.local:80` (when `deployHttpbinExample: true`) |
| Route approval | [Tailscale admin → Machines](https://login.tailscale.com/admin/machines) — advertised routes must be approved before they carry traffic |

### Important Notes

- **Approve the advertised routes in the Tailscale admin console.** Until you do, the gateway joins the tailnet but no traffic reaches the GVC — the most common reason this appears not to work.
- **Run the gateway in a single location.** A subnet router advertising the same routes from several locations gives Tailscale competing paths.
- **Auth keys expire.** Tailscale's default is 90 days. A gateway that drops off the tailnet after a restart is usually an expired key, not a template fault.
- **Keep a valid key in the secret.** The gateway rejoins with the key on every container start, so an expired key surfaces at the next restart. After replacing the key, run `cpln workload force-redeployment RELEASE_NAME-tailscale --gvc GVC_NAME`; a running gateway does not pick up the new value by itself.
- **Each target workload must allow `RELEASE_NAME-tailscale`** in its internal firewall, or it stays unreachable from the tailnet.

### Links

- [Tailscale documentation](https://tailscale.com/kb/)
- [Subnet routers](https://tailscale.com/kb/1019/subnets)
- [Auth keys](https://tailscale.com/kb/1085/auth-keys)
