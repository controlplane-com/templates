# Catalog Changelog

High-level, user-facing catalog changes by month: new templates and notable version updates, one line each. Feeds the marketplace "What's New" section. Maintained by the template pipeline at ship time (entry added when a template or version merges); internal tooling changes are not listed.

## 2026-07

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
