# Template e2e tests

A template with a `tests/` directory is installed for real on its PRs: CI creates a GVC in the CI org,
installs the changed version, runs the template's checks, upgrades into it from the versions customers
run, and deletes everything. The report lands on the PR as one comment.

```
{service}/tests/
  baselines/{version}.yaml   # how to install that version: GVC locations, prerequisite secrets, values
  checks.yaml                # what must work, each check tagged with the versions it applies to
```

## When it runs

- **`E2E Test Coverage`** (every PR, no credentials): when a PR changes what a version of an opted-in
  template deploys, it must also change something under that template's `tests/`, and the version must have
  a baseline. "Changes what it deploys" means the default `helm template` output differs, so README, comment
  and `wizard.yaml` fixes are exempt. A maintainer can waive it with the `e2e-gate-exempt` label.
- **`Template e2e tests`** (every PR and every push, or by hand from the Actions tab with a `targets` list
  such as `kafka/4.4.0`): a PR that changes no tested version passes at once; otherwise it runs
  automatically with the org token from the `e2e-nifah` environment. GitHub does not give that token to
  PRs from forks, so a fork's change is tested by pushing it to a branch in this repo.

Both `E2E Test Coverage` and `E2E result` are required checks on `main`. `E2E result` fails when any check
fails, so an untested or failing change cannot merge.

A version is tested when its render changed or it is new; a change to `tests/` alone re-tests the template's
newest version with a baseline.

## What every run checks

For the version under test, on a fresh install:

1. The install succeeds and every workload becomes ready (`--wait`, the baseline's `timeoutSeconds`).
2. **Rendered == stored**: each workload, volumeset, identity and policy the API stored matches the chart's
   render under the Console Drift tab's rules. Any difference is the drift users see on a default install.
3. Every check in `checks.yaml` whose range includes the version.
4. **Two no-op upgrades**: the second must report nothing `Updated`, and no stored spec may change.
5. Uninstall removes every resource of the release (uninstall can exit 0 having deleted nothing).

Then, for each `upgradeFrom` entry: install that version with its own baseline, run its checks, upgrade
into the version under test, and repeat 1-3 and 5.

## Baselines

A baseline is the typical customer install of one version, in production shape (the usual locations and
replica counts) at the smallest size that runs. Keep any resource reduction modest and proven: a baseline
that only works because CI is lenient tests nothing.

```yaml
locations: [aws-us-east-1]          # the GVC CI creates; a multi-location template lists three
timeoutSeconds: 900                 # per install / upgrade

generated:                          # random per run, masked in the logs → {gen.NAME}
  adminpw: hex                      # hex | kraft-cluster-id

secrets:                            # prerequisite secrets CI creates → {secrets.KEY.name}
  creds:
    type: dictionary
    keys: [password]                # each key gets a random value → {secrets.creds.password}
    entries: {username: admin}      # fixed or templated keys
  config:
    type: opaque
    payload: |                      # templated; may use any value above
      password: "{secrets.creds.password}"

vars:                               # names the checks use, so one check reads every version's layout
  admin_password: "{secrets.creds.password}"

values:                             # passed with -f; strings are templated
  credentialsSecretName: "{secrets.creds.name}"

upgradeFrom:                        # each version needs its own baseline
  - version: 4.1.0                  # upgraded with 4.1.0's own values, as `helm upgrade -f` would
  - version: 3.2.0
    values: new                     # or switch to this baseline's values on the upgrade
```

Always-available placeholders: `{release}`, `{gvc}`, `{org}`. Pick `upgradeFrom` versions from current
customer usage, most-used first; do not commit usage data itself (it names customer orgs).

## Checks

```yaml
checks:
  - id: produce-consume
    description: A message produced over SASL reaches a consumer.
    issue: "#5137"                  # optional: the change this check proves
    since: 4.2.0                    # optional range, inclusive
    until: 4.9.9
    exec:
      workload: "{release}-client"
      container: kafka
      shell: bash                   # default sh
      script: |
        ...
    expect:
      exitCode: 0                   # default 0
      stdout: "^CONSUMED "          # regex that must match (multiline)
      notStdout: "server\\.log"     # regex that must not match
    retries: 3                      # default 3
    retryDelaySeconds: 15
    timeoutSeconds: 120
```

A check marked `since:` the version under test is reported as **new**. Every check needs a way to fail:
assert on output only the working feature produces (a consumed message, a row read back), never on a
command merely exiting 0. Prefer scripts that work on every version in range, using `vars` where the
layout differs.

**Adding a feature or fixing a bug:** add a check with `since: <new version>` that fails on the old
behaviour, and give the new version a baseline (copy the previous one and adjust).

## Running locally

```bash
python3 .github/e2e/run.py run --target kafka/4.4.0 --gvc test-gvc-2 --release test-e2e \
  --upgrades none --out /tmp/kafka.json
python3 .github/e2e/run.py report --dir /tmp --out /tmp/report.md
```

`--gvc` uses an existing GVC and leaves it in place; without it the runner creates and deletes a
`templates-ci-*` GVC, which only the CI service account may do.

## The CI org

Org `nifah`, service account `templates-ci` in group `template-pipeline`. Its policies let it create
GVCs, workloads, volumesets, identities, secrets and policies anywhere, but manage only resources tagged
`templates-ci/managed: "true"`. The runner puts that tag on the GVC, on every secret it creates, and on
every chart resource and Helm release secret (`cpln helm --tag/--state-tag`). The policies match the tag
by equality: a regex (`=~`) query in a policy made every permission check on that kind fail with a 500,
org-wide. Every run first deletes CI GVCs older than three hours.
