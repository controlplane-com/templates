## Nginx App

Creates an nginx proxy which routes traffic to different internally accessible workloads for different request paths.

### Default Routing Rules

- all requests starting with `/` -> `example` workload
- all requests starting with `/health` -> 200
- all requests starting with `/fail` -> 502
- Any 5XX errors are returned the same as the custom `/fail` response.
