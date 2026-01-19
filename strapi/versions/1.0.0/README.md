# Strapi Headless CMS for Control Plane

Deploy Strapi, the leading open-source headless CMS, on Control Plane.

## Table of Contents

1. [Understanding Strapi](#1-understanding-strapi)
2. [Prerequisites](#2-prerequisites)
3. [Quick Start Guide](#3-quick-start-guide)
4. [Creating Your Strapi Project](#4-creating-your-strapi-project)
5. [Content Types Example](#5-content-types-example)
6. [Plugins Example](#6-plugins-example)
7. [Frontend Styling](#7-frontend-styling)
8. [Database Migrations](#8-database-migrations)
9. [Building Your Docker Image](#9-building-your-docker-image)
10. [Container Registries](#10-container-registries)
11. [Deploying to Control Plane](#11-deploying-to-control-plane)
12. [Production Considerations](#12-production-considerations)
13. [Troubleshooting](#13-troubleshooting)

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

# 3. Build and push to Control Plane registry
cpln image build --push --name my-strapi --tag v1 --org my-org

# 4. Deploy to Control Plane
cpln helm install my-cms strapi \
  --set global.cpln.gvc=my-gvc \
  --set strapi.image=/org/my-org/image/my-strapi:v1 \
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

Let's install CKEditor 5 - a professional rich text editor similar to WordPress's editor.

### Why CKEditor 5?

The default Strapi rich text editor is basic. CKEditor 5 provides:
- Professional WYSIWYG editing experience
- Media library integration (insert images from Strapi)
- Custom toolbar configuration
- Dark mode support
- Clean semantic HTML output

### Step 1: Install the Plugin

```bash
npm install @ckeditor/strapi-plugin-ckeditor
```

### Step 2: Rebuild Admin Panel

```bash
npm run build
```

### Step 3: Configure (Optional)

Create or update `config/plugins.js`:

```javascript
// config/plugins.js
module.exports = {
  ckeditor: {
    enabled: true,
    config: {
      plugin: {
        // Customize editor styles
        styles: `
          .ck-editor__main {
            --ck-font-size-base: 14px;
          }
        `
      },
      editor: {
        // Toolbar configuration
        toolbar: {
          items: [
            'heading',
            '|',
            'bold',
            'italic',
            'underline',
            'link',
            '|',
            'bulletedList',
            'numberedList',
            '|',
            'blockQuote',
            'insertImage',
            'mediaEmbed',
            '|',
            'undo',
            'redo'
          ]
        },
        // Enable media library integration
        strapiMediaLib: {
          enabled: true
        }
      }
    }
  }
};
```

### Step 4: Restart and Use

```bash
npm run develop
```

When you create or edit a content type with a Rich Text field, you'll now see the CKEditor interface instead of the default editor.

### Using CKEditor in Content Types

1. Go to **Content-Type Builder**
2. Add a new field → **Rich text (Blocks)**
3. The field will use CKEditor for editing

### Popular Plugins

| Plugin | Purpose | Install |
|--------|---------|---------|
| CKEditor 5 | Professional rich text editor | `@ckeditor/strapi-plugin-ckeditor` |
| GraphQL | GraphQL API | `@strapi/plugin-graphql` |
| SEO | Meta tags, sitemap | `@strapi/plugin-seo` |
| i18n | Internationalization | Built-in, enable in plugins.js |
| Users & Permissions | Authentication | Built-in |
| Upload | Media management | Built-in |

Browse more plugins at [Strapi Marketplace](https://market.strapi.io/)

---

## 7. Frontend Styling

When displaying Strapi rich text content on your frontend, you need CSS to style headings, paragraphs, code blocks, tables, and other HTML elements. The `example/` folder includes production-ready stylesheets.

### Available CSS Files

| File | Purpose |
|------|---------|
| `rich-text.css` | Styles for default Strapi rich text (light theme) |
| `rich-text.dark.css` | Dark theme overrides for rich text |
| `ckeditor5.css` | Styles for CKEditor 5 content (light theme) |
| `ckeditor5.dark.css` | Dark theme overrides for CKEditor 5 |

### Basic Usage

**React/Next.js:**

```jsx
import './rich-text.css';
// or for CKEditor content:
// import './ckeditor5.css';

function Article({ content }) {
  return (
    <div
      className="strapi-rich-text"  // or "ck-content" for CKEditor
      dangerouslySetInnerHTML={{ __html: content }}
    />
  );
}
```

**Vue:**

```vue
<template>
  <div class="strapi-rich-text" v-html="content"></div>
</template>

<style src="./rich-text.css"></style>
```

### Dark Mode

**Option 1: Always Dark**

```html
<link rel="stylesheet" href="rich-text.css">
<link rel="stylesheet" href="rich-text.dark.css">
```

**Option 2: Respect System Preference**

```html
<link rel="stylesheet" href="rich-text.css">
<link rel="stylesheet" href="rich-text.dark.css" media="(prefers-color-scheme: dark)">
```

**Option 3: Toggle with JavaScript**

```javascript
// Add dark theme stylesheet dynamically
function enableDarkMode() {
  const link = document.createElement('link');
  link.rel = 'stylesheet';
  link.href = '/rich-text.dark.css';
  link.id = 'dark-theme';
  document.head.appendChild(link);
}

function disableDarkMode() {
  document.getElementById('dark-theme')?.remove();
}
```

### CSS Variables

All styles use CSS variables for easy customization. Override variables in your own CSS:

```css
/* Custom theme */
:root {
  /* Typography */
  --srt-font-family-base: 'Inter', sans-serif;
  --srt-font-size-base: 1.125rem;
  --srt-line-height-normal: 1.8;

  /* Colors */
  --srt-color-text-primary: #333;
  --srt-color-link: #0066cc;
  --srt-color-link-hover: #004499;

  /* Spacing */
  --srt-margin-paragraph: 1.25em;
  --srt-margin-heading-top: 1.5em;

  /* Code blocks */
  --srt-color-bg-code-block: #1e1e1e;
  --srt-color-code-inline: #c7254e;
}
```

### Variable Reference

**Colors:**
- `--srt-color-text-primary` / `--ck-color-text-primary` - Main text color
- `--srt-color-text-heading` / `--ck-color-text-heading` - Heading color
- `--srt-color-link` / `--ck-color-link` - Link color
- `--srt-color-bg-code-block` / `--ck-color-bg-code-block` - Code block background
- `--srt-color-bg-blockquote` / `--ck-color-bg-blockquote` - Blockquote background

**Typography:**
- `--srt-font-family-base` / `--ck-font-family-base` - Body font
- `--srt-font-family-mono` / `--ck-font-family-mono` - Code font
- `--srt-font-size-base` / `--ck-font-size-base` - Base font size
- `--srt-line-height-normal` / `--ck-line-height-normal` - Default line height

**Spacing:**
- `--srt-margin-paragraph` / `--ck-margin-paragraph` - Paragraph margin
- `--srt-margin-heading-top` / `--ck-margin-heading-top` - Heading top margin
- `--srt-padding-code-block-x` / `--ck-padding-code-block-x` - Code block horizontal padding

**Borders:**
- `--srt-border-radius-md` / `--ck-border-radius-md` - Default border radius
- `--srt-border-width-blockquote` / `--ck-border-width-blockquote` - Blockquote border width

See the CSS files for the complete list of available variables.

### CKEditor-Specific Features

The `ckeditor5.css` file includes styles for CKEditor-specific features:

**Text Sizes:**
```html
<span class="text-tiny">Tiny text</span>
<span class="text-small">Small text</span>
<span class="text-big">Big text</span>
<span class="text-huge">Huge text</span>
```

**Highlight Markers:**
```html
<mark class="marker-yellow">Yellow highlight</mark>
<mark class="marker-green">Green highlight</mark>
<mark class="marker-pink">Pink highlight</mark>
<mark class="marker-blue">Blue highlight</mark>
```

**Image Alignment:**
```html
<figure class="image image-style-align-left">...</figure>
<figure class="image image-style-align-center">...</figure>
<figure class="image image-style-align-right">...</figure>
```

**To-Do Lists:**
```html
<ul class="todo-list">
  <li><label class="todo-list__label"><input type="checkbox" checked><span>Done item</span></label></li>
  <li><label class="todo-list__label"><input type="checkbox"><span>Pending item</span></label></li>
</ul>
```

---

## 8. Database Migrations

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

## 9. Building Your Docker Image

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

### Build and Push to Control Plane Registry

```bash
# Build and push in one command
cpln image build --push --name my-strapi --tag v1 --org my-org
```

The image will be available at: `/org/my-org/image/my-strapi:v1`

### Test Locally (Optional)

```bash
# Build locally first
docker build -t my-strapi:local .

# Run with test environment
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
  my-strapi:local
```

### Generating Secrets

Use these commands to generate secure secrets:

```bash
# Generate APP_KEYS (comma-separated, minimum 2 required)
echo "$(openssl rand -base64 32),$(openssl rand -base64 32),$(openssl rand -base64 32),$(openssl rand -base64 32)"

# Generate individual secrets
openssl rand -base64 32  # API_TOKEN_SALT
openssl rand -base64 32  # ADMIN_JWT_SECRET
openssl rand -base64 32  # TRANSFER_TOKEN_SALT
openssl rand -base64 32  # JWT_SECRET
```

---

## 10. Container Registries

### Control Plane Registry (Recommended)

Control Plane has a built-in container registry. This is the simplest option - no pull secrets required.

**Manual Build:**

```bash
cpln image build --push --name my-strapi --tag v1 --org my-org
```

**Configure values.yaml:**

```yaml
strapi:
  image: /org/my-org/image/my-strapi:v1
  imagePullSecret: ""  # Not needed for Control Plane registry
```

---

### CI/CD with Control Plane Registry

For automated builds in CI/CD pipelines, use the `CPLN_TOKEN` secret and environment variables.

**GitHub Actions Example:**

```yaml
name: Build and Deploy Strapi

env:
  CPLN_ORG: my-org
  IMAGE_NAME: my-strapi

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Install Control Plane CLI
        run: |
          curl -sL https://github.com/controlplane-com/cli/releases/latest/download/cpln-linux-amd64 -o cpln
          chmod +x cpln
          sudo mv cpln /usr/local/bin/

      - name: Build and push image
        env:
          CPLN_TOKEN: ${{ secrets.CPLN_TOKEN }}
        run: |
          cpln image build --push \
            --name $IMAGE_NAME \
            --tag ${GITHUB_SHA::7} \
            --org $CPLN_ORG

      - name: Deploy to Control Plane
        env:
          CPLN_TOKEN: ${{ secrets.CPLN_TOKEN }}
        run: |
          cpln helm upgrade my-cms strapi \
            --org $CPLN_ORG \
            --set strapi.image=/org/$CPLN_ORG/image/$IMAGE_NAME:${GITHUB_SHA::7} \
            -f values.yaml
```

**GitLab CI Example:**

```yaml
variables:
  CPLN_ORG: my-org
  IMAGE_NAME: my-strapi

build:
  image: ubuntu:latest
  script:
    - curl -sL https://github.com/controlplane-com/cli/releases/latest/download/cpln-linux-amd64 -o cpln
    - chmod +x cpln && mv cpln /usr/local/bin/
    - export SHORT_SHA=$(echo $CI_COMMIT_SHA | cut -c1-7)
    - cpln image build --push --name $IMAGE_NAME --tag $SHORT_SHA --org $CPLN_ORG
  variables:
    CPLN_TOKEN: $CPLN_TOKEN  # Set in GitLab CI/CD variables
```

**Environment Variables:**

| Variable | Description |
|----------|-------------|
| `CPLN_TOKEN` | Service account token (store as secret) |
| `CPLN_ORG` | Your Control Plane organization |
| `IMAGE_NAME` | Name for your image (e.g., `my-strapi`) |

---

### Alternative: External Registries

You can also use external container registries if preferred. For private registries, you'll need to create a pull secret.

**GitHub Container Registry (ghcr.io):**

```bash
# Create pull secret
cpln secret create github-registry \
  --org your-org \
  --type docker \
  --docker-server ghcr.io \
  --docker-username YOUR_GITHUB_USERNAME \
  --docker-password YOUR_GITHUB_TOKEN
```

```yaml
strapi:
  image: ghcr.io/your-org/your-strapi:latest
  imagePullSecret: "github-registry"
```

**Docker Hub:**

```bash
cpln secret create dockerhub-registry \
  --org your-org \
  --type docker \
  --docker-server docker.io \
  --docker-username YOUR_DOCKERHUB_USERNAME \
  --docker-password YOUR_ACCESS_TOKEN
```

```yaml
strapi:
  image: your-username/your-strapi:latest
  imagePullSecret: "dockerhub-registry"
```

**Image URL Formats:**

| Registry | URL Format |
|----------|------------|
| Control Plane | `/org/ORG_NAME/image/IMAGE:TAG` |
| GitHub | `ghcr.io/owner/image:tag` |
| GitLab | `registry.gitlab.com/group/project:tag` |
| Docker Hub | `username/image:tag` |
| AWS ECR | `123456789.dkr.ecr.region.amazonaws.com/image:tag` |

---

## 11. Deploying to Control Plane

### Step 1: Set Up PostgreSQL Database

Strapi requires a PostgreSQL database. You can use any of these options:

- **Control Plane postgres template** - Deploy using `cpln helm install my-db postgres`
- **Cloud-hosted PostgreSQL** - AWS RDS, Google Cloud SQL, Azure Database, etc.
- **Self-managed PostgreSQL** - Any accessible PostgreSQL instance

Whatever option you choose, you'll need:
- Database hostname (e.g., `my-db-postgres.my-gvc.cpln.local` for Control Plane)
- Database name, username, and password
- Port (default: 5432)

### Step 2: Deploy Strapi

```bash
cpln helm install my-cms strapi \
  --set global.cpln.gvc=my-gvc \
  --set strapi.image=/org/my-org/image/my-strapi:v1 \
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
  image: /org/my-org/image/my-strapi:v1
  imagePullSecret: ""  # Not needed for Control Plane registry

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

## 12. Production Considerations

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

## 13. Troubleshooting

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

- [EXTRAS.md](./EXTRAS.md) - Automated deployments, webhooks, and advanced integrations
- [Strapi Documentation](https://docs.strapi.io/)
- [Strapi Marketplace](https://market.strapi.io/) - Plugins and integrations
- [Strapi GitHub](https://github.com/strapi/strapi)
- [Control Plane Documentation](https://docs.controlplane.com/)
- [Knex.js Documentation](https://knexjs.org/) (for migrations)
