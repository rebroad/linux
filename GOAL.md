# Goal: fix Snapper-triggered Btrfs qgroup inconsistency

Find and fix why hourly Snapper snapshots make qgroup accounting
inconsistent, while preserving accurate accounting and expected cleanup
behavior. The goal is to eliminate unnecessary full rescans by correcting
their cause, not by hiding inconsistency or weakening accounting.

## Remaining work

1. **Complete the paired upstream contributions.** Snapper changes for
   upstream `master` and Debian Snapper `0.10.6` stop clean quota queries from
   starting unnecessary rescans. They do not alter the stock kernel's
   snapshot-inheritance decision: the reproduced snapshot-only tracker layout
   still takes its conservative rescan fallback on Debian's kernel. No qgroup
   counter corruption has been demonstrated; a full rescan agrees with the
   incrementally maintained counters. The kernel quick-inherit change is
   therefore an optional, narrowly scoped optimization for avoiding that
   snapshot-triggered scan, not a correctness fix required to repair bad
   accounting. The RFC has been updated with this distinction. Before
   proposing it formally, finish quota-limit coverage and build/test against
   current upstream; retain the exact topology guards and fallback for all
   other layouts.
2. **Keep the host rollout gated.** The host still runs Debian Snapper
   `0.10.6-1.2` and its stock kernel module. Do not install either candidate
   until the paired changes have review and the full accounting/quota checks
   pass. Keep the timeline wrapper's explicit rescan block disabled and
   `SPACE_LIMIT` empty during investigation.
3. **Finish accounting and recovery coverage.** QEMU now covers compressed
   and incompressible data, externally shared snapshots, partial overwrites,
   truncation, create/delete churn, timeline cleanup, concurrent tracker
   allocation, orphan and one-sided tracker recovery, and interrupted scans
   with complete trackers. Extend quota-limit checks and any additional Btrfs
   layouts needed to support the paired patch.
4. **Investigate reported stalls independently.** Capture task stacks,
   transaction state, and storage/I/O evidence during an incident. Do not infer
   that rescans caused the stalls from timing or an inconsistency warning
   alone.
5. **Preserve temporary host containment.** Confirm the wrapper still skips
   automatic rescans while snapshots continue. Restore the original
   `SPACE_LIMIT="0.5"` settings only after both changes are deliberately
   deployed and their initialization scan, quota accounting, and cleanup
   behavior are verified.

## Acceptance

Repeated Snapper-style snapshots and cleanup, including externally shared
extents, keep qgroup data consistent without unnecessary full rescans on the
supported kernel path; reference and exclusive counters match a full rescan,
and quota limits retain their existing snapshot-only scope. Any remaining
limitation or unverified stall hypothesis is documented explicitly.

## Completed evidence

See [`GOAL-done.md`](GOAL-done.md) for completed investigation, reproduction
results, kernel baseline, and temporary containment details. That file is
historical reference; the items above are the active work.
