## External Secret Syncer (ESS)

### Overview

Creates an application that continuously syncs secrets from external providers into Control Plane secrets on a configurable schedule. Supported providers: **HashiCorp Vault**, **AWS Secrets Manager**, **AWS Parameter Store**, **Doppler**, **GCP Secret Manager**, **1Password**, **1Password Connect**, and **Infisical**.

---

### How It Works

ESS runs as a workload on Control Plane. Your provider configuration and secrets list are stored in a Control Plane secret and mounted into the workload as `sync.yaml`. On startup, ESS schedules a polling loop for each configured secret. At each interval, it fetches the latest value from the external provider and creates or updates the corresponding Control Plane secret via the API.

ESS tags every secret it manages with `syncer.cpln.io/source` (set to the workload path). This prevents two ESS instances from accidentally overwriting each other's secrets.

---

### Patch Notes

This version adds automatic base64 handling to `discoverAllSecrets`: a discovered opaque secret whose value is canonical base64 is marked `encoding: base64`, so Control Plane decodes the payload when workloads consume it. Add a `cpln-encoding: disable` label to a GCP secret to opt it out and store its value verbatim.

> **Upgrade note:** On the first sync after upgrading, any already-discovered opaque secret whose value looks like base64 is re-written with `encoding: base64`, and workloads consuming it start receiving the **decoded** value. If a consumer decodes such a secret itself today, label the GCP secret `cpln-encoding: disable` **before** upgrading to keep the current behavior.

### Prerequisites

**One `opaque` secret must exist BEFORE you install**, holding your entire `sync.yaml`.

The sync configuration carries provider credentials — a Vault token, AWS access keys, a 1Password service
account token — so it is not a value. A value would put every one of them in the Helm release. It is also a
configuration *file* rather than a set of environment variables, and a `cpln://secret` reference inside a file
is never resolved, so individual keys cannot be swapped out either. The whole file is therefore yours.

Write your configuration to a file:

```yaml
# sync.yaml
providers:
  - name: my-vault
    vault:
      address: https://my-vault.com:8200
      token: YOUR-VAULT-TOKEN
    syncInterval: 1m
secrets:
  - name: my-app-secret
    provider: my-vault
    type: opaque
    path: secret/data/my-app
    key: password
```

Then create the secret from it and set `configSecretName` to the name you used:

```bash
cpln secret create-opaque --name my-ess-config --encoding plain -f sync.yaml
```

The schema for `providers` and `secrets` is documented below — it is unchanged, it simply lives in this file
now instead of under `essConfig` in your values.

**If the secret does not exist at install time, the deployment wedges silently.** `cpln logs` returns
**zero lines**. Read `status.versions[].message`:

```bash
cpln workload get-deployments RELEASE_NAME-ess --gvc GVC_NAME -o yaml
```

<b>Upgrading from 2.0.x:</b> move your existing `essConfig` block into `sync.yaml` verbatim — the keys are
identical, only the top-level `essConfig:` wrapper goes away — create the secret, and delete `essConfig` from
your values. An upgrade that still carries `essConfig` is refused at render. Rotate any credential that was in
your values file, since it was stored in the Helm release.

### Configuring `values.yaml`

#### Top-level fields

| Field | Description |
|---|---|
| `image` | The ESS container image. Do not change unless upgrading. |
| `resources.cpu` / `resources.memory` | Resource limits for the workload container. |
| `port` | Port for the ESS HTTP admin API (default: `3004`). Used for health checks and manual sync triggers. |
| `allowedIp` | List of CIDRs allowed to reach the ESS admin API externally. Replace the placeholder with your IP, or use `0.0.0.0/0` to allow all. |
| `configSecretName` | Name of the `opaque` secret holding your `sync.yaml` — the full sync configuration. See [Prerequisites](#prerequisites). |

---

#### `providers`

Each provider entry requires a unique `name` and exactly one provider block. An optional `syncInterval` sets the default interval for all secrets using that provider.

**Vault**
```yaml
- name: my-vault
  vault:
    address: https://my-vault.com:8200  # required
    token: <TOKEN>                       # required
  syncInterval: 1m                       # optional — overrides global default
```

**AWS Parameter Store**
```yaml
- name: my-aws-ssm
  awsParameterStore:
    region: us-east-1
    accessKeyId: <ACCESS_KEY>       # optional if using an IAM-linked identity
    secretAccessKey: <SECRET_KEY>   # optional if using an IAM-linked identity
```

**AWS Secrets Manager**
```yaml
- name: my-aws-secrets-manager
  awsSecretsManager:
    region: us-east-1
    accessKeyId: <ACCESS_KEY>
    secretAccessKey: <SECRET_KEY>
```

**Doppler**
```yaml
- name: my-doppler
  doppler:
    accessToken: <TOKEN>  # use a Doppler service token (dp.st....)
```

**GCP Secret Manager**
```yaml
- name: my-gcp
  gcpSecretManager:
    projectId: 123456789876
    credentials:                    # optional — omit to use Application Default Credentials
      clientEmail: <EMAIL>
      privateKey: <PRIVATE_KEY>
```

**1Password**
```yaml
- name: my-1password
  onePassword:
    serviceAccountToken: <TOKEN>
    integrationName: my-ess         # optional
    integrationVersion: 1.0.0       # optional
```

**1Password Connect**
```yaml
- name: my-1password-connect
  onePasswordConnect:
    serverURL: https://my-connect-server.example.com  # required
    token: <TOKEN>                                     # required
```

**Infisical**
```yaml
- name: my-infisical
  infisical:
    clientId: <CLIENT_ID>          # required — from an Infisical machine identity
    clientSecret: <CLIENT_SECRET>  # required
    projectId: <PROJECT_ID>        # required
```

---

#### `secrets`

Each secret entry syncs one value (or a set of values) from a provider into a Control Plane secret.

| Field | Description |
|---|---|
| `name` | Name of the Control Plane secret to create or update. |
| `provider` | Must match a provider `name` defined above. |
| `syncInterval` | Optional. Overrides the provider-level and global default for this specific secret. |

Each secret must use exactly one of the following sync types:

---

##### `opaque` — Single value (stored as a Control Plane `opaque` secret)

Shorthand (path only, no fallback):
```yaml
- name: my-secret
  provider: my-vault
  opaque: /v1/secret/data/myapp
```

With options:
```yaml
- name: my-secret
  provider: my-vault
  opaque:
    path: /v1/secret/data/myapp    # path to fetch
    parse: data.password           # optional — extract a key from a JSON/YAML response
    default: fallback-value        # optional — used if fetch fails
    encoding: base64               # optional — base64-decode the fetched value
```

> **Note:** If you use the shorthand form (`opaque: /some/path`) with no `default`, a fetch failure causes the sync to fail with no fallback.

---

##### `dictionary` — Multiple values (stored as a Control Plane `dictionary` secret)

Each key in the dictionary is fetched independently:
```yaml
- name: my-secret
  provider: my-vault
  dictionary:
    PORT:
      path: /v1/secret/data/app
      parse: data.port
      default: 5432
    PASSWORD:
      path: /v1/secret/data/app
      parse: data.password
    USERNAME:
      path: /v1/secret/data/app
      parse: data.username
      default: "no username"
```

Each key supports `path`, `parse`, `default`, and `encoding` — the same options as `opaque`. A failure on one key does not block others.

---

##### `dictionaryFromProject` — Sync an entire project (Doppler or GCP Secret Manager)

Syncs all secrets from a provider project in one operation, stored as a Control Plane `dictionary` secret. The expected shape depends on the provider.

**Doppler** — specify a `project/config` path:
```yaml
- name: my-doppler-config
  provider: my-doppler
  dictionaryFromProject:
    path: my-project/dev    # format: "project/config" — exactly two segments
```

**GCP Secret Manager** — set to `true` to pull every accessible secret from the project configured on the provider:
```yaml
- name: my-gcp-config
  provider: my-gcp
  dictionaryFromProject: true
```

Each fetched secret's latest version becomes one key in the resulting dictionary. Secrets with no accessible latest version (no versions, disabled, or destroyed) are skipped.

> **Note:** `dictionaryFromProject` is only valid with the Doppler or GCP Secret Manager providers. Doppler requires the `{ path: ... }` object form; GCP requires the `true` form. Mixing them (or using either with another provider) causes ESS to exit at startup.

---

##### `dictionaryFromJson` — Flatten a JSON object (any provider)

Fetches a single value containing a JSON object and flattens it into a Control Plane `dictionary` secret. Set it to the path of the value to fetch. Valid with any provider.

```yaml
- name: json-config
  provider: my-aws-secrets-manager
  dictionaryFromJson: /example/app/config   # path to a value holding a JSON object
```

Each leaf in the JSON object becomes one dictionary key:

- **Nested objects** are flattened using dot notation (`{ "db": { "host": "x" } }` → key `db.host`).
- **Arrays** are JSON-stringified into the value (`{ "tags": ["a", "b"] }` → key `tags` with value `["a","b"]`).
- **`null`** is stored as the string `"null"`; numbers and booleans are stored as their string form.

For example, `{"db":{"host":"db.internal","port":5432},"tags":["a","b"]}` produces a dictionary with keys `db.host` (`db.internal`), `db.port` (`5432`), and `tags` (`["a","b"]`).

> **Note:** If the fetched value is not a valid JSON object — a raw string, number, array, or malformed JSON — ESS stores the raw value under a single `__raw` key and logs a warning, so the secret stays usable as a dictionary type.

---

##### `discoverAllSecrets` — Mirror an entire GCP project (one secret each)

Discovers every accessible secret in the GCP project configured on the provider and creates a **separate** Control Plane secret for each one. This differs from `dictionaryFromProject: true`, which combines every secret into a single dictionary. GCP Secret Manager only.

```yaml
- name: gcp-discover        # identifier only — created secrets are named after the GCP secrets
  provider: my-gcp
  discoverAllSecrets: true
```

The type of each created secret is controlled by a `cpln-type` **label** on the GCP secret:

- `cpln-type: dictionary` — the value is parsed as JSON and flattened into a Control Plane `dictionary` secret (same flattening rules as `dictionaryFromJson`, including the `__raw` fallback for non-JSON values).
- `cpln-type: opaque` (or no label) — stored as a Control Plane `opaque` secret.

Opaque values that are canonical base64 are automatically marked `encoding: base64` on the created Control Plane secret, so the payload is decoded when workloads consume it. Surrounding whitespace (such as a trailing newline from `... | base64 | gcloud ...`) is trimmed from the stored payload. Detection can be switched off per secret with a `cpln-encoding` **label** on the GCP secret:

- `cpln-encoding: disable` — the value is stored verbatim and never marked `encoding: base64`. Use this for plain values that happen to look like base64 (for example, a 16-character alphanumeric API key).

Each Control Plane secret is named after its GCP secret, normalized to a valid Control Plane name (lowercased, with unsupported characters such as `_` replaced by `-` — e.g. `MY_API_KEY` → `my-api-key`). If two names normalize to the same value, the last one wins and a warning is logged. Created secrets carry a `syncer.cpln.io/discoveredBy` tag set to this entry's `name`. Secrets with no accessible latest version (no versions, disabled, or destroyed) are skipped.

> **Note:** `discoverAllSecrets` is only valid with a GCP Secret Manager provider, and must be set to `true`. ESS does not delete a discovered Control Plane secret when its source GCP secret is later removed (see [Important Notes](#important-notes)).

---

#### Doppler Path Formats

| Sync type | Path format | Example |
|---|---|---|
| `opaque` or `dictionary` key | `project/config/SECRET_NAME` | `my-app/production/DATABASE_URL` |
| `dictionaryFromProject` | `project/config` | `my-app/production` |

---

#### Infisical Path Formats

The Infisical project is set on the provider (`infisical.projectId`). Secret paths are scoped to an environment within that project.

| Sync type | Path format | Example |
|---|---|---|
| `opaque` or `dictionary` key | `<environmentID>/<secret>` | `dev/DATABASE_URL` |

---

#### Sync Interval Format

Intervals use the format `<hours>h<minutes>m<seconds>s`. All parts are optional but at least one is required.

Examples: `10s`, `5m`, `1h`, `1h30m`, `1h30m10s`

Priority (highest wins):
1. Secret-level `syncInterval`
2. Provider-level `syncInterval`
3. Global default (`300s`)

---

### Important Notes

- **Conflict protection:** If a Control Plane secret already exists and is managed by a different ESS instance, the sync for that secret will fail. Two ESS instances cannot manage the same secret.
- **Secret type changes:** Changing a secret from `opaque` to `dictionary` (or vice versa) causes ESS to delete the existing secret and recreate it. There is a brief window where the secret does not exist.
- **No automatic deletion:** ESS only creates and updates secrets — it never deletes them. Removing a secret from `sync.yaml`, or deleting a source secret upstream, leaves the existing Control Plane secret in place; delete unwanted secrets manually. ESS-managed secrets carry the `syncer.cpln.io/source` tag (and discovered secrets additionally carry `syncer.cpln.io/discoveredBy`) to help identify them.
- **Doppler `parse`:** The `parse` field only works when the Doppler secret's value is JSON or YAML. Using `parse` on a plain string secret throws an error.
- **`sync.yaml` hot reload:** ESS watches its config file and automatically restarts when changes are detected (every ~5 seconds). No workload restart is needed after updating the config secret.

### Resources

- [ESS Documentation](https://docs.controlplane.com/template-catalog/templates/ess)
- [Image Source Code](https://github.com/controlplane-com/external-secret-syncer)