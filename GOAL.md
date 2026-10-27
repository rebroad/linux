# Goal: accurate Btrfs qgroup stats without unacceptable filesystem latency

This is the active checklist. Keep every item below 100% here, with its rough
completion percentage and remaining gates. Put completed work and detailed
evidence in [`GOAL-done.md`](GOAL-done.md); do not maintain a separate progress
file. Percentages estimate acceptance work completed, not confidence or test
pass rates; items overlap and should not be averaged.

## First priority: diagnose the stalls and establish the accounting trade-off — 84%

Determine whether accurate qgroup statistics for our required layout can
coexist with low-latency snapshots and cleanup on the supported Btrfs stack.
Do not assume that qgroup inconsistency is a bug: establish whether it is an
intended fallback, a performance/accuracy trade-off, an overly conservative
limitation, or a defect. Also determine whether our kernel changes caused or
contributed to each observed stall; if not, identify the responsible kernel
path or dependency.

1. Capture blocked-task stacks, transaction progress, device request latency,
   qgroup state, and the caller/reason that stops each rescan during
   representative live events. Record `qgroup_mark_inconsistent()` reasons,
   since that path can stop an active scan internally. Identify transaction
   writers and distinguish snapshot/drop work, discard, metadata I/O, and
   unrelated device or GPU waits. Correlate only evidence from the same event;
   do not infer that a rescan caused a stall merely because they overlap.
   The 17:00 host capture first observed two p8 workers but missed the first
   caller. A follow-up at 20:00 captured Snapper explicitly entering the
   rescan ioctl. During that first worker, `btrfs_run_qgroups()` saw eight
   qgroup info/limit update failures with `-ENOENT`; source confirms those
   functions return that error when the corresponding on-disk qgroup key is
   absent. The trace did not identify the qgroup IDs or the operation that
   removed/omitted those keys. A second Snapper rescan followed inheritance
   from source `0/262` to requested parent `1/100`; no Kingston worker was
   seen. Snapper source calls the rescan policy from
   `Btrfs::prepareQGroupTracking()` before snapshot creation, but this capture
   did not record the user-space call site. Review [`GOAL-done.md`](GOAL-done.md).
   A targeted 21:00 trace is armed to record failing qgroup IDs and qgroup
   removals. Keep the ordinary-deletion cause and stall attribution open;
   these host captures show transient waits, not a prolonged stall.
   A stock 7.2.9 QEMU run with 32,768 metadata files per source, 28 snapshots
   per config, and the default deletion threshold 3 reproduced stale counters
   after snapshot inheritance but no qgroup info/limit update errors during
   cleanup or deletion. Root snapshot drops took 161 s on p8 and 122 s on
   Kingston under TCG. The corresponding 131,072-file default-threshold run
   exceeded its one-hour bound during queued drops; it also logged no such
   update errors before stopping. These are not host-latency measurements.
   Reproduce Snapper-triggered scans on demand in QEMU; do not wait for the
   host's hourly timer to make controlled-test progress. Host captures remain
   necessary for host-specific stalls and scan stop causes.
2. Compare stock and modified Btrfs on the exact supported kernel and the
   representative four-config workload. Measure snapshot, cleanup, deletion,
   transaction-commit, and recovery costs, including distributions and worst
   observed stalls. Use host-scale storage measurements before deciding the
   modified module is acceptable for host use.
3. Reproduce and isolate the first inconsistent transition on the exact
   7.2.9 workflow. Test snapshot creation/inheritance and deletion separately;
   do not treat the deletion threshold as the only possible trigger. Identify
   the extent/backref work that dominates the slow path and determine whether
   it can be reduced without compromising the four counters.
4. Decide whether routine snapshots can keep all required counters accurate
   while infrequent deletion makes them explicitly stale for later recovery.
   If not, identify and quantify which accuracy and latency requirements
   cannot both be met under the tested kernel, layout, workload, and limits.
   Do not call a design universally impossible based on incomplete testing.
5. Fix and regression-test any confirmed defect. Do not install a modified
   Btrfs module on the host unless its correctness, latency, stall behavior,
   Secure Boot signature, and rollback path have passed review.

## Remaining work

1. **Four-collective accounting and recovery — 88%:** Preserve separate snapshot
   qgroups for p8-root, p8-home, Kingston-root, and Kingston-home. Validate
   their exclusive-space totals against a completed full rescan while updates
   are quiesced. Verify repeated snapshots, cleanup, deletion, stale-value
   display, deferred cleanup, and recovery on the selected design. Complete
   independent p8 accounting and safe host cleanup/rollback checks before
   restoring quota-based cleanup limits.
2. **Locally built Snapper — 90%:** Keep the host target on our locally built
   Snapper based on the latest official upstream source. Complete stale-quota,
   cleanup, rollback/runtime, and subsequent local-package upgrade checks.
   A deferred rescan must show last-known numbers with an explicit stale
   status; quota-based deletion must wait for current counters.
3. **Conditional kernel durability — 65%:** First establish whether a kernel
   change is necessary. If selected, support every installed kernel and the next APT
   candidate with a matching reviewed, signed module in the initramfs. Finish
   exact-release comparisons and a disposable end-to-end APT kernel
   transaction, including build failure, package-state, boot-selection,
   rollback, and security-update behavior. Never let an unsupported release
   silently boot with stock Btrfs in place of the selected implementation.
4. **Suspend-aware rescan containment — 89%:** Keep Snapper's hold-file gate and
   local-time window configurable; leave the per-day scan limit disabled
   during this investigation. Keep the window at 05:00-21:00 local time. The
   `force-suspend` hold is active overnight only (21:00 until its configured
   04:00 expiry); from 04:00 through 21:00 its marker must be expired and must
   not block a scan. Expiry is deadline-based and must not depend on the
   machine waking to remove the marker. In a controlled case, capture the
   stale state before suspend and the explicit hold-deferral result during
   resume timer catch-up.
   Verify the hold blocks both Snapper's internal quota path and the timeline
   wrapper, and a deferred scan may resume only after the hold expires and
   policy allows it. A deferred scan must never relabel stale values as
   consistent. The internal path, stale-value display, quota-cleanup deferral,
   and all-roots timeline-wrapper hold/expiry behavior passed in stock-module
   QEMU. Still verify actual suspend/resume and systemd timer catch-up.

## Acceptance

For the supported kernel, four-group layout, representative host workload, and
explicit latency limits, reach a decisive, reviewable verdict: either
demonstrate accurate required statistics for routine snapshots without
unacceptable filesystem latency, with any permitted stale interval and
recovery behavior measured; or show which requirements cannot be met together
and quantify the least-cost trade-off. Define accuracy by matching all four
exclusive-space totals against a completed full rescan whenever status says
consistent. Define latency against stock using snapshot and transaction
timing distributions, user-visible stalls, and worst observed waits. Incomplete
tests or a missing implementation do not prove impossibility.

Automatic rescans must stay within the configured local-time window. During
investigation, the per-day cap remains disabled and `force-suspend` may hold
new scans until its configured deadline. The timeline wrapper's separate
explicit rescan commands remain disabled. Preserve visible stale status and
prevent quota-based deletion while accounting is stale.

See [`GOAL-done.md`](GOAL-done.md) for completed evidence, test detail, and
historical captures.
