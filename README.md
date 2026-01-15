# Control Plane Templates

### Purpose

Templates are used by Control Plane users to quickly deploy applications such as databases, queues, and even stateless apps.

### How templates work

Each template provides a Helm chart that makes deployment quick and easy. Each template has metadata in its root folder. The following are required components within each template folder:

- `icon.png` - Template icon (no resolution restriction, rendered in a square space, transparent background required)
- `versions/` - Parent folder containing all versions, each in its own subfolder (e.g., `versions/1.0.0/`)

**Recommended:**
- `RELEASES.md` - Release notes documenting changes across all versions

Each version folder must contain:
- `Chart.yaml` - Helm chart metadata with required fields and annotations
- `README.md` - Usage instructions for this version

Visit [Control Plane](https://controlplane.com) to learn about the platform.

---

## Contributing: Adding Templates and Versions

### Adding a New Template

1. Create a folder with a lowercase name (use hyphens for multi-word names, e.g., `postgres-highly-available`)
2. Add `icon.png` with transparent background
3. Create `versions/1.0.0/` folder
4. Add `Chart.yaml` with all required fields (see below)
5. Add `README.md` with usage instructions
6. (Recommended) Create `RELEASES.md` at template root for release notes

### Adding a New Version to an Existing Template

1. Create a new version folder under `versions/` (e.g., `versions/1.1.0/`)
2. Copy the previous version as a starting point
3. Update the `version` field in `Chart.yaml` (must match folder name exactly)
4. Update `appVersion` if the underlying application version changed
5. Update `created` date (for new versions) and `lastModified` date
6. Update the version's `README.md` with any changes
7. Add release notes to `RELEASES.md`

### Chart.yaml Requirements

```yaml
apiVersion: v2
name: template-name                    # Must match directory name exactly
description: Description for Control Plane
type: application
version: X.Y.Z                         # Must match folder name
appVersion: "app-version"              # Quoted string

annotations:
  created: "YYYY-MM-DD"                # ISO date when version was created
  lastModified: "YYYY-MM-DD"           # ISO date of last modification
  category: "category-name"            # e.g., database, cache, queue, event-streaming
  createsGvc: false                    # Boolean: does this template create a GVC?

# Optional: for templates that depend on other templates
dependencies:
  - name: dependency-name
    version: X.Y.Z
    repository: "https://controlplane-com.github.io/helm-packages"
```

**Categories:** `database`, `cache`, `event-streaming`, `queue`, `key-value store`, `authentication`, `app`, `security`, `proxy`

### Versioning Guidelines

- **MAJOR** (X.0.0): Breaking changes, major application version jumps, significant rewrites
- **MINOR** (0.X.0): New features, backward-compatible additions
- **PATCH** (0.0.X): Bug fixes, small configuration updates

### Common Mistakes to Avoid

- Version folder name not matching Chart.yaml `version` field
- Missing required annotations (`created`, `lastModified`, `category`, `createsGvc`)
- Forgetting to update `lastModified` date when making changes
- Using underscores instead of hyphens in template names
- Not quoting the `appVersion` value
