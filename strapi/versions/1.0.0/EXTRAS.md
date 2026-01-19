# Strapi Extras

Advanced configurations and integrations for your Strapi deployment.

## Table of Contents

1. [Automated Website Deployments](#automated-website-deployments)
2. [Selective Webhook Subscriptions](#selective-webhook-subscriptions)
3. [Integration Examples](#integration-examples)

---

## Automated Website Deployments

When using Strapi as a headless CMS for a static site (Next.js, Gatsby, Astro, etc.), you'll want to automatically rebuild your website when content changes.

### How It Works

```
Content Editor publishes article in Strapi
            ↓
Strapi fires webhook to your deployment service
            ↓
Deployment service triggers rebuild
            ↓
Static site regenerates with new content
            ↓
Updated website is live
```

### Webhook Event Types

Strapi supports the following webhook events:

| Event | Trigger |
|-------|---------|
| `entry.create` | New content created |
| `entry.update` | Content modified |
| `entry.delete` | Content deleted |
| `entry.publish` | Content published (draft → live) |
| `entry.unpublish` | Content unpublished (live → draft) |
| `media.create` | File/image uploaded |
| `media.update` | Media modified |
| `media.delete` | Media deleted |

### Setting Up Webhooks

**Step 1: Get your deployment hook URL**

Most hosting providers offer webhook URLs for triggering builds:

- **Vercel**: Project Settings → Git → Deploy Hooks
- **Netlify**: Site Settings → Build & Deploy → Build hooks
- **GitHub Actions**: Use workflow dispatch endpoint

**Step 2: Configure in Strapi Admin**

1. Go to **Settings → Webhooks**
2. Click **Create new webhook**
3. Enter:
   - **Name**: e.g., "Deploy Website"
   - **URL**: Your deployment hook URL
   - **Events**: Select which events should trigger deployment

**Step 3: Select Events**

For most static sites, you'll want:
- `entry.publish` - Deploy when content goes live
- `entry.unpublish` - Deploy when content is removed
- `entry.update` - Deploy when published content changes

**Tip**: Skip `entry.create` if you use draft/publish workflow, as new drafts shouldn't trigger deployments.

### Webhook Payload

Each webhook includes:

**Headers:**
```
X-Strapi-Event: entry.publish
Content-Type: application/json
```

**Body:**
```json
{
  "event": "entry.publish",
  "createdAt": "2026-01-16T12:00:00.000Z",
  "model": "article",
  "uid": "api::article.article",
  "entry": {
    "id": 1,
    "title": "My Article",
    "slug": "my-article",
    "publishedAt": "2026-01-16T12:00:00.000Z"
    // ... other fields
  }
}
```

### Security: HMAC Signature Verification

Strapi can sign webhooks with HMAC-SHA256 to verify authenticity.

**Enable in webhook settings:**
1. Edit your webhook in Strapi Admin
2. Add a secret key
3. Strapi will include `X-Strapi-Signature` header

**Verify in your receiver:**
```javascript
const crypto = require('crypto');

function verifySignature(payload, signature, secret) {
  const hmac = crypto.createHmac('sha256', secret);
  const digest = hmac.update(JSON.stringify(payload)).digest('hex');
  return crypto.timingSafeEqual(
    Buffer.from(signature),
    Buffer.from(digest)
  );
}
```

---

## Selective Webhook Subscriptions

### The Challenge

By default, Strapi webhooks fire for **all content types**. If you have multiple content types (Articles, Products, Pages), a single `entry.publish` webhook fires for all of them.

### Native Limitation

**Strapi does not currently support per-content-type webhook filtering in the admin UI.**

This means you cannot configure "only fire webhooks when Articles are published" directly in Strapi.

### Workaround: Filter at the Receiver

The webhook payload includes the `model` and `uid` fields, which identify the content type. Filter in your webhook handler:

**Option 1: Simple Filter**

```javascript
// Your webhook endpoint
app.post('/webhook/deploy', (req, res) => {
  const { model, event } = req.body;

  // Only rebuild for specific content types
  const triggerModels = ['article', 'page', 'author'];

  if (!triggerModels.includes(model)) {
    console.log(`Skipping ${model} - not in trigger list`);
    return res.status(200).send('Skipped');
  }

  // Trigger deployment
  triggerDeploy();
  res.status(200).send('Deploying');
});
```

**Option 2: Different Actions per Content Type**

```javascript
app.post('/webhook', (req, res) => {
  const { model, event, entry } = req.body;

  switch (model) {
    case 'article':
      // Rebuild blog section only
      triggerBlogRebuild();
      break;

    case 'product':
      // Update product catalog
      updateProductIndex(entry);
      break;

    case 'navigation':
      // Full site rebuild (navigation affects everything)
      triggerFullRebuild();
      break;

    default:
      // Ignore other content types
      console.log(`No action for ${model}`);
  }

  res.status(200).send('OK');
});
```

**Option 3: Lifecycle Hooks in Strapi**

For more control, use Strapi lifecycle hooks instead of webhooks:

```javascript
// src/api/article/content-types/article/lifecycles.js
module.exports = {
  async afterUpdate(event) {
    const { result } = event;

    // Only trigger if published
    if (result.publishedAt) {
      await fetch('https://your-deploy-hook.com', {
        method: 'POST',
        body: JSON.stringify({
          model: 'article',
          id: result.id
        })
      });
    }
  }
};
```

This approach gives you **per-content-type control** directly in Strapi.

---

## Integration Examples

### Vercel Deploy Hook

**Step 1: Create Deploy Hook in Vercel**
1. Go to your Vercel project
2. Settings → Git → Deploy Hooks
3. Create hook, copy URL

**Step 2: Add to Strapi**
```
Name: Vercel Deploy
URL: https://api.vercel.com/v1/integrations/deploy/prj_xxxxx/yyyyyyy
Events: entry.publish, entry.unpublish
```

### Netlify Build Hook

**Step 1: Create Build Hook in Netlify**
1. Site settings → Build & deploy → Build hooks
2. Add build hook, copy URL

**Step 2: Add to Strapi**
```
Name: Netlify Build
URL: https://api.netlify.com/build_hooks/xxxxxxxxx
Events: entry.publish, entry.unpublish
```

### GitHub Actions Workflow

**Step 1: Create workflow file**

```yaml
# .github/workflows/rebuild.yml
name: Rebuild Site

on:
  workflow_dispatch:
  repository_dispatch:
    types: [strapi-content-update]

jobs:
  build:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Build and deploy
        run: |
          npm ci
          npm run build
          # Deploy to your hosting
```

**Step 2: Create webhook receiver**

```javascript
// Middleware to receive Strapi webhook and trigger GitHub Action
app.post('/strapi-webhook', async (req, res) => {
  await fetch(
    'https://api.github.com/repos/OWNER/REPO/dispatches',
    {
      method: 'POST',
      headers: {
        'Authorization': `token ${process.env.GITHUB_TOKEN}`,
        'Accept': 'application/vnd.github.v3+json'
      },
      body: JSON.stringify({
        event_type: 'strapi-content-update',
        client_payload: req.body
      })
    }
  );
  res.status(200).send('OK');
});
```

### Control Plane Workload Restart

To trigger a workload restart/redeploy on content change:

**Step 1: Create a webhook receiver workload**

```javascript
// Simple Express app to receive webhooks
const express = require('express');
const { exec } = require('child_process');

const app = express();
app.use(express.json());

app.post('/webhook', (req, res) => {
  const { model } = req.body;

  // Only rebuild for specific models
  if (['article', 'page'].includes(model)) {
    // Use cpln CLI to force redeploy
    exec('cpln workload force-redeployment my-frontend --gvc my-gvc',
      (error, stdout) => {
        if (error) console.error(error);
        else console.log('Redeployment triggered');
      }
    );
  }

  res.status(200).send('OK');
});

app.listen(3000);
```

**Step 2: Configure Strapi webhook**
```
Name: Control Plane Redeploy
URL: https://webhook-receiver.my-gvc.cpln.app/webhook
Events: entry.publish
```

---

## Best Practices

### 1. Debounce Rapid Changes

If editors make multiple quick changes, you don't want 10 deployments:

```javascript
let deployTimeout;

app.post('/webhook', (req, res) => {
  clearTimeout(deployTimeout);

  // Wait 30 seconds for more changes before deploying
  deployTimeout = setTimeout(() => {
    triggerDeploy();
  }, 30000);

  res.status(200).send('Queued');
});
```

### 2. Queue Deployments

For high-traffic sites, queue deployments instead of triggering immediately:

```javascript
const deployQueue = [];
let isDeploying = false;

app.post('/webhook', (req, res) => {
  deployQueue.push(req.body);
  processQueue();
  res.status(200).send('Queued');
});

async function processQueue() {
  if (isDeploying || deployQueue.length === 0) return;

  isDeploying = true;
  deployQueue.length = 0; // Clear queue

  await triggerDeploy();

  isDeploying = false;

  // Check if more items queued during deploy
  if (deployQueue.length > 0) {
    processQueue();
  }
}
```

### 3. Monitor Webhook Delivery

Check webhook delivery status in Strapi Admin:
- Settings → Webhooks → Click webhook → View delivery logs

Failed deliveries show error codes and can be retried.

### 4. Use Environment-Specific Webhooks

Different webhooks for different environments:

```javascript
// config/env/production/plugins.js
module.exports = {
  // Production webhook settings
};

// config/env/staging/plugins.js
module.exports = {
  // Staging webhook settings
};
```
