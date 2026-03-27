# OpenTelemetry Collector
The OpenTelemetry Collector is a tool for receiving, processing, and exporting telemetry data such as traces and metrics using the OpenTelemetry Protocol (OTLP).

## Configuration

- This template does not create a GVC, and you will need to enable tracing on the GVC level after installing, specifying the target workload and port. This will trigger a restart of all workloads in the GVC.
- Once tracing is enabled, your application must emit traces by using the OpenTelemetry SDK.

### Supported External Services
- [OpenTelemetry Collector Documentation](https://opentelemetry.io/docs/collector/)