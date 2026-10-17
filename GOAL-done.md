# Completed investigation evidence

This file records verified findings that inform the active tasks in
[`GOAL.md`](GOAL.md). The cause has not yet been fixed.

## Kernel baseline

- The host kernel was `7.1.13+deb13-amd64`, Debian package
  `7.1.13-1~bpo13+1`. Work is in the main `~/src/linux` checkout on branch
  `codex/qgroup-root-cause-7.1.13`, based on upstream tag `v7.1.13`.
- Debian's source patch series contains one Btrfs patch, changing only the
  RAID5/6 warning in `fs/btrfs/super.c`. SHA-256 for `fs/btrfs/qgroup.c` matches
  between the upstream tag and Debian's orig source archive
  (`bf44fc4f...e923d227`). The qgroup implementation being investigated thus
  matches the running Debian kernel's source.

## Snapshot trigger and accounting evidence

- The Kingston timeline wrapper runs Snapper timelines for `root` and `home`,
  then checks qgroup state and launches a full rescan if accounting is
  inconsistent. Its automated-rescan block is temporarily commented out;
  snapshot creation remains enabled.
- Snapper configs assign snapshots to qgroups `1/100` (`root`) and `1/101`
  (`home`). Live source subvolumes are `0/256` (`@`) and `0/257` (`@home`),
  without parent qgroups. The `.snapshots` subvolumes are `0/258` and `0/259`.
- Linux `v7.1.13`'s quick-inherit path requests a rescan when the source qgroup
  has no parent. Snapper passes its configured `QGROUP` as the snapshot's
  inheritance parent.
- A controlled QEMU reproduction using the installed Debian 7.1.13 kernel
  confirmed that creating a snapshot with `-i 1/100` from an unparented source
  marks qgroups inconsistent immediately. `btrfs quota rescan -s` reports no
  active scan while `btrfs qgroup show` reports inconsistent data.
- In a separate run, creating a snapshot without qgroup inheritance left
  qgroups consistent; `btrfs quota rescan -s` reported no active scan. This
  identifies configured inheritance as the distinguishing trigger in this
  reproduction, but the effect on Snapper's intended accounting and cleanup
  still needs to be addressed.
- After a full rescan, assigning the live source to `1/100` prevented a later
  inherited snapshot from triggering another rescan. However, the snapshot-only
  parent had 25,182,208 referenced bytes and 16,384 exclusive bytes; including
  the live source changed these to 25,198,592 referenced and 25,198,592
  exclusive bytes. Snapper `v0.10.6` uses the high-level qgroup's exclusive
  count for snapshot-space usage, so this assignment changes the metric and is
  not an established fix.

## Why the rescan is requested, and Snapper's role

- In `v7.1.13`, `qgroup_snapshot_quick_inherit()` declines its fast path when
  the source qgroup has no parent. This is necessary for the current
  snapshot-only parent: aggregate referenced/exclusive counters cannot reveal
  which extents in the source overlap extents already referenced by snapshots
  in that parent. Assuming no overlap or subtracting source exclusives would
  produce incorrect parent counts.
- The official Btrfs qgroup documentation describes the same limit: exclusive
  and referenced byte counters do not encode extent-sharing relationships;
  changing qgroup membership can therefore require a full rescan. The fast
  path is safe only for restricted cases where ownership can be derived from
  existing counters. This evidence currently points to an expected limitation
  of full qgroups, rather than a kernel accounting bug.
- The Snapper source checkout is at tag `v0.10.6`, matching the installed
  version recorded during this investigation. `Snapper::queryQuotaData()` calls
  `quota_rescan()` and waits for it before reading the configured qgroup's
  `exclusive` count. The cleanup code calls this query when `SPACE_LIMIT` is
  enabled. Therefore the timeline wrapper's explicit rescan block is not the
  only possible rescan source; space-aware Snapper cleanup independently
  requests a scan.
- The external-root timeline wrapper uses `snapper create --cleanup-algorithm
  timeline`. In the inspected Snapper source, this sets the snapshot's cleanup
  metadata and passes `QGROUP` to the snapshot ioctl. Creation itself does not
  run the cleanup algorithm. The wrapper's own later rescan block was a
  separate path. The packaged `snapper-cleanup` service is another path to
  space-aware qgroup queries. In the current environment, systemd reports its
  timer enabled and active. Reading the live mounted Snapper configs was denied
  by the environment, so current `SPACE_LIMIT` values and whether the active
  timer will enter the quota-aware branch remain unverified here.
- The current evidence explains why the inconsistency flag is set and why a
  scan can later start, but it does not establish an acceptable replacement
  accounting model. No kernel or Snapper code fix has been selected.

## Source-inclusive qgroup experiment

- On the exact Debian 7.1.13 kernel, a disposable Btrfs image was configured
  with the source subvolume and snapshot subvolumes under the same parent
  qgroup. Three inherited snapshots followed by deletion of one snapshot and
  `btrfs subvolume sync` completed with qgroup data consistent and no rescan in
  progress. This matches the kernel fast-path condition.
- That parent qgroup reported `rfer == excl == 33,619,968` bytes after three
  snapshots of a 32 MiB source, and `33,603,584` bytes after deletion completed.
  It accounts the live source together with the snapshots; the earlier
  snapshot-only reproduction reported just 16,384 exclusive bytes for the
  same source data shared with the live source. This layout prevents the
  inconsistency but changes the cleanup metric, so it is not itself an
  acceptable fix.
- A second run waited for `btrfs subvolume sync` after deleting one of three
  snapshots. The deleted qgroup disappeared, the shared parent counters
  decreased by one nodesize, and the filesystem remained consistent with no
  rescan in progress. This confirms the no-rescan result through completed
  snapshot cleanup for this simple layout.
- A possible metric such as source-inclusive parent `rfer` minus live-source
  `rfer` needs further testing. The required test must include extents shared
  with subvolumes outside the cleanup set, because such extents can make this
  difference overstate bytes exclusively attributable to the snapshots.

## Temporary host containment (2026-10-17)

- `snapper-cleanup.timer` is enabled and active; the cleanup service was
  inactive at inspection. The system and Kingston `root`/`home` configs all
  had `SPACE_LIMIT="0.5"`, which lets quota-aware cleanup call Snapper's
  rescan-and-wait query. To keep that path from starting new scans during this
  investigation, `SPACE_LIMIT` is temporarily empty in all four configs.
- Snapshot creation, `QGROUP`, `FREE_LIMIT="0.2"`, and timeline cleanup remain
  configured. Quota-based space cleanup is paused. Restore `SPACE_LIMIT="0.5"`
  in these four files after the accounting fix is verified:
  `/etc/snapper/configs/{root,home}` and
  `/mnt/kingston/@/etc/snapper/configs/{root,home}`.
- Kingston already had a rescan running before the config changes. Its status
  remained `rescan operation running` afterward; this containment does not
  cancel or interrupt an in-flight scan. A kernel stack showed the
  `btrfs-qgroup-rescan` worker at 08:52, but the available journal excerpt did
  not establish which command started that scan.

## Earlier containment and suspend work

- Automated qgroup rescans were disabled in the host timeline wrapper to limit
  instability during investigation. This is temporary containment, not a
  solution to inconsistency.
- A prior effort explored allowing suspend during a qgroup scan, including a
  7.2.6 worktree patch and an unsent upstream report/patch. That effort was
  superseded by the root-cause objective. Its QEMU fixture did not establish
  successful suspend/resume behavior; do not treat it as validated or active
  work.
