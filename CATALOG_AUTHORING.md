# Authoring catalog entries (`catalog.yaml`)

> **Keep in sync.** Update this guide, `.claude/skills/catalog-authoring/SKILL.md` and `.schema/catalog.v1.schema.json` in the same commit as any change to the catalog entry spec.

Every template has one `catalog.yaml` at its root, next to `icon.png`. It describes what the template is for, in the words someone would use to look for it. The marketplace search reads it to rank templates for a request such as "vector database for RAG" or "self-hosted Google Analytics". Most of those requests come from AI agents that pick and install a template for a user. The Console catalog uses it too.

A person or an agent should be able to write, update or review a `catalog.yaml` from this guide alone.

## Contents

- [1. Rules](#1-rules)
- [2. A complete example](#2-a-complete-example)
- [3. Field reference](#3-field-reference)
- [4. Vocabularies](#4-vocabularies)
- [5. How search uses each field](#5-how-search-uses-each-field)
- [6. Procedure](#6-procedure)
- [7. Validation](#7-validation)
- [8. Review checklist](#8-review-checklist)
- [9. Common mistakes](#9-common-mistakes)

---

## 1. Rules

1. **Required.** Every template has a `catalog.yaml`. CI rejects a template without one, or with an invalid one, and the marketplace drops such a template from the catalog: it can't be installed or upgraded until the file is fixed. Library charts (`type: library`, such as `cpln-common`) need none. A template that must not be public, such as a test app, sets `internal: true` instead of the search fields (§2).
2. **It describes the latest version.** Search shows only the latest version. When a new version changes what the template deploys, its prerequisites or its topology, update `catalog.yaml` in the same pull request.
3. **It lives outside `versions/`.** Published versions are immutable, but this file is not part of any chart package. Improve it at any time without publishing a chart version.
4. **The chart is the truth.** Claim only what the latest version actually deploys. The chart wins over the README, and the README wins over upstream docs.
5. **Write for a reader who is choosing.** Plain, specific and factual. No marketing ("powerful", "seamless", "blazing fast", "enterprise-grade"), no version numbers (they go stale), no "for Control Plane" (every template is).
6. **Template names go only in template fields.** `family`, `pickInsteadIf[].template` and `related[].template` hold template names from this repo. `alternativeTo` holds names of products outside this repo and never a template name.
7. **Don't list what it can't do.** Every word in `keywords`, `useCases` and `summary` makes the template rank for searches with that word. Needs the template does not cover go in `pickInsteadIf`, which points to the template that covers them.

---

## 2. A complete example

`postgres/catalog.yaml`:

```yaml
# yaml-language-server: $schema=../.schema/catalog.v1.schema.json
apiVersion: catalog.controlplane.com/v1
kind: TemplateCatalogEntry

title: PostgreSQL
category: database
topology: single
# family: postgres         # omitted: it defaults to this template's own name

summary: >-
  A single PostgreSQL server on a persistent, snapshotted volume, with an optional PgBouncer
  connection pooler and optional scheduled pg_dump backups to S3, GCS or an S3-compatible
  endpoint. The default relational database for an app in one location.

keywords:
  - postgresql
  - pg
  - sql
  - relational database
  - rdbms
  - pgbouncer
  - connection pooling
  - pg_dump
  - database backups

useCases:
  - Relational database for a web app or API
  - Transactional SQL datastore for a service in one location
  - Development or staging database that mirrors a production Postgres

alternativeTo:
  - Amazon RDS for PostgreSQL
  - Google Cloud SQL for PostgreSQL
  - Azure Database for PostgreSQL
  - Heroku Postgres
  - Neon

compatibleWith: [postgres-wire]

pickInsteadIf:
  - need: automatic failover inside one location
    template: postgres-highly-available
  - need: one cluster across several locations that survives losing a location
    template: postgres-multi-location
  - need: active-active writes in several regions
    template: pgedge
  - need: vector similarity search on embeddings
    template: pgvector
  - need: geospatial data and queries
    template: postgis
  - need: time-series data with hypertables and compression
    template: timescaledb

related:
  - template: pgdog
    relation: companion
    note: Connection pooler, load balancer and sharding proxy in front of Postgres

prerequisites:
  - kind: secret
    secretType: dictionary
    keys: [username, password, database]
    valuesPath: config.credentialsSecretName
    required: true
    description: Database credentials. Create it before installing; when it is missing the workload waits with no logs.
  - kind: bucket
    valuesPath: [backup.aws.bucket, backup.gcp.bucket, backup.minio.bucket]
    required: false
    when: backup.enabled
    description: Object storage bucket that receives the scheduled backups.
  - kind: cloud-account
    valuesPath: [backup.aws.cloudAccountName, backup.gcp.cloudAccountName]
    required: false
    when: backup.enabled with backup.provider aws or gcp
    description: Control Plane cloud account for the backup bucket, plus a bucket-scoped IAM policy on AWS.
  - kind: secret
    secretType: dictionary
    keys: [accessKey, secretKey]
    valuesPath: backup.minio.credentialsSecretName
    required: false
    when: backup.enabled with backup.provider minio
    description: Access keys for the MinIO or S3-compatible backup endpoint.
```

The same family seen from the variant, `postgres-highly-available/catalog.yaml` (abridged):

```yaml
title: PostgreSQL (highly available)
category: database
family: postgres
topology: highly-available
pickInsteadIf:
  - need: one cluster across several locations that survives losing a location
    template: postgres-multi-location
```

A template that must not be public, `test-app/catalog.yaml` (complete):

```yaml
# yaml-language-server: $schema=../.schema/catalog.v1.schema.json
apiVersion: catalog.controlplane.com/v1
kind: TemplateCatalogEntry
internal: true
```

Search never returns an internal template. Where it appears in the catalog still follows its `environments.yaml` (the test apps stay on staging), and the catalog shows its `Chart.yaml` category. Use `internal: true` only for templates nobody should find by searching: test apps and internal tools.

---

## 3. Field reference

| Field | Required | Constraints |
|---|---|---|
| `apiVersion` | yes | `catalog.controlplane.com/v1` |
| `kind` | yes | `TemplateCatalogEntry` |
| `title` | yes | 1 to 60 characters |
| `category` | yes | one value from §4.1 |
| `topology` | yes | one value from §4.2 |
| `family` | no | an existing template name; defaults to this template's name |
| `summary` | yes | 100 to 600 characters |
| `keywords` | yes | 3 to 25 unique entries, lowercase, each up to 40 characters |
| `useCases` | yes | 2 to 8 entries, each up to 120 characters |
| `alternativeTo` | no | up to 12 entries, each up to 60 characters, none a template name |
| `compatibleWith` | no | values from §4.3 |
| `pickInsteadIf` | no | up to 10 `{need, template}` entries |
| `related` | no | up to 10 `{template, relation, note?}` entries |
| `prerequisites` | yes | a list; `[]` when the default install needs nothing created first |
| `internal` | no | `true` keeps the template out of search; then only `apiVersion` and `kind` are required, and every other field is ignored |

### `title`

The product name as people write it: `PostgreSQL`, `Apache Kafka`, `n8n`. A variant names its difference in parentheses: `PostgreSQL (highly available)`, `Redis (multi-location)`.

### `category`

The one category a person would browse to find it. It replaces the free-form `category` annotation in `Chart.yaml` everywhere the catalog is shown. Keep the annotation, because `Chart.yaml` still requires it.

### `topology`

How the template's main component runs: the component the template is named after, not its bundled database. See §4.2.

### `family`

Groups templates that deploy the same software in different topologies, such as `postgres`, `postgres-highly-available` and `postgres-multi-location`. The value is the name of the family's default member, usually the simplest one. Search shows one result per family and lists the other members as variants. The result is the variant the query names ("redis cluster") or whose topology it asks for ("postgres with automatic failover"); otherwise it is the default member.

Software that is a different product built on the same base gets its own family. `pgvector`, `postgis` and `timescaledb` are not in the `postgres` family.

### `summary`

Two to four sentences:

1. What it is and what it deploys, by component.
2. The choices it offers, such as optional pooling, backups or HA.
3. When it is the right pick.

Don't copy the `Chart.yaml` description, which is a 15-word card line. Name the software, don't describe a Helm chart.

### `keywords`

Words and short phrases someone might search for that are not already in the title. Include:

- other spellings and abbreviations (`postgresql`, `pg`);
- the generic kind of thing (`relational database`, `message queue`);
- protocols and standards it implements (`oidc`, `s3`);
- notable components it deploys (`pgbouncer`, `patroni`);
- capabilities it really has (`database backups`).

Lowercase. Avoid words every template shares (`self-hosted`, `open source`, `kubernetes`, `cloud`, `deploy`).

### `useCases`

Problems it solves, phrased the way a user would state them. Write "Store and query vector embeddings for retrieval-augmented generation", not "pgvector extension enabled". Each entry starts with a noun or a verb, and none mentions Control Plane.

### `alternativeTo`

Products outside this repo that this template can replace: SaaS products, managed cloud services and other software. Use each product's official name and capitalization, as in `Amazon RDS for PostgreSQL`, `Google Analytics` and `Auth0`.

These are what people mean when they ask for "something like X, but self-hosted". Never put a template from this repo here; that goes in `related`.

### `compatibleWith`

The APIs and wire protocols the template's service speaks, so that existing clients, drivers and SDKs work unchanged. Use values from §4.3 only; to add one, extend the vocabulary in this guide and the schema.

### `pickInsteadIf`

Needs this template does not meet, each with the template in this repo that meets it:

```yaml
pickInsteadIf:
  - need: automatic failover inside one location   # a need, in the reader's words; up to 120 characters
    template: postgres-highly-available            # must exist, must not be this template
```

This field is how search helps a reader choose between near neighbours. List the realistic confusions only. A need that no template covers belongs in `summary` instead.

### `related`

Other templates often used together with this one, or that solve the same problem without one deciding need:

```yaml
related:
  - template: ollama
    relation: companion      # companion | alternative
    note: Runs the local models that Open WebUI chats with   # optional, up to 120 characters
```

- `companion`: a separate template often installed alongside this one.
- `alternative`: another template for the same job where no single need decides between them (`kafka` and `redpanda`). When one need does decide, use `pickInsteadIf`.

Don't list templates this chart bundles as subcharts. Search reads those from the `Chart.yaml` `dependencies`.

### `prerequisites`

Everything someone must create before installing, plus what optional features need. This is the most common install failure, so be complete. Read the README's Prerequisites section, the `values.yaml` comments and every `cpln://secret/...` in `templates/`.

| Key | When | Meaning |
|---|---|---|
| `kind` | always | one value from §4.4 |
| `description` | always | what it is and what happens without it; up to 200 characters |
| `required` | always | `true` when the default install fails or waits without it |
| `when` | `required: false` | the values that make it needed, e.g. `backup.enabled with backup.provider minio` |
| `valuesPath` | when values take its name | the values key, or a list when the key depends on a provider |
| `secretType` | `kind: secret` | one value from §4.5 |
| `keys` | `secretType: dictionary` | the dictionary keys the template reads |

A secret the template creates by itself is not a prerequisite.

---

## 4. Vocabularies

### 4.1 `category`

| Value | For |
|---|---|
| `database` | relational, document, wide-column, time-series, graph and vector databases |
| `cache` | in-memory caches and key-value stores used as caches |
| `messaging` | message queues, task queues, brokers, event streaming and change data capture |
| `search` | full-text and search engines |
| `storage` | object, file and block storage, file transfer |
| `analytics` | analytics engines, query engines, BI and product analytics |
| `observability` | metrics, logs, traces, dashboards, uptime and error tracking |
| `ai` | model serving, LLM gateways, AI agents and AI tooling |
| `identity` | authentication, SSO and user management |
| `secrets` | secret stores and secret synchronisation |
| `security` | firewalls, scanners and policy enforcement |
| `networking` | gateways, proxies, VPNs and remote access |
| `workflow` | workflow automation, orchestration and durable execution |
| `developer-tools` | tools for developers and operators, such as git hosting, database GUIs, feature flags and CI |
| `apps` | end-user applications: CRM, CMS and publishing, support desks, newsletters, knowledge bases, internal tools |

### 4.2 `topology`

Take the first value that applies:

| Value | Applies when the main component |
|---|---|
| `multi-location` | runs in several GVC locations and keeps working after losing one |
| `distributed` | is a cluster where the software partitions or replicates data across nodes by itself (sharding, a consensus quorum) |
| `highly-available` | has standbys that take over automatically inside one location |
| `single` | is one instance with persistent state and no automatic failover |
| `stateless` | keeps no persistent state of its own, so its replicas are interchangeable |

### 4.3 `compatibleWith`

`postgres-wire`, `mysql-wire`, `mongodb-wire`, `redis-protocol`, `cql`, `kafka-api`, `amqp`, `mqtt`, `nats`, `s3-api`, `openai-api`, `otlp`, `prometheus-remote-write`, `promql`, `elasticsearch-api`, `oidc`, `saml`, `ldap`, `smtp`, `iceberg-rest`, `sftp`, `ftp`, `webdav`

### 4.4 `prerequisites[].kind`

`secret`, `cloud-account`, `bucket`, `domain`, `other`

### 4.5 `prerequisites[].secretType`

The Control Plane secret types: `opaque`, `dictionary`, `tls`, `userpass`, `keypair`, `aws`, `ecr`, `gcp`, `azure-sdk`, `azure-connector`, `docker`, `nats-account`

---

## 5. How search uses each field

Knowing this explains the rules above. Weights are tuned against a set of real queries, so only the order is stable:

1. **Strongest:** the template name, `title`, `keywords` and `alternativeTo`. A template whose name, keyword or `alternativeTo` product appears in the query gets an extra boost, larger the more of the query it covers. When the query asks for an alternative ("Sentry alternative"), only names and `alternativeTo` count: a keyword such as "slack digest" says the template works with Slack, not that it replaces Slack.
2. **Strong:** `useCases` and `summary`.
3. **Medium:** the `Chart.yaml` description, `category` and `compatibleWith`.
4. **Weak:** the latest version's README; upgrade and migration sections are skipped.

How `pickInsteadIf` is indexed: each `need` counts as text of the template it points to, never of the template that declares it. `postgres` saying "automatic failover → postgres-highly-available" makes `postgres-highly-available` rank higher for "postgres with automatic failover", and does not make `postgres` rank for it.

What appears in results: `title`, `summary`, `useCases`, `alternativeTo`, `compatibleWith`, `topology`, `prerequisites`, `pickInsteadIf`, `related` and the family's variants. Search returns these to agents verbatim, so write them to stand alone.

---

## 6. Procedure

Run everything from the repo root. `T=<template>` and `D=$T/versions/<latest version>`.

1. **Gather the facts:**
   ```sh
   sed -n '1,/^## Configuration/p' $D/README.md                     # intro, architecture, prerequisites
   grep -n 'description\|dependencies' -A12 $D/Chart.yaml | head -40   # card line, bundled subcharts
   grep -rn 'cpln://secret' $D/templates/                             # secrets the chart reads
   grep -n -i 'secretName\|cloudAccount\|bucket\|REQUIRED' $D/values.yaml
   grep -rn 'localOptions\|staticPlacement\|locations' $D/templates/ $D/values.yaml | head   # multi-location?
   ```
2. **Find the neighbours** to decide `family`, `pickInsteadIf` and `related`:
   ```sh
   ls -d ${T%%-*}*/                                    # same-prefix templates, often variants
   grep -H '^category:\|^family:' */catalog.yaml       # every template's category and family
   ```
   Read the neighbours' `catalog.yaml` files. When this template should appear in a neighbour's `pickInsteadIf` (for example a new HA variant), update the neighbour in the same pull request.
3. **Write the file** with the field reference (§3) and the vocabularies (§4).
4. **Check the references:**
   ```sh
   for t in $(grep -E '^\s*(-\s*)?template:|^family:' $T/catalog.yaml | awk '{print $NF}'); do
     test -d "$t/versions" || echo "missing template: $t"
   done
   ```
5. **Check it finds.** Write three requests someone would make that this template should answer, such as "postgres for my web app", "something like Heroku Postgres" or "sql database with backups to s3". For each one, make sure its distinctive words appear in `title`, `keywords`, `alternativeTo` or `useCases`. Write one request this template should **not** win, and make sure it appears in `pickInsteadIf` of this template, pointing to the right one.
6. **Validate** (§7) and run the review checklist (§8).

**For a new version:** reread the diff of the README and `values.yaml` against the previous version. Update `summary`, `topology` and `prerequisites` (including every `valuesPath`) when they changed.

---

## 7. Validation

```sh
pip install jsonschema pyyaml                        # once
python3 .github/scripts/validate_catalog.py          # every template; exits 1 on any problem
python3 .github/scripts/validate_catalog.py "$T"     # report only this template's problems
```

Start the file with `# yaml-language-server: $schema=../.schema/catalog.v1.schema.json` and editors with the YAML language server validate it as you type.

CI (`.github/workflows/validate-catalog.yml`) runs the same script on every pull request. It checks every template, because entries reference each other:

- the file exists and matches the schema (for an internal entry: `apiVersion`, `kind` and `internal: true`);
- every template reference (`family`, `pickInsteadIf`, `related`) exists, is not internal, and is not the template itself; a `family` points at the family's default member;
- no `alternativeTo` entry is a template name;
- every `valuesPath` exists in the latest `values.yaml`.

---

## 8. Review checklist

- [ ] The file is at `<template>/catalog.yaml`, with the right `apiVersion` and `kind`.
- [ ] `internal: true` is set only on a template nobody should find by searching (test apps, internal tools).
- [ ] Everything matches the latest version's chart, not an older version or the upstream product.
- [ ] `summary` says what it deploys, the options and when to pick it, in 2 to 4 sentences, with no marketing or version numbers.
- [ ] `keywords` add terms beyond the title, are lowercase and include nothing the template can't do.
- [ ] `useCases` are problems a user would state.
- [ ] `alternativeTo` holds real external products under their official names, and no template names.
- [ ] `topology` follows the precedence in §4.2 for the main component.
- [ ] Variants share a `family`; the default member is the simplest one.
- [ ] `pickInsteadIf` covers the realistic confusions with neighbours; the neighbours point back where it makes sense.
- [ ] `related` lists no bundled subcharts.
- [ ] `prerequisites` lists every secret, cloud account, bucket or domain the user creates, with the right `required`, `when` and `valuesPath`; `[]` only when there is none.
- [ ] The check in §6 step 5 passes.

---

## 9. Common mistakes

| Mistake | Why it hurts | Fix |
|---|---|---|
| A template name in `alternativeTo` | Readers and agents take it for an external product | Use `related` |
| `failover` in the keywords of a single-instance template | It ranks for HA searches it can't serve | Put the need in `pickInsteadIf` pointing to the HA variant |
| The Chart description copied into `summary` | The summary adds nothing for ranking or choosing | Write the components, options and when to pick it |
| Marketing words | They match nothing users search for and read as noise to agents | State facts |
| Bundled subcharts listed under `related` | Duplicates `Chart.yaml` and suggests installing them separately | Drop them |
| A prerequisite only an optional feature needs, marked `required: true` | Agents create things nobody needs | `required: false` with `when` |
| A missing prerequisite secret | The install waits silently with no logs | List every secret the user creates |
| A stale `valuesPath` after a version bump | Agents put the secret name under a key the chart ignores | Recheck every path against the latest `values.yaml` |
| Versions in `summary` ("PostgreSQL 18") | Goes stale with the next version | Leave versions out |
