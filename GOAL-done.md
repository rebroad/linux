# Completed investigation evidence

This file records verified findings that inform the active tasks in
[`GOAL.md`](GOAL.md). A tracking-parent fix candidate has now passed the
described QEMU snapshot and cleanup workloads on the deployed Snapper version;
broader filesystem coverage and host rollout remain open.

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
- At the time of the initial investigation, the Snapper source checkout was at
  tag `v0.10.6`, matching the installed version then recorded.
  `Snapper::queryQuotaData()` calls
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
  space-aware qgroup queries. Systemd reports its timer enabled and active.
  Privileged inspection confirmed that the system and Kingston configs had
  `SPACE_LIMIT="0.5"` before temporary containment was applied.
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
  inconsistency only while the parent exclusively owns all referenced
  extents. It changes the cleanup metric, so it is not itself an acceptable
  fix.
- A second run waited for `btrfs subvolume sync` after deleting one of three
  snapshots. The deleted qgroup disappeared, the shared parent counters
  decreased by one nodesize, and the filesystem remained consistent with no
  rescan in progress. This confirms the no-rescan result through completed
  snapshot cleanup for this simple layout.
- A controlled external-sharing run confirmed that source-inclusive parent
  `rfer` minus live-source `rfer` is not an exact substitute for snapshot-only
  `exclusive`. With source and snapshots in `1/100`, and a separate outside
  snapshot sharing their old extents, the 7.1.13 kernel still marked qgroups
  inconsistent on inherited snapshot creation. After a full rescan, the
  difference `1/100.rfer - source.rfer` was 4,243,456 bytes, while the
  snapshot-only `1/101.excl` was 49,152 bytes. The outside shared data makes
  the first metric overstate bytes exclusively attributable to the cleanup
  set, and the parent no longer satisfies the kernel's `excl == rfer` fast
  path condition.
- Together, these runs show that assigning the source to Snapper's snapshot
  parent avoids rescans only in the special case where no extent referenced by
  that parent is also referenced outside it. That condition cannot be assumed
  for the live filesystem.

## Tracking-parent prototype (2026-10-17)

- Kernel source is on `codex/qgroup-root-cause-7.1.13`. Commit `3e4d0853dc36`
  adds a level-2 tracking-parent fast path; `6bdac37f7104` updates its exclusive
  counter rule. For the snapshot-only parent, the fast path takes referenced
  bytes from the tracker and retains the parent's existing exclusive count,
  adding only one nodesize for the new snapshot root. This avoids deriving the
  parent's exclusive count from tracker and source totals, which failed when
  the source and existing snapshots already shared extents.
- Snapper commit `1a643d69` creates the tracking parent before a
  cleanup-enabled snapshot when both the live source and configured
  snapshot-only QGROUP are unparented. It recognizes a complete tracker only
  when its exact direct members are the source and snapshot parent. Parent
  lookup filters Btrfs's reciprocal relation records by qgroup level.
- A QEMU integration run used the Debian `7.1.13+deb13-amd64` kernel image,
  the custom Btrfs module with matching vermagic, and the Snapper `0.13.2`
  build. It seeded two existing snapshot qgroups, included a separate outside
  snapshot sharing source extents, ran tracker migration, made three further
  Snapper snapshots, deleted one snapshot, and compared all qgroup counters
  before and after an explicit full rescan. The test passed with no
  `qgroup marked inconsistent` warning after tracker setup, and the full scan
  changed no counters. The tested serial log is
  `/var/tmp/qgroup-root-cause-7.1.13/serial_snapper7.log`.
- The first timeline-retention fixture put all snapshots in the same guest
  hour and asserted the wrong deletion selection. The corrected fixture below
  advances the guest clock between snapshots and exercises the retention
  algorithm across hourly buckets.

## Snapper 0.10.6 backport and hourly cleanup run (2026-10-17)

- The installed host Snapper is `0.10.6`. Backport commit `770bf48e` on
  `codex/qgroup-root-cause-0.10.6` adapts the tracking-parent change to that
  release. It is published at
  `origin/codex/qgroup-root-cause-0.10.6`. The CLI and `libsnapper.so.7` built
  successfully in the sibling build tree. The full top-level build still
  cannot build the unrelated `mksubvolume` utility because
  `libext2fs-dev` is absent; it was not installed.
- The QEMU run used the Debian `7.1.13+deb13-amd64` kernel image and the
  matching custom Btrfs module. Its fresh Btrfs image included an outside
  snapshot sharing source extents. Two existing snapshots were assigned to
  snapshot-only QGROUP `1/0`, then a cleanup-enabled Snapper snapshot created
  tracker `2/0` as the parent of both `0/256` (live source) and `1/0`.
- The tracker migration completed one rescan. Four more snapshots were
  created at successive guest-hour timestamps. Timeline cleanup then removed
  the two legacy snapshots and three older tracked snapshots, retaining the
  newest hourly snapshots. No additional qgroup scan completed during those
  snapshots or cleanup, and the log contains no `qgroup marked inconsistent`
  warning. A final explicit full rescan changed none of the qgroup counters;
  the fixture reported `SNAPPER-0106-INTEGRATION: PASS`.
- The test init script, overlay, fresh image, and serial log are under
  `/var/tmp/qgroup-root-cause-7.1.13/`; the log is
  `serial_snapper0106.log`. This validates the stated legacy layout and hourly
  cleanup sequence, not compression, concurrent configs, partial tracker
  recovery, or host runtime behavior.
- This remains a QEMU-verified candidate rather than a host rollout. Automated
  rescans and quota-aware cleanup remain contained on the host pending broader
  tests and a deliberate rollout.

## Tracker interruption recovery and master forward port (2026-10-17)

- Snapper now recognizes a narrowly defined partial tracker: exactly one of
  the live source or configured snapshot QGROUP has a level-2 parent, and that
  parent's only member is the expected qgroup. It adds the missing relation
  and calls `quota_rescan_if_needed()`. Ambiguous or multiply-parented layouts
  remain untouched. The existing complete-tracker fast path remains unchanged.
- The 0.10.6 branch backports the existing status-aware rescan helper from
  master. This matters because Btrfs may already have started or completed a
  rescan after a qgroup relation changes; Snapper waits for a running scan or
  starts one only if qgroup status still says it is needed. It does not start
  another scan after a clean automatic rescan.
- Both the fresh-tracker and one-sided-partial-tracker cases passed the same
  QEMU timeline workload on `7.1.13+deb13-amd64`, for Snapper `0.10.6` and
  master `0.13.2`. Each run created multiple successive-hour snapshots,
  applied timeline cleanup, then compared qgroup counters before and after a
  full rescan. All four runs reported `SNAPPER-0106-INTEGRATION: PASS`; none
  logged `qgroup marked inconsistent`. After tracker setup, the hourly
  snapshots and cleanup started no additional scans. The serial logs are
  `serial_snapper0106.log`, `serial_snapper0106fresh.log`,
  `serial_snapper_master_recovery.log`, and
  `serial_snapper_master_fresh.log` under
  `/var/tmp/qgroup-root-cause-7.1.13/`.
- The backport fixup is `53aef9df` on
  `codex/qgroup-root-cause-0.10.6`. The forward-port fixup is `0972b9de` on
  `codex/qgroup-tracker-recovery`. Both branches are pushed. The master
  checkout's unrelated untracked config files remain untouched.
- The tests cover interruption after one of the two tracker relations is
  written. They do not identify an empty level-2 qgroup left by interruption
  immediately after qgroup creation; safely distinguishing such an orphan
  from a deliberately empty qgroup remains open, along with concurrent
  tracker creation and compressed extents.

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
- The current remaining issue is not explained by a faulty quick-inherit
  calculation: exact qgroup exclusivity for a snapshot-only set requires
  knowing which extents overlap with source and external subvolumes. The
  `v7.1.13` kernel's full-rescan fallback is consistent with Btrfs's documented
  qgroup model. No evidence currently justifies an upstream bug report or a
  patch that simply skips the consistency check.

## Earlier containment and suspend work

- Automated qgroup rescans were disabled in the host timeline wrapper to limit
  instability during investigation. This is temporary containment, not a
  solution to inconsistency.
- A prior effort explored allowing suspend during a qgroup scan, including a
  7.2.6 worktree patch and an unsent upstream report/patch. That effort was
  superseded by the root-cause objective. Its QEMU fixture did not establish
  successful suspend/resume behavior; do not treat it as validated or active
  work.
