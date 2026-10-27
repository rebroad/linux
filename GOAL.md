# Goal: accurate Btrfs qgroup stats without unacceptable filesystem latency

This is the active checklist. Keep every item below 100% here, with its rough
completion percentage and remaining gates. Put completed work and detailed
evidence in [`GOAL-done.md`](GOAL-done.md); do not maintain a separate progress
file. Percentages estimate acceptance work completed, not confidence or test
pass rates; items overlap and should not be averaged.

## First priority: diagnose the stalls and establish the accounting trade-off — 79%

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

Current runtime and diagnostic facts that affect these open gates:

- The host is running Debian kernel `7.2.9+deb13-amd64`. At 15:10 local on
  2026-10-27, the loaded module's build ID matched the stock module extracted
  from the selected stock initrd; the different DKMS module was present on
  disk but was not loaded. Both filesystems were inconsistent, neither had
  an active rescan, and no tasks were in D state. This confirms the host was
  using stock Btrfs during this capture, not the modified shared-parent code.
  Evidence is in [`GOAL-done.md`](GOAL-done.md).
- Kernel logs show pairs of `qgroup scan paused` messages on p8 around each
  hourly Snapper timeline run from 10:00 through 15:01. The 14:00 and 15:00
  runs also have corresponding root/home snapshot records. Stock Btrfs source
  shows `qgroup_mark_inconsistent()` can set the scan-cancel flag, which makes
  the worker log `qgroup scan paused`; the worker also stops for other reasons.
  The timing strongly correlates the messages with the timeline workload, but
  does not identify the stop condition or exact triggering operation/reason.
  A live trace is still needed. The prior TTM GPU-fence capture remains
  separate evidence and did not show Btrfs tasks blocked.
- A five-second scheduler trace at 15:29 local on 2026-10-27 ran while both
  rescans were idle. It sampled swap page-fault waits and a Psensor thread
  waiting for an NVMe hwmon log read, plus USB-resume and ordinary TTY/process
  waits; it saw no qgroup marks or rescan-worker activity. This does not
  attribute the earlier systemwide hangs. A focused trace is armed for the
  next timeline run and records D-state wait durations as well as stacks.
- The latest blocked-task sample found TTM GPU-fence waits, not Btrfs tasks.
- A 19:06 stock-kernel capture showed the qgroup scans had paused by 19:02;
  `btrfs-cleaner` was blocked reading extent-tree metadata during snapshot-drop
  delayed-ref work while `fstrim` was blocked on synchronous discard. The trim
  ran 18:49-19:08 and discarded about 508 GiB on Kingston and 214.6 GiB on p8.
  Stock source and a threshold-zero QEMU reproduction show that an
  inconsistency transition can itself stop a rescan. The host pause's exact
  caller/threshold and the cause of the reported multi-minute stalls remain
  unproven; the capture does not show the rescan worker blocked.
- Exact-release QEMU tests show stock and custom feature-off reproduce
  inconsistency/rescans; quick-inherit feature-on kept counters accurate in
  both tested snapshot orders. A matched 217-snapshot comparison now also
  covers 131,072 metadata files per source. Quick-inherit kept all four
  counters accurate through snapshots; stock counters differed after full
  rescans. At threshold 1, deletion made both implementations stale. In TCG,
  custom and stock median snapshot cycles were 1,490 ms and 500 ms; stock also
  had 29 s and 53 s cycles while rescans ran. These are not host-latency
  measurements; live host stall attribution and host-scale storage evidence
  remain open.
- Snapper's local-time hold/window behavior is installed and simulated. The
  stock-module QEMU test now captured stale values, explicit hold deferrals,
  quota-cleanup deferral, and two recovery scans after expiry. The all-roots
  timeline wrapper also held scans while stale and recovered after expiry.
  An actual suspend/resume and systemd timer catch-up remain untested. Detailed
  results are in [`GOAL-done.md`](GOAL-done.md).

See [`GOAL-done.md`](GOAL-done.md) for completed evidence, test detail, and
historical captures.
