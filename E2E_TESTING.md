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
  a baseline. "Changes what it deploys" means the default `helm template` output differs, so README and other `.md`, comment,
  `wizard.yaml`, `catalog.yaml` and icon changes are exempt, and a PR with only those changes runs no suite. A maintainer can waive it with the `e2e-gate-exempt` label.
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

1. The install succeeds and every workload becomes ready: `--wait`, then every replica in every location, so a
   stateful workload that starts its replicas one at a time has finished starting before any check runs
   (the baseline's `timeoutSeconds` bounds each wait).
2. **Rendered == stored**: each workload, volumeset, identity and policy the API stored matches the chart's
   render under the Console Drift tab's rules. Any difference is the drift users see on a default install.
   For now drift is reported as a **warning** and does not fail the run, until the catalog's existing drift
   is fixed. A template with no drift left sets `driftBlocks: true` at the top of its `tests/checks.yaml`,
   and from then on drift **fails** its runs. A resource that cannot be read always fails.
3. Every check in `checks.yaml` whose range includes the version.
4. **Two no-op upgrades**: the second must report nothing `Updated`, and no stored spec may change.
5. Uninstall removes every resource of the release (uninstall can exit 0 having deleted nothing).

Then each of the baseline's `variants` (see [Variants](#variants)) gets the same five steps on a fresh
install of its own. Then, for each `upgradeFrom` entry: install that version with its own baseline, run its checks, upgrade
into the version under test, and repeat 1-3 and 5. The checks on the starting version only **warn**: that
version has already shipped and the PR cannot fix it. Everything run against the version under test blocks.

## Baselines

A baseline is the typical customer install of one version, in production shape (the usual locations and
replica counts) at the smallest size that runs. Keep any resource reduction modest and proven: a baseline
that only works because CI is lenient tests nothing.

```yaml
locations: [aws-us-east-1]          # the GVC CI creates; a multi-location template lists every location it needs
timeoutSeconds: 900                 # per install / upgrade

generated:                          # random per run, masked in the logs → {gen.NAME}
  adminpw: hex                      # hex | kraft-cluster-id | fernet | pkcs12
  cert: pkcs12                      # a throwaway self-signed .p12 (openssl pkcs12 -export): {gen.cert} is
                                    # its base64 text, {gen.cert.passphrase} its random password

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
  - version: 2.0.0
    timeoutSeconds: 300             # optional: the upgrade's own wait
    knownIssue:                     # optional: everything after the starting install warns
      note: "2.x volumesets were renamed in 3.0.0; the upgrade deletes them"
```

### Variants

The baseline stays the chart's typical install. An optional feature that changes what the chart does
(synchronous replication, a backup mode, an HA flag) gets a **variant**: one more fresh install of the same
version with `values` deep-merged over the baseline's. To also test turning the feature on in an existing
release, give an `upgradeFrom` entry a `set` (merged over that upgrade's values) and a `name`.

```yaml
variants:
  - name: sync                      # lowercase, digits, '-', at most 20 characters; scenario "install 3.0.0 [sync]"
    values:
      synchronous:
        enabled: true
    timeoutSeconds: 1200            # optional: this install's own wait

upgradeFrom:
  - version: 2.4.1
    values: new
    name: sync                      # scenario "upgrade 2.4.1 → 3.0.0 (new values) [sync]"
    set:                            # turned on by the upgrade
      synchronous:
        enabled: true
```

Select a variant's checks with `scenarios: "\\[sync\\]"`, and keep a default-only check off it with
`scenarios: "^(?!.*\\[sync\\])"`. Each variant costs a full install in every run, so add one only for a
feature with its own failure modes; a value the chart merely passes through needs none. Variants use the
baseline's `generated` values and `secrets`. The same version may appear twice in `upgradeFrom` (plain and
with `set`). Locally, `--variants none` (or a comma-separated list of names) limits which run.

### Refused upgrades

When the new version must refuse to start on the old version's data (a database major-version guard), the
`upgradeFrom` entry says so, and gives the values that make the upgrade work:

```yaml
upgradeFrom:
  - version: 3.4.2
    refused:
      timeoutSeconds: 420             # watch window (default 420): the upgrade must never be ready in it
    then:
      set: {image: "postgres:18"}     # deep-merged over the upgrade's values for the second upgrade
```

The scenario (`upgrade 3.4.2 → 4.0.0 (refused, then pinned)`) installs 3.4.2 and runs its checks, then
runs a plain `cpln helm upgrade` with no `--wait`, as a user would. That must exit 0, and the release must
never become ready for the whole window, and the window must end with the new version HELD for at least
3 polls over 60 s: in every location, the deployment is not ready and has an entry for the workload version
the upgrade set that is not ready and carries no "will be restarted shortly (version transition N -> N+1)"
or "is initializing" message. After a stateful upgrade the old replica keeps serving under the transition
message for ~90 s before any new-version entry appears, so slowness and that transition do not count as a
refusal, and the checks below run on the new replica. Older-version entries may stay ready: with several
replicas the rollout replaces one at a time, and the replicas it has not reached keep serving while the
first replaced one is held. Size `timeoutSeconds` to cover the transition, the new replica's start and that minute. On a failed
watch or refused check the log shows every deployment's version entries and messages. Next it runs the `phase: refused` checks, which prove why it was
refused: the guard's message, the old data untouched, nothing running on it. The scenario fails if no such
check covers the version, since never becoming ready proves nothing on its own. Last, it upgrades again
with `then.set` and continues like any upgrade: every replica ready, drift, then the normal checks (so a
`{installed_version}` row proves the data survived). A failed step skips the rest, apart from uninstall.

```yaml
  - id: guard-holds
    since: 4.0.0
    phase: refused
    exec:
      workload: "{release}-postgres"
      shell: bash
      script: |
        echo "DATA=$(cat "$PGDATA/PG_VERSION")"
        grep -qx postgres /proc/[0-9]*/comm && echo POSTGRES_RUNNING || echo NO_POSTGRES
        cat /tmp/pg-major-guard
    expect:
      stdout: "(?s)^DATA=18$.*^NO_POSTGRES$.*REFUSING TO START.*--set image=postgres:18"
    retries: 8                      # an exec can land on the held container's restart
```

A check that only holds on a fresh install (the new major version, for one) takes `scenarios: "^install "`.

An `upgradeFrom` entry marked `knownIssue` records an upgrade path that is known to be broken in a shipped
version. Its failures warn with the note, except a leak on uninstall, which still fails. Keep a working
upgrade source next to it, so an upgrade regression still blocks, and remove the entry with the fix.

Always-available placeholders: `{release}`, `{gvc}`, `{org}`, and `{locations.0}`, `{locations.1}`, …
(the baseline's `locations`, in the order listed). Checks also get `{version}` (the version
running now) and `{installed_version}` (the one the scenario installed first), so a check can write a
row tagged with `{version}` and prove the row tagged `{installed_version}` survived the upgrade. Pick `upgradeFrom` versions from current
customer usage, most-used first; do not commit usage data itself (it names customer orgs).

### Multi-location baselines

A template whose point is several locations lists them in its baseline, and CI creates the GVC with
exactly those. Prove the cross-location behaviour with checks that write in one location and read in
another (`exec.location`). Cross-location traffic is billed, so keep it minimal: pick nearby regions
(`aws-us-east-1` + `aws-us-east-2`) unless the behaviour needs distance, and move a handful of small
messages or rows, never a bulk load.

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
      location: "{locations.1}"     # optional: run in this location's replica (default: any)
      replica: "{release}-client-0" # optional: one replica by name
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
    phase: refused                  # optional: run ONLY in a refused upgrade's held step (default: ready,
                                    # every other step)
    scenarios: "^install "          # optional: regex on the scenario name; run only where it matches
                                    # (variant scenarios also start "install ": use "\\[NAME\\]")
    knownIssue:                     # optional: a failure warns instead of blocking
      note: "REST Proxy rejects valid users with jaas values carried from 4.1.0 and older"
      scenarios: "^upgrade "        # regex on the scenario name; default every scenario
```

Use `knownIssue` to record something that does not work yet without blocking every PR on that template.
Scope it as narrowly as you can, so the same check still blocks where it passes today, and remove it
with the fix.

A check marked `since:` the version under test is reported as **new**. Every check needs a way to fail:
assert on output only the working feature produces (a consumed message, a row read back), never on a
command merely exiting 0. Prefer scripts that work on every version in range, using `vars` where the
layout differs.

**Adding a feature or fixing a bug:** add a check with `since: <new version>` that fails on the old
behaviour, and give the new version a baseline (copy the previous one and adjust).

## Running locally

```bash
python3 .github/e2e/run.py run --target kafka/4.4.0 --gvc test-gvc-2 --release test-e2e \
  --upgrades none --variants none --out /tmp/kafka.json
python3 .github/e2e/run.py report --dir /tmp --out /tmp/report.md
```

`--gvc` uses an existing GVC and leaves it in place; without it the runner creates and deletes a
`templates-ci-*` GVC, which only the CI service account may do.

Ctrl-C (SIGINT) or SIGTERM stops the run after cleanup: the running scenario uninstalls the release it
installed, the teardown deletes the run's secrets, and the run exits 130 with a `harness · runner` failure
in its result file. Signals that arrive during that cleanup are ignored. `report` skips any JSON file in
`--dir` that is not a result file.

## The CI org

Org `nifah`, service account `templates-ci` in group `template-pipeline`. Its policies let it create
GVCs, workloads, volumesets, identities, secrets and policies anywhere, but manage only resources tagged
`templates-ci/managed: "true"`. The runner puts that tag on the GVC, on every secret it creates, and on
every chart resource and Helm release secret (`cpln helm --tag/--state-tag`). The policies match the tag
by equality: a regex (`=~`) query in a policy made every permission check on that kind fail with a 500,
org-wide. Every run first deletes CI GVCs older than three hours.
