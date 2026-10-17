# Goal: find and fix why Snapper snapshots make Btrfs qgroups inconsistent

## User outcome

Hourly Snapper snapshots on Kingston must not repeatedly make Btrfs qgroup
accounting inconsistent and trigger disruptive full rescans. Identify the
specific operation and qgroup relationship that sets the inconsistency flag,
determine whether it is expected behavior, a configuration problem, or a Btrfs
bug, then fix the cause. Do not treat disabling rescans or suppressing the
inconsistency warning as a fix.

## Investigation scope

- Trace the actual hourly path from `snapper-timeline.timer` through the
  installed timeline wrapper and Snapper configs to the snapshot ioctl and
  qgroup inheritance code.
- Correlate snapshot creation times, snapshot IDs, qgroup relationships,
  kernel warnings, and rescan starts/completions. Distinguish snapshot creation
  that marks qgroups inconsistent from the wrapper that subsequently launches
  a rescan.
- Reproduce the Kingston configuration and snapshot sequence in a controlled
  filesystem image. Inspect which condition in qgroup inheritance requires a
  full rescan (parent mismatch, multiple parents, non-exclusive parent, or
  another path) and explain why the hourly workload reaches that condition.
- Determine whether Btrfs is correctly requiring a rescan under its documented
  accounting semantics, whether Snapper's `QGROUP` assignment or snapshot
  layout is inappropriate, or whether an incremental-accounting/kernel bug
  causes avoidable inconsistency.
- Implement the smallest correct fix at the responsible layer: configuration,
  Snapper integration, or kernel qgroup accounting. Preserve correct referenced
  and exclusive counts, quota enforcement, and recovery behavior. Do not simply
  skip the warning or mark accounting consistent without proving the counts.
- Keep automated qgroup rescans disabled on the host while investigating
  system stalls. Snapper snapshot creation remains enabled unless evidence shows
  it must be paused for a safe reproduction. The temporary host safeguard is
  operational containment, not the final fix.

## Verification required

- Reproduce the inconsistency with the same qgroup hierarchy and Snapper-like
  hourly snapshots on a disposable Btrfs image; record the pre/post qgroup
  status and relevant kernel messages.
- Verify the proposed fix over repeated snapshot creation and cleanup, including
  shared extents, parent/child qgroups, and rescan recovery. Check qgroup
  referenced/exclusive values against a full rescan and ensure no fresh
  rescan is required after each snapshot.
- Build and run relevant Btrfs/kernel or Snapper tests for the layer changed.
  Keep source edits in source trees and build outputs in the prescribed
  external build trees.
- Validate the fix against the Debian-approved kernel baseline in use for this
  machine, and keep the host's automatic rescan initiator disabled until the
  fix is verified.
- Investigate the reported system stalls separately from the inconsistency
  trigger. A qgroup warning/rescan correlation alone does not prove that the
  scan caused the stalls; collect stacks and transaction/IO evidence where
  needed.
- Search existing upstream Linux/Btrfs reports and discussions. If the root
  cause is an upstream bug and no report exists, prepare a focused report and
  patch for the correct Btrfs venue. Do not send it until the reproduction and
  evidence support the diagnosis and the user has reviewed the concrete draft.

## Current evidence and status

- The host wrapper runs Snapper timelines for Kingston's `root` and `home`
  configurations, then checks qgroup status and launches a full rescan when
  accounting is inconsistent. That rescan block is temporarily commented out;
  snapshot creation is still enabled.
- The Kingston Snapper configs assign new snapshots to qgroups `1/100` (root)
  and `1/101` (home). Kernel logs report `qgroup inherit needs a rescan` at
  times that coincide with timeline service runs. This points to snapshot
  inheritance as the inconsistency trigger, while the wrapper is the subsequent
  rescan initiator.
- In Linux `v7.2.6` qgroup inheritance can request a rescan when quick
  inheritance is unsafe, including when the parent qgroup does not exclusively
  own all referenced bytes. The exact branch and snapshot responsible in the
  host workload have not yet been proven.
- A prior QEMU fixture contains a long snapshot loop, but its captured serial
  log ends during snapshot creation and does not prove a completed reproduction
  or any suspend/resume behavior. Rework or resume the fixture to produce
  bounded, conclusive evidence before relying on it.
- The earlier suspendability patch and unsent upstream draft are not the active
  objective. Preserve them as historical work unless root-cause findings show
  they are needed for the final fix.
