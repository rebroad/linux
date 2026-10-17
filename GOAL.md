# Goal: fix Snapper-triggered Btrfs qgroup inconsistency

Find and fix why hourly Snapper snapshots make qgroup accounting
inconsistent, while preserving accurate accounting and expected cleanup
behavior. The goal is to eliminate unnecessary full rescans by correcting
their cause, not by hiding inconsistency or weakening accounting.

## Remaining work

1. **Choose a correct accounting design.** Determine how Snapper can measure
   retained snapshot space without rescanning after each snapshot. Test any
   proposed qgroup hierarchy or derived metric with extents shared by the live
   source and by subvolumes outside the cleanup set. If no existing layout
   preserves exact semantics, identify the smallest principled Btrfs or Snapper
   change.
2. **Implement the fix at the responsible layer.** Preserve meaningful
   referenced and exclusive counts, quota enforcement, and cleanup decisions.
   Do not count live source data as snapshot-only usage unless the accounting
   is demonstrably corrected.
3. **Verify on the matching kernel.** Reproduce repeated snapshot creation and
   cleanup on a disposable Btrfs image using the source matching the running
   Debian kernel. Compare incremental counters with a full rescan and verify
   that the fix avoids unnecessary rescans. Build in the prescribed external
   build tree for any kernel change.
4. **Investigate reported stalls independently.** Capture useful task stacks,
   transaction state, and storage/I/O evidence during an incident. Do not infer
   that rescans caused the stalls from timing or an inconsistency warning
   alone.
5. **Handle upstream work if warranted.** Search for an existing report if
   testing demonstrates a Btrfs bug. If none exists, prepare a focused report
   and patch for the right venue, and present the draft for review before
   submitting it.
6. **Keep temporary host containment deliberate.** The timeline wrapper's
   explicit rescan block remains disabled, and quota-aware Snapper cleanup is
   temporarily paused. Verify effective behavior so no rescan source is
   overlooked. Restore the original `SPACE_LIMIT="0.5"` settings only after
   the accounting fix is verified and automated rescans are safe.

## Acceptance

Repeated Snapper-style snapshots and cleanup, including externally shared
extents, keep qgroup data consistent without unnecessary full rescans; the
accounting still supports correct snapshot cleanup and quota enforcement. Any
remaining limitation or unverified stall hypothesis is documented explicitly.

## Completed evidence

See [`GOAL-done.md`](GOAL-done.md) for completed investigation, reproduction
results, kernel baseline, and temporary containment details. That file is
historical reference; the items above are the active work.
