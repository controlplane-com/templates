## External Secret Syncer (ESS)

### Overview

Creates an application that continuously syncs secrets from external providers into Control Plane secrets on a configurable schedule. Supported providers: **HashiCorp Vault**, **AWS Secrets Manager**, **AWS Parameter Store**, **Doppler**, **GCP Secret Manager**, **1Password**, and **1Password Connect**.

---

### How It Works

ESS runs as a workload on Control Plane. Your provider configuration and secrets list are stored in a Control Plane secret and mounted into the workload as `sync.yaml`. On startup, ESS schedules a polling loop for each configured secret. At each interval, it fetches the latest value from the external provider and creates or updates the corresponding Control Plane secret via the API.

ESS tags every secret it manages with `syncer.cpln.io/source` (set to the workload path). This prevents two ESS instances from accidentally overwriting each other's secrets. An hourly cleanup job also deletes any Control Plane secrets that ESS owns but that have been removed from your `sync.yaml` config.

---

### Configuring `values.yaml`

#### Top-level fields

| Field | Description |
|---|---|
| `image` | The ESS container image. Do not change unless upgrading. |
| `resources.cpu` / `resources.memory` | Resource limits for the workload container. |
| `port` | Port for the ESS HTTP admin API (default: `3004`). Used for health checks and manual sync triggers. |
| `allowedIp` | List of CIDRs allowed to reach the ESS admin API externally. Replace the placeholder with your IP, or use `0.0.0.0/0` to allow all. |
| `essConfig` | The full sync configuration — providers and secrets (see below). |

---

#### `essConfig.providers`

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

---

#### `essConfig.secrets`

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

##### `dictionaryFromProject` — Entire Doppler project (Doppler only)

Syncs all secrets from a Doppler project+config in one operation, stored as a Control Plane `dictionary` secret:
```yaml
- name: my-doppler-config
  provider: my-doppler
  dictionaryFromProject:
    path: my-project/dev    # format: "project/config" — exactly two segments
```

> **Note:** `dictionaryFromProject` is only valid with a Doppler provider. Using it with any other provider causes ESS to exit at startup.

---

#### Doppler Path Formats

| Sync type | Path format | Example |
|---|---|---|
| `opaque` or `dictionary` key | `project/config/SECRET_NAME` | `my-app/production/DATABASE_URL` |
| `dictionaryFromProject` | `project/config` | `my-app/production` |

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
- **Cleanup:** ESS runs an hourly job that deletes Control Plane secrets it owns but that no longer appear in `sync.yaml`. Removing a secret from the config will eventually result in its deletion from Control Plane.
- **Doppler `parse`:** The `parse` field only works when the Doppler secret's value is JSON or YAML. Using `parse` on a plain string secret throws an error.
- **`sync.yaml` hot reload:** ESS watches its config file and automatically restarts when changes are detected (every ~5 seconds). No workload restart is needed after updating the config secret.

### Resources

- [ESS Documentation](https://docs.controlplane.com/template-catalog/templates/external-secret-syncer)
- [Image Source Code](https://github.com/controlplane-com/external-secret-syncer)