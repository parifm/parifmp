# Metadata cleanup operational guide

How `metadata_cleanup.py` behaves at each stage, what it costs, how to run it from clients, and how to recover from an interrupted reupload.

[TOC]

## Background

Space reclamation never reclaims metadata — graceful handling of metadata download failure is difficult to implement — so leaked metadata objects accumulate on the OBS tier until cleaned up manually. [WEKAPP-361718](https://wekaio.atlassian.net/browse/WEKAPP-361718) is the motivating incident: 1 PB+ of excess metadata on a customer's OBS tier. Hagai wrote `metadata_cleanup.py` to automate the cleanup; it lives in the wekapp repo at [scripts/obs/metadata-cleanup/metadata_cleanup.py](https://github.com/weka/wekapp/blob/trunk/dev/scripts/obs/metadata-cleanup/metadata_cleanup.py) (branch `trunk/dev`), and the in-repo runbook is `weka/fs/docs/stow-metadata-cleanup.md`. Eyal presented the script's architectural underpinnings in a [recorded talk](https://drive.google.com/drive/folders/1dgZ1XnvxwDDcOfa2vYmOfIe_rJBjc51a).

Use the script only after consultation with R&D, and always use the most current version from GitHub.

Scope: the script cleans up metadata objects only — it does not clean up manifest objects or stow specs (locators).

## Requirements and global flags

The script requires Python 3.11 and boto3 (`python3.11 -m pip install boto3`) on every host that runs it.

Global flags go before the operation name:

*   `--workdir <dir>` (required) — where results, state, and logs are stored.
*   `--log-level` — default INFO2.
*   `-v` / `--verbose` — enable boto3 S3 debug logs.
*   `--skip-ssl-verify` or `--ca-bundle <file>` (mutually exclusive) — for stores with self-signed or private-CA certificates.

## Stage overview

1.  **Sandline** — restarts all compute buckets, in batches, and records per-bucket raft-term thresholds. About 15 minutes at ~1700 buckets. The one cluster-impacting step (a cluster-wide failover). Requires `--obs-bucket <name>` to name the OBS bucket being cleaned.
2.  **Unstow** — config-only OBS status flip. Seconds.
3.  **Reupload** — re-serializes metadata only; existing data blobs are referenced, never re-uploaded. Hours, sized by filesystem metadata.
4.  **Scan** — S3-lists this cluster's `/m/` prefixes and collects pre-sandline keys.
5.  **Operator review.**
6.  **Delete** — re-validates each key, then deletes one by one. Days to weeks at PB scale.

Scan and delete resume from persisted per-bucket cursors (S3 continuation token / processed count). The reupload phase is not cursor-resumable — an interruption there needs manual handling, because a re-run trips on already-synchronized snapshots (see the recovery section below).

## Canonical per-phase commands

Run the operations in this order; the `status` operation can run at any time between steps.

```shell
python3.11 metadata_cleanup.py --workdir /mnt/weka/obs-cleanup sandline --obs-bucket <obs-bucket-name>
python3.11 metadata_cleanup.py --workdir /mnt/weka/obs-cleanup unstow
python3.11 metadata_cleanup.py --workdir /mnt/weka/obs-cleanup reupload
python3.11 metadata_cleanup.py --workdir /mnt/weka/obs-cleanup scan --bucket-id + --parallel 10
python3.11 metadata_cleanup.py --workdir /mnt/weka/obs-cleanup delete --bucket-id + --parallel 10 --force
```

*   `--bucket-id +` selects the compute buckets whose leader is on the host running the command; `--parallel 10` works 10 buckets concurrently in threads within the process.
*   `delete` refuses to run without `--force`. Without it, the script prints a reminder to consider temporarily enabling versioning on the object store as a safety net — and, after the delete is done, to disable versioning and verify that the reuploaded snapshots can be downloaded.

## Snapshots during the backup-less window

The cluster is never without snapshots — all local snapshots stay intact on SSD throughout; unstow only flips their OBS status. What's at risk between unstow and reupload completion is the OBS backup copy (download/DR ability). That window is smaller than it sounds: the reupload is metadata-only, so it's sized by the filesystem's USED SSD (META) — typically hours, not the weeks the delete phase takes.

Creating SSD-only snapshots during the window is safe by construction: creation writes nothing to OBS (no spec, no metadata blobs), cannot enter the reupload set (frozen at sandline from previously-`SYNCHRONIZED` snapshots), and trips none of the script's phase guards — there is no code path connecting a local snapshot creation to the cleanup.

The condition is create-only. Snapshot deletion/rotation and uploads must stay off for the window:

*   Deletes block the unstow manhole and can break the reupload mid-flight.
*   Post-sandline uploads that later rotate become new leak this run won't reclaim.

snaptool schedules bundle create+upload+delete, so the schedule must be verifiably create-only; if that can't be guaranteed, keep the scheduler off entirely (the tested configuration). Create-only snapshots during the window have not been exercised in a production run.

## Timing between sandline and reupload

No technical deadline. The sandline only records per-bucket raft-term thresholds; nothing decays, and it invalidates nothing — until unstow runs, all uploaded snapshots remain `SYNCHRONIZED` and downloadable. The backup-less window starts at unstow, not at the sandline.

Keep the gap reasonably short anyway:

*   Scheduled uploads must stay disabled from before the sandline onward, so a long gap is a long time without fresh OBS backups.
*   Anything uploaded and rotated away post-sandline is leak this run won't reclaim.
*   If bucket leaders move in the meantime, re-record the distribution (the `bucket_redist` operation) before fanning out scan/delete.

## Jumbo OBS buckets

No correctness complications at 32 PiB. The scan is scoped to this cluster's `/m/` metadata prefixes, and every delete re-validates bucket id, GUID, and raft term, so bucket size doesn't change safety. Data blobs are never touched: the reuploaded snapshots keep referencing the existing data objects, so the 32 PiB of data is out of scope entirely — scan time scales with the number of leaked metadata objects, not data size.

The complications are throughput. Deletes go out one object at a time (batch delete is broken in current boto3, WEKAPP-504770), so at the ~8 PB leak estimate plan for weeks; raise `--parallel` (16–32) fanned across backends. Scan and delete resume from persisted cursors after any interruption.

Ceph-specific: the listing+delete load lands on the RGW bucket index and garbage collection — the store should be healthy and monitored on its side. If versioning is enabled as the delete safety net, space only frees after versioning is reduced/disabled.

## Resource footprint per phase

The script itself is lightweight everywhere — a Python process doing S3 list/delete over HTTP: tens to hundreds of MB of RAM and roughly a core per process (plus `--parallel` threads, each holding one S3 connection), running on the OS cores outside the Weka containers.

Per phase:

*   **Sandline** — the one cluster-impacting step: restarts all compute buckets (a cluster-wide failover).
*   **Unstow** — seconds, config-only.
*   **Reupload** — runs through the normal stow pipeline on the compute nodes but is metadata-only; cost ≈ the filesystems' USED SSD (META), near-zero data traffic.
*   **Scan and delete** — just the Python processes.

Storage: the shared workdir holds ~100 bytes per collected object plus logs. At this scale, size the temp SSD filesystem generously (100–200 GB), since logs accumulate over the multi-week delete.

## What to monitor per phase

Only the reupload is visible to Weka stats — it's an ordinary snapshot upload: watch the object-storage stats (upload ops/throughput/failures), SSD read bandwidth, and `weka cluster task` for per-upload progress. Expect a PUT-heavy but modest-bandwidth profile, since it's metadata-only.

Scan and delete bypass Weka entirely (direct boto3 to the store), so Weka stats won't show them — monitor host CPU/RAM on the machines running the script and the store's own metrics (RGW request rates, index/GC load).

Throughout all phases: `weka events` (the script fires a cluster event on any critical error), `weka alerts`, the script's `status` operation between steps, and the workdir's `metadata_cleanup_critical.log` — which must stay empty.

## Running from a Weka client

Scan and delete can run from a Weka client with an admin logged in, with conditions — and `--bucket-id=-` (or an explicit id list) is required from a client. The runbook's `+` mode selects "buckets whose leader is on this host" from the map recorded at sandline: a client's hostname isn't in that map, so `+` would find zero buckets. `-` selects buckets by phase state in the shared workdir instead, ignoring hostname.

What the client needs for scan/delete: Python ≥ 3.11 plus boto3, the shared workdir mounted, and network reach to the S3 endpoint (verify — clients may sit on different VLANs than the backends' data path). The `weka` CLI login is needed only for the critical-error event path.

The sandline/unstow/reupload phases drive `weka debug` commands that should redirect to the leader from a client, but no field run has driven them from a client.

Operational shape of `-`:

*   It is a single-runner mode — one process picks up all buckets in the phase and works them at `--parallel N` (default 1, i.e. serial — raise it).
*   It is phase-aware and resumable: re-runs skip finished buckets, and interrupted buckets continue from their persisted cursor. A premature `delete --bucket-id=-` simply processes whatever buckets are ready and skips the rest — re-run until `status` shows all finished.
*   Never run two `-` processes (or `-` alongside a `+` fan-out) concurrently — their bucket selections overlap; see [Workdir layout and parallelism](#workdir-layout-and-parallelism) for the failure mechanism.
*   To parallelize across several clients, give each an explicit disjoint id list. No range syntax exists, so generate it — for example `scan --bucket-id $(seq -s, 0 419)` on client A, `$(seq -s, 420 839)` on client B, and so on. Explicit lists are literal (not phase-filtered), so on retries drop already-finished buckets from the list.

## Workdir layout and parallelism

The workdir is the coordination mechanism between phases and hosts: one shared directory per cleanup run, on a filesystem every participating host mounts. The script partitions its files into two classes:

*   **Global files, written only by the serial phases.** `metadata_cleanup_state.json` holds the global phase — written only by sandline, unstow, and reupload; scan and delete only read it. `metadata_cleanup_sandline_config.json` and `metadata_cleanup_buckets_dist.json` are written at sandline (or by `bucket_redist`) and are read-only afterward.
*   **Per-bucket files, keyed by bucket id.** `metadata_cleanup_state_b<id>.json` holds that bucket's phase and cursors. `metadata_cleanup_objects_b<id>.txt` holds that bucket's scan results — appended by scan, consumed by delete, which resumes by line offset into it.

The logs (`metadata_cleanup.log`, `metadata_cleanup_host_<hostname>.log`, `metadata_cleanup_critical.log`) are shared append targets; every line is stamped with hostname, pid, and bucket id, so concurrent appends from many processes are by design.

**The invariant: concurrent commands sharing one workdir are safe exactly when their bucket-id sets are disjoint** — then no two processes ever write the same file.

Safe in one shared workdir:

*   The `+` fan-out on every backend at once — bucket sets are disjoint by leader distribution.
*   Explicit disjoint id lists across hosts.
*   One `-` runner, plus `status` from any host at any time (`status` is read-only).
*   Scan on some buckets while delete works different buckets, via explicit lists.
*   `--parallel N` threads within one process — the bucket list is computed once, one thread per bucket.

Unsafe — any overlap in bucket ids:

*   Two `-` runners (each enumerates all phase-eligible buckets, so their lists are identical).
*   A `-` runner alongside a `+` fan-out.
*   Overlapping explicit lists, including a retry list that still names a bucket another runner holds.
*   Scan and delete pointed at the same bucket concurrently.

Overlap fails three ways: racing writes to the same per-bucket state file (last writer wins, cursors corrupt), duplicate or torn lines appended to the scan result file (duplicates are survivable — re-deletes get a 404 — but a torn line kills the delete, which parses the file line by line), and phase-assert deaths that fire spurious cluster events.

The script help's note that "each command needs a different directory (duplicate the dir as needed)" is a coarse guard against overlap, not a requirement. Separate directories fragment scan results and `status` accounting, and each bucket's delete must then run in whichever directory holds its scan file. The one case where duplicating the workdir is the right tool: hosts that cannot mount a shared filesystem — copy the directory (carrying the read-only sandline config) to each host, run disjoint bucket sets locally, and keep each bucket's scan and delete in the same copy.

## Concurrency and bandwidth limits

Reupload — partially governed: it's a plain `weka fs snapshot upload` through the product's OBS stack, but since the phase is metadata-dominated (data blobs aren't re-uploaded), the per-source Mbps bandwidth limiters barely apply. Metadata PUTs are governed by stow's own node-global concurrency semaphore (live-tunable), which is the actual knob for this phase.

Scan and delete — not governed: they are direct boto3 calls from the script, completely outside Weka's OBS stack; Weka's limits neither throttle nor protect the store. Their only throttles are `--parallel` × processes × hosts — size those deliberately for the Ceph cluster's comfort.

## Why reupload is not cleanly resumable

Scan and delete persist per-bucket cursors and resume exactly where they stopped. Reupload has no per-snapshot checkpoint: the script iterates the snapshot set frozen at sandline time and advances the global phase only after all uploads complete. Two consequences if the script dies mid-reupload:

1.  The in-flight upload does not stop. `weka fs snapshot upload` starts a cluster-side task that keeps running on its own. Don't re-run anything immediately; watch `weka cluster task` until the current upload finishes, or until the snapshot reaches `SYNCHRONIZED` in `weka fs snapshot`.
2.  A plain re-run of reupload fails. The script re-issues the upload command for the full frozen set, starting from the first snapshot — already `SYNCHRONIZED`, so the CLI refuses (`SnapshotIsSynchronized`). The script treats any command failure as critical: it fires a cluster event and exits. Expect that spurious event here — it's the script's error channel, not a cluster problem.

## Recover from an interrupted reupload

1.  Let any in-flight upload task finish (`weka cluster task`).
2.  Identify what's left: compare `weka fs snapshot -o name,filesystem,local_object_status` against the reupload set — the script's log lists it at every start as "Will operate on snapshot …" lines. Anything still `NONE` needs uploading.
3.  Upload the remaining snapshots manually, shallow to deep (the same order the script printed them), waiting for `SYNCHRONIZED` after each:

    ```shell
    weka fs snapshot upload <fs> <snap> --site local
    ```

4.  Once every snapshot in the set shows `SYNCHRONIZED`, advance the script's state machine:

    ```shell
    python3.11 metadata_cleanup.py --workdir <shared> reupload --print-only
    ```

    `--print-only` validates the set and moves the phase forward to scan without issuing any uploads — it's the supported way to tell the script the reuploads are done.
5.  Only then proceed to scan.

Warning: Don't advance with `--print-only` while any snapshot is still `NONE` or `UPLOADING`. The delete phase's safety assumes the reupload completed in full — that's what guarantees every live spec references only post-sandline metadata.

Warning: Don't use the hidden `--skip` flag for this. It marks the reupload as skipped in the state file, which changes the run's semantics rather than recording it as done.

## Prevent interruptions

Run the reupload inside tmux on one stable host (per the runbook), and treat it as a single unattended multi-hour command. The recovery procedure above only matters if that command dies.
