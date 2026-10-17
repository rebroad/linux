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
- The Snapper branch contains five commits, compares cleanly against current
  upstream `master`; draft upstream PR [#1200](https://github.com/openSUSE/snapper/pull/1200)
  is open for review, paired with the kernel change.
- PR checks passed for Debian, Fedora, Leap, Ubuntu, Tumbleweed (GCC and Clang),
  and codespell. No review decision or maintainer review was recorded.

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
