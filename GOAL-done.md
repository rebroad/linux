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
  tracker creation and broader compressed-extent layouts.

## Compressed extent tracker recovery (2026-10-17)

- A follow-up QEMU run used Snapper 0.10.6, the Debian
  `7.1.13+deb13-amd64` kernel image, and the matching custom Btrfs module. The
  fixture verified that an 8 MiB zero-filled file was stored in actual Zstd
  extents, then began with the source qgroup outside level-2 tracker `2/0` and
  the snapshot-only QGROUP as its sole child.
- Snapper restored the missing source relation with zero rescans. Four further
  hourly snapshots and timeline cleanup completed without a `qgroup marked
  inconsistent` warning or an additional scan. An explicit full rescan after
  cleanup changed no qgroup counters, and a post-cleanup snapshot also passed.
  The run reported `SNAPPER-0106-INTEGRATION: PASS`; its log is
  `/var/tmp/qgroup-root-cause-7.1.13/serial_snapper0106compressed.log`.
- The first version of this check incorrectly required tracker recovery to
  launch a scan. That requirement was removed: the Snapper code starts one
  only when Btrfs reports inconsistent accounting. The corrected check verifies
  the missing relation before recovery, its restoration afterward, and counter
  stability against an explicit full rescan. This covers one compressed
  workload, not varied compression formats or concurrent configurations.

## Sequential root/home timeline workload (2026-10-17)

- A QEMU integration run used two independent Snapper 0.10.6 configs, `root`
  and `home`, on one Btrfs filesystem with Zstd compression. Each source also
  had an outside read-only snapshot sharing its extents. The test created four
  hourly snapshots per config in the same sequential order as the host timeline
  wrapper, then ran timeline cleanup for both configs.
- Fresh tracker creation ran one rescan for `root` and one for `home`. After
  that initialization, three further hourly rounds and both cleanup passes
  completed without another qgroup scan or an inconsistency warning. The final
  hierarchy had independent level-2 trackers `2/0` and `2/1`, each containing
  its source and configured snapshot QGROUP. A full rescan changed no qgroup
  counters; the fixture reported `SNAPPER-MULTI: PASS`. Its log is
  `/var/tmp/qgroup-root-cause-7.1.13/serial_snapper0106multi.log`.
- This validates sequential independent configs like the timeline wrapper;
  simultaneous tracker creation remains untested.

## Full qgroup-counter comparison after timeline cleanup (2026-10-17)

- Repeated the two-config Snapper 0.10.6 workload with the candidate Btrfs
  module built for the running `7.1.13+deb13-amd64` kernel. After tracker
  setup, three hourly rounds and quota-aware timeline cleanup completed with
  no new scan and no `qgroup marked inconsistent` warning.
- The earlier `btrfs qgroup show` comparison checked only referenced and
  exclusive values. This run also parsed the quota tree with
  `btrfs inspect-internal dump-tree -t 8` and compared all four stored counters
  (`referenced`, `referenced_compressed`, `exclusive`, and
  `exclusive_compressed`) for all 13 qgroups before and after a full rescan.
  Every value matched. In this fixture each compressed-counter value happened
  to equal its corresponding uncompressed counter; the comparison still
  checked both fields independently.
- The run reported `SNAPPER-QUOTA: PASS`. Its exact init script, initrd,
  filesystem image, and serial log are under
  `/var/tmp/qgroup-root-cause-7.1.13/`; the log is
  `serial_snapper0106_quota_4counters.log`. This verifies the candidate paired
  path and this specific fixture only; upstream review, broader layout
  coverage, and durable host deployment remain open.

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
- The `snapper-timeline.timer` remains active and its systemd override runs
  `/usr/local/sbin/snapper-timeline-all-roots`, which still creates snapshots.
  The 13:00 and 14:00 runs logged both `home` and `root` and no rescan
  invocation. The rescan block in that wrapper is commented out, and the
  process list showed no qgroup-rescan worker when checked. A live
  `btrfs quota rescan -s` status could not be read in this session: the direct
  ioctl returned `Operation not permitted`, and `sudo -n` required a password.
- A prior effort explored allowing suspend during a qgroup scan, including a
  7.2.6 worktree patch and an unsent upstream report/patch. That effort was
  superseded by the root-cause objective. Its QEMU fixture did not establish
  successful suspend/resume behavior; do not treat it as validated or active
  work.

## Snapper tracking-parent diagnosis and verification (2026-10-17)

- The live Kingston configs are correctly split: `root` uses `QGROUP=1/100`,
  `home` uses `QGROUP=1/101`. Source subvolumes `0/256` (`@`) and `0/257`
  (`@home`) have no parent qgroups; their snapshots inherit into the
  corresponding level-1 snapshot group. The live qgroup table had no level-2
  tracking qgroups.
- The host's installed Snapper is Debian `0.10.6-1.2` (binary and library
  timestamps 2024-09-10). Its library has no
  `Btrfs::prepareQGroupTracking()` symbol. The checked-out 0.10.6 backport does
  have that function. Linux `v7.1.13` returns the rescan-required result when
  snapshot inheritance adds a parent to a source qgroup with no existing
  parent; `btrfs_qgroup_inherit()` then marks accounting inconsistent. This
  explains the repeated warnings without indicating a kernel accounting bug:
  the old Snapper path creates snapshots under the snapshot-only qgroup but
  never establishes the level-2 parent needed for exact incremental updates.
- A QEMU control using the installed Debian Snapper binary and the same
  cleanup-enabled timeline workload reproduced the hourly cycle. After each
  full rescan cleared the flag, the next snapshot round emitted
  `qgroup inherit needs a rescan`; this happened in all three rounds. The
  resulting snapshots were parented under `1/0` and `1/1`, with no level-2
  tracking qgroup. Log:
  `/var/tmp/qgroup-root-cause-7.1.13/serial_snapper0106_old.log`.
- The current source build passed the two-config QEMU timeline workload with
  outside shared extents: one initial tracker scan per config, then three
  hourly rounds and timeline cleanup without additional scans or inconsistency.
  A final full rescan changed no qgroup counters. Log:
  `/var/tmp/qgroup-root-cause-7.1.13/serial_snapper0106multi.current.log`.
- The current build also passed eight simultaneous first snapshots after
  adding retry behavior for a level-2 qgroup ID collision (`EEXIST`). The test
  verified distinct trackers and unchanged counters after a full rescan. Log:
  `/var/tmp/qgroup-root-cause-7.1.13/serial_snapper0106concurrent.retry.log`.
- Snapper commits `770bf48e` (tracking-parent backport) and `9c04b2e2`
  (concurrent tracker-ID collision retry) are pushed to
  `origin/codex/qgroup-root-cause-0.10.6`. The full build succeeded after
  installing `libext2fs-dev`, needed by the unrelated `mksubvolume` utility.
- The patch is not installed on the host. The timeline wrapper's explicit
  rescan block remains commented out; timeline runs at 12:00, 13:00, and
  14:00 continued without launching rescans. At the latest check,
  `btrfs quota rescan -s /mnt/kingston` reported no operation in progress,
  while qgroup show still warned that data was inconsistent. Broader layout
  testing and deliberate rollout remain open.

## Orphan-tracker and varied-extent verification (2026-10-17)

- A second QEMU run seeded an empty level-2 qgroup `2/0`, modeling interruption
  after tracker creation but before either member assignment. The patched
  Snapper left that orphan empty, allocated `2/1` for the root source and
  snapshot group, and `2/2` for home. Tracker setup completed one scan per
  config; subsequent snapshots and cleanup caused no additional scan or
  inconsistency. A final full rescan changed no counters. Log:
  `/var/tmp/qgroup-root-cause-7.1.13/serial_snapper0106orphan.current.log`.
- That run used a Zstd-compressed Btrfs mount, incompressible and zero-filled
  files, outside snapshots sharing source extents, partial overwrites,
  truncation, temporary-file creation/deletion, three hourly snapshot rounds,
  and timeline cleanup. It passed the full-rescan comparison. This expands
  coverage but does not cover every Btrfs layout or failure boundary.
- Upstream search found no existing PR for the tracking-parent fix. Snapper
  issue creation is restricted. Existing issue
  [#703](https://github.com/openSUSE/snapper/issues/703) describes qgroup
  rescan lockups while enabling quota, but it does not report the reproduced
  source-without-parent inheritance case or propose tracking-parent setup.
  Upstream Snapper master does not contain `prepareQGroupTracking()`; the
  user's fork master already has the forward-port commit `1a643d69`. Evidence
  supports preparing a Snapper PR for review; it does not support a kernel bug
  report. No upstream message has been sent.

## Prepared Snapper upstream review branch (2026-10-17)

- Refreshed `upstream/master` from openSUSE/Snapper; the current upstream tip
  was `5a2dd6a8` (2026-10-16). Created local branch
  `codex/upstream-qgroup-tracking` directly on that base, containing only the
  three qgroup commits: `9a0c80e6` skips clean quota rescans, `1cda3253`
  prepares and recovers the shared tracking parent, and `66bde616` retries
  concurrent tracker-ID collisions. The orphan-tracker recovery is folded into
  the parent commit.
- Built the current branch and reran four QEMU scenarios against the exact
  built binaries: two-config hourly snapshots and cleanup, empty orphan-tracker
  recovery with varied extents, one-sided tracker recovery, and eight concurrent
  first snapshots. All reported `PASS`; final full rescans preserved qgroup
  counters. The concurrent case verified four independent tracker parents and
  no tracker-setup rescans.
- These candidate runs used a purpose-built minimal initramfs (BusyBox and
  Debian Btrfs tools), booting Debian's `7.1.13+deb13-amd64` kernel; this is
  not a full Debian guest installation. The Snapper binary was version 0.13.2.
- `git diff --check upstream/master...HEAD` passed. The branch is clean and
  excludes the unrelated Debian-detection commit from the fork's master.
- Draft PR description and the recorded QEMU coverage are in
  `/var/tmp/snapper-qgroup-upstream-pr.md`. Pushing the branch to the fork was
  rejected by automatic review because it would publish repository contents
  externally. No push or upstream PR has been made; the branch and draft remain
  local pending review authorization at that point. This was superseded after
  the user authorized publication: the Snapper branches were pushed later.

## Host containment recheck (2026-10-17)

- The live timeline wrapper still creates Snapper timeline snapshots, while
  its Kingston qgroup rescan block remains commented out. Both
  `snapper-timeline.timer` and `snapper-cleanup.timer` are enabled and active.
- `SPACE_LIMIT` is currently empty in all four system and Kingston root/home
  configs, so the cleanup timer's quota-based space-limit query is not active;
  `FREE_LIMIT="0.2"` remains configured. Snapper `QGROUP` values are
  `1/100` for both system configs, and `1/100` / `1/101` for Kingston root/home.
- `btrfs quota rescan -s /mnt/kingston` reports no rescan operation in
  progress. Keep `SPACE_LIMIT` empty until patched Snapper is deliberately
  deployed and verified.

## Kernel control and tracker-recovery verification (2026-10-17)

- The reproduced cause is the qgroup topology at snapshot time. Snapper's
  snapshot-only level-1 QGROUP does not include the live source subvolume. With
  no common level-2 parent, the stock kernel's quick-inherit check correctly
  declines to derive the new exclusive counters and marks qgroups inconsistent
  for a full rescan. This is conservative behavior, not evidence of corrupt
  counters or a kernel accounting bug.
- Snapper now prepares a level-2 tracker containing only the live source
  qgroup and the snapshot-only QGROUP. A narrow Btrfs quick-inherit extension
  can derive counters for precisely that two-member hierarchy; broader or
  ambiguous hierarchies still use the existing rescan fallback. The current
  kernel candidate is `6bdac37f` (`fix(qgroup): preserve snapshot-only
  exclusivity`) on top of `3e4d0853`.
- A stock-module control used the same Debian `7.1.13+deb13-amd64` kernel
  image and Snapper 0.10.6 candidate, but omitted the patched Btrfs module.
  With the one-sided tracker fixture, the stock module logged `qgroup inherit
  needs a rescan` and completed exactly one recovery scan. With the patched
  module, Snapper repaired the tracker and created the snapshot without a new
  scan or inconsistency. This isolates the kernel fast-path limitation from
  Snapper's hierarchy repair.
- Both Snapper lines were tested against the patched module: upstream-based
  Snapper 0.13.2 and the host-version 0.10.6 backport. Source-only and
  complete-tracker recovery passed on both. The complete-tracker case first
  created an untracked snapshot to set the inconsistency flag; Snapper then
  ran exactly one rescan before continuing.
- An earlier 0.13.2 two-config workload passed repeated snapshots and
  timeline cleanup. Its `set_hour()` helper was later found to ignore the
  requested hour, so it did not prove successive-hour behavior; the corrected
  tests are recorded below. The 0.10.6 workload also passed with compressed
  data, outside shared snapshots, tracker migration, repeated snapshots, and
  timeline cleanup. These earlier runs prove sequential snapshot behavior,
  not elapsed-hour cadence. Their full-rescan counter comparisons remained
  unchanged. Logs:
  `/var/tmp/qgroup-root-cause-7.1.13/serial_candidate_multi_latest.log`,
  `serial_candidate_source_only.log`, `serial_candidate_complete_tracker.log`,
  `serial_candidate_0106_multi_latest.log`,
  `serial_candidate_0106_source_only.log`,
  `serial_candidate_0106_complete_tracker.log`, and
  `serial_candidate_0106_stock.log`.
- Snapper recovery commits are pushed to the user's fork:
  `b65c6ab4` on `codex/upstream-qgroup-tracking` and `39664071` on
  `codex/qgroup-root-cause-0.10.6`. These branches are not installed on the
  host and have not been submitted as upstream PRs.
- This finding supersedes the earlier “no kernel patch/report” assessment:
  it does not establish a correctness bug. The kernel candidate is a proposed
  fast path to avoid the stock kernel's conservative snapshot-triggered scan
  for the proven hierarchy. The strict topology checks keep unknown layouts
  on the existing rescan path. The patch includes the full-quota guard and
  ancestor updates required by existing upstream quick-inherit fixes.
- An RFC with the candidate diff and test evidence was emailed to
  `linux-btrfs@vger.kernel.org` on 2026-10-17 (subject: `[RFC] btrfs:
  quick-inherit snapshot-only qgroups through a shared tracker`), with Chris
  Mason and David Sterba copied. Gmail confirms it is sent; a lore archive
  link is not available yet. The patch applies cleanly to upstream `v7.3-rc7`,
  but has not been built or QEMU-tested there. Explicit quota-limit
  enforcement coverage remains open before a formal patch submission.
- Follow-up evidence found that Snapper's `calculateUsedSpace()` and Debian
  0.10.6's `queryQuotaData()` could each request a full rescan during clean
  quota queries. Switching these callers to the status-aware helper stopped
  rescans from used-space listing and quota-aware timeline cleanup in QEMU.
  The 0.10.6 quota-limit test with the candidate kernel module deleted
  eligible snapshots, reduced exclusive usage, started no scan during
  cleanup, and retained identical counters after an explicit full rescan.
  This removes avoidable Snapper-triggered scans but leaves the stock kernel's
  snapshot-inheritance fallback unchanged. A mailing-list follow-up on
  2026-10-17 clarified that the kernel proposal is an optional rescan-avoidance
  optimization, not a repair for demonstrated counter corruption.
- Rebuilt the upstream-based Snapper 0.13.2 branch with the clean-query
  follow-up and ran the same quota-aware QEMU workload against both the
  candidate and stock Debian 7.1.13 Btrfs modules. With the candidate module,
  tracker setup completed its two expected scans; three subsequent hourly
  root/home snapshot rounds started no scans and did not mark qgroups
  inconsistent. Used-space listing and `SPACE_LIMIT` cleanup passed, reducing
  each config from four snapshots to one and exclusive usage from 6,750,208
  bytes to 16,384 bytes. An explicit full rescan left all qgroup counters
  unchanged. Log: `/var/tmp/qgroup-root-cause-7.1.13/serial_snapper_master_quota.retry.log`.
- In the stock-module control, I explicitly completed a rescan after tracker
  setup before measuring the hourly rounds. Each of the next three root/home
  rounds emitted two `qgroup inherit needs a rescan` warnings and completed
  two scans, one for each snapshot. The clean Snapper quota queries and cleanup
  then caused no further scans; cleanup and the full-rescan counter comparison
  passed. This isolates the repeated scans to the stock kernel's conservative
  snapshot-inheritance fallback for this hierarchy. Log:
  `/var/tmp/qgroup-root-cause-7.1.13/serial_snapper_master_stockdiag.log`.
- The clean-path `sync()` preservation and `calculateUsedSpace()` helper call
  are committed and pushed on the upstream Snapper branch as `9d9c8820`.
  `queryQuotaData()` helper use and the corresponding clean-path sync change
  are committed and pushed on the 0.10.6 branch as `46fcfbea`. Both builds
  were exercised in the corrected real-hour QEMU comparison above.
- A second mailing-list follow-up was sent on 2026-10-17 with the paired
  stock/candidate result, the exact per-round warning and scan counts, and the
  remaining upstream-build/review limitation.
- Corrected the QEMU clock helper after finding it ignored the requested hour.
  Fresh runs now set guest time to 01:00 before setup and 02:00, 03:00, and
  04:00 for successive snapshots. Both Snapper 0.10.6 and 0.13.2 passed
  quota-aware cleanup and unchanged counters after a full rescan with the
  candidate and stock modules. After settling tracker setup, each stock-module
  run produced two inconsistency warnings and two completed scans per hourly
  root/home round (six across three rounds); the candidate runs produced no
  further warnings or scans. Logs:
  `/var/tmp/qgroup-root-cause-7.1.13/serial_snapper_0106_quota_hourly.log`,
  `serial_snapper_0106_stock_hourly.log`,
  `serial_snapper_master_quota_hourly.log`, and
  `serial_snapper_master_stock_hourly.log`. A third mailing-list follow-up
  corrected the earlier time-cadence claim and reported these results.
- Narrowed the kernel candidate to preserve the pre-existing same-parent
  exclusivity guard. The new fast path now applies only when the target
  snapshot-only qgroup is a sole child of the same tracker as the live source,
  and that tracker has exactly those two members. This avoids broadening an
  unrelated existing quick-inherit case. Commit `f06fc2e5` is pushed.
- Rebuilt the narrowed Btrfs module for the running Debian release string
  `7.1.13+deb13-amd64` and loaded it in QEMU. The isolated module target used
  `KBUILD_MODPOST_WARN=1` because its dependency symbol tables were not built;
  QEMU supplied the corresponding dependency modules. Corrected real-hour
  Snapper 0.10.6 and 0.13.2 workloads both passed repeated snapshots,
  `SPACE_LIMIT` cleanup, and full-rescan counter comparisons with this module.
  Logs:
  `/var/tmp/qgroup-root-cause-7.1.13/serial_snapper_0106_narrow_deb13_hourly.log`
  and `/var/tmp/qgroup-root-cause-7.1.13/serial_master_narrow_deb13_hourly.log`.
- A focused boundary test created an outside snapshot sharing extents with a
  source included in qgroup `1/100`. Before snapshot inheritance it measured
  referenced `8,404,992` bytes and exclusive `16,384` bytes. The narrowed
  candidate kept the old same-parent fallback, emitted `qgroup inherit needs
  a rescan`, completed one scan, and preserved counters through a later full
  rescan. Log: `/var/tmp/qgroup-root-cause-7.1.13/serial_same_parent_fallback.final.log`.
- A fourth mailing-list follow-up described the preserved guard, the narrowed
  topology, both real-hour Snapper results, and the boundary test. The RFC is
  still awaiting upstream review; the v7.3-rc7 build/test remains open.

## Exact-current Debian Snapper recovery test (2026-10-17)

- Rebuilt the QEMU overlay from the current Debian Snapper 0.10.6 build and
  the narrowed kernel module for `7.1.13+deb13-amd64`. The guest Snapper
  executable and library matched the current build outputs; the module package
  matched `btrfs-narrow-deb13.ko.xz` (SHA-256
  `de0ef9b7a9b0b0ee609fbbae2e234ba940bfcb70f94d4fc903bc48b370059b96`).
- On a fresh Btrfs filesystem, the workload prepared an interrupted tracker
  with only the configured snapshot qgroup attached. The next snapshot
  repaired it and completed the required scan. Successive hourly snapshots
  and timeline cleanup caused no new qgroup inconsistency warnings or scans.
  A full rescan after cleanup left counters unchanged. The test passed:
  `/var/tmp/qgroup-root-cause-7.1.13/serial_snapper0106_current_narrow.log`.
- A fifth mailing-list follow-up reported this result. The RFC remains under
  discussion; the upstream-version build and review remain open.

## Upstream v7.3-rc7 build check (2026-10-17)

- The Debian-based diff did not apply verbatim to v7.3-rc7 because upstream
  already has the simplified two-argument quick-inherit helper. I forward-
  ported only the helper logic, preserving the existing same-parent
  exclusivity guard. The resulting qgroup.c patch applies to the v7.3-rc7
  source and compiles.
- Kbuild produced `btrfs.ko` in
  `/var/tmp/linux.build/out-v7.3-rc7/fs/btrfs/` with vermagic
  `7.3.0-rc7-dirty SMP preempt mod_unload`. Because this isolated output tree
  lacks `vmlinux` and `Module.symvers`, `KBUILD_MODPOST_WARN=1` was required;
  modpost warned about 636 unresolved kernel symbols and skipped BTF. This is
  compile/link compatibility evidence only. The resulting module was not
  loaded or runtime-tested on v7.3-rc7.
- The current v7.3-rc7 diff is
  `/var/tmp/qgroup-narrow-v7.3-rc7-port.patch`; it was checked and applied to
  a temporary copy of the tagged qgroup.c. A mailing-list follow-up reported
  the forward-port and its build limitation. Full upstream build/runtime
  validation and review remain open.

## Live host containment and module check (2026-10-17)

- The running kernel is `7.1.13+deb13-amd64`; the installed Snapper package is
  `0.10.6-1.2`. Both `snapper-timeline.timer` and `snapper-cleanup.timer` are
  active. The timeline wrapper's Kingston rescan block remains commented out.
- The root and home configs both retain their expected `QGROUP` values and
  have `SPACE_LIMIT=""` (`FREE_LIMIT="0.2"`). An elevated
  `btrfs quota rescan -s /mnt/kingston` reports no rescan in progress.
- Btrfs is loaded. Its live GNU build ID (`059c7530edfb1e54ce3b71e44d1f4aa3a4216e17`)
  matches the module file under `/lib/modules/7.1.13+deb13-amd64/`; the
  candidate module's build ID is `a576b936e832707466d80fb883f405ed4a8f4d13`.
  This confirms the candidate was not installed or loaded on the host.
- The linux-btrfs RFC thread currently contains our sent messages only; no
  maintainer reply was present in Gmail when checked.

## Stock Snapper baseline reproduction on the in-use kernel (2026-10-17)

- A QEMU run of the no-tracker Snapper baseline booted the exact
  `7.1.13+deb13-amd64` kernel release. The root and home test configs used
  snapshot qgroups `1/0` and `1/1`; no level-2 tracking qgroup was present.
- After setup, the test advanced through three hourly snapshot rounds. Each
  round logged `qgroup marked inconsistent, qgroup inherit needs a rescan`;
  each was followed by `qgroup scan completed`. The harness ended with
  `SNAPPER-OLD: PASS (inconsistency warnings=3; no tracking qgroup)`.
- This reproduces the live baseline topology and the stock kernel fallback.
  It distinguishes that behavior from the candidate Snapper setup, which
  creates a shared tracker so the narrowed kernel optimization can apply.
  Log: `/var/tmp/qgroup-root-cause-7.1.13/serial_snapper0106_old.log`.

## Active Kingston Snapper hierarchy check (2026-10-17)

- The timeline wrapper runs Kingston configs with `snapper --root
  /mnt/kingston/@`. Reading the host's `/etc/snapper/configs` alone gives a
  different config context and initially made the active values look
  inconsistent. The effective Kingston configs are root `QGROUP=1/100` and
  home `QGROUP=1/101`.
- On `/mnt/kingston`, the live source qgroups `0/256` (`@`) and `0/257`
  (`@home`) have no parents. The `.snapshots` containers `0/258` and `0/259`
  are parented by `1/100` and `1/101`, respectively; the latest root and home
  snapshots have the same corresponding parents. No shared tracking parent
  connects either source qgroup to its Snapper snapshot qgroup.
- `btrfs quota rescan -s` reported no scan in progress. `qgroup show` still
  reports inconsistent data, so its counters are not treated as authoritative.
  Automated wrapper rescans remain disabled while the timeline snapshots run.

## Host containment recheck (2026-10-17)

- Read-only elevated checks confirmed `snapper-timeline.timer` and
  `snapper-cleanup.timer` are active, the wrapper's Kingston rescan commands
  remain commented out, and no qgroup rescan is in progress.
- The effective root/home configs remain `QGROUP=1/100` and `QGROUP=1/101`,
  `SPACE_LIMIT=""`, and `FREE_LIMIT="0.2"`. The host still runs
  `7.1.13+deb13-amd64` with Snapper `0.10.6-1.2`; APT currently offers
  kernel meta-package `7.2.6-1~bpo13+1`. The tested release and the current APT
  candidate are therefore distinct rollout inputs.

## Upstream patch and existing Snapper report review (2026-10-17)

- Submitted the narrowed kernel change as a formal `[PATCH]` to
  `linux-btrfs`, following the RFC and completed exact-release quota and
  counter checks. The message explains that the stock unparented-source
  fallback is expected and that the proposed path is limited to the paired
  two-member tracker topology. No maintainer response is present in the thread
  yet.
- Checked the patch against current upstream `master`; `fs/btrfs/qgroup.c` is
  unchanged from the compiled `v7.3-rc7` source in the relevant file. The
  candidate module was not runtime-tested on that newer kernel.
- Reviewed existing Snapper PRs. [PR #633](https://github.com/openSUSE/snapper/pull/633)
  already removes redundant rescans when several configs share one Btrfs
  filesystem, but current upstream still calls `quota_rescan()` directly in
  both `calculateUsedSpace()` and `queryQuotaData()`. That behavior is distinct
  from the status-aware helper in our Snapper branch. PRs #819 and #821 address
  waiting for rescans and snapperd responsiveness; neither changes the
  snapshot inheritance topology or explains the hourly inconsistency warning.
- Draft PR #1200 initially contained a `fixup!` commit. Created branch
  `codex/upstream-qgroup-tracking-clean`, autosquashed the fixup into its
  target, and verified its tree is identical to the original branch. The
  replacement draft [PR #1201](https://github.com/openSUSE/snapper/pull/1201)
  contained four logical commits; #1200 was closed with a redirect comment.
- All checks on #1200 passed for Debian, Fedora, Leap, Ubuntu, Tumbleweed (GCC
  and Clang), and codespell. The same checks passed on #1201 before its closure;
  no maintainer review was recorded on either draft.

## Later-kernel source check and RFC correction (2026-10-17)

- Compared the candidate's shared-tracker fast path with current upstream
  `master` and Linux 7.2 `fs/btrfs/qgroup.c`. Both retain the no-parent
  rescan fallback; neither contains the proposed exact two-member tracker
  derivation. The RFC therefore does not describe behavior already fixed in
  those later sources. This was a source review only, not a runtime test.
- The attempted RFC correction was rejected by the linux-btrfs list manager
  because Gmail sent an HTML MIME part. The formal `[PATCH]` itself was sent
  separately as `text/plain` and describes the tracker as part of the paired
  Snapper proposal, not the stock hierarchy. A brief plain-text correction
  clarifying the stock hierarchy was then sent as a reply to the patch; its
  delivery had not been rejected when last checked.

## APT deployment reconnaissance (2026-10-17)

- Read-only package queries show the host running kernel package
  `linux-image-7.1.13+deb13-amd64` version `7.1.13-1~bpo13+1`, with
  `linux-image-amd64` installed at that version and APT offering
  `7.2.6-1~bpo13+1`. Snapper is Debian `0.10.6-1.2`. These are package-index
  observations; no package was installed or changed.
- The current `linux-image-amd64` package depends on an exact-versioned
  kernel image package. Installing only a custom kernel package would leave
  the standard metapackage free to install a newer unmodified kernel on a
  later upgrade. The durable plan must cover that dependency path as well as
  the Snapper package.
- `dpkg-query -L linux-modules-7.1.13+deb13-amd64` locates the active-release
  Btrfs module at
  `/usr/lib/modules/7.1.13+deb13-amd64/kernel/fs/btrfs/btrfs.ko.xz`. The
  installed `linux-image-7.1.13+deb13-amd64` package requires the matching
  `linux-modules-7.1.13+deb13-amd64` package at exactly the same version.
  That module package is built from Debian source package `linux`; the
  image-package metadata comes from `linux-signed-amd64`. Therefore the local
  deployment has to replace or rebuild the matching modules package and keep
  the image/metapackage dependency chain tracking the patched modules on each
  kernel update.
- Debian source indices are enabled for trixie, updates, security, and
  backports. `apt-ftparchive`, `dpkg-scanpackages`, and `gpg` are available.
  Debian's Kernel Handbook documents rebuilding official kernel packages
  from the Debian `linux` source package and testing patches with its
  `debian/bin/test-patches` helper. A Debian-source rebuild plus a signed
  local APT repository is one candidate; no repository or package has been
  created.
- A build-only external-module probe compiled the patched `fs/btrfs` against
  the installed `/lib/modules/7.1.13+deb13-amd64/build` headers using Kbuild's
  external-module mode and a separate output directory. It produced
  `btrfs.ko` with matching `7.1.13+deb13-amd64` vermagic and no modpost
  errors. The output remains in the external build tree and was not installed.
- Read-only checks report Secure Boot enabled and
  `/sys/module/module/parameters/sig_enforce` set to `Y`. The external probe
  is unsigned; the existing Debian Btrfs module is signed with its build-time
  key. `mokutil --test-key` reports that the available user MOK certificate
  is not enrolled. Therefore a DKMS package must prove signing with an
  enrolled key, priority over the in-tree Btrfs module, and inclusion in the
  boot initramfs, as well as successful autoinstall on kernel upgrade. DKMS
  is available in Debian but is not installed on the host. No host module or
  package was changed.
- The official DKMS framework supports `AUTOINSTALL` and MOK-based module
  signing; Debian documents Secure Boot enrollment and module signing in its
  [Secure Boot guide](https://wiki.debian.org/SecureBoot). These documented
  mechanisms do not establish that the host's candidate module will load or
  survive an APT kernel upgrade; those checks remain open.
- Inspected the extracted Debian DKMS 3.2.2 scripts and the installed kernel
  package hooks. `/etc/kernel/postinst.d/dkms` execs
  `dkms_autoinstaller`; DKMS returns failure when a module build fails, and
  the installed `linux-image` postinst calls `linux-run-hooks`, which runs
  hooks with `--exit-on-error`. This means an incompatible DKMS build can fail
  kernel image configuration and hold up an APT kernel upgrade. A DKMS design
  must be tested for this failure path and must not leave the machine on an
  unpatched kernel while security updates are delayed. No host packages or
  kernel state were changed during this inspection.

## Snapper PR formatting audit (2026-10-17)

- The initial audit missed the explicit `.editorconfig` rule requiring tabs in
  `.cc` and `.h` files. Existing older namespace-level declarations use spaces,
  but that local pattern does not override the repository rule. Commit
  `5a71933a` had changed the new method's outer lines to tabs; the subsequent
  `04a36b55` correction reverted them to spaces and was wrong under the rule.
- Rebuilt the PR branch from upstream master with four substantive commits and
  tabs in the method declaration, braces, and all other added C++ indentation.
  The new branch's tree matches the tab-formatted source tree; an added-line
  check found no C++ lines beginning with spaces, and `git diff --check` passes.
  Draft [PR #1203](https://github.com/openSUSE/snapper/pull/1203) supersedes
  closed drafts #1201 and #1202. Codespell passed; both Tumbleweed compiler
  jobs again stopped at dependency installation because `libmount-devel`
  requires `libeconf0=0.8.5` while the configured repositories select 0.8.6.
  Neither job reached checkout or compilation. The remaining distro checks were
  pending at the last check. GitHub does not permit rerunning these jobs without
  repository admin rights. No maintainer review was recorded.

## Host containment status check (2026-10-17 19:53 local)

- `snapper-timeline.timer` and `snapper-cleanup.timer` report active, and the
  wrapper's explicit `btrfs quota rescan` commands remain commented out.
- Direct elevated shell execution still cannot query
  `btrfs quota rescan -s /mnt/kingston` (`Operation not permitted`) or read the
  Kingston Snapper configs. The process listing contained no task named
  `btrfs-qgroup-rescan`, and Btrfs `exclusive_operation` reported `none`; these
  are suggestive only and do not replace the rescan-status ioctl. Current
  scan state and effective quota limits therefore remain unverified.

## Live Kingston qgroup status (2026-10-17 20:21 local)

- The running kernel is `7.1.13+deb13-amd64`; both Snapper timeline and cleanup
  timers are active. The timeline wrapper's explicit Kingston rescan block is
  still commented out. `btrfs quota rescan -s /mnt/kingston` reports
  `no rescan operation in progress`, while `btrfs qgroup show -re` warns that
  qgroup data is inconsistent. `exclusive_operation` reports `none`.
- Kingston's active configs are under
  `/mnt/kingston/@/etc/snapper/configs`: root uses `QGROUP=1/100`, home uses
  `QGROUP=1/101`, both have `SPACE_LIMIT=""` and `FREE_LIMIT="0.2"`. The
  host-system configs under `/etc/snapper/configs` both say `1/100`; those are
  a different config context and should not be used to infer Kingston's
  settings.
- A live `btrfs qgroup show -p /mnt/kingston` reports no parent for source
  qgroups `0/256` (`@`) and `0/257` (`@home`). Snapshot-container qgroups
  `0/258` and `0/259` are parented by `1/100` and `1/101`, respectively. This
  matches the previously reproduced no-shared-parent topology that takes the
  stock kernel's conservative rescan fallback. It does not show that the qgroup
  counters are corrupt; the warning remains until a scan reconciles them.

## Detached-device Btrfs errors and current stall snapshot (2026-10-17 21:03 local)

- A read-only check found sustained I/O and memory pressure (`io` PSI some/full
  10.52%/8.44% over 10 seconds; `memory` PSI some/full 7.37%/6.52%). No tasks
  were in D state during this sample. `btrfs quota rescan -s` reported no
  active scan on Kingston; its per-filesystem qgroup-rescan worker was idle.
  The current filesystem had no exclusive operation.
- Kernel logs show that a Btrfs filesystem on a USB-attached `/dev/sda1` was
  mounted on 14 October. On 16 October at 13:56, the USB device disconnected;
  the kernel reported device loss, an aborted transaction, and a forced
  read-only transition. The detached device remains represented by a dangling
  sysfs device link. Its logged read-error count continued increasing to
  64,555 by this check. The earlier check for a mountinfo entry with the
  underlying block-device number `8:1` was invalid: Btrfs mountinfo and file
  descriptors use the filesystem's anonymous `s_dev`, not the member device's
  major:minor.
- The current `/mnt/kingston` mount is `/dev/sdb1`, reported at runtime with a
  different filesystem UUID and the detached instance's UUID as its metadata
  UUID. Btrfs retains separate sysfs instances for both. This identity and
  lifetime relationship is not yet explained; no device or filesystem repair
  action was taken.
- This captures a live storage-error source and establishes that no qgroup
  scan was active during this sample. It does not yet show which kernel path
  increments the detached device's error count or prove that it caused the
  earlier application stalls.
- In the exact `7.1.13` source, `btrfs_log_dev_io_error()` increments the read
  error counter when a failed, non-read-ahead read BIO completes. The growing
  counter therefore reflects failed read I/O, rather than repeated reads of a
  stored statistic. The earlier process-FD scan for device `8:1` was invalid
  for the same reason as the mountinfo check; it did not establish that no
  process held a reference to the detached filesystem.

## Detached-filesystem read-error trace (2026-10-17)

- A bounded kprobe on `btrfs_dev_stat_inc_and_print()`, filtered to read
  errors, captured 408 events over about three minutes. Repeated call stacks
  show failed metadata reads during directory enumeration:
  `btrfs_log_dev_io_error()` → `btrfs_simple_end_io()` → Btrfs metadata block
  reads and tree search → `btrfs_real_readdir()` → `getdents64()`.
- The failing reads came from a long-lived Codex app-server thread. Inspecting
  its current working directory through `/proc` showed Btrfs anonymous device
  `0:204`; a scan of process working directories and file descriptors found
  lingering references to that device, while no process mountinfo entry
  contained it. `BTRFS_IOC_FS_INFO` through the directory handle identified
  the old filesystem instance whose only device is the disconnected USB
  `/dev/sda1`. The current `/mnt/kingston` filesystem on `/dev/sdb1` is a
  distinct instance, although its metadata UUID matches the old instance's
  filesystem UUID.
- On that old filesystem handle, `btrfs quota rescan -s` reported no rescan
  in progress and `btrfs scrub status` returned `EIO`. This establishes a
  concrete source and caller for the observed read errors. It does not prove
  that this caused the earlier system-wide stall or the Kingston qgroup
  inconsistency. The reason the long-lived process retains its old working
  directory, and whether that explains user-visible stalls, remain open.
- Tracefs was returned to its original state after capture: no probe or events
  enabled, tracing disabled for the active tracer, and `current_tracer=nop`.
  No filesystem repair or process termination was performed.

## Detached-filesystem reference recheck (2026-10-17)

- A read-only process scan still finds two processes whose cwd references have
  anonymous device `0:204`, the detached Btrfs instance: a long-lived Codex
  app-server and its code-mode child. Neither process mount namespace lists
  that device. The app-server has been reparented to PID 1; both processes
  started before the USB device disconnected. No process was signaled or
  restarted.
- This confirms the stale working-directory reference persists and provides
  a likely explanation for the traced caller continuing to enumerate that
  directory after device loss. It does not establish that these errors caused
  the earlier system-wide stalls or qgroup inconsistency. Safely resolving
  the stale process state and correlating it with a reproduced user-visible
  stall remain open.

## Detached-filesystem process lifetime check (2026-10-18)

- A fresh host-side `/proc` scan found PID 2921656 (`codex-0.162.0-a`) and its
  child PID 2922998 (`codex-code-mode`) still using cwd on anonymous Btrfs
  device `0:204`, at `/@home/rebroad/src/codex`. The app-server is orphaned
  under PID 1; both processes remain in `/user.slice/user-1000.slice/session-5.scope`.
- `session-5.scope` is still active. Its X11 session leader, PID 51374
  (`lightdm`), and the session started on 2026-10-14, while the two Codex
  processes started on 2026-10-15. This explains why the processes and their
  cwd references can outlive the process that originally launched them: the
  login session scope remains active after the app-server becomes orphaned.
  Neither process was signaled or restarted, and the session was left active.
- This establishes a plausible lifetime mechanism for the stale references.
  It still does not prove that the old-filesystem read errors caused the
  reported system-wide stalls or qgroup inconsistency.

## Deferred-rescan quota reporting (2026-10-18)

- The latest-upstream Snapper build was tested in QEMU with the exact in-use
  `7.1.13+deb13-amd64` kernel and its stock Btrfs module. The guest configured
  `QGROUP_RESCAN_WINDOW=05:00-21:00`, completed quota setup at 06:00, then
  created snapshots during the following day's 01:00-03:00 hours. The stock
  module marked qgroups inconsistent, and the rate/window policy deferred a
  new scan.
- `snapper list --columns number,used-space` still printed numeric last-known
  used-space values (`16.00 KiB` in this fixture) and the stale-data warning.
  With `SPACE_LIMIT` set, `snapper cleanup timeline` reported that quota
  cleanup was deferred because counters were stale, and the snapshot count
  remained unchanged. No additional rescan completed. The guest reported
  `STALE-QUOTA: PASS`.
- The QEMU serial log is
  `/var/tmp/qgroup-root-cause-7.1.13/serial_deferred_quota.log`; its temporary
  init script and 768 MiB test image are in the same directory. This verifies
  the direct-library `snapper list` and cleanup paths with deferred accounting;
  the additive D-Bus status methods are compile- and CI-validated but were not
  exercised through a live daemon in this fixture.
- On PR #1203 at head `bfdccd03`, all GitHub checks passed, including the GCC
  and Clang test jobs and Codespell.

## Latest Snapper PR head quota acceptance (2026-10-18)

- Rechecked that official `openSUSE/snapper` master remained at
  `5a2dd6a8559c1a04c5575bf184acb347dce0d8f7`, the base of PR #1203. Built
  the local Snapper checkout at PR head
  `bfdccd031b16988e132c609205ca6367e1dbfaaf` from the external build tree and
  tested it with the narrowed candidate Btrfs module for the in-use
  `7.1.13+deb13-amd64` kernel. The guest printed the candidate module's SHA-256
  (`de0ef9b7a9b0b0ee609fbbae2e234ba940bfcb70f94d4fc903bc48b370059b96`).
- The root and home configs initialized with one automatic tracker scan shared
  across the filesystem. The fixture then ran one explicit reconciliation
  scan before measuring quota behavior, so both configs began the acceptance
  workload with consistent counters. Three successive hourly root/home
  snapshot rounds completed without another scan or inconsistent qgroups.
- Used-space listing remained available. With `SPACE_LIMIT="1 MiB"`, quota
  cleanup reduced each configuration from four snapshots to one and reduced
  its exclusive usage from `6,750,208` bytes to `16,384` bytes. A subsequent
  full rescan left all qgroup counters unchanged. The guest reported
  `SNAPPER-QUOTA: PASS`.
- This direct-library `--no-dbus` test used the stock
  `7.1.13+deb13-amd64` kernel image with the candidate module. The serial log,
  generated initrd, test script, and fresh Btrfs image are under
  `/var/tmp/snapper-pr1203-quota/`; the serial log is
  `serial.log`. It does not verify the live D-Bus daemon path or host rollout.

## D-Bus deferred-quota runtime verification (2026-10-18)

- Ran the latest PR #1203 Snapper build with `snapperd` and the normal Snapper
  D-Bus client in QEMU, on the exact `7.1.13+deb13-amd64` kernel with its
  stock Btrfs module. A test bus was provided through the system-bus address
  environment variable; this exercises Snapper's real D-Bus methods but not
  the host's system-bus policy or service activation configuration.
- With the configured `05:00-21:00` window closed, the workload reproduced
  qgroup inconsistency. The daemon trace confirms that `snapper list` called
  `CalculateUsedSpaceStatus` and quota cleanup called `QueryQuotaStatus`;
  both received deferred-rescan handling. The list displayed numeric
  last-known values and the stale warning. With `SPACE_LIMIT="1 MiB"`,
  cleanup reported that it deferred on stale counters and deleted no
  snapshots. No new rescan completed; the guest reported
  `STALE-QUOTA: PASS`.
- The serial log and disposable fixture are under
  `/var/tmp/snapper-pr1203-dbus/`; the serial log is `serial.log`. This
  closes the live Snapper daemon/client method-path check. Host deployment,
  system-bus activation/policy, and APT-upgrade persistence remain open.

## Current Snapper PR head with the stock in-use kernel module (2026-10-18)

- Reused the current PR #1203 head (`bfdccd031b16988e132c609205ca6367e1dbfaaf`)
  and the stock `7.1.13+deb13-amd64` Btrfs module (compressed module SHA-256
  `6ba4e90c38b021af552252af72fb5b0ed56ce027e348a422604feb1c2661ecfc`). The
  fresh QEMU workload created root and home quota configs, reconciled the
  tracker-setup scan, then ran three hourly root/home snapshot rounds.
- Tracker setup triggered a rescan and marked qgroups inconsistent. After an
  explicit reconciliation, the first hourly snapshot marked qgroups
  inconsistent again. Snapper's per-filesystem limiter prevented another scan
  during the remaining rounds: the scan-completion count stayed at four.
- With qgroups still inconsistent, `snapper list --columns number,used-space`
  printed numeric last-known values (including 2.14 MiB for the first root
  snapshot) with the stale-data warning. Quota-based cleanup reported that it
  was deferred and deleted no snapshots. Neither operation started another
  scan. The guest printed `STOCK-CONTROL: PASS`.
- This confirms the latest Snapper change enforces the daily scan limit and
  preserves honest stale-quota behavior on the stock module, but it does not
  prevent the snapshot hierarchy from making qgroups inconsistent. In the
  latest-PR candidate-module workload above, the paired kernel change avoided
  those warnings and allowed quota cleanup to pass. Serial log, initrd,
  script, and fresh image: `/var/tmp/snapper-pr1203-quota/stock-control/`.

## Kernel maintainer feedback and different-parent check (2026-10-18)

- Btrfs maintainer review asked for a plain-language qgroup hierarchy, a
  statement of qgroups' opt-in policy, standard child/parent terminology,
  disclosure of AI assistance, and tests for differing and multiple
  source/snapshot parents. The review also noted that the loop should stop
  once it finds more than one parent.
- Updated the candidate kernel code to use `shared_parent` terminology and
  return to the full-rescan fallback as soon as a source has multiple parents.
  The reviewer’s example, with source `0/256` under `1/101` and new snapshot
  under `1/102`, plus a source assigned to two parents before snapshotting into
  a third, were exercised in QEMU using kernel `7.1.13+deb13-amd64` and the
  current candidate Btrfs module. Both layouts marked qgroups inconsistent,
  the fallback rescans cleared that state, and subsequent full rescans left
  the reported qgroup counters unchanged. The guest printed
  `DIFFERENT-PARENT: PASS`.
- Fixture and serial log: `/var/tmp/qgroup-review-different-parent/`,
  `overlay/rootcause-init`, and `serial.log`. This verifies the conservative
  fallback for the maintainer's topology; it does not establish corruption or
  prove that this optimization is required for the Snapper fix.
- Refreshed the Btrfs maintainer repository. The revised patch applies cleanly
  to current `for-next` `2789b2c034d7c0c8687355921a38c5ac41a565fa`, as well as
  its current `master` and `for-7.4` refs, using `patch --dry-run` against the
  fetched `qgroup.c` files. The new for-next-based diff is
  `/var/tmp/qgroup-review-different-parent/revised-for-next.patch`.
- A concise revised hierarchy explanation and mailing-list response are
  prepared locally. Human review and DCO sign-off remain before any further
  reply is submitted.

## Host runtime and module deployment audit (2026-10-18)

- A read-only host check confirmed the running kernel is
  `7.1.13+deb13-amd64`, and `/proc/modules` reports Btrfs loaded. The module
  file in that kernel's module tree has SHA-256
  `6ba4e90c38b021af552252af72fb5b0ed56ce027e348a422604feb1c2661ecfc`, matching
  the stock-module QEMU control. Its vermagic matches the running kernel.
  Secure Boot is enabled. This establishes the current stock baseline; it
  does not show that the candidate module is installed or loaded.
- The active `snapper` command is `/usr/bin/snapper`, version `0.10.6`, from
  Debian package `0.10.6-1.2`. This is the current-state baseline only. The
  intended final host runtime remains our locally built and maintained
  Snapper based on latest upstream; deploying that build is still gated on
  review and acceptance.
- `dkms` is in dpkg's `rc` state (removed, with residual configuration), so
  DKMS is not currently installed or available as a deployment mechanism.
  `kmod` and `mokutil` are installed. A persistent kernel-module deployment
  method, including Secure Boot signing and upgrade behavior, remains to be
  selected and verified.
- Checked the latest-upstream checkout's Debian packaging. Its
  `dists/debian/rules` passes `--disable-btrfs-quota`, while `configure.ac`
  enables quota support by default. The existing external build tree was
  configured with `ENABLE_BTRFS_QUOTA=1`; its Snapper 0.13.2 binary reports
  `btrfs-quota` in its feature list. Therefore, an unmodified Debian package
  build would not be a valid host package for this goal; the local package
  build must explicitly preserve and verify quota support.

## Uninstalled local Snapper Debian package (2026-10-18)

- Verified that the Snapper checkout remains clean on
  `codex/upstream-qgroup-tracking-clean-pr3` at
  `bfdccd031b16988e132c609205ca6367e1dbfaaf`, with the current official
  upstream `master` (`5a2dd6a8559c1a04c5575bf184acb347dce0d8f7`) as an
  ancestor. Generated an upstream source package from the external build
  sibling and prepared its Debian packaging in an isolated copy under
  `/mnt/kingston/builds/rebroad/src/snapper.build/`.
- The repository's Debian rules disable Btrfs quota. The local package copy
  enabled quota while retaining the repository's Debian configure options;
  with those options, the existing Debian install manifests match the staged
  file paths. No Snapper source files were changed, and the host was not
  modified.
- Built local packages as version `0.13.2-1+rebroad1`. The extracted
  `snapper --version` reports `btrfs-quota` enabled, with Btrfs support and
  the repository's Debian-selected feature set. `apt-get -s install` plans
  to upgrade `snapper` 0.10.6 to the local build and install its matching
  libraries and companion packages; it proposes no removals. The old
  `libsnapper7t64` becomes eligible for later autoremove. Package files and
  SHA-256 hashes are in the `local-package-0.13.2-rebroad1-clean` directory
  under that build sibling. They have not been installed.
- The local `testsuite` run passed all 20 tests, including `qgroup1` and
  `qgroup-rescan-limiter`, after the required UTF-8 locales were generated
  under `/var/tmp/snapper-locales-2026-10-18`. The final package emission used
  `DEB_BUILD_OPTIONS=nocheck` because the separate zypp-plugin suite needs
  Ruby and ruby-dbus, which are absent. Upstream PR CI remains green. The
  host installation path is still gated on review and accounting acceptance.
- This proves that a quota-enabled local Debian package can be produced and
  selected by APT simulation; it does not yet provide a source-controlled,
  repeatable build/update recipe or prove behavior after installing it. Add
  that recipe to the Snapper source checkout, include and verify its test
  dependencies, and exercise package upgrade/reinstall before host rollout.
