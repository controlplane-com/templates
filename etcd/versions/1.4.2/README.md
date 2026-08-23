## etcd

etcd is a distributed, reliable key-value store for the most critical data of a distributed system. It provides a reliable way to store data that needs to be accessed by a distributed system or cluster of machines. etcd is essential for maintaining cluster health by providing consistent coordination, service discovery, and configuration management across distributed systems.

### Architecture

- **Stateful etcd workload** — `replicas` nodes forming a Raft cluster, using per-replica addressing so each node can find its peers.
- **Volume set** — the data directory, one per replica.
- **Secret** — the startup script that derives each node's identity and peer list at boot.
- **Identity and policy** — `reveal` on the startup secret.

This template does not create a GVC.

### Prerequisites

None for a default install.

### Connecting

| What | Value |
|---|---|
| Client API (same GVC) | `RELEASE_NAME-etcd.GVC_NAME.cpln.local:2379` |
| Per-replica | `replica-N.RELEASE_NAME-etcd.LOCATION.GVC_NAME.cpln.local:2379` |

Use the fully-qualified internal hostname; the bare workload name is not reliably resolvable.

### Configuring etcd

Update the `values.yaml` file with your settings:

- **`replicas`**: Number of etcd instances (default: 3, **must be odd**)
- **`resources.cpu`**: CPU per instance (default: 1 core CPU)
- **`resources.memory`**: Memory per instance (default: 2 Gi RAM)

Note: Default resources can be lowered for lighter usage. Refer to the [etcd docs](https://etcd.io/docs/v3.6/op-guide/hardware/) for recommended resources.
- **`internal_access.type`**: Internal firewall access (`same-gvc`, `same-org`, or `workload-list`)
- **`internal_access.workloads`**: Specific workloads (when using `workload-list` or `same-gvc`)
- **`multiZone`**: Distributes replicas equally across available zones

Note: Confirm your location supports multi-zone
- **`tuning.autoCompactionMode`**: How the retention value below is read — `periodic` (a duration) or `revision` (a revision count) (default: `periodic`)
- **`tuning.autoCompactionRetention`**: History kept before old revisions are discarded (default: `1h`)
- **`tuning.quotaBackendBytes`**: Backend size limit in bytes (default: `0`, meaning etcd's own 2 GiB limit)

### Storage growth and compaction

etcd keeps every superseded revision until it is compacted, so the backend grows with **time alone** — a client that renews a lease on a timer (Patroni renews its leader lease every ~10 s) writes new revisions whether or not any application data changes, measured at ~151k revisions and ~19 MB per day on an otherwise idle cluster. Left uncompacted, the backend reaches etcd's 2 GiB default quota in roughly 110 days, at which point etcd raises a cluster-wide `NOSPACE` alarm and **every member goes read-only**.

```yaml
# etcd keeps every superseded revision until told otherwise, so compaction is
# required rather than optional and cannot be switched off here.
tuning:
  autoCompactionMode: periodic # periodic (retention is a duration) or revision (a revision count)
  autoCompactionRetention: 1h # periodic needs an explicit unit (1h, 30m, 24h); revision takes a count
  quotaBackendBytes: 0 # backend size limit in bytes; 0 = etcd's own default of 2 GiB
```

The 1-hour default keeps the backend flat. Raising `autoCompactionRetention` to `24h` or more buys a longer history window at the cost of a larger backend; `revision` mode keeps a fixed number of revisions instead of a time window. In `periodic` mode the unit is required, because etcd reads a bare number as **hours**. Disabling compaction is not offered — a retention of `0`, an unrecognised mode and a negative quota are all rejected at render time.

Compaction frees pages for reuse *inside* the backend file, so `dbSize` plateaus rather than shrinking. That is expected and is sufficient to stay under quota; defragmentation only returns free pages to the filesystem and this template does not automate it. Leave `quotaBackendBytes` at `0` unless the keyspace genuinely outgrows 2 GiB — 8 GiB (`8589934592`) is etcd's own suggested maximum, above which it warns at startup.

### If the backend quota is already full

Enabling compaction stops further growth but does not rescue a cluster that has already hit the quota: it cannot shrink an existing backend file, and once etcd has raised a `NOSPACE` alarm, writes stay rejected until an operator disarms it.

The symptom usually shows up in the **client, not in etcd**. A Patroni replica that cannot renew its DCS lease exits cleanly, so it restart-loops with `exitCode: 0` / `reason: Completed` and a climbing restart count — which reads as healthy and gets misdiagnosed as a Postgres problem. Check etcd first.

Both inspection commands are read-only:

```bash
cpln workload exec {release}-etcd --gvc {gvc} --container etcd -- etcdctl endpoint status --cluster -w table
cpln workload exec {release}-etcd --gvc {gvc} --container etcd -- etcdctl alarm list
```

A `DB SIZE` near 2.1 GB on every member, plus `NOSPACE` in `alarm list`, confirms it. Recovering from there — compacting to a revision, defragmenting each member, then disarming the alarm — is an operator procedure that this template deliberately does not perform, because each step is disruptive and the order matters. Follow etcd's [maintenance guide](https://etcd.io/docs/v3.6/op-guide/maintenance/) and plan it as a maintenance window.

### Supported External Services
- [etcd docs](https://etcd.io/docs/v3.6/)
- [etcd maintenance and compaction](https://etcd.io/docs/v3.6/op-guide/maintenance/)

### Important Notes

- **`replicas` must be odd and at least 3.** An even count gains no fault tolerance and risks split votes.
- **Compaction is required, not optional.** etcd retains every superseded revision until told otherwise, so a cluster left uncompacted will fill its backend quota and go read-only. The `tuning` values control this and cannot switch it off.
- **A full backend quota puts the cluster into a read-only alarm** that survives restarts — it must be cleared explicitly after compacting and defragmenting.
- **Uninstalling deletes the volume sets**, and with them the entire keyspace.
