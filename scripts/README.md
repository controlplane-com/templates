# Scripts

## keep-gvc.py

Marks the GVC a Helm release created as "keep", so upgrading to a version that no longer creates it does not delete it.

### When you need it

Some templates used to create their own GVC, and their newer versions deploy into an existing GVC instead
(the template's README says which version changed, under "Upgrading in place from …"). A plain
`cpln helm upgrade` across that change **deletes the GVC the old release created, with every workload,
volume set and identity inside it**. Run this script first, and the upgrade keeps the GVC and everything in
it.

### Requirements

- Python 3 and the `cpln` CLI, signed in with the profile you upgrade with.
- Permission to reveal and update secrets in the org (the release's records are stored as secrets).

### Usage

```bash
curl -fsSLO https://raw.githubusercontent.com/controlplane-com/templates/main/scripts/keep-gvc.py

python3 keep-gvc.py RELEASE_NAME            # 1. shows what it would change; changes nothing
python3 keep-gvc.py RELEASE_NAME --apply    # 2. makes the change
```

Add `--org ORG_NAME` if the release is not in your profile's default org.

Then upgrade, following the template README's "Upgrading in place from …" section. Two rules apply to every
template:

- Pass `--gvc` the name of the GVC **the old release created**, not the GVC you ran the original install
  against. A different `--gvc` starts an empty install there instead of upgrading the one that holds your data.
- The upgrade output must include `Skipped deletion of /org/ORG_NAME/gvc/GVC_NAME`. If it does not, stop:
  the GVC was not protected.

### What it changes

Only the release's stored records: the secrets named `cpln-helm-release-RELEASE_NAME-…-vN`. In each record
that `cpln helm` still reads when it decides what to delete, it adds `helm.sh/resource-policy: keep` to the
GVC entry. It does not touch the live GVC, the workloads or any other resource.

With `--apply` it saves each record it edits to `RECORD_NAME-backup.json` in the current directory first,
then reads the record back to confirm the change. To undo before upgrading, restore the backup:

```bash
cpln apply -f RECORD_NAME-backup.json
```

Running it again is safe: records that are already marked are left as they are.

### Afterwards

The GVC now belongs to you rather than to the release. A later `cpln helm uninstall` removes the release's
resources but leaves the GVC in place. Delete it yourself with `cpln gvc delete GVC_NAME` once you no longer
need it.
