# Goal: find and fix why Snapper snapshots make Btrfs qgroups inconsistent

## User outcome

Hourly Snapper snapshots on Kingston must not repeatedly make Btrfs qgroup
accounting inconsistent and trigger disruptive full rescans. Identify the
specific operation and qgroup relationship that sets the inconsistency flag,
determine whether it is expected behavior, a configuration problem, or a Btrfs
bug, then fix the cause. Do not treat disabling rescans or suppressing the
inconsistency warning as a fix.

## Investigation scope

- Work in this `~/src/linux` checkout, not a linked worktree. Use the source
  corresponding to the kernel currently running on the host. At the start of
  this investigation, `uname -r` reported `7.1.13+deb13-amd64`, from Debian
  package `7.1.13-1~bpo13+1`. Confirm the exact Debian source package and patches
  before making kernel-level conclusions. If the host kernel changes, retarget
  to the new running version.
- Trace the actual hourly path from `snapper-timeline.timer` through the
  installed timeline wrapper and Snapper configs to the snapshot ioctl and
  qgroup inheritance code.
- Correlate snapshot creation times, snapshot IDs, qgroup relationships,
  kernel warnings, and rescan starts/completions. Distinguish snapshot creation
  that marks qgroups inconsistent from the wrapper that subsequently launches
  a rescan.
- Reproduce the Kingston configuration and snapshot sequence in a controlled
  filesystem image. Identify the exact qgroup inheritance condition that
  requests a full rescan and explain why the hourly workload reaches it.
- Determine whether Btrfs is correctly requiring a rescan under its accounting
  semantics, whether Snapper's `QGROUP` assignment or snapshot layout is
  inappropriate, or whether an incremental-accounting/kernel bug causes
  avoidable inconsistency.
- Implement the smallest correct fix at the responsible layer: configuration,
  Snapper integration, or kernel qgroup accounting. Preserve correct
  referenced and exclusive counts, quota enforcement, and recovery behavior.
  Do not simply skip the warning or mark accounting consistent without proving
  the counts.
- Keep automated qgroup rescans disabled on the host while investigating
  system stalls. Snapper snapshot creation remains enabled unless evidence
  shows it must be paused for a safe reproduction. This host safeguard is
  operational containment, not the final fix.

## Verification required

- Reproduce the inconsistency with the same qgroup hierarchy and Snapper-like
  hourly snapshots on a disposable Btrfs image; record the pre/post qgroup
  status and relevant kernel messages.
- Verify the proposed fix over repeated snapshot creation and cleanup, including
  shared extents, parent/child qgroups, and rescan recovery. Compare qgroup
  referenced/exclusive values against a full rescan and ensure repeated
  snapshots no longer trigger unnecessary rescans.
- Build and run relevant Btrfs/kernel or Snapper checks for the layer changed.
  Keep source edits in source trees and build outputs in the prescribed
  external build trees.
- Validate kernel changes against the exact running Debian source baseline.
- Investigate reported system stalls separately from the inconsistency trigger.
  A qgroup warning/rescan correlation alone does not prove that the scan caused
  the stalls; collect stacks and transaction/I/O evidence where needed.
- Search existing upstream Linux/Btrfs reports and discussions. If the root
  cause is an upstream bug and no report exists, prepare a focused report and
  patch for the correct Btrfs venue. Do not send it until the reproduction and
  evidence support the diagnosis and the user has reviewed the concrete draft.

## Current evidence and status

- The Kingston wrapper runs Snapper timelines for `root` and `home`, then
  checks qgroup status and launches a full rescan when accounting is
  inconsistent. That rescan block is temporarily commented out; snapshot
  creation remains enabled.
- The Kingston Snapper configs assign new snapshots to qgroups `1/100` (root)
  and `1/101` (home). Kernel logs report `qgroup inherit needs a rescan` at
  times that coincide with timeline service runs.
- Live qgroup output maps the source subvolumes to `0/256` (`@`) and `0/257`
  (`@home`), both with no parent qgroup. The snapshot destination subvolumes
  are `0/258` and `0/259`, with parents `1/100` and `1/101` respectively.
  Snapper's snapshot implementation passes the configured QGROUP as the
  inheritance parent. Linux `v7.1.13` has a quick-inherit check that explicitly
  requires a full rescan when the source has no parent qgroup. This strongly
  identifies the trigger; a controlled reproduction and accounting comparison
  are still required before selecting a fix.
- The exact running kernel is Linux `7.1.13+deb13-amd64`, package
  `7.1.13-1~bpo13+1`. Active work is in this `~/src/linux` checkout on branch
  `codex/qgroup-root-cause-7.1.13`, based on upstream `v7.1.13`. Debian's source
  patch series has one Btrfs patch, which changes only the RAID5/6 warning in
  `fs/btrfs/super.c`; it does not touch qgroup code. SHA-256 for
  `fs/btrfs/qgroup.c` matches between the upstream tag and Debian's orig source
  archive (`bf44fc4f...e923d227`). Thus the qgroup code under investigation
  matches the running Debian kernel. The prior 7.2.6 worktree is not active.
- A prior QEMU fixture contains a long snapshot loop, but its captured serial
  log ends during snapshot creation and does not prove a completed reproduction
  or suspend/resume behavior. Rework it into a small conclusive reproduction.
- The earlier suspendability patch and unsent upstream draft are not the active
  objective. Preserve them as historical work unless root-cause findings show
  they are needed for the final fix.
