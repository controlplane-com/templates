# Release Notes - Strapi Template

## Version 1.0.0

### What's New

- **Custom Image Approach**: Build your own Docker image with your Strapi project, content types, and plugins baked in
- **Comprehensive Documentation**: Extensive README explaining Strapi's code-first paradigm, content types vs content, and the development workflow
- **Database Migrations**: Built-in support for Knex.js migrations with examples
- **Private Registry Support**: Support for GitHub, GitLab, Bitbucket, and Docker Hub container registries
- **Auto-scaling**: Serverless deployment with configurable min/max replicas
- **Secure Secrets**: Manages API keys, JWT secrets, and database credentials via Control Plane secrets

### Template Structure

```
strapi/
├── versions/
│   └── 1.0.0/
│       ├── Chart.yaml
│       ├── README.md           ← Comprehensive documentation
│       ├── values.yaml
│       ├── example/            ← Example files for your project
│       │   ├── Dockerfile
│       │   ├── .env.example
│       │   └── database/migrations/.gitkeep
│       └── templates/
│           ├── _helpers.tpl
│           ├── identity.yaml
│           ├── policy.yaml
│           ├── secret.yaml
│           └── workload.yaml
```

### Configuration Highlights

- **Custom Image**: Bring your own Strapi Docker image
- **External Database**: Connect to your existing PostgreSQL database
- **Private Registries**: Optional image pull secret for private container registries
- **Resources & Scaling**: Configurable CPU, memory, and autoscaling settings

### Breaking Changes from Previous Development

- Removed embedded PostgreSQL dependency - users now manage their own database
- Requires a custom Docker image (no generic image support)

### Notes

- Generate unique secrets before production deployment
- See README.md for complete setup instructions
- Test migrations locally before deploying to production
