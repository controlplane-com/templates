# Release Notes - Version 1.0.0

## Initial Release

### What's New

- **Strapi Headless CMS**: Deploy Strapi with PostgreSQL backend on Control Plane
- **Community Docker Image**: Uses `naskio/strapi` for Strapi v4 support
- **Auto-scaling**: Serverless deployment with configurable min/max replicas
- **Secure Secrets**: Manages API keys, JWT secrets, and database credentials securely
- **PostgreSQL Integration**: Uses postgres template (v3.0.0) as dependency
- **Health Check**: Startup script waits for PostgreSQL before starting Strapi

### Configuration

- Customizable PostgreSQL resources and storage
- Configurable Strapi resources and autoscaling
- Secure secret management for all sensitive values

### Notes

- Replace all default secrets before production deployment
- MinIO integration documented for file uploads (optional)
