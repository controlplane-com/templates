# OpenBao

OpenBao is the Linux Foundation's open-source (MPL-2.0) fork of HashiCorp Vault — an identity-based secrets engine with a Vault-compatible API: KV storage, dynamic secrets, PKI, and transit encryption. This template deploys a single-node OpenBao server with integrated raft storage and hands-free auto-unseal.

## Architecture

- **OpenBao server** — a `stateful` workload (`{release}-openbao`, HTTP API + web UI on port 8200) with integrated raft storage; auto-unseals itself on every boot.
- **Volumeset** — persistent raft data (`/openbao/data`): all secrets, auth config, and cluster state. A final snapshot is kept 7 days on uninstall.
- **Config secret** — the rendered HCL server config, file-mounted.
- **Identity + policy** — `reveal` on exactly the secrets the server mounts; in the KMS seal modes the identity carries keyless (credential-free) cloud access scoped to the one KMS key.

## Prerequisites

- **Static seal (default): an opaque unseal-key secret — create it BEFORE installing.** The workload references it by name (`seal.static.secretName`, default `my-openbao-unseal-key`) and the deployment wedges on a missing secret:

  ```bash
  printf '%s' "$(openssl rand -hex 32)" | cpln secret create-opaque --name my-openbao-unseal-key --encoding plain -f -
  ```

  **WRITE-ONCE — never change or delete this secret.** It wraps OpenBao's encryption barrier; losing or rotating it makes all stored data permanently unrecoverable.

- **KMS seal modes (`awskms` / `gcpckms`)**: a KMS key, a Control Plane cloud account, and a scoped grant — see **Auto-unseal setup** below. No unseal-key secret is needed.

## Configuration

### OpenBao server

```yaml
openbao:
  image: openbao/openbao:2.6.1   # 2.6.x pinned deliberately (2.7 moves KMS seals to external plugins)
  resources:
    minCpu: 250m
    maxCpu: 1000m
    minMemory: 256Mi
    maxMemory: 1Gi
```

### Seal / auto-unseal

```yaml
seal:
  type: static                   # static | awskms | gcpckms — one mode only

  static:
    secretName: my-openbao-unseal-key   # opaque secret with a 32-byte hex/base64 key — MUST exist before install

  aws:                           # used only with type: awskms
    kmsKeyId: arn:aws:kms:us-east-1:111111111111:key/my-openbao-kms-key   # key ARN (or ID/alias)
    region: us-east-1
    cloudAccountName: my-aws-cloud-account
    policyName: my-openbao-kms-policy   # your IAM policy granting Encrypt/Decrypt/DescribeKey on the key

  gcp:                           # used only with type: gcpckms
    project: my-gcp-project
    region: global               # key ring location
    keyRing: my-openbao-keyring
    cryptoKey: my-openbao-key
    cloudAccountName: my-gcs-cloud-account
```

### Storage

```yaml
volumeset:
  capacity: 10                   # GiB (minimum 10) — raft data: all secrets, auth config, cluster state
```

### Access

```yaml
publicAccess:
  enabled: false                 # true = HTTPS API + web UI on the auto *.cpln.app endpoint
internalAccess:
  type: same-gvc                 # none | same-gvc | same-org | workload-list
  workloads: []                  # used only with workload-list
```

## Auto-unseal setup (KMS modes)

### AWS KMS (`seal.type: awskms`)

Access is keyless — the workload identity federates into your AWS account through a Control Plane cloud account; no static credentials anywhere.

1. Create (or pick) a symmetric KMS key. Set `seal.aws.kmsKeyId` to its ARN and `seal.aws.region` to its region.
2. If you do not have one, [create an AWS Cloud Account](https://docs.controlplane.com/guides/create-cloud-account). Set `seal.aws.cloudAccountName`.
3. Create an IAM policy with the following JSON (replace the ARN with your key's) and set `seal.aws.policyName` to its name:

```JSON
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "kms:Encrypt",
                "kms:Decrypt",
                "kms:DescribeKey"
            ],
            "Resource": "arn:aws:kms:us-east-1:111111111111:key/YOUR_KEY_ID"
        }
    ]
}
```

### GCP Cloud KMS (`seal.type: gcpckms`)

1. Create a key ring + symmetric crypto key in Cloud KMS. Fill in `seal.gcp.project`, `region` (key ring location), `keyRing`, and `cryptoKey`.
2. If you do not have one, [create a GCP Cloud Account](https://docs.controlplane.com/guides/create-cloud-account). Set `seal.gcp.cloudAccountName`.
3. No manual IAM step — the template binds `roles/cloudkms.cryptoKeyEncrypterDecrypter` on exactly that crypto key to the workload identity.

## First run — initialize once

The server boots reachable but **uninitialized**. Initialize it exactly once:

```bash
cpln workload exec {release}-openbao --gvc {gvc} --container openbao -- bao operator init
```

**Save the printed recovery keys and initial root token immediately — they are shown once and stored nowhere.** The template never touches them. From then on, every restart auto-unseals with zero manual steps. Log in (`bao login <root-token>` or the web UI), create scoped auth (e.g. userpass/OIDC), then revoke the root token per standard practice.

## Connecting

| Target | Address | Credentials |
|---|---|---|
| Internal (same GVC) | `http://{release}-openbao.{gvc}.cpln.local:8200` | OpenBao token / auth method |
| Public API + UI (if enabled) | `https://<canonical>.cpln.app` (UI at `/ui/`) | OpenBao token / auth method |
| Health | `GET /v1/sys/health` | none |

External clients use `https://` (the platform edge terminates TLS); same-GVC clients use plain `http://` over the mesh's mTLS. The canonical hostname appears under `status.canonicalEndpoint` (`cpln workload get {release}-openbao -o yaml`).

## Important Notes

- **Static mode: the unseal-key secret must exist before install and is WRITE-ONCE** — a missing secret wedges the deployment; a lost or changed key makes all stored data unrecoverable. Back the key up securely.
- **Run `bao operator init` once after install and save the output** — recovery keys and the root token are printed once, to your terminal only.
- **Do not switch `seal.type` after initialization** — the seal wraps the existing data; changing modes requires an OpenBao seal migration, not a values change.
- **Data survives restarts and upgrades; uninstall deletes the volumeset** (final snapshot kept 7 days). A reinstall starts uninitialized.
- **Private by default** — set `publicAccess.enabled: true` to expose the API + web UI on the canonical endpoint.

## Links

- [OpenBao docs](https://openbao.org/docs/)
- [Seal / auto-unseal configuration](https://openbao.org/docs/configuration/seal/)
- [Raft storage](https://openbao.org/docs/configuration/storage/raft/)
- [operator init](https://openbao.org/docs/commands/operator/init/)
- [GitHub](https://github.com/openbao/openbao)
