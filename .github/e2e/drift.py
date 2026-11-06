"""Rendered-vs-stored comparison for one installed release (the check the Console's Drift tab makes).

The API backfills fields a chart sends only part of (a partial `defaultOptions` block comes back with
`target: 95`, `timeoutSeconds: 5`, ...) and drops a few it does not keep. Neither churns on upgrade, so a
no-op upgrade reports `Unchanged` while the Console's release Drift tab shows the release drifting from the
moment it is installed. This module compares each rendered resource with what the API stored, after the same
normalisation the Drift tab applies: a field at its platform default on both sides is not drift, and some
arrays compare order-insensitively. Keep DEFAULT_RULES and SORT_RULES in step with the Drift tab.
"""
import json
import re

COMPARE = {
    "workload": ["spec"],
    "volumeset": ["spec"],
    "identity": ["aws", "gcp", "azure", "ngs", "networkResources", "nativeNetworkResources"],
    "policy": ["bindings", "target", "targetKind", "targetLinks", "targetQuery"],
}
GVC_SCOPED = {"workload", "volumeset", "identity"}
# Environment-dependent backfill (production fills `interGvcFailover: true`); reported, never a failure.
ENV_DEPENDENT = ("spec.networking",)

DEFAULT_RULES = [
    (["spec", "supportDynamicTags"], False),
    (["spec", "env"], []),
    (["spec", "containers", "*", "env"], []),
    (["spec", "firewallConfig", "internal", "inboundAllowWorkload"], []),
    (["spec", "firewallConfig", "external", "inboundBlockedCIDR"], []),
    (["spec", "firewallConfig", "external", "outboundAllowHostname"], []),
    (["spec", "firewallConfig", "external", "outboundAllowPort"], []),
    (["spec", "firewallConfig", "external", "outboundBlockedCIDR"], []),
    (["spec", "loadBalancer", "direct", "enabled"], False),
    (["spec", "loadBalancer", "direct", "ports"], []),
    (["spec", "loadBalancer", "multiZone", "enabled"], False),
    (["spec", "defaultOptions", "debug"], False),
    (["spec", "defaultOptions", "suspend"], False),
    (["spec", "defaultOptions", "multiZone", "enabled"], False),
    (["spec", "containers", "*", "volumes", "*", "recoveryPolicy"], "retain"),
    (["spec", "containers", "*", "inheritEnv"], False),
    (["spec", "firewallConfig", "external", "inboundAllowCIDR"], []),
    (["spec", "firewallConfig", "external", "outboundAllowCIDR"], []),
    (["spec", "loadBalancer", "replicaDirect"], False),
]
SORT_RULES = [
    (["spec", "env"], "name"), (["spec", "containers", "*", "env"], "name"), (["targetLinks"], ""),
    (["spec", "firewallConfig", "external", "inboundAllowCIDR"], ""),
    (["spec", "firewallConfig", "external", "outboundAllowCIDR"], ""),
    (["spec", "firewallConfig", "external", "inboundBlockedCIDR"], ""),
    (["spec", "firewallConfig", "external", "outboundBlockedCIDR"], ""),
    (["spec", "firewallConfig", "external", "outboundAllowHostname"], ""),
    (["spec", "firewallConfig", "external", "outboundAllowPort"], ""),
    (["spec", "firewallConfig", "internal", "inboundAllowWorkload"], ""),
    (["spec", "loadBalancer", "direct", "ports"], ""),
]


def _parents(obj, path):
    """Yield (parent, key) for every concrete match of a path whose '*' iterates list items."""
    def go(node, rest):
        if not rest or node is None:
            return
        head, tail = rest[0], rest[1:]
        if head == "*":
            for item in node if isinstance(node, list) else []:
                yield from go(item, tail)
        elif isinstance(node, dict):
            if not tail:
                yield node, head
            else:
                yield from go(node.get(head), tail)
    yield from go(obj, path)


def normalize(rendered, stored):
    """Apply the Drift tab's default-stripping and array-sorting rules to both sides, in place."""
    for path, default in DEFAULT_RULES:
        r = list(_parents(rendered, path))
        s = list(_parents(stored, path))
        # Wildcard paths pair up by position; compare each concrete location on both sides.
        for (rp, rk), (sp, sk) in zip(r or [(None, None)] * len(s), s):
            rv = rp.get(rk, default) if rp is not None else default
            sv = sp.get(sk, default)
            if rv == default and sv == default:
                if rp is not None:
                    rp.pop(rk, None)
                sp.pop(sk, None)
    for path, key in SORT_RULES:
        for side in (rendered, stored):
            for p, k in _parents(side, path):
                if isinstance(p.get(k), list):
                    p[k] = sorted(p[k], key=lambda x: json.dumps(
                        x.get(key) if key and isinstance(x, dict) else x, sort_keys=True))


def _link(v):
    """Relative (`//identity/x`) and fully-qualified (`/org/O/gvc/G/identity/x`) links compare equal."""
    if isinstance(v, str) and (v.startswith("//") or v.startswith("/org/")):
        s = re.sub(r"^/org/[^/]+", "", v).lstrip("/")
        return re.sub(r"^gvc/[^/]+/", "", s)
    return v


def _walk(path, rendered, stored, out):
    if isinstance(rendered, dict) and isinstance(stored, dict):
        for k in sorted(set(rendered) | set(stored)):
            p = f"{path}.{k}" if path else k
            if k not in stored:
                out.append(("DROPPED", p, rendered[k], None))
            elif k not in rendered:
                out.append(("BACKFILLED", p, None, stored[k]))
            else:
                _walk(p, rendered[k], stored[k], out)
    elif isinstance(rendered, list) and isinstance(stored, list) and len(rendered) == len(stored):
        for i, (a, b) in enumerate(zip(rendered, stored)):
            _walk(f"{path}[{i}]", a, b, out)
    elif _link(rendered) != _link(stored) and str(_link(rendered)) != str(_link(stored)):
        out.append(("CHANGED", path, rendered, stored))


def compare(rendered_docs, fetch):
    """Return (drift, env, errors) lists of human-readable lines.

    rendered_docs: the parsed `helm template` output. fetch(kind, name, gvc_scoped) returns the stored
    resource as a dict, or None when it cannot be read.
    """
    drift, env, errors = [], [], []
    for d in rendered_docs:
        kind, name = d.get("kind"), d.get("name")
        if kind not in COMPARE:
            continue
        stored = fetch(kind, name, kind in GVC_SCOPED)
        if not isinstance(stored, dict) or "kind" not in stored:
            errors.append(f"{kind}/{name}: not readable")
            continue
        d = json.loads(json.dumps(d))
        out = []
        normalize(d, stored)
        for key in COMPARE[kind]:
            if key in d or key in stored:
                _walk(key, d.get(key), stored.get(key), out)
        for what, path, rv, sv in out:
            if path.startswith(ENV_DEPENDENT):
                env.append(f"{kind}/{name} {path}: stored {json.dumps(sv)}")
                continue
            detail = {"BACKFILLED": f"stored {json.dumps(sv)}, chart omits it",
                      "DROPPED": f"chart sends {json.dumps(rv)}, API did not keep it",
                      "CHANGED": f"chart {json.dumps(rv)} vs stored {json.dumps(sv)}"}[what]
            drift.append(f"{kind}/{name} {path}: {detail}")
    return drift, env, errors
