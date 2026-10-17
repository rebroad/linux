# Goal: let Btrfs qgroup rescans coexist with system suspend

## User outcome

A computer must be able to enter system suspend while a Btrfs qgroup rescan is active. `force-suspend` must not have to cancel or wait for the rescan. The rescan must remain intact across suspend and continue after resume. The implementation may leave the worker runnable during suspend preparation so the kernel freezer does not wait for the full rescan; the system must not wait for the scan to finish before entering sleep.

Ordinary suspend and resume must not cancel the scan, lose its progress, start a replacement scan, or mark accounting inconsistent. The workqueue change must preserve Btrfs transaction and I/O safety while suspend progresses.

## Implementation scope

- Use Debian's latest approved kernel source package as the target baseline. At the time this goal was recorded, the backports candidate was Linux `7.2.6-1~bpo13+1`; verify the current Debian candidate and its source patches before finalizing the base.
- Change the qgroup-rescan workqueue behavior so a long-running scan does not hold up system suspend. Verify how the worker behaves during suspend preparation, deep sleep, resume, and filesystem freeze/thaw; do not add cancellation or completion waits.
- Keep `force-suspend` independent of rescan cancellation. Remove any cancellation/wait behavior added solely as a workaround if it conflicts with the pause/resume design. Do not add Kingston unmount behavior.
- Update btrfs-progs or its documentation/tests only where the kernel behavior requires a user-visible interface or where existing tools need changes to observe the paused/resumed state. Do not add a cancellation command as a substitute for suspend support.
- Search the existing Linux/Btrfs reports and mailing-list discussions. If no current report covers this suspend failure, prepare and send a focused report and patch to the correct upstream Btrfs venue (`linux-btrfs@vger.kernel.org`).

## Verification required

- Build the kernel changes and any btrfs-progs changes against the selected Debian source baseline, keeping source edits in source trees and build output in the prescribed external build tree.
- Exercise a long-running qgroup rescan through the same freezer/suspend path that blocked the laptop, and verify that the same scan is active before suspend, suspend reaches sleep without waiting for its full completion, and the scan remains active or completes after resume without a new scan being started.
- Verify filesystem freeze/thaw behavior as well as system suspend, including error/abort paths, and confirm the qgroup status/progress and accounting consistency semantics.
- Test `force-suspend` behavior without actually suspending the host during development; use a controlled test environment for end-to-end suspend validation.
- Report what was built and tested, any unverified hardware-specific behavior, and the upstream report/patch status. Do not claim the goal is complete until the live suspend/resume behavior and upstream submission are verified.

## Current status

The target kernel worktree is based on upstream Linux `v7.2.6`, matching Debian backports `7.2.6-1~bpo13+1`. The worktree change removes `WQ_FREEZABLE` from the ordered qgroup-rescan workqueue while retaining `WQ_MEM_RECLAIM`. A QEMU deep-suspend test has shown the same scan active before and after S3, then completing through the existing wait-only `-W` path without starting another scan. Further review, filesystem-freeze checks, upstream reporting, and submission remain. The main `~/src/linux` checkout has unrelated local changes; preserve them.
