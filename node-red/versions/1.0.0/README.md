# Node-RED

A low-code flow editor and runtime: Node-RED wires APIs, MQTT devices, webhooks, schedules and databases together as flows you build in the browser and deploy with one click. This template deploys a single Node-RED on a persistent volume with daily snapshots, the editor behind an admin login taken from a secret, an optional login on HTTP endpoints and the Dashboard, and pinned extra nodes installed at start.

Node-RED is Apache-2.0 licensed, with no paid tier or feature gate.

## Architecture

- **`{release}-node-red`** — a `stateful` workload with one replica on HTTP :1880, serving the editor, the admin API, HTTP In endpoints and the Dashboard. Node-RED has no clustering, so there is no replica setting: a second copy would run every flow, schedule and MQTT subscription twice. It runs in the one location named by `location`.
- **`{release}-node-red-data`** — a volume set mounted at `/data`: flows, their encrypted credentials, installed nodes, file-backed context and projects. Snapshotted on `backup.schedule`, with a final snapshot when the release is uninstalled.
- **Identity and policy** — `reveal` on exactly the secrets Node-RED reads. The chart creates no secrets.

The settings file is generated at every start from `values.yaml`. The admin and HTTP endpoint passwords are hashed with bcrypt when Node-RED starts, and every credential variable is removed from the process environment before flows run, so `env.get()` and exec nodes cannot read them.

## Prerequisites

Two secrets must exist **before** you install, in a GVC that has the location you set in `location`. If a secret is missing, the deployment waits with no log lines; `cpln workload get-deployments {release}-node-red --gvc {gvc} -o yaml` names it. After creating it, run `cpln workload force-redeployment {release}-node-red --gvc {gvc}`.

**1. Admin login** — a `dictionary` with `username` and `password` (at least 12 characters; Node-RED refuses to start with a shorter one). It is read on every start:

```bash
cpln secret create-dictionary --name my-node-red-admin \
  --entry username=admin --entry password="$(openssl rand -hex 16)"
```

**2. Credential key** — an `opaque` secret of at least 16 characters that encrypts every password and token your flows store. Keep a copy and never change it: credentials saved under another key cannot be decrypted.

```bash
printf '%s' "$(openssl rand -hex 32)" | cpln secret create-opaque --name my-node-red-credential-secret --encoding plain -f -
```

**HTTP endpoint login (optional)** — a `dictionary` with `username` and `password` for `httpNodeAuth.secretName`, protecting every HTTP In endpoint and the Dashboard:

```bash
cpln secret create-dictionary --name my-node-red-http-auth \
  --entry username=api --entry password="$(openssl rand -hex 16)"
```

**Variables for flows (optional)** — a `dictionary` for `envSecret.secretName`; each key listed in `envSecret.keys` becomes an environment variable:

```bash
cpln secret create-dictionary --name my-node-red-env --entry API_TOKEN=YOUR_TOKEN
```

## Configuration

```yaml
location: aws-us-east-1          # the ONE location of your GVC that Node-RED runs in
image: nodered/node-red:5.0.9
resources: { minCpu: 250m, maxCpu: 1000m, minMemory: 256Mi, maxMemory: 1Gi }
timezone: UTC                    # IANA timezone for inject/cron schedules
contextStorage: localfilesystem  # localfilesystem (survives restarts) | memory
safeMode: false                  # true = start the editor without running flows
volumeset: { capacity: 10 }      # GiB (minimum 10)
backup:
  enabled: true                  # scheduled volume set snapshots
  schedule: "0 3 * * *"          # UTC; at most hourly
  retention: 7d                  # also how long the final snapshot at uninstall is kept
admin: { secretName: my-node-red-admin }                          # Prerequisites 1
credentialSecret: { secretName: my-node-red-credential-secret }   # Prerequisites 2
httpNodeAuth: { secretName: "" }  # optional login for HTTP In endpoints and the Dashboard
palette:
  allowInstall: true             # false = no installs from the editor or function nodes
  packages: []                   # pinned name@version, e.g. ["@flowfuse/node-red-dashboard@1.36.1"]
projects: { enabled: false }     # git-backed projects in the editor
extraEnv: []                     # plain variables, e.g. [{name: MQTT_HOST, value: broker.example.com}]
envSecret: { secretName: "", keys: [] }   # secret variables, e.g. my-node-red-env with keys [API_TOKEN]
publicAccess: { enabled: true }  # editor, HTTP endpoints and Dashboard on the canonical endpoint
internalAccess:
  type: same-gvc                 # none | same-gvc | same-org | workload-list
  workloads: []                  # workload-list only
```

**Extra nodes.** `palette.packages` is installed into `/data` with npm when the list changes, adding up to a few minutes to that start; an unchanged list skips npm, so a registry outage does not block a restart. A package that fails to install stops the start with a `cpln-node-red: FATAL:` log line. Nodes installed from the editor's palette manager are kept on the volume too. With `palette.allowInstall: false` neither the palette manager nor function nodes can install modules.

**Dashboard.** Add `@flowfuse/node-red-dashboard@1.36.1` to `palette.packages` (or install it from the palette manager); it serves `/dashboard` on the same port. With `httpNodeAuth` set, the Dashboard pages and its live-data socket (`/dashboard/socket.io`) both require the HTTP endpoint login. Without it, anyone who can reach the endpoint can read the Dashboard and press its buttons, so set `httpNodeAuth` or turn `publicAccess.enabled` off for a Dashboard with controls.

**Projects.** With `projects.enabled: true` the editor offers to create or clone a git project. Each project asks for its own credential key, which the chart does not manage; keep a copy of it.

## Connecting

| Target | Address | Credentials |
|---|---|---|
| Editor (public) | `status.canonicalEndpoint` of `cpln workload get {release}-node-red --gvc {gvc} -o yaml` | the admin login |
| Editor (private) | `cpln port-forward {release}-node-red 1880:1880 --gvc {gvc}`, then `http://localhost:1880` | the admin login |
| HTTP In endpoints | `https://ENDPOINT/PATH`, or `http://{release}-node-red.{gvc}.cpln.local:1880/PATH` inside the GVC | the HTTP endpoint login, when set |
| Admin API | the same address; a token from `POST /auth/token` | the admin login |

Get an admin API token, then call the API with it:

```bash
curl -s -X POST https://ENDPOINT/auth/token -H 'Content-Type: application/json' \
  -d '{"client_id":"node-red-admin","grant_type":"password","scope":"*","username":"admin","password":"YOUR_ADMIN_PASSWORD"}'
curl -s https://ENDPOINT/flows -H 'Authorization: Bearer ACCESS_TOKEN'
```

To change the admin password, update the secret and restart:

```bash
cpln secret edit my-node-red-admin
cpln workload force-redeployment {release}-node-red --gvc {gvc}
```

## Important Notes

- **Editor access is shell access.** Function and exec nodes run any code in the container, so treat the admin login like a shell password. Node-RED has no sign-in rate limit; keep the password long.
- **One replica, short restarts.** Every upgrade, restart or secret change restarts the single replica: flows, HTTP endpoints and the Dashboard pause for that time. Inject nodes set to run at start fire again.
- **Location.** A workload runs in every location of its GVC; this chart scales Node-RED to zero everywhere except `location`. A `location` your GVC does not have starts nothing, with no error.
- **Restoring a snapshot** replaces `/data` and restarts Node-RED onto it. List the snapshots, then restore one:

  ```bash
  cpln volumeset snapshot get {release}-node-red-data --gvc {gvc}
  cpln volumeset snapshot restore {release}-node-red-data --gvc {gvc} --snapshot-name SNAPSHOT_NAME --location LOCATION --volume-index 0
  ```

- **A crashing flow.** Set `safeMode: true` and upgrade: the editor starts without running flows. Fix the flow, deploy it, then set `safeMode: false`.
- **Uninstalling** deletes the volume set after a final snapshot, kept for `backup.retention`. The secrets you created are not deleted.

## Links

- [Node-RED documentation](https://nodered.org/docs/)
- [Securing Node-RED](https://nodered.org/docs/user-guide/runtime/securing-node-red)
- [Node-RED Admin HTTP API](https://nodered.org/docs/api/admin/)
- [Node-RED Dashboard 2.0](https://dashboard.flowfuse.com/)
- [Node-RED Docker image](https://hub.docker.com/r/nodered/node-red)
