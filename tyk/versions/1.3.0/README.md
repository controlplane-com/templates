# Tyk API Gateway

Tyk API Gateway is an open-source API management platform that controls, secures, and monitors API traffic.

In addition to creating a Tyk API Gateway workload, the template also provisions Redis which operates as the backing store for tokens, analytics, rate-limits, and state, and Redis Sentinel which provides automatic Redis failover and high availability.

## Important
Please read the instructions below carefully before configuring and installing.

## How This Template Works

Tyk organizes configuration into two key components:

**API Definitions** - describe individual APIs, including routes, rate limits, authentication, and upstream targets

**Policies** - define higher-level access rules and rate limits that can apply across multiple APIs

Both of these are provided to Tyk as JSON files, which this template expects to be mounted from Control Plane secrets. You must pre-configure each of these secrets.

Once you specify both `apiSecretName` and `policySecretName` in the values file, you can manage the secrets independently, as long as the names stay consistent.

## Creating the Secrets

Use the example `yaml` files below to properly configure the secrets. You can create these secrets using `cpln apply`.

### API Secret

```YAML
kind: secret
name: example-tyk-apis
description: example-tyk-apis
tags: {}
type: dictionary
data:
  app1.json: >-
    { "api_id": "app1", "name": "app1", "org_id": "default", "use_keyless":
    true, "use_jwt": false, "disable_rate_limit": true, "definition": {
    "location": "header", "key": "version" }, "version_data": { "not_versioned":
    true, "versions": { "Default": { "name": "Default", "use_extended_paths":
    true } } }, "proxy": { "listen_path": "/app1", "target_url":
    "http://app1.example-gvc.cpln.local:80", "strip_listen_path": true },
    "active": true}
  app2.json: >-
    { "api_id": "app2", "name": "app2", "org_id": "default", "use_keyless":
    true, "active": true, "version_data": { "not_versioned": true, "versions": {
    "Default": { "name": "Default", "use_extended_paths": true } } }, "proxy": {
    "listen_path": "/app2", "target_url":
    "http://app2.example-gvc.cpln.local:8080", "strip_listen_path": true,
    "preserve_host_header": false, "enable_load_balancing": false,
    "check_host_against_uptime_tests": false }}
```

### Policy Secret

```YAML
kind: secret
name: example-tyk-policies
description: example-tyk-policies
tags: {}
type: opaque
data:
  encoding: plain
  payload: |-
    {
          "app1-rate-limit": {
            "org_id": "default",
            "active": true,

            "rate": 20,
            "per": 100,

            "quota_max": 0,
            "quota_renewal_rate": 0,
            "quota_remaining": 0,

            "access_rights": {
              "tetris": {
                "api_id": "app1",
                "api_name": "app1",
                "versions": ["Default"]
              }
            }
          }
        }
```

## Additional Resources

- [Tyk Docs](https://tyk.io/docs)
- [Tyk API JSON Object](https://tyk.io/docs/5.0/tyk-gateway-api/api-definition-objects/)
- [Tyk Policy Guide](https://tyk.io/docs/5.1/basic-config-and-security/security/security-policies/policies-guide/)