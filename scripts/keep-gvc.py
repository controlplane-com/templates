#!/usr/bin/env python3
"""Mark the GVC a Helm release created as "keep", so upgrading to a version that no longer creates it does not delete it.

Some templates used to create their own GVC, and their newer versions deploy into an existing one instead. A
plain `cpln helm upgrade` across that change deletes the GVC the old release created, and with it every
workload, volume set and identity inside. This script prevents that. It adds `helm.sh/resource-policy: keep`
to the GVC entry in each of the release's stored records that `cpln helm` still reads when deciding what to
delete. The upgrade then prints `Skipped deletion of .../gvc/<name>` and the GVC and everything in it stay in
place. Nothing else in the release, and nothing in the live GVC, is changed.

Usage:
    python3 keep-gvc.py RELEASE [--org ORG]            # report what would change (changes nothing)
    python3 keep-gvc.py RELEASE [--org ORG] --apply    # make the change

Run it with the release unchanged since its last install or upgrade, right before the upgrade, using the same
`cpln` profile you upgrade with. With --apply it first saves each record it edits to
`<record-name>-backup.json` in the current directory, then reads the record back to confirm the change.
Requires the `cpln` CLI, signed in with permission to reveal and update secrets in the org.

After this, the GVC belongs to you rather than to the release: a later `cpln helm uninstall` leaves it in
place (empty). Delete it with `cpln gvc delete NAME` once you no longer need it.
"""
import argparse
import base64
import gzip
import json
import subprocess
import sys


def cpln(args, org, inp=None):
    cmd = ["cpln", *args] + (["--org", org] if org else [])
    r = subprocess.run(cmd, input=inp, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"error: `{' '.join(cmd)}` failed: {(r.stderr or r.stdout).strip()}")
    return r.stdout


def decode(secret):
    return json.loads(gzip.decompress(base64.b64decode(secret["data"]["payload"])))


def main():
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("release", help="the Helm release name (as shown by `cpln helm list`)")
    p.add_argument("--org", help="Control Plane org (default: the cpln profile's org)")
    p.add_argument("--apply", action="store_true", help="make the change (without it, only report)")
    a = p.parse_args()

    # The release's records are org-level secrets named cpln-helm-release-<release>-<id>-v<revision>.
    # --max 0: without it the listing stops at 50 secrets and a record could be missed.
    items = json.loads(cpln(["secret", "get", "-o", "json", "--max", "0"], a.org))["items"]
    records = sorted((s for s in items if s["name"].startswith("cpln-helm-release-")
                      and (s.get("tags") or {}).get("name") == a.release),
                     key=lambda s: int(s["tags"].get("version", 0)))
    if not records:
        sys.exit(f"error: no release records found for release '{a.release}'. Check the name and the org.")

    to_change = 0
    for s in records:
        if s["tags"].get("scanned-for-deletion") == "true":
            print(f"{s['name']}: already processed by an earlier upgrade, not read again; nothing to do")
            continue
        secret = json.loads(cpln(["secret", "reveal", s["name"], "-o", "json"], a.org))
        release = decode(secret)
        gvcs = [r for r in release.get("info", {}).get("resources", []) if r.get("kind") == "gvc"]
        if not gvcs:
            print(f"{s['name']}: this revision created no GVC; nothing to do")
            continue
        if all((r["template"].get("tags") or {}).get("helm.sh/resource-policy") == "keep" for r in gvcs):
            print(f"{s['name']}: GVC already marked keep; nothing to do")
            continue
        for r in gvcs:
            r["template"].setdefault("tags", {})["helm.sh/resource-policy"] = "keep"
        to_change += 1
        print(f"{s['name']}: will mark {', '.join(r['link'] for r in gvcs)} keep")
        if not a.apply:
            continue
        body = {k: secret[k] for k in ("kind", "name", "description", "tags", "type", "data") if k in secret}
        with open(f"{s['name']}-backup.json", "w") as f:  # the unchanged record, in a form `cpln apply` takes
            json.dump(body, f)
        body = json.loads(json.dumps(body))
        body["data"]["payload"] = base64.b64encode(
            gzip.compress(json.dumps(release, separators=(",", ":")).encode())).decode()
        cpln(["apply", "-f", "-"], a.org, inp=json.dumps(body))
        check = decode(json.loads(cpln(["secret", "reveal", s["name"], "-o", "json"], a.org)))
        ok = all((r["template"].get("tags") or {}).get("helm.sh/resource-policy") == "keep"
                 for r in check["info"]["resources"] if r.get("kind") == "gvc")
        if not ok:
            sys.exit(f"error: {s['name']} did not keep the change; restore it with "
                     f"`cpln apply -f {s['name']}-backup.json` and do not upgrade")
        print("  done (backup saved, change confirmed)")

    if not a.apply and to_change:
        print("\nNothing was changed. Run again with --apply to make the change.")
    elif a.apply and to_change:
        print("\nThe GVC is marked keep. The upgrade should print 'Skipped deletion of .../gvc/<name>'.")


if __name__ == "__main__":
    main()
