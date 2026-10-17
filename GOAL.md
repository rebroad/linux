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
  (`@home`), both with no parent qgroup. The `.snapshots` subvolumes are
  `0/258` and `0/259`, related to `1/100` and `1/101`. Snapper passes the
  configured QGROUP as the new snapshot's inheritance parent. Linux
  `v7.1.13` returns “rescan required” when that source has no parent qgroup.
- A controlled reproduction using the installed Debian `7.1.13` kernel confirms
  the sequence: create a snapshot with `-i 1/100` from an unparented source,
  and qgroups become inconsistent immediately; `btrfs quota rescan -s` reports
  no running scan while `qgroup show` reports inconsistent data. After a full
  rescan, assigning the live source subvolume to `1/100` makes a subsequent
  inherited snapshot avoid a new rescan.
- That assignment is not yet an acceptable fix. In the reproduction, the
  snapshot-only `1/100` qgroup measured 25,182,208 referenced bytes and 16,384
  exclusive bytes after rescan. Adding the live source changed it to 25,198,592
  referenced and exclusive bytes. Snapper `v0.10.6`, the installed version,
  uses the high-level qgroup's exclusive count as its snapshot-space usage, so
  including the live source would make Snapper count live data as snapshot
  usage. The expected accounting tradeoff must be resolved before choosing a
  fix.
- The exact running kernel is Linux `7.1.13+deb13-amd64`, package
  `7.1.13-1~bpo13+1`. Active work is in this `~/src/linux` checkout on branch
  `codex/qgroup-root-cause-7.1.13`, based on upstream `v7.1.13`. Debian's source
  patch series has one Btrfs patch, which changes only the RAID5/6 warning in
  `fs/btrfs/super.c`; it does not touch qgroup code. SHA-256 for
  `fs/btrfs/qgroup.c` matches between the upstream tag and Debian's orig source
  archive (`bf44fc4f...e923d227`). Thus the qgroup code under investigation
  matches the running Debian kernel. The prior 7.2.6 worktree is not active.
- The earlier 7.2.6 QEMU fixture remains inconclusive and is not being used.
  A separate bounded QEMU reproduction now runs the installed 7.1.13 kernel and
  confirms the snapshot inheritance trigger and the accounting impact of
  assigning the live source to the parent. Repeated real Snapper cleanup and
  retention behavior still need verification before selecting a fix.
- The earlier suspendability patch and unsent upstream draft are not the active
  objective. Preserve them as historical work unless root-cause findings show
  they are needed for the final fix.
