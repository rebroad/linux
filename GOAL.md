# Goal: fix Snapper-triggered Btrfs qgroup inconsistency

Find and fix why hourly Snapper snapshots make qgroup accounting
inconsistent, while preserving accurate accounting and expected cleanup
behavior. The goal is to eliminate unnecessary full rescans by correcting
their cause, not by hiding inconsistency or weakening accounting.

## Remaining work

1. **Harden the tracking-parent design.** The level-2 tracker and revised
   snapshot-parent exclusive-count update passed one QEMU workload with
   externally shared extents. Check compression, broader sharing patterns,
   duplicate/concurrent Snapper configs, and recovery from a partially created
   tracker before treating the fast path as general.
2. **Target the deployed Snapper version.** The checkout is now master
   `0.13.2`, while the installed host binary is `0.10.6`. Port and build the
   Snapper change against `v0.10.6`, then verify the exact installed-version
   path without enabling host rescans.
3. **Verify automatic cleanup semantics.** The explicit Snapper deletion run
   passed the full-rescan counter oracle. The QEMU timeline-retention fixture
   selected different snapshots than expected and did not complete its
   assertion; correct that fixture and verify the real cleanup algorithm,
   qgroup membership, and retained-space decisions.
4. **Expand matching-kernel verification.** Repeat the migration, snapshot,
   and cleanup scenarios with more varied extents and compare incremental
   counters with a full rescan. Continue using the Debian `7.1.13+deb13-amd64`
   kernel baseline and the external sibling build tree.
5. **Investigate reported stalls independently.** Capture useful task stacks,
   transaction state, and storage/I/O evidence during an incident. Do not infer
   that rescans caused the stalls from timing or an inconsistency warning
   alone.
6. **Handle upstream work if warranted.** Search for an existing report if
   testing demonstrates a Btrfs bug. If none exists, prepare a focused report
   and patch for the right venue, and present the draft for review before
   submitting it.
7. **Keep temporary host containment deliberate.** The timeline wrapper's
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
