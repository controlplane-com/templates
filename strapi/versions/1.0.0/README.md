## Strapi Headless CMS

Strapi is an open-source headless CMS that gives developers the freedom to choose their favorite tools and frameworks while also allowing editors to easily manage and distribute their content.

### Installation

```bash
cpln helm install my-strapi -f values.yaml
```

### Configuration

Update the `values.yaml` file before installation:

#### PostgreSQL Configuration

```yaml
postgres:
  config:
    username: strapi          # Database username
    password: strapi-password # Database password (change this!)
    database: strapi          # Database name
  resources:
    cpu: 500m
    memory: 1024Mi
  volumeset:
    capacity: 10              # Storage in GiB
```

#### Strapi Configuration

```yaml
strapi:
  image: naskio/strapi:latest
  resources:
    cpu: 500m
    memory: 512Mi
  autoscaling:
    minScale: 1
    maxScale: 3
  secrets:
    appKeys: "key1,key2,key3,key4"  # Comma-separated keys (change these!)
    apiTokenSalt: "change-me"        # Salt for API tokens
    adminJwtSecret: "change-me"      # Admin JWT secret
    transferTokenSalt: "change-me"   # Transfer token salt
    jwtSecret: "change-me"           # JWT secret
```

### Security Notes

**Important:** Before deploying to production, you must change the following default values:

1. `postgres.config.password` - Use a strong, unique password
2. `strapi.secrets.appKeys` - Generate random keys (4 comma-separated values)
3. `strapi.secrets.apiTokenSalt` - Generate a random salt
4. `strapi.secrets.adminJwtSecret` - Generate a random secret
5. `strapi.secrets.transferTokenSalt` - Generate a random salt
6. `strapi.secrets.jwtSecret` - Generate a random secret

You can generate random secrets using:
```bash
openssl rand -base64 32
```

### Accessing the Admin Panel

After deployment, access the Strapi admin panel at:
```
https://{workload-name}-{gvc-alias}.cpln.app/admin
```

The first time you access the admin panel, you'll be prompted to create an administrator account.

### Connecting from Other Workloads

To connect to Strapi from another workload in the same GVC:
```
{release-name}-strapi.{gvc-name}.cpln.local:1337
```

### Optional: MinIO Integration for File Uploads

To use MinIO for file storage instead of local storage:

1. Deploy the MinIO template separately
2. Install the Strapi AWS S3 provider in your Strapi project:
   ```bash
   npm install @strapi/provider-upload-aws-s3
   ```
3. Configure the upload provider in your Strapi config to point to MinIO:
   ```javascript
   // config/plugins.js
   module.exports = {
     upload: {
       config: {
         provider: 'aws-s3',
         providerOptions: {
           s3Options: {
             credentials: {
               accessKeyId: process.env.MINIO_ACCESS_KEY,
               secretAccessKey: process.env.MINIO_SECRET_KEY,
             },
             endpoint: 'http://{minio-workload}.{gvc}.cpln.local:9000',
             forcePathStyle: true,
             region: 'us-east-1',
           },
           params: {
             Bucket: 'strapi-uploads',
           },
         },
       },
     },
   };
   ```

### API Usage

Once deployed, your Strapi API will be available at:
- REST API: `https://{workload-name}-{gvc-alias}.cpln.app/api`
- GraphQL (if enabled): `https://{workload-name}-{gvc-alias}.cpln.app/graphql`

### Troubleshooting

**Strapi not starting:**
- Check if PostgreSQL is running and accessible
- Verify the database credentials are correct
- Check the workload logs for error messages

**Database connection errors:**
- Ensure the postgres workload is running
- Verify the `DATABASE_*` environment variables are set correctly
- Check that the strapi identity has permission to reveal the postgres config secret
