#!/usr/bin/env python3
"""Validates every template's catalog.yaml. See CATALOG_AUTHORING.md, section 7.

Usage: python3 .github/scripts/validate_catalog.py [template ...]
With template names, only their problems are reported; the cross-template checks still read every entry.
Requires: pip install jsonschema pyyaml
"""
import json
import re
import sys
from pathlib import Path

import yaml
from jsonschema import Draft202012Validator

ROOT = Path(__file__).resolve().parents[2]
SCHEMA = ROOT / ".schema" / "catalog.v1.schema.json"


def load_yaml(path):
    with open(path, encoding="utf-8") as f:
        return yaml.safe_load(f)


def version_key(version):
    return [(0, int(part)) if part.isdigit() else (1, part) for part in re.split(r"[.+-]", version)]


def chart_type(version_dir):
    try:
        return (load_yaml(version_dir / "Chart.yaml") or {}).get("type")
    except (OSError, yaml.YAMLError):
        return None


def discover_templates():
    """Maps each installable template to its latest version directory. Library charts are skipped."""
    templates = {}
    for folder in sorted(ROOT.iterdir()):
        versions_dir = folder / "versions"
        if folder.name.startswith(".") or not versions_dir.is_dir():
            continue
        installable = [v for v in versions_dir.iterdir() if v.is_dir() and chart_type(v) != "library"]
        if installable:
            templates[folder.name] = max(installable, key=lambda v: version_key(v.name))
    return templates


def has_values_path(values, dotted):
    node = values
    for part in dotted.split("."):
        if not isinstance(node, dict) or part not in node:
            return False
        node = node[part]
    return True


def main(only):
    validator = Draft202012Validator(json.loads(SCHEMA.read_text(encoding="utf-8")))
    templates = discover_templates()
    entries = {}
    errors = {}

    def fail(name, message):
        errors.setdefault(name, []).append(message)

    for name in templates:
        path = ROOT / name / "catalog.yaml"
        if not path.exists():
            fail(name, "catalog.yaml is missing; every installable template needs one (CATALOG_AUTHORING.md)")
            continue
        try:
            entry = load_yaml(path)
        except yaml.YAMLError as e:
            fail(name, f"catalog.yaml is not valid YAML: {e}")
            continue
        schema_errors = sorted(validator.iter_errors(entry), key=lambda e: [str(p) for p in e.path])
        for e in schema_errors:
            fail(name, f"{'/'.join(str(p) for p in e.path) or '(root)'}: {e.message}")
        if not schema_errors:
            entries[name] = entry

    public = {name for name, entry in entries.items() if not entry.get("internal")}
    template_names = {name.lower() for name in templates}

    def check_reference(name, where, target):
        if target == name:
            fail(name, f"{where}: points at this template itself")
        elif target not in templates:
            fail(name, f"{where}: '{target}' is not a template in this repo")
        elif target in entries and target not in public:
            fail(name, f"{where}: '{target}' is internal and never shown to users")

    for name in sorted(public):
        entry = entries[name]
        family = entry.get("family", name)
        if family != name:
            check_reference(name, "family", family)
            default = entries.get(family, {})
            if family in public and default.get("family", family) != family:
                fail(name, f"family: '{family}' belongs to family '{default['family']}'; use the family's default member")
        for i, item in enumerate(entry.get("pickInsteadIf", [])):
            check_reference(name, f"pickInsteadIf/{i}/template", item["template"])
        for i, item in enumerate(entry.get("related", [])):
            check_reference(name, f"related/{i}/template", item["template"])
        for i, product in enumerate(entry.get("alternativeTo", [])):
            if product.lower() in template_names:
                fail(name, f"alternativeTo/{i}: '{product}' is a template in this repo; list it under related")
        values_file = templates[name] / "values.yaml"
        values = load_yaml(values_file) if values_file.exists() else {}
        for i, item in enumerate(entry.get("prerequisites", [])):
            paths = item.get("valuesPath", [])
            for values_path in [paths] if isinstance(paths, str) else paths:
                if not has_values_path(values or {}, values_path):
                    fail(name, f"prerequisites/{i}/valuesPath: '{values_path}' is not a key in {values_file.relative_to(ROOT)}")

    reported = {name: messages for name, messages in errors.items() if not only or name in only}
    for name in sorted(reported):
        for message in reported[name]:
            print(f"FAIL [{name}]: {message}")
    internal = len(entries) - len(public)
    print(f"{len(entries)} valid catalog entries ({internal} internal) for {len(templates)} templates; {len(reported)} with problems")
    return 1 if reported else 0


if __name__ == "__main__":
    sys.exit(main(set(sys.argv[1:])))
