# Goal: fix Snapper-triggered Btrfs qgroup inconsistency

Find and fix why hourly Snapper snapshots make qgroup accounting
inconsistent, while preserving accurate accounting and expected cleanup
behavior. The goal is to eliminate unnecessary full rescans by correcting
their cause, not by hiding inconsistency or weakening accounting.

## Remaining work

1. **Harden the tracking-parent design.** The level-2 tracker and revised
   snapshot-parent exclusive-count update passed QEMU workloads with outside
   shared extents and the installed Snapper version. A Zstd-compressed extent
   also passed the one-sided tracker-recovery workload. Still check varied
   compressed layouts, duplicate/concurrent Snapper configs, and safe handling
   of an empty orphan tracker left if interrupted between qgroup creation and
   its first member assignment.
2. **Expand accounting verification.** Test more varied extent layouts and
   cleanup sequences on the Debian `7.1.13+deb13-amd64` kernel, comparing
   incremental counters with a full rescan. The tested fixture covers one
   legacy two-snapshot layout, hourly creation, and timeline cleanup; it does
   not cover every filesystem feature or workload.
3. **Keep the host rollout gated.** The `v0.10.6` Snapper backport is built
   and tested in QEMU, but neither it nor the custom Btrfs module is installed
   on the host. Preserve the temporary host containment until broader tests
   and a deliberate rollout are complete.
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
