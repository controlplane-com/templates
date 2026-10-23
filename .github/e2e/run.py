#!/usr/bin/env python3
"""End-to-end template tests: install a chart for real, check it works, tear it down.

Subcommands (see E2E_TESTING.md for the test-file format):
  plan     --base SHA [--targets "svc/ver ..."]   which versions this PR must test (JSON on stdout)
  gate     --base SHA                             fail when a chart change ships without test changes
  run      --target svc/ver --out FILE            one target: every scenario, then teardown
  sweep    [--older-than-hours N]                 delete CI GVCs a dead run left behind
  report   --dir DIR --out FILE                   one Markdown report from the per-target JSON files

`run` creates its own GVC (named templates-ci-*) unless --gvc names an existing one, which is the local
development mode: the GVC is then left in place and only this run's release is removed from it.
The CPLN_TOKEN / CPLN_ORG environment (or a cpln profile) selects the org.
"""
import argparse
import base64
import datetime as dt
import json
import os
import re
import secrets as pysecrets
import subprocess
import sys
import tempfile
import time

import yaml

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import drift  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
GVC_PREFIX = "templates-ci-"
# The CI service account manages only resources carrying this tag (its policies match on it).
MANAGED_TAG = ("templates-ci/managed", "true")
IGNORED_FOR_RENDER = re.compile(r"/(README\.md|wizard\.yaml)$")


# ─── small helpers ────────────────────────────────────────────────────────────

def log(msg):
    print(msg, flush=True)


def group(title):
    if os.environ.get("GITHUB_ACTIONS"):
        print(f"::group::{title}", flush=True)
    else:
        print(f"── {title}", flush=True)


def endgroup():
    if os.environ.get("GITHUB_ACTIONS"):
        print("::endgroup::", flush=True)


def mask(value):
    if os.environ.get("GITHUB_ACTIONS"):
        print(f"::add-mask::{value}", flush=True)


def sh(cmd, timeout=600, check=False, input=None):
    """Run a command; return (code, stdout, stderr). Never raises on a non-zero exit unless check."""
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout, input=input)
        code, out, err = p.returncode, p.stdout, p.stderr
    except subprocess.TimeoutExpired as e:
        code, out, err = 124, (e.stdout or b"").decode() if isinstance(e.stdout, bytes) else (e.stdout or ""), "timeout"
    if check and code:
        raise RuntimeError(f"{' '.join(cmd[:4])} … exited {code}: {(err or out).strip()[-400:]}")
    return code, out, err


def semver(v):
    return tuple(int(x) for x in v.split("."))


def in_range(version, check):
    v = semver(version)
    if check.get("since") and v < semver(str(check["since"])):
        return False
    if check.get("until") and v > semver(str(check["until"])):
        return False
    return True


def fill(obj, ctx):
    """Replace {release}, {gvc}, {org} and {secrets.NAME.KEY|name} placeholders in every string."""
    if isinstance(obj, dict):
        return {k: fill(v, ctx) for k, v in obj.items()}
    if isinstance(obj, list):
        return [fill(v, ctx) for v in obj]
    if isinstance(obj, str):
        def sub(m):
            key = m.group(1)
            if key not in ctx:
                raise KeyError(f"unknown placeholder {{{key}}}")
            return ctx[key]
        return re.sub(r"\{([a-zA-Z0-9_.-]+)\}", sub, obj)
    return obj


def load_yaml(path):
    with open(path) as f:
        return yaml.safe_load(f) or {}


def cpln(*args, timeout=300):
    # Org flags go before a `--`, or `workload exec` would pass them to the container command.
    split = args.index("--") if "--" in args else len(args)
    return sh(["cpln", *args[:split], *ORG_ARGS, *args[split:]], timeout=timeout)


def cpln_json(*args):
    code, out, _ = cpln(*args, "-o", "json")
    if code:
        return None
    try:
        return json.loads(out)
    except json.JSONDecodeError:
        return None


def missing(*args):
    """True only when the API says 404. Any other failure (403, 500, a timeout) is not proof of absence."""
    code, out, err = cpln(*args, "-o", "json")
    return code != 0 and '"status": 404' in (out + err)


ORG_ARGS = []


# ─── plan / gate: what changed ────────────────────────────────────────────────

def changed_files(base):
    code, out, err = sh(["git", "-C", ROOT, "diff", "--name-only", f"{base}...HEAD"])
    if code:
        code, out, err = sh(["git", "-C", ROOT, "diff", "--name-only", base, "HEAD"], check=True)
    return [l for l in out.splitlines() if l]


def render(chart_dir):
    if not os.path.isdir(os.path.join(chart_dir, "charts")):
        sh(["helm", "dependency", "build", chart_dir], timeout=300)
    code, out, err = sh(["helm", "template", "ci", chart_dir, "--set", "global.cpln.gvc=ci"], timeout=120)
    return out if code == 0 else f"RENDER-ERROR {err}"


def render_changed(base, version_dir):
    """True when the version is new or its default render differs from the base commit's."""
    tmp = tempfile.mkdtemp(prefix="e2e-base-")
    code, _, _ = sh(["git", "-C", ROOT, "archive", "--format=tar", "-o", f"{tmp}/b.tar", base, version_dir])
    if code:  # the directory does not exist on the base commit: a new version
        return True
    sh(["tar", "-xf", f"{tmp}/b.tar", "-C", tmp], check=True)
    return render(os.path.join(tmp, version_dir)) != render(os.path.join(ROOT, version_dir))


def touched_versions(files):
    out = set()
    for f in files:
        m = re.match(r"^([^/]+)/versions/(\d+\.\d+\.\d+)/", f)
        if m and not IGNORED_FOR_RENDER.search(f):
            out.add((m.group(1), m.group(2)))
    return out


def cmd_plan(a):
    if a.targets:
        targets = [tuple(t.split("/")) for t in a.targets.split()]
    else:
        files = changed_files(a.base)
        targets = {tv for tv in touched_versions(files) if render_changed(a.base, f"{tv[0]}/versions/{tv[1]}")}
        # A change to a template's tests re-runs its newest tested version.
        for f in files:
            m = re.match(r"^([^/]+)/tests/", f)
            if m:
                vs = baselines(m.group(1))
                if vs:
                    targets.add((m.group(1), max(vs, key=semver)))
    plan = [f"{s}/{v}" for s, v in sorted(targets)
            if os.path.exists(os.path.join(ROOT, s, "tests", "baselines", f"{v}.yaml"))]
    print(json.dumps(plan))


def baselines(service):
    d = os.path.join(ROOT, service, "tests", "baselines")
    return [f[:-5] for f in os.listdir(d) if re.match(r"^\d+\.\d+\.\d+\.yaml$", f)] if os.path.isdir(d) else []


def cmd_gate(a):
    """A template that has opted in (it has a tests/ directory) must update its tests with any render change."""
    files = changed_files(a.base)
    problems = []
    for s, v in sorted(touched_versions(files)):
        if not os.path.isdir(os.path.join(ROOT, s, "tests")):
            continue
        if not render_changed(a.base, f"{s}/versions/{v}"):
            continue
        if not os.path.exists(os.path.join(ROOT, s, "tests", "baselines", f"{v}.yaml")):
            problems.append(f"{s} {v}: the render changed but {s}/tests/baselines/{v}.yaml does not exist")
        elif not any(f.startswith(f"{s}/tests/") for f in files):
            problems.append(f"{s} {v}: the render changed but nothing under {s}/tests/ did — add or update a check "
                            f"for this change in {s}/tests/checks.yaml")
    for p in problems:
        print(f"::error::{p}" if os.environ.get("GITHUB_ACTIONS") else f"FAIL {p}")
    if not problems:
        print("e2e coverage gate: ok")
    return 1 if problems else 0


# ─── run: one target ──────────────────────────────────────────────────────────

class Target:
    def __init__(self, service, version, release, gvc, own_gvc):
        self.service, self.version = service, version
        self.chart = os.path.join(ROOT, service, "versions", version)
        self.release, self.gvc, self.own_gvc = release, gvc, own_gvc
        self.org = os.environ.get("CPLN_ORG", "")
        self.results = []          # {scenario, check, status, detail, new}
        self.created_secrets = []
        self.checks = load_yaml(os.path.join(ROOT, service, "tests", "checks.yaml")).get("checks", [])

    def baseline(self, version):
        return load_yaml(os.path.join(ROOT, self.service, "tests", "baselines", f"{version}.yaml"))

    def record(self, scenario, check, ok, detail="", new=False, skipped=False, warn=False):
        """warn=True: a failure is reported as a warning and does not fail the run."""
        status = "skip" if skipped else ("pass" if ok else ("warn" if warn else "fail"))
        self.results.append({"scenario": scenario, "check": check, "status": status, "detail": detail, "new": new})
        log(f"  [{status.upper():4}] {scenario} · {check}{(' — ' + detail) if detail else ''}")
        return ok


def make_release(run_id, index):
    """Short and unique per run, attempt and matrix job: secret and policy names are org-wide."""
    n, digits = int(run_id), "0123456789abcdefghijklmnopqrstuvwxyz"
    s = ""
    while n:
        n, r = divmod(n, 36)
        s = digits[r] + s
    return f"e2e{s[-7:] or '0'}{os.environ.get('GITHUB_RUN_ATTEMPT', '1')}{index}"


def create_gvc(t, locations):
    manifest = {"kind": "gvc", "name": t.gvc, "description": f"templates e2e CI: {t.service} {t.version}",
                "tags": {MANAGED_TAG[0]: MANAGED_TAG[1], "cpln/marketplace-gvc": t.gvc, "templates-ci/target": f"{t.service}-{t.version}",
                         "templates-ci/run": os.environ.get("GITHUB_RUN_ID", "local")},
                "spec": {"staticPlacement": {"locationLinks": [f"//location/{l}" for l in sorted(locations)]}}}
    code, out, err = apply(manifest)
    g = cpln_json("gvc", "get", t.gvc)
    if not g:  # `cpln apply` exits 0 on a 400, so the read-back is the real check
        raise RuntimeError(f"GVC {t.gvc} was not created or cannot be read: {(err or out).strip()[-300:]}")


def apply(manifest):
    with tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False) as f:
        yaml.safe_dump(manifest, f)
    try:
        args = ["apply", "--file", f.name] + (["--gvc", manifest["gvc"]] if manifest.get("gvc") else [])
        return cpln(*args)
    finally:
        os.unlink(f.name)


def generate(kind):
    if kind == "kraft-cluster-id":  # a KRaft cluster id is a base64url UUID without padding
        return base64.urlsafe_b64encode(pysecrets.token_bytes(16)).decode().rstrip("=")
    return pysecrets.token_hex(16)


def prepare(t, base, ctx, version):
    """Resolve a baseline's generated values, create its prerequisite secrets, then resolve its vars.

    Every generated value is masked in the CI log. Secrets are tagged so CI may manage and later delete
    them (its policies only reach resources tagged with a templates-ci-* GVC)."""
    for key, kind in (base.get("generated") or {}).items():
        if f"gen.{key}" not in ctx:
            ctx[f"gen.{key}"] = generate(kind)
            mask(ctx[f"gen.{key}"])
    for key, spec in (base.get("secrets") or {}).items():
        if f"secrets.{key}.name" in ctx:  # an upgrade keeps the secrets the install created
            continue
        name = f"{t.release}-{key}"
        tags = {MANAGED_TAG[0]: MANAGED_TAG[1], "cpln/marketplace-gvc": t.gvc, "app.cpln.io/instance": t.release}
        if spec.get("type", "dictionary") == "dictionary":
            values = {k: generate("hex") for k in spec.get("keys", [])}
            for v in values.values():
                mask(v)
            ctx.update({f"secrets.{key}.{k}": v for k, v in values.items()})
            values.update({k: str(v) for k, v in fill(spec.get("entries") or {}, ctx).items()})
            manifest = {"kind": "secret", "name": name, "type": "dictionary", "tags": tags, "data": values}
        else:
            manifest = {"kind": "secret", "name": name, "type": "opaque", "tags": tags,
                        "data": {"encoding": "plain", "payload": fill(spec["payload"], ctx)}}
        apply(manifest)
        if not cpln_json("secret", "get", name):  # `cpln apply` exits 0 on a 400
            raise RuntimeError(f"secret {name} was not created")
        t.created_secrets.append(name)
        ctx[f"secrets.{key}.name"] = name
    for key, value in (base.get("vars") or {}).items():
        ctx[key] = fill(str(value), ctx)


def values_file(base, ctx):
    f = tempfile.NamedTemporaryFile("w", suffix=".yaml", delete=False)
    yaml.safe_dump(fill(base.get("values") or {}, ctx), f)
    f.close()
    return f.name


def chart_values(chart):
    """The version's own values.yaml, passed explicitly: some versions' .helmignore leaves it out of the
    chart (kafka 2.0.0-3.5.1), so Helm alone would render them with no defaults at all."""
    return ["-f", os.path.join(chart, "values.yaml")]


def helm(t, verb, version, vfile, timeout_s):
    chart = os.path.join(ROOT, t.service, "versions", version)
    args = ["helm", verb, t.release, chart, "--gvc", t.gvc, "--dependency-update", *chart_values(chart), "-f", vfile,
            "--wait", "--timeout", str(timeout_s), "--tag", "=".join(MANAGED_TAG), "--state-tag", "=".join(MANAGED_TAG)]
    code, out, err = cpln(*args, timeout=timeout_s + 300)
    return code, out + err


def deployments_summary(t):
    lines = []
    wls = cpln_json("workload", "query", "--gvc", t.gvc, "--tag", f"app.cpln.io/instance={t.release}") or {}
    for w in wls.get("items", []):
        d = cpln_json("workload", "get-deployments", w["name"], "--gvc", t.gvc) or {}
        for dep in d.get("items", []):
            st = dep.get("status", {})
            msgs = [v.get("message") for v in st.get("versions", []) if v.get("message")]
            lines.append(f"{w['name']}@{dep.get('name')}: ready={st.get('ready')} {'; '.join(msgs)[:200]}")
    return lines


def rendered_docs(t, version, vfile):
    chart = os.path.join(ROOT, t.service, "versions", version)
    code, out, err = sh(["helm", "template", t.release, chart, "--set", f"global.cpln.gvc={t.gvc}",
                         *chart_values(chart), "-f", vfile])
    if code:
        raise RuntimeError(err.strip()[-400:])
    return [d for d in yaml.safe_load_all(out) if isinstance(d, dict) and d.get("kind")]


def fetch(t):
    def f(kind, name, gvc_scoped):
        return cpln_json(kind, "get", name, *(["--gvc", t.gvc] if gvc_scoped else []))
    return f


def check_drift(t, scenario, version, vfile):
    drifted, env, errors = drift.compare(rendered_docs(t, version, vfile), fetch(t))
    detail = "; ".join(errors + drifted)[:1500]
    if env:
        log(f"  (environment-dependent, not drift: {'; '.join(env)[:300]})")
    # Drift warns for now: most shipped templates still drift, so it would block every PR until they are
    # fixed. A resource that could not be read still fails, since that is not drift.
    if drifted and not errors:
        log(f"::warning::{t.service}/{t.version} {scenario}: drift — {detail[:300]}")
    return t.record(scenario, "rendered == stored (Console Drift tab)", not (drifted or errors), detail,
                    warn=not errors)


def stored_specs(t):
    out = {}
    for kind in ("workload", "volumeset", "identity"):
        r = cpln_json(kind, "query", "--gvc", t.gvc, "--tag", f"app.cpln.io/instance={t.release}") or {}
        for i in r.get("items", []):
            out[f"{kind}/{i['name']}"] = {k: i.get(k) for k in ("spec", "aws", "gcp", "azure") if k in i}
    return out


def check_noop_upgrade(t, scenario, version, vfile, timeout_s):
    """Two upgrades with identical values. The second must be all Unchanged; anything the first reports
    Updated must be spec-identical before and after (a one-time re-apply, not chart drift)."""
    before = stored_specs(t)
    code, out = helm(t, "upgrade", version, vfile, timeout_s)
    if code:
        return t.record(scenario, "no-op upgrade", False, out.strip()[-600:])
    first = re.findall(r"^\s*Updated\s+(\S+)", out, re.M)
    after = stored_specs(t)
    changed = [k for k in before if before[k] != after.get(k)]
    code, out2 = helm(t, "upgrade", version, vfile, timeout_s)
    second = re.findall(r"^\s*Updated\s+(\S+)", out2, re.M)
    ok = code == 0 and not second and not changed
    detail = []
    if changed:
        detail.append("stored spec changed on upgrade 1: " + ", ".join(changed))
    if second:
        detail.append("upgrade 2 still Updated: " + ", ".join(s.rsplit("/", 2)[-2] + "/" + s.rsplit("/", 1)[-1] for s in second))
    if first and not changed:
        log(f"  (upgrade 1 re-applied {len(first)} resource(s) with identical specs: known one-time re-apply)")
    return t.record(scenario, "no-op upgrade ×2 (no churn)", ok, "; ".join(detail))


def run_checks(t, scenario, version, ctx, new_version, warn=False):
    """warn=True for the starting version of an upgrade: it has already shipped, so a PR cannot fix it."""
    ctx["version"] = version  # the version running now; {installed_version} is the scenario's first one
    for c in t.checks:
        cid = c["id"]
        if not in_range(version, c):
            continue
        is_new = str(c.get("since", "")) == new_version and version == new_version
        ok, detail = exec_check(t, c, ctx)
        label = cid + (f" ({c['issue']})" if c.get("issue") else "")
        known = c.get("knownIssue") or {}
        is_known = bool(known) and re.search(known.get("scenarios", ""), scenario) is not None
        if not ok and is_known:
            detail = f"known issue: {known.get('note', '').strip()} | {detail}"
        t.record(scenario, label, ok, detail, new=is_new, warn=warn or is_known)


def exec_check(t, c, ctx):
    e = fill(c["exec"], ctx)
    expect = c.get("expect") or {}
    tries, delay = int(c.get("retries", 3)), int(c.get("retryDelaySeconds", 15))
    detail = ""
    for attempt in range(1, tries + 1):
        cmd = ["workload", "exec", e["workload"], "--gvc", t.gvc]
        if e.get("container"):
            cmd += ["--container", e["container"]]
        cmd += ["--", e.get("shell", "sh"), "-c", e["script"]]
        code, out, err = cpln(*cmd, timeout=int(c.get("timeoutSeconds", 120)))
        problems = []
        if code != int(expect.get("exitCode", 0)):
            problems.append(f"exit {code}, expected {expect.get('exitCode', 0)}")
        if expect.get("stdout") and not re.search(expect["stdout"], out, re.M):
            problems.append(f"stdout did not match /{expect['stdout']}/")
        if expect.get("notStdout") and re.search(expect["notStdout"], out, re.M):
            problems.append(f"stdout matched forbidden /{expect['notStdout']}/")
        if not problems:
            return True, ""
        tail = (out.strip() or err.strip())[-300:].replace("\n", " ⏎ ")
        detail = f"{'; '.join(problems)} (attempt {attempt}/{tries}): {tail}"
        if attempt < tries:
            time.sleep(delay)
    return False, detail


def uninstall(t, scenario):
    """Uninstall and prove nothing of this release is left (uninstall can exit 0 having deleted nothing)."""
    # A volumeset still finishing its deletion (or final snapshot) can abort an uninstall partway;
    # running it again resumes. Measured on kafka 4.4.0: the second run removed everything.
    ok, detail = False, ""
    for attempt in range(1, 7):
        cpln("helm", "uninstall", t.release, "--gvc", t.gvc, timeout=900)
        left = leftovers(t)
        if not left:
            ok = True
            detail = f"needed {attempt} uninstall runs" if attempt > 1 else ""
            break
        detail = f"left behind after {attempt} runs: {', '.join(left)[:400]}"
        time.sleep(45)
    t.record(scenario, "uninstall removes everything", ok, detail)
    return ok


def leftovers(t):
    left = []
    for kind, scoped in (("workload", True), ("volumeset", True), ("identity", True), ("policy", False), ("secret", False)):
        r = cpln_json(kind, "query", *(["--gvc", t.gvc] if scoped else []),
                      "--tag", f"app.cpln.io/instance={t.release}")
        if r is None:  # an unreadable kind is not an empty one
            left.append(f"{kind}/? (query failed)")
            continue
        left += [f"{kind}/{i['name']}" for i in r.get("items", [])
                 if not (kind == "secret" and i["name"] in t.created_secrets)]
    return left


def scenario_fresh(t, timeout_s):
    sc = f"install {t.version}"
    group(sc)
    base = t.baseline(t.version)
    ctx = {"release": t.release, "gvc": t.gvc, "org": t.org, "installed_version": t.version}
    prepare(t, base, ctx, t.version)
    vfile = values_file(base, ctx)
    code, out = helm(t, "install", t.version, vfile, timeout_s)
    if t.record(sc, "install + every workload ready", code == 0,
                "" if code == 0 else (out.strip()[-500:] + " | " + " | ".join(deployments_summary(t)))[:1500]):
        check_drift(t, sc, t.version, vfile)
        run_checks(t, sc, t.version, ctx, t.version)
        check_noop_upgrade(t, sc, t.version, vfile, timeout_s)
    uninstall(t, sc)
    endgroup()


def scenario_upgrade(t, src, timeout_s):
    """src: {"version": "4.1.0", "values": "carry"|"new"}. "carry" upgrades with the starting version's own
    values, the way a user's `helm upgrade -f my-values.yaml` does; "new" switches to the target's baseline."""
    old, mode = str(src["version"]), src.get("values", "carry")
    sc = f"upgrade {old} → {t.version}" + (" (new values)" if mode == "new" else "")
    group(sc)
    old_base, new_base = t.baseline(old), t.baseline(t.version)
    ctx = {"release": t.release, "gvc": t.gvc, "org": t.org, "installed_version": old}
    prepare(t, old_base, ctx, old)
    old_vfile = values_file(old_base, ctx)
    code, out = helm(t, "install", old, old_vfile, timeout_s)
    if t.record(sc, f"install {old} (starting point)", code == 0, "" if code == 0 else out.strip()[-500:]):
        run_checks(t, sc + f" [before, on {old}]", old, ctx, t.version, warn=True)
        if mode == "new":
            # Secrets the new baseline adds are created now; ones it shares keep their values, as a user's would.
            prepare(t, new_base, ctx, t.version)
            new_vfile = values_file(new_base, ctx)
        else:
            new_vfile = old_vfile
        code, out = helm(t, "upgrade", t.version, new_vfile, timeout_s)
        if t.record(sc, f"upgrade to {t.version} + every workload ready", code == 0,
                    "" if code == 0 else (out.strip()[-500:] + " | " + " | ".join(deployments_summary(t)))[:1500]):
            check_drift(t, sc, t.version, new_vfile)
            run_checks(t, sc, t.version, ctx, t.version)
    uninstall(t, sc)
    endgroup()


def teardown(t):
    group("teardown")
    for name in t.created_secrets:
        cpln("secret", "delete", name)
    if t.own_gvc:
        delete_gvc(t.gvc)
    endgroup()


def delete_gvc(gvc):
    """Workloads first (a volumeset in use cannot be deleted), then volumesets, then tagged org-scoped
    leftovers, then the GVC itself. Only ever called on a templates-ci-* GVC."""
    assert gvc.startswith(GVC_PREFIX), gvc
    for kind in ("workload", "volumeset"):
        for _ in range(6):
            items = (cpln_json(kind, "get", "--gvc", gvc, "--max", "0") or {}).get("items", [])
            if not items:
                break
            for i in items:
                cpln(kind, "delete", i["name"], "--gvc", gvc)
            time.sleep(15)
    for kind in ("secret", "policy"):
        r = cpln_json(kind, "query", "--tag", f"cpln/marketplace-gvc={gvc}") or {}
        for i in r.get("items", []):
            cpln(kind, "delete", i["name"])
    for _ in range(6):
        cpln("gvc", "delete", gvc)
        if missing("gvc", "get", gvc):
            log(f"deleted GVC {gvc}")
            return True
        time.sleep(20)
    log(f"::warning::GVC {gvc} could not be deleted; the sweep will retry")
    return False


def cmd_run(a):
    service, version = a.target.split("/")
    run_id = os.environ.get("GITHUB_RUN_ID", str(int(time.time())))
    release = a.release or make_release(run_id, a.index)
    own = not a.gvc
    gvc = a.gvc or f"{GVC_PREFIX}{release}"
    t = Target(service, version, release, gvc, own)
    base = t.baseline(version)
    timeout_s = int(base.get("timeoutSeconds", 900))
    log(f"{service} {version}: release {release}, GVC {gvc} ({'created by this run' if own else 'existing'})")
    started = time.time()
    try:
        if own:
            create_gvc(t, base.get("locations") or ["aws-us-east-1"])
            log(f"GVC locations: {', '.join(sorted(base.get('locations') or ['aws-us-east-1']))}")
        if not a.skip_fresh:
            scenario_fresh(t, timeout_s)
        sources = [s if isinstance(s, dict) else {"version": str(s)} for s in base.get("upgradeFrom") or []]
        if a.upgrades:
            wanted = set(a.upgrades.split(","))
            sources = [s for s in sources if str(s["version"]) in wanted]
        for src in sources:
            t.release = release + "u" + str(src["version"]).replace(".", "")
            scenario_upgrade(t, src, timeout_s)
    except Exception as e:  # a harness error is a failed run, never a silent pass
        t.record("harness", "runner", False, f"{type(e).__name__}: {e}")
    finally:
        teardown(t)
    report = {"target": a.target, "gvc": gvc, "locations": base.get("locations"), "minutes": round((time.time() - started) / 60, 1),
              "results": t.results}
    with open(a.out, "w") as f:
        json.dump(report, f, indent=1)
    failed = [r for r in t.results if r["status"] == "fail"]
    log(f"{service} {version}: {len(t.results) - len(failed)} passed, {len(failed)} failed")
    return 1 if failed else 0


def cmd_sweep(a):
    gvcs = (cpln_json("gvc", "get", "--max", "0") or {}).get("items", [])
    now = dt.datetime.now(dt.timezone.utc)
    for g in gvcs:
        if not g["name"].startswith(GVC_PREFIX):
            continue
        age_h = (now - dt.datetime.fromisoformat(g["created"].replace("Z", "+00:00"))).total_seconds() / 3600
        if age_h >= a.older_than_hours:
            log(f"sweeping {g['name']} (created {age_h:.1f} h ago)")
            delete_gvc(g["name"])
    return 0


# ─── report ───────────────────────────────────────────────────────────────────

def cmd_report(a):
    files = sorted(f for f in os.listdir(a.dir) if f.endswith(".json")) if os.path.isdir(a.dir) else []
    lines = ["<!-- templates-e2e-report -->", "## Template e2e tests", ""]
    run_url = os.environ.get("RUN_URL")
    if not files:
        lines.append("No template in this PR has e2e tests to run.")
    total_fail = 0
    for fn in files:
        r = load_yaml(os.path.join(a.dir, fn))
        res = r.get("results", [])
        fails = [x for x in res if x["status"] == "fail"]
        warns = [x for x in res if x["status"] == "warn"]
        total_fail += len(fails)
        icon = "❌" if fails else ("⚠️" if warns else "✅")
        warned = f", {len(warns)} warning{'s' if len(warns) != 1 else ''}" if warns else ""
        lines.append(f"### {icon} {r['target']} — {len(res) - len(fails) - len(warns)}/{len(res)} passed{warned} "
                     f"({r.get('minutes')} min, {', '.join(r.get('locations') or [])})")
        lines.append("")
        lines.append("| Scenario | Check | Result |")
        lines.append("|---|---|---|")
        for x in res:
            mark = {"pass": "pass", "fail": "**FAIL**", "warn": "warn", "skip": "skip"}[x["status"]]
            if x["new"]:
                mark += " · new"
            detail = (" — " + x["detail"].replace("|", "\\|")) if x["detail"] else ""
            lines.append(f"| {x['scenario']} | {x['check']} | {mark}{detail[:400]} |")
        lines.append("")
    if run_url:
        lines.append(f"[Run logs]({run_url})")

    with open(a.out, "w") as f:
        f.write("\n".join(lines) + "\n")
    print("\n".join(lines))
    return 1 if total_fail else 0


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--org", help="org (default: CPLN_ORG or the cpln profile)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("plan"); p.add_argument("--base", required=True); p.add_argument("--targets", default="")
    p = sub.add_parser("gate"); p.add_argument("--base", required=True)
    p = sub.add_parser("run")
    p.add_argument("--target", required=True); p.add_argument("--out", required=True)
    p.add_argument("--index", type=int, default=0)
    p.add_argument("--gvc", help="use this existing GVC instead of creating one (local development)")
    p.add_argument("--release", help="release name (default: generated from the run id)")
    p.add_argument("--skip-fresh", action="store_true", help="run only the upgrade scenarios")
    p.add_argument("--upgrades", help="comma-separated upgrade sources to run (default: the baseline's upgradeFrom; 'none' for none)")
    p = sub.add_parser("sweep"); p.add_argument("--older-than-hours", type=float, default=3)
    p = sub.add_parser("report"); p.add_argument("--dir", required=True); p.add_argument("--out", required=True)
    a = ap.parse_args()
    org = a.org or os.environ.get("CPLN_ORG")
    if org:
        ORG_ARGS.extend(["--org", org])
        os.environ["CPLN_ORG"] = org
    return {"plan": cmd_plan, "gate": cmd_gate, "run": cmd_run, "sweep": cmd_sweep, "report": cmd_report}[a.cmd](a) or 0


if __name__ == "__main__":
    sys.exit(main())
