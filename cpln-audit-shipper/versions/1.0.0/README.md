## Audit Shipper

Ships your org's audit logs to a destination you own, continuously and incrementally:

- **The Control Plane audit trail** ([docs](https://docs.controlplane.com/core/audittrail)): who did what to which resource in the org, through the API, the console or the CLI. Read from the audit API, per audit context.
- **Kubernetes audit logs of mk8s clusters**: the API server audit log of each cluster, read from the org's logs with `{cluster_name="<cluster>", job="audit"}`.

Either source, or both at once, go to one destination: **Amazon S3** (JSON Lines), **syslog** over TCP or TLS (RFC 5424, in the layout Control Plane org logging uses), or an **OpenTelemetry** collector (OTLP/HTTP). Each stream keeps a checkpoint, so restarts, upgrades, crashes and suspensions continue where it stopped. [Delivery guarantees](#delivery-guarantees) states what is and is not guaranteed for each destination.

This template ships audit logs only. Workload logs go out through [org external logging](https://docs.controlplane.com/external-logging/overview).

```
standard workload, 1 replica per location
  ├─ at start / stop ──add / remove its own key──────────────────────▶ the release's service account (workload token)
  ├─ every interval, per audit context ──GET /audit/org/<org>────────▶ audit.cpln.io  (service account key, readAudit)
  ├─ every interval, per mk8s cluster ──GET …/loki/api/v1/query_range▶ logs.cpln.io   (service account key, readLogs)
  ├─ deliver ──▶ S3 objects │ syslog over TLS │ OTLP/HTTP
  └─ checkpoint + lease ──▶ S3 object (conditional writes)  or  file on a volume set (+ flock)
```

What gets created: one standard workload, one identity (unless you reuse one), a service account for the release (unless you bring one), the policies the chosen sources and destination need, and with volume set state a shared volume set. Uninstalling removes them and leaves your bucket, data and secrets untouched.

## Prerequisites

1. **Nothing for API access.** The audit and logs APIs accept a user token or a service account key, and **not** a workload's own `CPLN_TOKEN`: that token is only valid on the workload's route to the Control Plane API, and the audit service rejects it with `403 token invalid`. So the release creates its own service account, `RELEASE-audit-shipper`, with no group memberships, and grants it `readAudit` on the audit contexts and, with the Kubernetes source on, `readLogs` on the org. It also lets the workload identity add and remove that account's keys (`addKey`, `edit` and `view` on it, nothing else):

   - Each replica adds a key of its own at startup, through the Control Plane API, and keeps it only in memory. No key is stored in a secret or shown anywhere.
   - A replica removes its key as soon as it is told to stop. A location runs one replica, so a starting replica first removes any key its location's earlier replicas left (after a crash, or during a rollout); the account holds one key per location.
   - A replica whose key disappears restarts on its own and adds a new one.
   - A service account holds at most 10 keys, so with the release's own account a GVC can have up to 10 locations.
   - Uninstalling deletes the service account, and with it any key left.

   **To use a service account you manage instead**, set `serviceAccount.existingName` and `serviceAccount.existingKeySecret`, an opaque secret holding one of its keys. Create the key without printing it:

   ```bash
   cpln serviceaccount add-key my-service-account --desc cpln-audit-shipper -o json \
     | python3 -c 'import json,sys; sys.stdout.write(json.load(sys.stdin)["key"])' \
     | cpln secret create-opaque --name my-service-account-key --file - --encoding plain
   ```

   The release then grants that account the same `readAudit` and `readLogs`, and the identity `reveal` on the secret. Keep it out of groups such as `superusers`.

2. **For the Kubernetes source:** each cluster needs the mk8s logs add-on with audit logs on (`spec.addOns.logs.auditEnabled: true`).

   > **`readLogs` cannot be narrowed.** It exists only on the org, and a policy for it can only target `all`. The service account's keys can therefore read **every log in the org**, across all workloads and clusters, not just the audit logs. Only this release's identity can add a key to it (or, with your own account, reveal the key secret).

3. **A destination:** a bucket, a syslog listener or an OTLP endpoint (see [Destinations](#destinations)).
4. **For S3, as destination or checkpoint store:** AWS access, see [AWS access](#aws-access).

## Sources

| | Control Plane audit trail (`sources.cplnAudit`) | Kubernetes audit logs (`sources.k8sAudit`) |
|---|---|---|
| On by default | yes | no |
| Streams | one per audit context in `contexts` (`cpln` holds every platform event; add your custom contexts) | one per mk8s cluster in `clusters` |
| Read from | `audit.cpln.io`, 1000 events per page | the org's Loki at `logs.cpln.io` (looked up in `https://api.cpln.io/discovery`), 5000 entries per request, each request at most 1 hour |
| Record | the audit event JSON | the Kubernetes `audit.k8s.io/v1` Event JSON, at `Metadata` level (no request or response bodies) |
| Record ID (deduplication key) | `id` | `auditID` + `/` + `stage` (one request has up to two stages); a hash of the line if it is not an audit event |
| Lookback of a new stream | `24h` | `1h` |
| `settleDelay` / `overlap` | `1m` / `15m` | `2m` / `2m` |
| How far back data exists | the audit trail's retention (not published) | the org's log retention (`spec.observability.logsRetentionDays`, 30 days by default) |

`sources.k8sAudit.pipeline` appends a LogQL pipeline to the selector to drop noise before it is shipped, such as `| verb != "get"`. It must start with `|` and must not turn the query into a metric query. Filter on the existing stream labels (`verb`, `user`, `namespace`, `resource`, `decision`, `response_code`, and so on). Avoid parser stages such as `| json` or `| logfmt`: Loki adds every field they extract to each entry's labels, and the labels are shipped as syslog structured data or OTLP attributes, which makes every message much larger.

### Late events

Every cycle reads up to *now − `settleDelay`*, and re-reads `overlap` before its checkpoint, skipping what it already shipped. An event is missed only when it becomes readable more than `overlap + settleDelay` after its own timestamp.

- **Audit trail:** events become readable within seconds. The default tolerance is 16 minutes.
- **Kubernetes audit logs:** promtail stamps an entry with the request's `requestReceivedTimestamp`, and a `watch` request is logged only when it ends, up to about an hour later. Those entries reach Loki with old timestamps, and Loki drops the ones that fall too far behind the newest entry of their stream. With the default 2 minutes, a busy cluster misses about 0.15% of its entries, all of them `watch` / `ResponseComplete` (measured: 38 of 24,887 entries in 5.5 minutes). To catch them, set `sources.k8sAudit.settleDelay: 1h`; everything then arrives an hour late. Raising `overlap` instead would re-read an hour of logs on every cycle. Once entries are stamped with `stageTimestamp` instead (pending a platform change), the default catches everything.

## Destinations

Set `sink.type` to `s3`, `syslog` or `otlp`. One release ships to one destination; install a second release, with its own `stream`, for a second destination.

### Amazon S3

```
s3://BUCKET/PREFIX/data/org=ORG/source=cpln-audit/context=CONTEXT/year=YYYY/month=MM/day=DD/hour=HH/STREAM_FROM_TO_PART.jsonl.gz
s3://BUCKET/PREFIX/data/org=ORG/source=k8s-audit/cluster=CLUSTER/year=…/hour=HH/STREAM_FROM_TO_PART.jsonl.gz
```

- One record per line, exactly as the source returned it (audit events are re-serialized only to drop whitespace).
- The folders come from each record's time in UTC; the `key=value` names work as partitions in Athena, Glue and Spark.
- `FROM` and `TO` are the bounds of the batch that wrote the object, and `PART` numbers objects within one hour of one batch, split at `tuning.maxObjectEvents` and `tuning.maxObjectBytes`. Records are sorted by time, then ID. Each object carries metadata `event-count`, `first-event-time`, `last-event-time`, `stream`, `batch-from`, `batch-to`.
- Nothing is written for a window without new records, and nothing is ever deleted.
- Encryption: the bucket's default, or SSE-KMS with `sink.s3.kmsKeyId` (S3 Bucket Keys on).

### Syslog

Messages use the layout of the fluent-bit syslog output that Control Plane [org logging](https://docs.controlplane.com/external-logging/syslog) uses, so a receiver that already takes org logs parses both the same way:

```
<15>1 2026-11-17T17:56:21.943333Z prod-cluster mk8s-audit - - [cpln@0 cluster_alias="k8a1b2c3d4e5f" cluster_name="prod-cluster" decision="allow" … verb="get"] \xEF\xBB\xBF{"kind":"Event",…}
<15>1 2026-11-17T20:43:22.519000Z my-org cpln-audit - - [cpln@0 action="create" context="cpln" id="8785…" resource_type="image" … subject="ci@my-org"] \xEF\xBB\xBF{"id":"8785…",…}
```

- `PRI` is facility 1 and severity 7 (`sink.syslog.facility`, `sink.syslog.severity`). The time has microseconds, in UTC.
- `HOSTNAME` is the cluster name for Kubernetes audit logs and the org for the audit trail. `APP-NAME` is `mk8s-audit` or `cpln-audit`; route on it.
- Structured data, under SD-ID `cpln@0`: the Loki stream labels for Kubernetes audit logs; for the audit trail `id`, `org`, `context`, `event_source`, `location`, `request_id`, `subject`, `subject_type`, `resource_type`, `resource_name`, `resource_link`, `action` and `result`. Names are cut at 32 bytes and anything outside printable ASCII, `=`, space, `]` and `"` becomes `_`; values escape `"`, `\` and `]`.
- A UTF-8 byte order mark comes before MSG, which is the record JSON with `\r` and `\n` escaped. A message is cut at `sink.syslog.maxMessageBytes` (32 KiB) without splitting a UTF-8 character. Messages are typically 1.5 to 3 KB: **the receiver's maximum message length must allow the full size.**
- Framing: `newline` (one message per line, what fluent-bit sends) or `octet-counting` (RFC 6587, which RFC 5425 specifies for TLS).
- TLS (`sink.syslog.tls`, on by default): TLS 1.2 or later, the certificate chain and host name are verified, and SNI is the host. `sink.syslog.caSecret` names an opaque secret with a PEM CA bundle that replaces the public CAs.
- **Delivery confirmation:** each batch is sent on one connection. The shipper then closes its side (TLS `close_notify`, then a TCP half-close) and waits for the listener to close too, which shows the listener read everything. A listener that does not close within `sink.syslog.timeout` gets a warning and the batch counts as sent; a reset or a send error fails the batch.
- Firewall: hostname rules only open ports 80, 443 and 445. A listener on another port needs its address, or `0.0.0.0/0` (the default), in `firewall.outboundAllowCIDR`.

### OpenTelemetry (OTLP)

OTLP/HTTP logs with JSON encoding, posted to `sink.otlp.endpoint` + `/v1/logs`, gzip-compressed by default.

- Resource attributes: `service.name=cpln-audit-shipper`, `cpln.org`, `cpln.audit.source` (`cpln-audit` or `k8s-audit`), and `k8s.cluster.name` or `cpln.audit.context`.
- Each log record: the record's time, severity `INFO`, the body is the record JSON as a string, and the attributes are `audit.id` plus the fields or labels listed for syslog.
- A batch is posted in requests of at most 1000 records and about 4 MiB. A 2xx response acknowledges a request; 429 and 5xx are retried with backoff, honouring `Retry-After`; any other response fails the batch.
- Authentication: `sink.otlp.authHeader.name` (such as `Authorization`) with its whole value in an opaque secret `sink.otlp.authHeader.secret` (such as `Bearer TOKEN`). Other headers go in `sink.otlp.headers`. `sink.otlp.caSecret` adds a private CA.

## Delivery guarantees

Every destination gets **at-least-once** delivery of every record that becomes readable within its source's late-event tolerance, with the two exceptions in the table: what the destination itself acknowledges is the limit. Every record carries its ID (`id`, or `auditID` and `stage`), so a consumer that needs exactly-once can drop duplicates.

| Destination | Acknowledgement | When a record can arrive twice |
|---|---|---|
| S3 | The S3 PUT response | Rarely. A batch is recorded as *pending* before its upload, and a replay after a crash or failure rebuilds exactly that batch and overwrites the **same object names**. Duplicates come only from resetting a checkpoint, raising `overlap`, or changing the prefix, gzip, stream or object limits while a batch is pending. |
| Syslog | The listener closing the connection after reading the batch. That shows it read the bytes, not that it stored them. **A listener that never closes** gets a warning and the batch counts as sent after `sink.syslog.timeout`, so records it did not read are lost. | When a batch fails part-way (a reset, a crash, or a stop past `tuning.drainTimeout`), its records are sent again, so up to one batch (`tuning.maxBatchEvents`) is duplicated. |
| OTLP | A 2xx per request. **Records the endpoint rejects inside a 2xx** (`partialSuccess`) are logged with a warning and not sent again. | A failed request fails its batch, and the batch's earlier requests are sent again. A retried request whose first attempt landed also duplicates. |

On a normal stop (an upgrade, a redeploy, scaling), a delivery under way gets `tuning.drainTimeout` (30s) to finish and be checkpointed, so a stop does not resend it. The platform waits half of `tuning.terminationGracePeriodSeconds` (90) before it signals the shipper, so the drain plus 15 seconds to remove the replica's key must fit in the other half; the chart checks this.

## Checkpoints

Each stream has a checkpoint: a watermark (everything before it was delivered), the IDs delivered within the last `overlap`, any pending batch, and a lease. It is written after every batch, never before its records are delivered. Choose where with `state.backend`:

| | `s3` (default) | `volumeSet` |
|---|---|---|
| Where | `s3://BUCKET/PREFIX/state/…/checkpoint.json`. With the S3 destination and an empty `state.s3.bucket`, the destination bucket. Otherwise set `state.s3.bucket` and `state.s3.region` (a small bucket of its own is fine). | `/state/state/…/checkpoint.json` on a shared volume set (10 GiB minimum; a few KB are used) |
| GVC locations | any number | **exactly one** |
| Needs AWS access | yes | no |
| Several replicas | Every location runs a replica. They take turns through a lease in the checkpoint, written with S3 conditional writes; a replica that finds the lease held skips that cycle. A replica that died holding a lease blocks the stream for up to `leaseTTL`. | One replica. A file lock (`flock`) keeps a replacement out until the old replica has stopped; the replacement then takes over any lease the old one left at once. |

Volume sets are per location, so nothing would keep replicas in different locations apart. The wizard only offers volume set state for a single-location GVC, and the shipper reads its GVC at startup (with `view`, granted by the chart) and exits when it has more than one location. It also exits, instead of running unprotected, when the volume does not support file locks. On BYOK locations a shared volume set needs the location's shared file system to be set up; `fileSystemType: shared` is the only type a standard workload can mount.

**When a checkpoint is lost** (the object or the volume set deleted), the stream starts again at `startTime`, or at `initialLookback` before now, and ships that range again. A checkpoint that exists but cannot be read (corrupt, another schema, another stream, access denied) stops the stream: the shipper **never resets progress by itself**. See [Recovery](#recovery-backfill-and-reset).

## AWS access

Needed when the destination or the checkpoint store is S3. The policy below covers both; drop the statements you do not need (replace `BUCKET` and `PREFIX`, default prefix `cpln-audit`; with a separate state bucket, the state statements go on that bucket):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {"Sid": "WriteRecords", "Effect": "Allow", "Action": "s3:PutObject",
     "Resource": "arn:aws:s3:::BUCKET/PREFIX/data/*"},
    {"Sid": "ReadWriteCheckpoints", "Effect": "Allow", "Action": ["s3:GetObject", "s3:PutObject"],
     "Resource": "arn:aws:s3:::BUCKET/PREFIX/state/*"},
    {"Sid": "ReportMissingCheckpoint", "Effect": "Allow", "Action": "s3:ListBucket",
     "Resource": "arn:aws:s3:::BUCKET", "Condition": {"StringLike": {"s3:prefix": "PREFIX/state/*"}}}
  ]
}
```

- Records are write-only: the shipper never reads, lists or deletes them, and needs no `s3:DeleteObject`.
- `s3:ListBucket` on the state prefix makes S3 answer *404* for a checkpoint that does not exist yet instead of *403*. Without it a new stream cannot tell "no checkpoint" from "no permission" and fails, on purpose.
- SSE-KMS (an explicit key, or a bucket default that is a customer-managed key): also `kms:GenerateDataKey` and `kms:Decrypt` on the key.
- Never let a lifecycle rule expire `state/`. Bucket versioning keeps every checkpoint version, which helps recovery.

### `aws.authMode: identity` (default): Control Plane cloud access, no stored keys

The workload identity gets credentials from Control Plane's [cloud access](https://docs.controlplane.com/reference/identity), through the AWS SDK's default credential chain.

1. Create a Control Plane [AWS cloud account](https://docs.controlplane.com/guides/create-cloud-account) for the bucket's AWS account, unless you have one.
2. Create the policy above in that AWS account as a customer-managed policy, for example `cpln-audit-shipper`.
3. Set `aws.identity.cloudAccountName` and `aws.identity.policyRefs: [cpln-audit-shipper]`, or `aws.identity.roleName` for an existing role that Control Plane may use.

With `identity.existingName`, the chart creates no identity; yours must already have AWS access to the bucket.

### `aws.authMode: secret`: access keys in a secret

For a bucket in an AWS account without a Control Plane cloud account. The secret holds an IAM **user's** access key ID and secret access key (or temporary credentials); to use a role, those keys assume it. Create the secret without the keys appearing on a command line or in a file: paste them in the Console (Secrets → New → AWS), or:

```bash
read -r -p "Access key ID: " AKID; read -r -s -p "Secret access key: " SAK; echo
printf '{"kind":"secret","name":"cpln-audit-shipper-aws","type":"aws","data":{"accessKey":"%s","secretKey":"%s"}}' "$AKID" "$SAK" \
  | cpln apply --file -
unset AKID SAK
```

An `aws` secret exposes `accessKey` and `secretKey`, the chart's defaults; its role ARN and external ID are **not** read. A `dictionary` secret works with `aws.secret.accessKeyIdKey` and `aws.secret.secretAccessKeyKey`, and temporary credentials add `aws.secret.sessionTokenKey` (rotate the secret before they expire).

- **Direct keys:** the IAM user gets the S3 policy above.
- **Assume a role:** set `aws.secret.assumeRole.roleArn` (and optionally `externalId`, `durationSeconds`). The user then only needs `sts:AssumeRole` on the role, and the role needs the S3 policy and a trust policy that admits the user. The assumed credentials are renewed about five minutes before they expire.

## Configuration

| Value | Default | Meaning |
|---|---|---|
| `interval` | `5m` | Time between the starts of two cycles of each stream (10s to 24h; `1m` works well). |
| `stream` | `default` | Names this export; part of every checkpoint and object name. |
| `serviceAccount.existingName`, `.existingKeySecret` | empty | Empty: the release creates its own service account and its replicas add their own keys. Set both to use your own account and key; see [Prerequisites](#prerequisites). |
| `sources.cplnAudit.*` | on, `[cpln]` | `contexts`, `startTime`, `initialLookback`, `endTime`, `settleDelay`, `overlap`. |
| `sources.k8sAudit.*` | off | `clusters`, `pipeline`, and the same time settings. |
| `sink.type` | `s3` | `s3`, `syslog` or `otlp`, configured under `sink.s3`, `sink.syslog`, `sink.otlp`. |
| `state.backend` | `s3` | `s3` (`state.s3.*`) or `volumeSet` (`state.volumeSet.existingName`, `.capacity`). |
| `aws.*` | `identity` | See [AWS access](#aws-access); ignored without S3. |
| `identity.existingName` | empty | Reuse an identity in the GVC. |
| `resources.cpu` / `.memory` | `250m` / `512Mi` | Reserved in full (Capacity AI is off). |
| `firewall.*` | all outbound | Needs `api.cpln.io`, `audit.cpln.io`, `logs.cpln.io`, and the destination. |
| `tuning.maxBatchEvents` / `.maxBatchBytes` | `10000` / 32 MiB | New records held before they are delivered and checkpointed. |
| `tuning.maxObjectEvents` / `.maxObjectBytes` | `10000` / 32 MiB | S3 object limits, before compression. |
| `tuning.leaseTTL` | `5m` | How long a replica that died holding a lease blocks the others. |
| `tuning.cycleBudget` | `30m` | A backlog is worked off in cycles of about this length, each followed at once by the next. |
| `tuning.drainTimeout` / `.terminationGracePeriodSeconds` | `30s` / `90` | See [Delivery guarantees](#delivery-guarantees). |
| `tuning.heartbeatMaxAge` | `30m` | The liveness probe restarts the shipper when a stream made no progress for this long. |
| `tuning.logLevel` | `info` | `debug`, `info`, `warn`, `error`. |

**Memory.** Each stream works through one request and one batch at a time, so memory does not grow with the backlog, but the streams run side by side, so it grows with the number of busy clusters. An hour-long backfill of a busy cluster (about 80 entries per second, 278,000 entries of about 2.4 KB) peaked at 112 MB of heap. The audit trail needs about 15 MB. The Go memory limit is set to 80% of the container's, so `512Mi` leaves room for about three busy clusters; raise it for more.

## How it works

The workload runs one long-lived replica per GVC location. Each stream (an audit context or a cluster) runs its own loop: a cycle every `interval`, or at once after a cycle that ran longer. Each cycle:

1. Takes the stream's lease in its checkpoint, or skips the cycle when another replica holds it. A new stream saves its starting point here, before anything is delivered, so a failed first cycle does not move its start.
2. Fixes its end at *now − `settleDelay`* and reads from *watermark − `overlap`* one window at a time, dropping the IDs it already delivered. A window is accepted only when it fits in one page: the audit API orders tied timestamps differently on every call, so paging through a full window could skip or repeat records. A full window is narrowed and read again, and the window size carries over to later cycles.
3. Once a batch is full (`maxBatchEvents` or `maxBatchBytes`), records it as *pending*, delivers it, then moves the watermark and stores the IDs inside the new overlap, all in one conditional write.
4. Repeats until it reaches its end, then releases the lease.

A replica writes its checkpoint only while it holds the lease, and every write is conditional on the version it last wrote. A replica that stalls past its lease cannot overwrite the work of the replica that took over. Every delivery is also cut off before the replica's lease could expire.

Two streams of one release run independently: one failing (its source down, say) does not hold up the other.

## Recovery, backfill and reset

- **A cycle failed.** Nothing to do: the checkpoint only moves after delivery, and the next cycle retries from it. The log says why.
- **After a suspension, an outage or a crash,** each stream resumes from its checkpoint and works off the backlog in cycles of about `cycleBudget`, limited only by how far back the source still holds data (30 days of Kubernetes audit logs by default). The destination usually sets the pace: a real syslog listener over TLS took about 13 seconds per 5 minutes of a busy cluster, so an hour of backlog takes about 2.5 minutes and 30 days about 1.3 days. The audit trail is much smaller.
- **An interrupted batch** is delivered again. For S3 it is rebuilt with exactly the same bounds, so it overwrites the same objects. For syslog and OTLP its records are collected again within the batch limits.
- **The checkpoint is unreadable.** The stream stops and says so. With S3 versioning, restore the previous version of `checkpoint.json`; otherwise reset the stream.
- **Backfill a range** without touching the live stream: install a second release with its own `stream` and `startTime`/`endTime` for the source. It works through the range, logs `status: complete` on every cycle, and can then be uninstalled. Records the live stream already shipped are shipped again.
- **Skip a gap on purpose:** reset the stream with `startTime` after the gap, or start a new `stream`.
- **Reset a stream:** suspend the workload, delete the checkpoint, resume. With S3 state: `aws s3 rm s3://BUCKET/PREFIX/state/org=ORG/source=…/sink=…/stream=STREAM/checkpoint.json`. With volume set state, delete the file from a workload that mounts the volume set, or uninstall, delete the volume set, and reinstall. The stream then starts at `startTime` or `initialLookback`.

## Monitoring and troubleshooting

Logs are JSON lines. Each cycle ends with `cycle finished`, `cycle skipped: …` or `cycle failed, …`, carrying `status`, `events`, `writes`, `bytes`, `batches`, `queries`, `watermark`, `lag_seconds` (now minus the watermark) and `duration_ms`, plus `context` or `cluster`. Credentials and record contents are never logged.

```bash
cpln logs '{gvc="GVC", workload="RELEASE-audit-shipper", container="shipper"}' --since 1h
```

Alert when `lag_seconds` grows beyond a few intervals plus `settleDelay`, or on `cycle failed`.

| Log message | Cause and fix |
|---|---|
| `audit API denied the request (HTTP 403)` | The service account lacks `readAudit` on the context, or its key was removed (restart the replica to add a new one) or, with your own account, is wrong or revoked. |
| `cannot add a key to the service account` | The identity lacks `addKey`, `edit` or `view` on the release's service account (the `-key` policy), or the account holds 10 keys, one per location: keys are named `cpln-audit-shipper LOCATION …`, and those of locations no longer in the GVC can go (`cpln serviceaccount remove-key`). Right after install the replica retries for up to 5 minutes, since the service account can be created after the workload. |
| `logs API denied the request` | The service account lacks `readLogs` on the org. |
| `more than 5000 records in […)` | More Kubernetes audit entries share one nanosecond than a request returns; does not occur with real clusters. |
| `logs API returned matrix, not log streams` | `sources.k8sAudit.pipeline` turned the query into a metric query. |
| `cannot obtain AWS credentials` | No cloud access on the identity, wrong keys, or a denied AssumeRole (permission, trust policy, external ID). |
| `reading checkpoint … access denied` | Missing `s3:GetObject` on the state prefix, `s3:ListBucket` for a new stream, or `kms:Decrypt`. |
| `connecting to syslog …: no such host` (`EAI_NODATA`) | The name does not resolve from the workload. After fixing DNS, a replica may keep a cached negative answer: `cpln workload force-redeployment RELEASE-audit-shipper --gvc GVC`. |
| `TLS handshake with syslog …: x509: certificate signed by unknown authority` | The listener's CA is private: put its PEM bundle in an opaque secret and set `sink.syslog.caSecret`. |
| `syslog listener did not close the connection` (warning) | The listener keeps connections open; batches count as sent after `sink.syslog.timeout`. |
| Messages arrive merged or cut | The listener expects the other framing (`sink.syslog.framing`), or its maximum message length is below `sink.syslog.maxMessageBytes`. |
| `posting records … HTTP 4xx` | The OTLP endpoint rejected the request: check the URL, the auth header and its secret. |
| `volume set state needs a single-location GVC` | Use `state.backend: s3`, or a GVC with one location. |
| `the state volume cannot lock files` | The volume set is not a shared file system; use `fileSystemType: shared`. |
| `another replica holds the state lock; waiting` | Normal for a few seconds during a rollout, while the old replica stops. |
| `cycle skipped: another replica holds the checkpoint lease` | Normal with several locations. After a crash it clears within `leaseTTL`. |
| `checkpoint state is invalid` | See [Recovery](#recovery-backfill-and-reset). Progress was not reset. |
| `invalid configuration` (exit code 2) | The message lists every invalid setting. |

## Verify end to end

1. Install. The first cycle starts as soon as the replica has its key, usually within a minute (up to about 5 minutes, while the release's service account is being created), and logs `cycle finished` with `events` for each stream.
2. Make a change you can recognise, such as `cpln secret create-opaque --name audit-probe --file <(echo probe) && cpln secret delete audit-probe`, and wait one `interval` plus `settleDelay`.
3. Find it at the destination: `aws s3 cp s3://BUCKET/PREFIX/data/…/FILE.jsonl.gz - | gunzip | grep audit-probe`, or search the syslog receiver or collector for `audit-probe`.
4. To confirm nothing is duplicated, count each ID over a range, for S3:

   ```bash
   aws s3 cp --recursive s3://BUCKET/PREFIX/data/org=ORG/source=cpln-audit/ /tmp/audit && \
     find /tmp/audit -name '*.gz' -exec gunzip -c {} + | python3 -c \
     'import sys,json,collections; c=collections.Counter(json.loads(l)["id"] for l in sys.stdin); print(len(c), "events,", sum(v>1 for v in c.values()), "duplicated")'
   ```

## Upgrading, migrating and uninstalling

Checkpoints are keyed by org, source, context or cluster, destination type and stream, not by release or version, so upgrades and reinstalls continue where each stream stopped. Uninstalling removes the workload, identity, policies, the release's service account and (with volume set state) the created volume set, which deletes those checkpoints; S3 checkpoints and all shipped data stay.

**Moving from another shipper** to this template: to avoid a gap or a resend, set the source's `startTime` to where the old shipper stopped, and stop the old one first. For a syslog receiver that already parses `mk8s-audit` messages nothing changes: `APP-NAME`, `HOSTNAME` and the structured data are the same.

## Building the image

The shipper is a small Go program in [controlplane-com/cpln-audit-shipper](https://github.com/controlplane-com/cpln-audit-shipper), published as `ghcr.io/controlplane-com/cpln-build/cpln-audit-shipper`. To run your own build, push it to your org's registry with `make cpln-image ORG=my-org TAG=<tag>` there, and set `image: //image/cpln-audit-shipper:<tag>`.
