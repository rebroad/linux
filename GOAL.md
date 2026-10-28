# Goal: accurate Btrfs qgroup stats without unacceptable filesystem latency

This is the active checklist. Keep every item below 100% here, with its rough
completion percentage and remaining gates. Put completed work and detailed
evidence in [`GOAL-done.md`](GOAL-done.md); do not maintain a separate progress
file. Percentages estimate acceptance work completed, not confidence or test
pass rates; items overlap and should not be averaged.

## First priority: diagnose the stalls and establish the accounting trade-off — 95%

Determine whether accurate qgroup statistics for our required layout can
coexist with low-latency snapshots and cleanup on the supported Btrfs stack.
Do not assume that qgroup inconsistency is a bug: establish whether it is an
intended fallback, a performance/accuracy trade-off, an overly conservative
limitation, or a defect. Also determine whether our kernel changes caused or
contributed to each observed stall; if not, identify the responsible kernel
path or dependency.

1. Capture blocked-task stacks, transaction progress, device request latency,
   qgroup state, and the caller/reason that stops each rescan during an actual
   stall. The Oct 28 14:00 stock 7.2.9 trace tied two p8 rescans to Snapper's
   per-snapshot qgroup preflight and recorded four inheritance marks. It also
   captured 72 qgroup IDs whose limit-item updates returned `-ENOENT` during
   transaction accounting. Cross-capture matching ties 16 of those IDs to
   Oct 27 cleanup removals whose relation and qgroup removal returned
   rescan-required; this confirms the stale-qgroup failure on the host. The
   loaded module's message format matches upstream v7.2.9; this checkout adds
   qgroup IDs. The Debian 7.2.9 source patch set does not modify qgroup code.
   A separate Oct 28 10:40 system-wide stall occurred with the stock module:
   the cleaner waited for a transaction during dropped-snapshot qgroup
   cleanup, and Tor waited on an ordered extent. Identify the transaction
   blocker and device latency in a live capture, and account for the other 56
   qgroup IDs.
2. Compare stock and modified Btrfs on the exact supported kernel and the
   representative four-config workload. Measure snapshot, cleanup, deletion,
   transaction-commit, and recovery costs on host-like storage. A fresh 7.2.9
   QEMU A/B and its reversed-order repeat isolated `shared_parent_quick_inherit`:
   enabled kept all four groups consistent and full-rescan counters unchanged;
   disabled triggered rescans and counters changed. A matched 4-vCPU stock
   control reproduced the disabled-switch accounting result. The isolated
   qgroup quick-inherit, fallback, and overflow selftests also passed in QEMU
   on the exact 7.2.9 module across all five tested metadata node sizes. Still
   test other hierarchies, measure on host-like storage, and profile cleanup
   and transaction stalls before selecting a kernel behavior. See
   [`GOAL-done.md`](GOAL-done.md) for results.
3. Reproduce and isolate the first inconsistent transition on the exact
   7.2.9 workflow. Test snapshot creation/inheritance and deletion separately;
   determine whether the 14:00 missing qgroup items belong to deleted snapshots;
   identify the extent/backref work that dominates cleanup and whether it can
   be reduced without compromising the four counters.
4. Decide whether routine snapshots can keep all required counters accurate
   while infrequent deletion makes them explicitly stale for later recovery.
   If not, identify and quantify which accuracy and latency requirements
   cannot both be met under the tested kernel, layout, workload, and limits.
   Earlier multi-switch TCG results suggested consistent counters might make
   root-snapshot deletion much slower, but matched 4-vCPU runs show long root
   deletions across stock and both custom modes. Attribute the variability
   before treating it as a design trade-off. Do not call a design universally
   impossible based on incomplete testing.
5. Fix and regression-test any confirmed defect. Do not install a modified
   Btrfs module on the host unless its correctness, latency, stall behavior,
   Secure Boot signature, and rollback path have passed review.

## Remaining work

1. **Four-collective accounting and recovery — 90%:** Preserve separate snapshot
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
