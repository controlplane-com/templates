# Catalog Changelog

High-level, user-facing catalog changes by month: new templates and notable version updates, one line each. Feeds the marketplace "What's New" section. Maintained by the template pipeline at ship time (entry added when a template or version merges); internal tooling changes are not listed.

## 2026-08

- **New template: seaweedfs 1.0.0** — S3-compatible object storage usable as the backup and attachment target for any catalog template that speaks S3
- **New template: trino 1.0.0** — distributed SQL engine that answers a single query across PostgreSQL, MySQL, ClickHouse, MongoDB and more, with a scalable worker tier
- **New template: qdrant 1.0.0** — vector database for semantic search and RAG, with API-key authentication, snapshots, and durable on-disk storage
- **New template: chatwoot 1.0.0** — open-source customer-support platform with a shared inbox, live chat widget, and real-time agent updates, backed by PostgreSQL and Redis
- **New template: twenty 1.0.0** — open-source CRM with a customizable data model, REST and GraphQL APIs, and a background worker for automations
- **redis 3.5.0** — Redis 8 by default (adds an AGPL-licensed option), plus scheduled backups now accept `*/5`-style cron expressions
- **New template: openbao 1.0.0** — OpenBao secrets engine (Vault-compatible: KV, dynamic secrets, PKI, transit) on raft storage, with auto-unseal via a static key or AWS/GCP KMS
- **New template: grafana 1.0.0** — Grafana OSS dashboards over your own datasources, with datasource provisioning as code, horizontal scaling (`replicas`), and Redis-backed alerting HA
- **New template: docmost 1.0.0** — open-source knowledge base and wiki with real-time collaborative editing, backed by PostgreSQL and Redis, with local or S3 attachment storage
- **New template: tooljet 1.0.0** — open-source low-code internal-tools builder (visual app builder, 50+ connectors, built-in ToolJet Database) backed by PostgreSQL
- **New template: listmonk 1.0.0** — self-hosted newsletter and mailing-list manager with public subscription pages, backed by highly-available or single-instance PostgreSQL

## 2026-07

- **New template: ghost 1.0.0** — open-source publishing platform (blog, newsletters, paid memberships, Content API) backed by bundled MySQL 8, with optional SMTP and scheduled S3/GCS database backups
- **New template: infisical 1.0.0** — open-source secrets management (web UI + API, per-environment scoping, versioning) with horizontal scaling (`replicas`), backed by PostgreSQL and highly-available Redis
- **mysql 1.4.3** — scheduled backups now dump the configured application database (previously the backup job targeted a placeholder database — upgrade if you use `backup.enabled`)
- **New template: prometheus 1.0.0** — Prometheus metrics database with remote-write ingestion, durable TSDB storage, and an optional Thanos sidecar (Store API + object-storage block upload) for a global query tier
- **New template: thanos 1.0.0** — Thanos Query global metrics view fanning out across Prometheus installs (cross-GVC), with HA-pair deduplication and an optional Store Gateway + Compactor long-term storage tier
- **otel-collector 1.1.0** — OTLP metrics pipeline with Prometheus remote-write export and authenticated public ingestion (bearer token or mTLS), alongside the existing trace path
- **New template: timescaledb-highly-available 1.0.0** — Patroni-managed multi-replica TimescaleDB (PostgreSQL time-series) with automatic failover, etcd, HAProxy leader routing, optional PgBouncer, and S3/GCS/MinIO backups
- **New template: gitea 1.0.0** — lightweight self-hosted Git service (repos, PRs, issues, package registry) backed by PostgreSQL, with public HTTPS + Git-over-HTTPS and optional Git-over-SSH
- **New template: umami 1.0.0** — privacy-first, cookieless web/product analytics (self-hosted Google Analytics alternative) with a scalable app tier and a choice of highly-available or single-instance PostgreSQL
- **New template: litellm 1.0.0** — OpenAI-compatible LLM gateway (virtual keys, spend tracking, rate limiting across 100+ providers) backed by PostgreSQL and Redis
- **New template: open-webui 1.0.0** — self-hosted ChatGPT-style chat UI for LLMs, pairing with the Ollama template and any OpenAI-compatible endpoint
- **New template: vaultwarden 1.0.0** — self-hosted, Bitwarden-compatible password manager with scheduled volume-snapshot backups
- **New template: timescaledb 1.0.0** — PostgreSQL + TimescaleDB (time-series: compression, continuous aggregates, retention) with optional PgBouncer and S3/GCS/MinIO backups
- **New template: glitchtip 1.0.0** — MIT-licensed, Sentry-compatible error tracking with horizontal web scaling and a choice of highly-available or single-instance PostgreSQL
- **New template: unleash 1.0.0** — open-source feature-flag server with horizontal scaling (`replicas`), API-token seeding, and a choice of highly-available or single-instance PostgreSQL backing
- **New template: uptime-kuma 1.0.0** — self-hosted uptime monitoring with public status pages, 90+ alert integrations, and HTTP/TCP/DNS/ping checks
- **New template: temporal 1.0.0** — durable-execution platform (workflows that survive crashes and restarts) with web UI and a choice of highly-available or single-instance PostgreSQL backing
- **New template: metabase 1.0.0** — self-hosted BI and analytics (dashboards, SQL editor, scheduled reports) with a choice of highly-available or single-instance PostgreSQL backing
- **New template: n8n 1.0.0** — workflow automation (editor, integrations, webhooks) with a choice of highly-available or single-instance PostgreSQL backing
- **postgres-highly-available 2.4.1** — HAProxy now waits for the database endpoints before starting, eliminating an install-time DNS race
- **mimir 1.0.0 update** — optional HA clustering: set `replicas: 3` for a 3-way-replicated ingest cluster with zero-downtime rolling restarts
- **New template: mimir 1.0.0** — self-hosted Grafana Mimir long-term Prometheus metrics store backed by S3, GCS, or any S3-compatible bucket, with optional multi-tenancy
- **hermes-agent 1.0.0 update** — dashboard browser login fixed (upstream patch applied at boot)
- **kafka 4.1.0** — rack-aware fetching to reduce cross-zone traffic (off by default) and log volume-set import/override support
- **New template: hermes-agent 1.0.0** — Nous Research's self-hosted AI agent: persistent memory, browser automation, OpenAI-compatible API, web dashboard
- **New template: sftpgo 1.0.0** — SFTP server on S3/GCS/MinIO storage with per-user isolation and an optional scale-to-zero mode
- **keycloak 1.0.0** — identity and access management with clustered HA, backed by highly-available PostgreSQL
- **cpln-trivy 1.1.0** — image rescan support (`rescanAfter`) and hardened secret handling
