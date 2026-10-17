# Goal: fix Snapper-triggered Btrfs qgroup inconsistency

Find and fix why hourly Snapper snapshots make qgroup accounting
inconsistent, while preserving accurate accounting and expected cleanup
behavior. The goal is to eliminate unnecessary full rescans by correcting
their cause, not by hiding inconsistency or weakening accounting.

## Remaining work

1. **Get review of the prepared upstream Snapper contribution.** A focused
   two-commit branch is based on the freshly fetched upstream tip, and its PR
   description with QEMU evidence is at
   `/var/tmp/snapper-qgroup-upstream-pr.md`. The branch is local because the
   attempt to push it to the GitHub fork was rejected by automatic review.
   Obtain authorization for that external publication before pushing or
   opening an upstream PR. Do not file a kernel bug report unless further
   tests show the kernel still rescans or miscounts with the tracking hierarchy
   in place.
2. **Keep the host rollout gated.** The `v0.10.6` Snapper backport is built
   and QEMU-tested, but the host still runs Debian Snapper `0.10.6-1.2`, which
   predates the tracking-parent fix. Neither the backport nor custom Btrfs
   module is installed. Keep the timeline wrapper's explicit rescan block
   disabled until broader tests and deliberate rollout are complete.
3. **Extend workload coverage.** Current QEMU cases cover Zstd-compressed and
   incompressible data, outside shared snapshots, partial overwrites,
   truncation, create/delete churn, timeline cleanup, concurrent tracker
   allocation, and an empty orphan tracker. Check additional Btrfs layouts and
   recovery boundaries before host rollout.
4. **Investigate reported stalls independently.** Capture useful task stacks,
   transaction state, and storage/I/O evidence during an incident. Do not infer
   that rescans caused the stalls from timing or an inconsistency warning
   alone.
5. **Preserve temporary host containment.** Confirm the wrapper still skips
   automatic rescans while snapshots continue. Restore the original
   `SPACE_LIMIT="0.5"` settings only after the patched Snapper is deliberately
   deployed and its initialization scan and cleanup behavior are verified.

## Acceptance

Repeated Snapper-style snapshots and cleanup, including externally shared
extents, keep qgroup data consistent without unnecessary full rescans; the
accounting still supports correct snapshot cleanup and quota enforcement. Any
remaining limitation or unverified stall hypothesis is documented explicitly.

## Completed evidence

See [`GOAL-done.md`](GOAL-done.md) for completed investigation, reproduction
results, kernel baseline, and temporary containment details. That file is
historical reference; the items above are the active work.
