# Goal: fix Snapper-triggered Btrfs qgroup inconsistency

Find and fix why hourly Snapper snapshots make qgroup accounting
inconsistent, while preserving accurate accounting and expected cleanup
behavior. The goal is to eliminate unnecessary full rescans by correcting
their cause, not by hiding inconsistency or weakening accounting.

## Remaining work

1. **Expand accounting verification.** The Snapper tracking-parent change and
   concurrent qgroup-ID collision retry now pass the tested two-config hourly
   workload, timeline cleanup, and eight simultaneous first snapshots on the
   Debian `7.1.13+deb13-amd64` kernel. Extend coverage to varied extent layouts,
   compression, and safe recovery from an empty orphan tracker left if
   interrupted between qgroup creation and its first member assignment.
2. **Keep the host rollout gated.** The `v0.10.6` Snapper backport is built
   and QEMU-tested, but the host still runs Debian Snapper `0.10.6-1.2`, which
   predates the tracking-parent fix. Neither the backport nor custom Btrfs
   module is installed. Keep the timeline wrapper's explicit rescan block
   disabled until broader tests and deliberate rollout are complete.
3. **Investigate reported stalls independently.** Capture useful task stacks,
   transaction state, and storage/I/O evidence during an incident. Do not infer
   that rescans caused the stalls from timing or an inconsistency warning
   alone.
4. **Handle upstream work if warranted.** Current evidence points to the
   installed Snapper version omitting the tracking-parent setup, while the
   kernel's rescan fallback is expected for that qgroup hierarchy. Search for
   an existing Snapper report before proposing an upstream submission; report
   a kernel bug only if further tests show the fixed hierarchy still needs an
   unnecessary rescan or miscounts extents.
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
