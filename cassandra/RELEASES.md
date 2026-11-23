# Release Notes - Version 1.1.2

## What's New

- **Scheduled backups upload again, in both backup types.** The default backup image is now `ghcr.io/controlplane-com/backup-images/cassandra-backup:5.0.9`. With the earlier `cassandra-backup:5.0` image, a logical run stopped before its first upload, and a physical sidecar's scheduled runs started without their settings, so no backup reached the bucket. If you set `backup.image` yourself, change it to the new tag.
- **The keyspace and application user are created as soon as every node has joined.** Earlier versions created them about 10 minutes after the first node started, so clients that connected as soon as the workload was ready were refused. If the nodes have not all joined after 10 minutes, the first node's log now says so with an `ERROR` line every 5 minutes and keeps waiting. It never creates the keyspace and user on a partial cluster.
- **Cassandra is pinned to `cassandra:5.0.9`** (it was the floating `cassandra:5.0` tag). Upgrading restarts the nodes one at a time and keeps their data.
- **A physical restore loads only your application tables.** The restore script skips the system keyspaces in a node's snapshot, so a restore no longer rolls back roles, passwords or the node's own state. The README's restore steps now give the exact commands for both backup types.
- **Passwords no longer appear on any command line.** The startup script, the shutdown drain, the repair job and the backup image pass the superuser password through files only the container's user can read. A password containing a single quote (`'`) no longer breaks the first-boot setup.
- **Shutdown drains the node.** The `nodetool drain` that runs before a node stops now authenticates, so each node flushes its writes before a rollout restarts it (it was refused before).
- **The AWS backup identity no longer carries the `cpln-connector` policy.** Only your bucket-scoped policy is attached. No action is needed.
- **No configuration drift on a default install.** The chart now renders the workload settings the platform stores, so the Console's Drift tab is clean.
