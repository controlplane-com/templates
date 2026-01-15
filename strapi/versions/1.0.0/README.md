# Strapi Headless CMS for Control Plane

Deploy Strapi, the leading open-source headless CMS, on Control Plane.

## Table of Contents

1. [Understanding Strapi](#1-understanding-strapi)
2. [Prerequisites](#2-prerequisites)
3. [Quick Start Guide](#3-quick-start-guide)
4. [Creating Your Strapi Project](#4-creating-your-strapi-project)
5. [Content Types Example](#5-content-types-example)
6. [Plugins Example](#6-plugins-example)
7. [Database Migrations](#7-database-migrations)
8. [Building Your Docker Image](#8-building-your-docker-image)
9. [Container Registries](#9-container-registries)
10. [Deploying to Control Plane](#10-deploying-to-control-plane)
11. [Production Considerations](#11-production-considerations)
12. [Troubleshooting](#12-troubleshooting)

---

## 1. Understanding Strapi

### What is Strapi?

Strapi is a **headless CMS framework** - it provides the backend (API + admin panel) for managing content, but not the frontend. You build your own frontend (React, Vue, Next.js, mobile app, etc.) that consumes the Strapi API.

### The Key Paradigm: Code-First

Unlike traditional CMS platforms (WordPress, Drupal), Strapi is **code-first**:

| Traditional CMS | Strapi |
|-----------------|--------|
| Install → Configure in UI → Done | Create project → Define schema in code → Build → Deploy |
| Schema stored in database | Schema stored as code files |
| Update via admin panel | Update via code + redeploy |

### Content Types vs Content

This is the most important concept to understand:

**Content Types** (Schema):
- Define the **STRUCTURE**: "An Article has title, body, author"
- Stored as **CODE FILES** in your project
- Changes require **rebuild + redeploy**

**Content** (Data):
- The actual **DATA**: "My First Post", "Hello World"
- Stored in **DATABASE** (PostgreSQL)
- Changes via Admin UI, **persists across deploys**

### Why Custom Images?

When you create a content type in Strapi's Admin UI (during development), it generates code files:

```
src/api/article/
├── content-types/article/schema.json    ← Defines fields
├── controllers/article.js               ← API logic
├── routes/article.js                    ← API endpoints
└── services/article.js                  ← Business logic
```

These files must be in your Docker image. This is why you can't use a generic Strapi image - **your schema is part of your application code**.

### Development vs Production Workflow

```
DEVELOPMENT (Your laptop)
├── Make schema changes in Admin UI
├── Files generated instantly
├── Hot reload sees changes
└── Use SQLite for simplicity

        ↓ (commit code, build image)

PRODUCTION (Control Plane)
├── Schema is FIXED (baked into image)
├── Content editors add/edit CONTENT only
├── Admin UI is read-only for schema
└── Use PostgreSQL for robustness
```

---

## 2. Prerequisites

- **Node.js** 18.x or 20.x (for local development)
- **Docker** (for building images)
- **Container registry account** (GitHub, GitLab, Docker Hub, etc.)
- **Control Plane account** with:
  - A GVC (Global Virtual Cloud)
  - A PostgreSQL database (use the `postgres` template)

---

## 3. Quick Start Guide

**5-minute overview of the full workflow:**

```bash
# 1. Create a new Strapi project
npx create-strapi-app@latest my-strapi --quickstart

# 2. Develop locally (create content types, install plugins)
cd my-strapi
npm run develop

# 3. Build your Docker image
docker build -t ghcr.io/your-org/my-strapi:v1 .

# 4. Push to registry
docker push ghcr.io/your-org/my-strapi:v1

# 5. Deploy to Control Plane
cpln helm install my-cms strapi \
  --set global.cpln.gvc=my-gvc \
  --set strapi.image=ghcr.io/your-org/my-strapi:v1 \
  --set strapi.database.host=my-postgres.my-gvc.cpln.local \
  --set strapi.database.username=strapi \
  --set strapi.database.password=secret123 \
  --set strapi.secrets.appKeys=$(openssl rand -base64 32)
  # ... more secrets
```

---

## 4. Creating Your Strapi Project

### Step 1: Create New Project

```bash
npx create-strapi-app@latest my-strapi --quickstart
cd my-strapi
```

The `--quickstart` flag uses SQLite for development (simpler setup).

### Step 2: Configure for PostgreSQL (Production)

Create or update `config/database.js`:

```javascript
// config/database.js
module.exports = ({ env }) => ({
  connection: {
    client: 'postgres',
    connection: {
      host: env('DATABASE_HOST', 'localhost'),
      port: env.int('DATABASE_PORT', 5432),
      database: env('DATABASE_NAME', 'strapi'),
      user: env('DATABASE_USERNAME', 'strapi'),
      password: env('DATABASE_PASSWORD', ''),
      ssl: env.bool('DATABASE_SSL', false) && {
        rejectUnauthorized: env.bool('DATABASE_SSL_REJECT_UNAUTHORIZED', true),
      },
    },
    debug: false,
  },
});
```

### Step 3: Project Structure

After creation, your project looks like:

```
my-strapi/
├── config/                  ← Configuration files
│   ├── admin.js
│   ├── api.js
│   ├── database.js
│   ├── middlewares.js
│   ├── plugins.js
│   └── server.js
├── database/
│   └── migrations/          ← Your migration files go here
├── public/                  ← Static files
├── src/
│   ├── admin/               ← Admin panel customization
│   ├── api/                 ← Your content types (auto-generated)
│   ├── components/          ← Reusable components
│   ├── extensions/          ← Plugin extensions
│   └── index.js
├── package.json
└── .env                     ← Environment variables (don't commit!)
```

---

## 5. Content Types Example

Let's create an "Article" content type step by step.

### Step 1: Start Development Server

```bash
npm run develop
```

Open http://localhost:1337/admin and create your first admin user.

### Step 2: Create Content Type via Admin UI

1. Go to **Content-Type Builder**
2. Click **Create new collection type**
3. Name it `Article`
4. Add fields:
   - `title` (Text, required)
   - `slug` (UID, based on title)
   - `content` (Rich text)
   - `coverImage` (Media, single image)
   - `publishedAt` (Datetime)

### Step 3: Examine Generated Files

After saving, Strapi generates these files:

```
src/api/article/
├── content-types/
│   └── article/
│       └── schema.json      ← Field definitions
├── controllers/
│   └── article.js           ← Empty (uses default)
├── routes/
│   └── article.js           ← REST endpoints
└── services/
    └── article.js           ← Empty (uses default)
```

### Step 4: The Schema File

```json
// src/api/article/content-types/article/schema.json
{
  "kind": "collectionType",
  "collectionName": "articles",
  "info": {
    "singularName": "article",
    "pluralName": "articles",
    "displayName": "Article"
  },
  "options": {
    "draftAndPublish": true
  },
  "attributes": {
    "title": {
      "type": "string",
      "required": true
    },
    "slug": {
      "type": "uid",
      "targetField": "title"
    },
    "content": {
      "type": "richtext"
    },
    "coverImage": {
      "type": "media",
      "multiple": false,
      "allowedTypes": ["images"]
    },
    "publishedAt": {
      "type": "datetime"
    }
  }
}
```

### Step 5: API Endpoints (Auto-generated)

Your Article now has these REST endpoints:

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/articles` | List all articles |
| GET | `/api/articles/:id` | Get single article |
| POST | `/api/articles` | Create article |
| PUT | `/api/articles/:id` | Update article |
| DELETE | `/api/articles/:id` | Delete article |

### Step 6: Set API Permissions

1. Go to **Settings → Users & Permissions → Roles**
2. Edit the **Public** role
3. Under **Article**, enable `find` and `findOne`
4. Save

Now your API is accessible without authentication.

---

## 6. Plugins Example

Let's install and configure the GraphQL plugin.

### Step 1: Install the Plugin

```bash
npm install @strapi/plugin-graphql
```

### Step 2: Rebuild

```bash
npm run build
```

### Step 3: Configure (Optional)

```javascript
// config/plugins.js
module.exports = {
  graphql: {
    config: {
      endpoint: '/graphql',
      playgroundAlways: false,
      defaultLimit: 25,
      maxLimit: 100,
    },
  },
};
```

### Step 4: Restart and Use

```bash
npm run develop
```

GraphQL endpoint available at: http://localhost:1337/graphql

Example query:

```graphql
query {
  articles {
    data {
      id
      attributes {
        title
        content
        publishedAt
      }
    }
  }
}
```

### Popular Plugins

| Plugin | Purpose | Install |
|--------|---------|---------|
| GraphQL | GraphQL API | `@strapi/plugin-graphql` |
| SEO | Meta tags, sitemap | `@strapi/plugin-seo` |
| i18n | Internationalization | Built-in, enable in plugins.js |
| Users & Permissions | Authentication | Built-in |
| Upload | Media management | Built-in |

---

## 7. Database Migrations

Strapi includes **built-in migration support** using Knex.js. Migrations run automatically on startup, before Strapi's auto-sync.

### When You Need Migrations

| Schema Change | Auto-handled by Strapi? | Migration Needed? |
|---------------|-------------------------|-------------------|
| Add content type | Yes | No |
| Add field | Yes | No |
| Remove field | Column orphaned | Yes, if cleaning up |
| Remove content type | Table orphaned | Yes, if dropping table |
| Rename field | No | **Yes** |
| Change field type | No | **Yes** |
| Data transformation | No | **Yes** |

### Creating Migration Files

Create files in `./database/migrations/` with this naming format:

```
YYYY.MM.DD.Thh.mm.ss.description.js
```

Example: `2026.01.15T12.00.00.rename-body-to-content.js`

### Migration File Template

```javascript
'use strict';

async function up(knex) {
  // Your forward migration code
}

async function down(knex) {
  // Optional: rollback code (not run automatically)
}

module.exports = { up, down };
```

### Example: Rename a Column

```javascript
// database/migrations/2026.01.15T12.00.00.rename-body-to-content.js
'use strict';

async function up(knex) {
  await knex.schema.table('articles', (table) => {
    table.renameColumn('body', 'content');
  });
}

async function down(knex) {
  await knex.schema.table('articles', (table) => {
    table.renameColumn('content', 'body');
  });
}

module.exports = { up, down };
```

### Example: Transform Data

```javascript
// database/migrations/2026.01.16T09.00.00.uppercase-titles.js
'use strict';

async function up(knex) {
  const articles = await knex('articles').select('id', 'title');

  for (const article of articles) {
    await knex('articles')
      .where('id', article.id)
      .update({ title: article.title.toUpperCase() });
  }
}

module.exports = { up };
```

### Example: Add Index for Performance

```javascript
// database/migrations/2026.01.17T10.00.00.add-slug-index.js
'use strict';

async function up(knex) {
  await knex.schema.table('articles', (table) => {
    table.index('slug', 'idx_articles_slug');
  });
}

async function down(knex) {
  await knex.schema.table('articles', (table) => {
    table.dropIndex('slug', 'idx_articles_slug');
  });
}

module.exports = { up, down };
```

### How Migrations Run

1. Strapi starts
2. Migrations in `./database/migrations/` run (alphabetically by filename)
3. Strapi's auto-sync runs (creates new tables/columns from schema.json files)
4. Application ready

### Important Limitations

- **No automatic rollback**: Strapi doesn't run `down()` automatically. Plan carefully!
- **Test first**: Always test migrations on a copy of production data
- **Backup**: Always backup your database before deploying migrations
- **One direction**: Design migrations to be safe to re-run or idempotent

---

## 8. Building Your Docker Image

### Example Dockerfile

Create a `Dockerfile` in your Strapi project root:

```dockerfile
# Build stage
FROM node:20-alpine AS build
WORKDIR /app

# Install dependencies
COPY package*.json ./
RUN npm ci

# Copy source and build
COPY . .
RUN npm run build

# Production stage
FROM node:20-alpine
WORKDIR /app

ENV NODE_ENV=production

# Copy built application
COPY --from=build /app ./

# Expose Strapi port
EXPOSE 1337

# Start Strapi
CMD ["npm", "run", "start"]
```

### Build and Push

```bash
# Build the image
docker build -t ghcr.io/your-org/my-strapi:v1 .

# Test locally (optional)
docker run -p 1337:1337 \
  -e DATABASE_HOST=host.docker.internal \
  -e DATABASE_PORT=5432 \
  -e DATABASE_NAME=strapi \
  -e DATABASE_USERNAME=strapi \
  -e DATABASE_PASSWORD=password \
  -e APP_KEYS=key1,key2 \
  -e API_TOKEN_SALT=salt1 \
  -e ADMIN_JWT_SECRET=secret1 \
  -e TRANSFER_TOKEN_SALT=salt2 \
  -e JWT_SECRET=secret2 \
  ghcr.io/your-org/my-strapi:v1

# Push to registry
docker push ghcr.io/your-org/my-strapi:v1
```

### Generating Secrets

Use these commands to generate secure secrets:

```bash
# Generate APP_KEYS (comma-separated, need at least 4)
echo "$(openssl rand -base64 32),$(openssl rand -base64 32),$(openssl rand -base64 32),$(openssl rand -base64 32)"

# Generate individual secrets
openssl rand -base64 32  # API_TOKEN_SALT
openssl rand -base64 32  # ADMIN_JWT_SECRET
openssl rand -base64 32  # TRANSFER_TOKEN_SALT
openssl rand -base64 32  # JWT_SECRET
```

---

## 9. Container Registries

Your Docker image can be hosted on any container registry.

### Public Images (No Authentication)

If your image is public, just specify the image URL:

```yaml
strapi:
  image: ghcr.io/your-org/your-strapi:latest
  imagePullSecret: ""  # Leave empty
```

### Private Images

For private images, you need to:
1. Create a pull secret in Control Plane
2. Reference it in your values.yaml

---

### GitHub Container Registry (ghcr.io)

**Step 1: Create a Personal Access Token**

1. Go to GitHub → Settings → Developer settings → Personal access tokens → Tokens (classic)
2. Generate new token with `read:packages` scope
3. Copy the token

**Step 2: Create Pull Secret in Control Plane**

```bash
cpln secret create github-registry \
  --org your-org \
  --type docker \
  --docker-server ghcr.io \
  --docker-username YOUR_GITHUB_USERNAME \
  --docker-password YOUR_GITHUB_TOKEN
```

**Step 3: Configure values.yaml**

```yaml
strapi:
  image: ghcr.io/your-org/your-strapi:latest
  imagePullSecret: "github-registry"
```

---

### GitLab Container Registry

**Step 1: Create a Deploy Token**

1. Go to GitLab → Project → Settings → Repository → Deploy tokens
2. Create token with `read_registry` scope
3. Copy username and token

**Step 2: Create Pull Secret in Control Plane**

```bash
cpln secret create gitlab-registry \
  --org your-org \
  --type docker \
  --docker-server registry.gitlab.com \
  --docker-username YOUR_DEPLOY_TOKEN_USERNAME \
  --docker-password YOUR_DEPLOY_TOKEN
```

**Step 3: Configure values.yaml**

```yaml
strapi:
  image: registry.gitlab.com/your-group/your-project:latest
  imagePullSecret: "gitlab-registry"
```

---

### Bitbucket Container Registry

**Step 1: Create an App Password**

1. Go to Bitbucket → Personal settings → App passwords
2. Create password with `repository:read` permission
3. Copy the password

**Step 2: Create Pull Secret in Control Plane**

```bash
cpln secret create bitbucket-registry \
  --org your-org \
  --type docker \
  --docker-server docker.io \
  --docker-username YOUR_BITBUCKET_USERNAME \
  --docker-password YOUR_APP_PASSWORD
```

---

### Docker Hub

**Step 1: Create an Access Token**

1. Go to Docker Hub → Account Settings → Security → Access Tokens
2. Create new token with `Read-only` permission
3. Copy the token

**Step 2: Create Pull Secret in Control Plane**

```bash
cpln secret create dockerhub-registry \
  --org your-org \
  --type docker \
  --docker-server docker.io \
  --docker-username YOUR_DOCKERHUB_USERNAME \
  --docker-password YOUR_ACCESS_TOKEN
```

**Step 3: Configure values.yaml**

```yaml
strapi:
  image: your-dockerhub-username/your-strapi:latest
  imagePullSecret: "dockerhub-registry"
```

---

### Image URL Formats Reference

| Registry | URL Format |
|----------|------------|
| GitHub | `ghcr.io/owner/image:tag` |
| GitLab | `registry.gitlab.com/group/project:tag` |
| Docker Hub | `username/image:tag` or `docker.io/username/image:tag` |
| AWS ECR | `123456789.dkr.ecr.region.amazonaws.com/image:tag` |
| Google GCR | `gcr.io/project-id/image:tag` |
| Azure ACR | `myregistry.azurecr.io/image:tag` |

---

## 10. Deploying to Control Plane

### Step 1: Create PostgreSQL Database

First, deploy a PostgreSQL database using the `postgres` template:

```bash
cpln helm install my-db postgres \
  --set global.cpln.gvc=my-gvc \
  --set postgres.config.username=strapi \
  --set postgres.config.password=secure-password \
  --set postgres.config.database=strapi
```

### Step 2: Deploy Strapi

```bash
cpln helm install my-cms strapi \
  --set global.cpln.gvc=my-gvc \
  --set strapi.image=ghcr.io/your-org/my-strapi:v1 \
  --set strapi.database.host=my-db-postgres.my-gvc.cpln.local \
  --set strapi.database.name=strapi \
  --set strapi.database.username=strapi \
  --set strapi.database.password=secure-password \
  --set strapi.secrets.appKeys="key1,key2,key3,key4" \
  --set strapi.secrets.apiTokenSalt="your-api-salt" \
  --set strapi.secrets.adminJwtSecret="your-admin-secret" \
  --set strapi.secrets.transferTokenSalt="your-transfer-salt" \
  --set strapi.secrets.jwtSecret="your-jwt-secret"
```

### Step 3: Using a Values File (Recommended)

Create `my-values.yaml`:

```yaml
global:
  cpln:
    gvc: my-gvc

strapi:
  image: ghcr.io/your-org/my-strapi:v1
  imagePullSecret: github-registry  # if private

  database:
    host: my-db-postgres.my-gvc.cpln.local
    port: "5432"
    name: strapi
    username: strapi
    password: secure-password
    ssl: "false"

  resources:
    cpu: 500m
    memory: 512Mi

  autoscaling:
    minScale: 1
    maxScale: 3

  secrets:
    appKeys: "key1,key2,key3,key4"
    apiTokenSalt: "your-api-salt"
    adminJwtSecret: "your-admin-secret"
    transferTokenSalt: "your-transfer-salt"
    jwtSecret: "your-jwt-secret"
```

Deploy with:

```bash
cpln helm install my-cms strapi -f my-values.yaml
```

### Step 4: Access Your Strapi

After deployment, access Strapi at:

```
https://my-cms-strapi.my-gvc.cpln.app
```

Admin panel:

```
https://my-cms-strapi.my-gvc.cpln.app/admin
```

---

## 11. Production Considerations

### Security Checklist

- [ ] Generate unique secrets for each environment
- [ ] Never commit secrets to version control
- [ ] Use private container registry for proprietary code
- [ ] Configure proper API permissions (don't expose everything to Public role)
- [ ] Enable rate limiting if needed
- [ ] Use SSL for database connections in production

### Scaling

The template configures autoscaling by default:

```yaml
autoscaling:
  minScale: 1    # Minimum instances
  maxScale: 3    # Maximum instances
```

Strapi is stateless (for API requests), so it scales horizontally. Media uploads should use cloud storage (S3, Cloudinary) for multi-instance deployments.

### Backups

- **Database**: Use PostgreSQL backups (pg_dump or managed service backups)
- **Media**: Use cloud storage with its own backup/versioning
- **Code**: Your Docker image is in your container registry

### Monitoring

Strapi logs to stdout/stderr. Control Plane captures these automatically.

---

## 12. Troubleshooting

### Container Fails to Start

**Symptom**: Workload keeps restarting

**Check logs**:
```bash
cpln workload logs my-cms-strapi --gvc my-gvc
```

**Common causes**:
- Database connection refused → Check database host/port
- Invalid secrets → Regenerate secrets
- Missing environment variables → Check values.yaml

### Database Connection Issues

**Symptom**: `ECONNREFUSED` or timeout

**Solutions**:
1. Verify database is running: `cpln workload get my-db-postgres --gvc my-gvc`
2. Check hostname format: `{release-name}-postgres.{gvc}.cpln.local`
3. Verify credentials match database configuration

### Admin Panel Shows "No Content Types"

**Symptom**: Admin panel is empty

**Cause**: Your image doesn't have content types baked in

**Solution**: Ensure you built and deployed an image with your `src/api/` folder

### Permission Denied on API

**Symptom**: 403 Forbidden on API calls

**Solution**:
1. Go to Settings → Users & Permissions → Roles
2. Configure Public or Authenticated role with proper permissions

### Migration Failed

**Symptom**: Strapi won't start after adding migration

**Solutions**:
1. Check migration syntax
2. Test migration locally first
3. Check Strapi logs for specific error
4. Ensure migration filename format is correct: `YYYY.MM.DDThh.mm.ss.name.js`

---

## Resources

- [Strapi Documentation](https://docs.strapi.io/)
- [Strapi GitHub](https://github.com/strapi/strapi)
- [Control Plane Documentation](https://docs.controlplane.com/)
- [Knex.js Documentation](https://knexjs.org/) (for migrations)
