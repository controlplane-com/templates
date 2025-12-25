# Sentry

Self-hosted Sentry is an open-source error tracking and performance monitoring platform.

## Usage

This template deploys a complete Sentry stack including:
- Sentry Web, Worker, and Cron
- PostgreSQL
- Redis
- Kafka
- ClickHouse
- Zookeeper

### Prerequisites

- Sufficient resources in your GVC (Sentry is resource-intensive).
- Persistent storage capability.

### Configuration

The default configuration is suitable for a small to medium deployment. 
You can override values in the `values.yaml` or through the Control Plane UI.

For more details on Sentry configuration, visit the [official documentation](https://develop.sentry.dev/self-hosted/).
