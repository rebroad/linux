# Goal: fix Snapper-triggered Btrfs qgroup inconsistency

Find and fix why hourly Snapper snapshots make qgroup accounting
inconsistent, while preserving accurate accounting and expected cleanup
behavior. The goal is to eliminate unnecessary full rescans by correcting
their cause, not by hiding inconsistency or weakening accounting.

## Remaining work

1. **Complete the paired upstream contributions.** The host currently runs
   kernel release `7.1.13+deb13-amd64`; use that exact release for all
   remaining investigation and acceptance testing. The stock-module and
   candidate-module QEMU comparisons, including hourly Snapper 0.10.6 and
   quota cleanup, use that release. Testing other kernel versions is outside
   this goal. Snapper changes for upstream `master` and Debian Snapper `0.10.6`
   stop clean quota queries from starting unnecessary rescans. The query-path
   follow-up is committed and pushed (`9d9c8820` and `46fcfbea`) and QEMU-tested
   on both Snapper lines. No qgroup counter corruption has been demonstrated;
   a full rescan agrees with incrementally maintained counters. On the stock
   kernel, the reproduced snapshot-only tracker layout takes the conservative
   rescan fallback; the exact two-member tracker optimization avoids those
   snapshot-triggered scans while preserving the existing same-parent
   exclusivity guard and passing quota cleanup. The kernel change is an
   optimization for this proven topology, not a repair for demonstrated bad
   accounting. The tracker is created only by the candidate Snapper
   `prepareQGroupTracking()` change; the stock Snapper baseline leaves the
   source and configured snapshot qgroup without a shared level-2 parent. The
   kernel's no-parent rescan fallback is expected for that baseline, so the
   kernel change alone will not avoid its scans. The no-rescan candidate is a
   paired Snapper/kernel path. The RFC, differential results, correction, and
   formal kernel patch have been sent to `linux-btrfs`. No maintainer response
   is recorded yet; continue with review feedback and requested checks. The
   narrowed patch was checked against current upstream source and compiled
   against `v7.3-rc7`, but runtime acceptance remains on the exact in-use
   `7.1.13+deb13-amd64` release. The Snapper companion branch is pushed to the
   fork and is available as clean-history draft upstream PR
   [#1201](https://github.com/openSUSE/snapper/pull/1201); keep it paired with
   the kernel change through review.
2. **Keep the host rollout gated.** The host still runs Debian Snapper
   `0.10.6-1.2` and its stock kernel module. Do not install either candidate
   until the paired changes have review and the full accounting/quota checks
   pass. Keep the timeline wrapper's explicit rescan block disabled and
   `SPACE_LIMIT` empty during investigation.
3. **Make the fix durable across APT upgrades.** Choose and document a
   maintainable, APT-managed deployment for the paired kernel and Snapper
   changes. It must ensure that a kernel upgrade/reinstall does not silently
   replace the fixed kernel with an unmodified one, and that Snapper package
   upgrades/reinstalls retain the fix. Prefer reviewed Debian/upstream
   packages when available; if the host needs locally maintained packages,
   define how they are built, installed, and kept current. Do not depend on a
   manually copied kernel module or silently hold back security updates.
   Before considering the host rollout complete, exercise the relevant APT
   upgrade/reinstall path and verify the running kernel, loaded module, and
   Snapper package contain the intended fix afterward.
4. **Finish accounting and recovery coverage.** QEMU now covers compressed
   and incompressible data, externally shared snapshots, partial overwrites,
   truncation, create/delete churn, timeline cleanup, concurrent tracker
   allocation, orphan and one-sided tracker recovery, and interrupted scans
   with complete trackers. The current Debian Snapper 0.10.6 build has now
   also passed a fresh-filesystem QEMU run that repairs an interrupted
   config-only tracker, completes successive hourly snapshots and timeline
   cleanup, and preserves counters across a full rescan. The exact-current
   Debian Snapper quota-limit test passed with the
   `7.1.13+deb13-amd64` candidate module, matching the running kernel.
   Extend coverage only for additional Btrfs layouts needed to support the
   paired patch, using the same kernel release.
5. **Investigate reported stalls independently.** Capture task stacks,
   transaction state, and storage/I/O evidence during an incident. Do not infer
   that rescans caused the stalls from timing or an inconsistency warning
   alone.
6. **Preserve temporary host containment.** Confirm the wrapper still skips
   automatic rescans while snapshots continue. Restore the original
   `SPACE_LIMIT="0.5"` settings only after both changes are deliberately
   deployed and their initialization scan, quota accounting, and cleanup
   behavior are verified.

## Acceptance

Repeated Snapper-style snapshots and cleanup, including externally shared
extents, keep qgroup data consistent without unnecessary full rescans on the
supported kernel path; reference and exclusive counters match a full rescan,
and quota limits retain their existing snapshot-only scope. The fix remains
installed and active after kernel and Snapper APT upgrade/reinstall operations,
with the running kernel, loaded module, and installed Snapper package verified.
Any remaining limitation or unverified stall hypothesis is documented
explicitly.

## Completed evidence

See [`GOAL-done.md`](GOAL-done.md) for completed investigation, reproduction
results, kernel baseline, and temporary containment details. That file is
historical reference; the items above are the active work.
