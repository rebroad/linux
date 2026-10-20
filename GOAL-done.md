# Completed investigation evidence

This file records verified findings and completed work for the active checklist
in [`GOAL.md`](GOAL.md). A tracking-parent fix candidate has now passed the
described QEMU snapshot and cleanup workloads on the then-current Snapper build;
broader filesystem coverage and host rollout remain open.

Snapper versions identified as Debian or distribution packages below are
historical diagnostic baselines or QEMU controls only. The intended host
runtime is our locally built Snapper from the latest upstream source, as
specified in `GOAL.md`.

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

- `snapper-cleanup.timer` was enabled and active; the cleanup service was
  inactive at inspection. The system and Kingston `root`/`home` configs all
  had `SPACE_LIMIT="0.5"`, which lets quota-aware cleanup call Snapper's
  rescan-and-wait query. An empty value was then used in an attempt to pause
  quota cleanup; later source review found that empty parsing retains the
  default `0.5`, so this did not disable the quota-aware pass. See the
  correction recorded below.
- Snapshot creation, `QGROUP`, `FREE_LIMIT="0.2"`, and timeline cleanup remain
  configured. `SPACE_LIMIT="0.5"` was intended to be restored after the
  accounting fix, but the later explicit-disable correction below supersedes
  this interim plan:
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
- At this 2026-10-18 pre-correction inspection, `SPACE_LIMIT` was empty in all
  four system and Kingston root/home configs. It was believed to disable the
  cleanup timer's quota-based space-limit query; source review below showed
  that belief was wrong. `FREE_LIMIT="0.2"` remained configured. Snapper
  `QGROUP` values were
  `1/100` for both system configs, and `1/100` / `1/101` for Kingston root/home.
- `btrfs quota rescan -s /mnt/kingston` reported no rescan operation in
  progress at that inspection.

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
- The earlier formal patch did not apply to the then-current development
  branch. A plain-text reply to the reviewer sent on 2026-10-18 acknowledged
  this, explained why the different-parent example intentionally returns to
  the rescan path, clarified that no counter corruption was demonstrated, and
  reported the exact-release different/multiple-parent QEMU checks. The reply
  is in the existing `linux-btrfs` review thread.
- The replacement patch remains local; it applies cleanly to the currently
  fetched `for-next` tip and is not yet resubmitted. The follow-up check below
  records the final diff review and the remaining DCO sign-off gate.

- Rechecked the `for-next` tip directly on the Btrfs maintainer remote on
  2026-10-18; it is still `2789b2c034d7c0c8687355921a38c5ac41a565fa`, and the
  extracted source file matches that ref's `fs/btrfs/qgroup.c` blob. The final
  email patch applies cleanly there and `checkpatch.pl --strict --no-tree
  --no-signoff` reports zero findings. Its commit text includes the qgroup
  topology, exact-kernel QEMU fallback results, and `Assisted-by` disclosure.
  The reviewable email file is
  `/var/tmp/qgroup-review-different-parent/revised-for-next.email.patch`
  (SHA-256 `ba296c63714f5dc36dc9045ebf37541e544ad074cf2d3b8060529c78de43f22d`).
  A regular `checkpatch.pl --strict` run reports only the absent
  `Signed-off-by` trailer; `--strict --no-tree --no-signoff` reports no style
  findings. A fresh zero-fuzz dry run on the current remote tip also applies
  cleanly. No `Signed-off-by` trailer was added; the user's DCO sign-off for
  this exact replacement patch is still required before submission.

- Checked current `torvalds/linux` master through the GitHub API on
  2026-10-18 at `58161ead29e50d70a317ea26b472e0c7508e69da`. Its
  `fs/btrfs/qgroup.c` still has the original same-parent-only quick-inherit
  condition (`list->group->qgroupid != parentid`) and the
  `parent->excl != parent->rfer` guard. It does not include the proposed
  shared-parent optimization, so this change is not already present in that
  mainline tip. This check does not replace checking the maintainer `for-next`
  tip again immediately before resubmission.

## Post-resume Snapper timer audit (2026-10-18)

- The active `snapper-timeline.timer` is an hourly `OnCalendar` timer and was
  due at 06:00 BST after its 05:00 run. The unit has no `Persistent=yes`;
  systemd's timer documentation still specifies that an active calendar timer
  whose event elapses during suspend catches up after resume. `Persistent=`
  only controls catch-up when the timer unit itself was inactive.
- The cleanup timer uses `OnBootSec` and `OnUnitActiveSec`, not a calendar
  event. No enabled `sleep.target` hook directly invokes Snapper or Btrfs; the
  only configured sleep-target symlinks at inspection were GRUB services.
  The `snapper-timeline.service` override runs the all-roots wrapper, whose
  explicit rescan block remains commented out.
- The force-suspend hold marker is not a guard for Snapper's library limiter:
  its only current reader is inside that commented-out wrapper block. A
  resumed hourly catch-up can therefore run Snapper and reach its internal
  automatic-rescan path if qgroups are inconsistent. Add and verify a
  suspend/resume guard for that timer path before declaring host containment
  complete.
- A follow-up host journal check on 2026-10-18 showed the timeline service
  running each hour from 00:00 through 05:00 BST, logging the `home` and `root`
  timeline calls and exiting successfully. The timer remained active with
  `Persistent=no`; its next elapse was 06:00. The new `sleep.target` unit was
  still absent.
- No `qgroup` or `rescan` entries appeared in the kernel journal for that
  period. The visible `kworker/R-btrfs-qgroup-rescan` threads were idle, which
  does not establish the filesystem's rescan state. A read-only
  `btrfs quota rescan -s /mnt/kingston` query still returned
  `Operation not permitted` from the escalated shell. Current scan status is
  therefore unverified; do not infer that no scan is running from the journal
  or worker thread names alone.

## Suspend-hook implementation (2026-10-18)

- Added and pushed `bin/snapper-timeline-sleep` and
  `systemd/snapper-timeline-sleep.service` in the home repository on
  `codex/snapper-timeline-sleep-guard` (commits `bf3ce0d4` and fixup
  `3b01c647`). The helper remembers whether `snapper-timeline.timer` was
  active, stops it before system sleep, and restarts it after resume only if it
  had been active. Repeated pre-sleep calls preserve the original state; an
  inactive timer remains inactive.
- The unit follows systemd's documented `sleep.target` oneshot pattern:
  `ExecStart` runs the pre-sleep action, and `ExecStop` runs after resume. It
  uses `RemainAfterExit=yes`, `StopWhenUnneeded=yes`, `Before=sleep.target`,
  and `WantedBy=sleep.target`, and requires the mount containing the helper.
  `systemd-analyze verify` passed with the packaged unit search path. A
  fake-`systemctl` harness passed active/inactive, repeated pre-sleep, resume,
  and stop/start failure-cleanup paths; `sh -n` passed too.
- The live hourly timer has `Persistent=no`, so stopping it across sleep
  prevents a missed calendar event from being replayed on resume. The host
  unit has not yet been installed or enabled. Install the committed unit at
  `/etc/systemd/system/snapper-timeline-sleep.service`, run `systemctl
  daemon-reload` and enable it, then verify the dependency on `sleep.target`
  and the active timer. Do not treat this guard as deployed before those live
  checks pass.

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
  DKMS is not currently installed or usable as a deployment mechanism.
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

## DKMS and Secure Boot follow-up (2026-10-18)

- Rechecked the exact running release `7.1.13+deb13-amd64`; matching
  `linux-headers-7.1.13+deb13-amd64` and `linux-image-7.1.13+deb13-amd64`
  packages are installed. DKMS is still removed (`rc`); Debian offers
  `3.2.2-1~deb13u1` as the package candidate.
- The kernel and header post-install hook directories contain executable
  `dkms` hooks. Each invokes `/usr/lib/dkms/dkms_autoinstaller` when present;
  that executable and the `dkms` command are currently absent. This confirms
  the hook points exist but does not yet prove the complete APT failure and
  rollback behavior for a failed module build.
- The installed image package's `postinst` calls `linux-run-hooks image
  postinst`; that helper executes the hook directories with
  `run-parts --exit-on-error`. The image hook order is `dkms`,
  `initramfs-tools`, `unattended-upgrades`, then `zz-update-grub`. A DKMS
  failure therefore stops this sequence before initramfs generation and GRUB
  update. The image `postinst` uses `#!/bin/sh -e`, so the nonzero helper
  result also fails package configuration. A temporary `run-parts` harness
  with a failing DKMS hook and later initramfs/GRUB sentinels returned the
  DKMS status (`42`) and ran only the DKMS hook. This validates the runner's
  short-circuit behavior, not the full dpkg rollback or reboot path. A DKMS
  rollout must account for this APT failure mode while preventing an unpatched
  kernel from becoming the boot target.
- `/var/lib/dkms/mok.key` and `mok.pub` exist, but
  `mokutil --test-key /var/lib/dkms/mok.pub` reports the certificate is not
  enrolled. The running stock Btrfs module reports signer `Build time
  autogenerated kernel key` and matching `7.1.13+deb13-amd64` vermagic. The
  existing DKMS key therefore cannot yet be treated as trusted for loading a
  candidate module. Do not import/enroll it until the signing and recovery
  plan is reviewed.
- Inspected the Debian `dkms` candidate package `3.2.2-1~deb13u1` without
  installing it. Its `prepare_mok()` defaults to `/var/lib/dkms/mok.key` and
  `/var/lib/dkms/mok.pub`, and can generate a missing key/certificate pair.
  The automatic `update-secureboot-policy --enroll-key` call is in its Ubuntu
  specific branch; Debian's default path does not enroll the generated or
  existing certificate. Thus installing DKMS alone would not make a signed
  Btrfs module trusted on this Secure Boot host. Its module-signing code calls
  the selected kernel `sign-file` utility, but acceptance still requires
  proving the installed module is signed by an enrolled key and is selected
  from the initramfs and root filesystem after boot.
- DKMS remains only a candidate deployment route. Verify module signing,
  trusted-key enrollment, initramfs selection, failed-build propagation, and
  a real kernel upgrade/reinstall before selecting it for host deployment.

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
- This initial package experiment proved that a quota-enabled local package
  could be produced and selected by APT simulation. Its outstanding recipe
  work was completed in the follow-up section below. Installation and
  post-install runtime behavior remain unverified.

## Repeatable latest-upstream local package recipe (2026-10-18)

- Added `scripts/build-local-debian-package.sh` to the Snapper fork branch
  `codex/local-debian-package-builder`, commits `518bf605c7fc1652b3fd472b98044232ba73d483`
  and `49876e92e1308f4caa2b1e27c20fee200efcd293`.
  The branch is based on the current upstream master ancestor and is pushed
  separately from upstream PR #1203; no additional PR was opened.
- The recipe checks that the committed source contains the live official
  upstream `master` tip, copies source with `cpto` into a fresh directory under
  `/mnt/kingston/builds/rebroad/src/snapper.build/`, regenerates Autotools
  files there, and creates the Debian source package. It unpacks the generated
  source and Debian overlay into the build sibling, removes the packaging
  option that disables Btrfs quota, and creates an APT-monotonic local package
  version containing a UTC build sequence and source commit. A `dpkg` version
  comparison verified that the new version sorts above the previous local
  package. Source checkout files remain source-only; no generated build
  outputs are written there.
- The final run built packages as
  `0.13.2-1+local1.20261018031913.g49876e92e130`. The extracted CLI reports
  Snapper 0.13.2, libsnapper 8.2.0, and
  `btrfs,no-bcachefs,lvm,no-ext4,xattrs,no-rollback,btrfs-quota,no-selinux`.
  Package files are under
  `/mnt/kingston/builds/rebroad/src/snapper.build/local-package-builds/0.13.2-49876e92e130-20261018T031839Z/`.
  SHA-256: `snapper_0.13.2-1+local1.20261018031913.g49876e92e130_amd64.deb`
  is `9f7939eefd54a7e4376e14941c821be29cae3928d286850deabab50c18475798`;
  `libsnapper_0.13.2-1+local1.20261018031913.g49876e92e130_amd64.deb` is
  `017cb0a41378ba5c37106a3cd8c37b1b751a3af2445c14363567c0f1fe1f3011`.
- The test run passed the main 20-test suite, including `qgroup1` and
  `qgroup-rescan-limiter`, and all other runnable tests: 30 passed, 2
  skipped, 0 failed. The skips were the Ruby D-Bus-backed mock and the
  shellcheck check because those optional tools are not installed. Tests run
  outside fakeroot in a private D-Bus session; package assembly disables the
  duplicate fakeroot test run.
- `apt-get -s` planned to upgrade the currently installed Snapper package to
  `0.13.2-1+local1.20261018031913.g49876e92e130`, install its matching
  libraries and companion packages,
  remove no packages, and leave four unrelated packages not upgraded. The
  old `libsnapper7t64` is marked eligible for a later autoremove. The
  simulation did not install anything. The host remains on its prior runtime;
  the intended final runtime remains our locally built Snapper based on latest
  upstream. Deployment is still gated on upstream review and full accounting
  acceptance.

## Shared-tracker counter recheck (2026-10-18)

- Rebuilt the QEMU initramfs overlay with the current Btrfs module from the
  `7.1.13+deb13-amd64` build (`btrfs.ko` SHA-256
  `5ee7596af036376fb4c874d9bf76b5c07de2858c9484b219b9899ab822e28be8`). The
  test used the latest-upstream Snapper overlay, two independent quota
  hierarchies, outside snapshots sharing source extents, tracker setup, three
  later snapshot rounds, timeline cleanup, and a final full rescan.
- Added diagnostic qgroup tables after tracker setup and each snapshot round,
  plus before and after the final full rescan. The full-rescan comparison
  produced no counter differences. The test ended with
  `SNAPPER-QUOTA: PASS`; after the two expected tracker-setup scans, the later
  snapshots, quota queries, and cleanup started no scans and marked no qgroups
  inconsistent.
- This verifies the current shared-tracker referenced and exclusive counters
  against a full rescan for the tested workload. The suspected missing
  nodesize adjustment was not reproduced; no kernel arithmetic change is
  justified by this audit. Log:
  `/var/tmp/qgroup-root-cause-7.1.13/accounting-audit.serial.log`.
- This is QEMU evidence only. The host still has the stock Btrfs module and
  has not been switched to the locally built Snapper package. Deployment
  remains gated on upstream review and the full system acceptance plan.

## Snapper PR description correction (2026-10-18)

- Updated PR #1203's description after checking its text against the current
  kernel-patch state. It now states that the stock Btrfs module still takes
  the conservative rescan fallback for the reproduced snapshot-only layout,
  and that the companion kernel optimization has been tested but is not yet
  submitted. PR head and source code were unchanged.

## Live host deployment recheck (2026-10-18)

- At 05:57 BST, the running kernel was still `7.1.13+deb13-amd64`, and the
  installed Snapper package was still Debian `0.10.6-1.2`. The local package
  build has not been deployed.
- `dpkg-query -W` prints DKMS version `3.2.2-1~deb13u1` even though the package
  is removed. `dpkg -s dkms` reports `deinstall ok config-files`, and
  `/usr/sbin/dkms` and `/usr/lib/dkms/dkms_autoinstaller` are absent. Treat
  DKMS as unavailable; the version-only query is not installation evidence.
- Secure Boot remains enabled, and `mokutil --test-key /var/lib/dkms/mok.pub`
  reports the certificate is not enrolled. A noninteractive `sudo -n id`
  requires a password, so the escalated shell did not grant root access.
- `snapper-timeline-sleep.service` is not installed. The Snapper timeline
  timer remains enabled and active. No host package, module, unit, or timer
  configuration was changed by this check.
- From 00:00 through the 06:00 run, the timeline timer completed seven runs, each
  reporting the host configs `home` and `root`; the 06:00 run finished at
  06:00:06 BST. The kernel journal query for `qgroup|quota rescan` returned no
  entries in that interval, and the visible qgroup-rescan kworkers were idle.
  This is not proof that qgroups were consistent: unprivileged
  `btrfs quota rescan -s` and `btrfs qgroup show` both fail with
  `Operation not permitted`.
- The installed module file
  `/lib/modules/7.1.13+deb13-amd64/kernel/fs/btrfs/btrfs.ko.xz` has SHA-256
  `6ba4e90c38b021af552252af72fb5b0ed56ce027e348a422604feb1c2661ecfc`, matching
  the previously recorded stock-module baseline. `/proc/modules` shows Btrfs
  loaded; the `modinfo` utility is unavailable in this shell.
- The live timeline wrapper matches its source copy, and its explicit rescan
  block remains commented out. The Kingston `@/etc/snapper/configs/root` and
  `home` files exist but are unreadable here. The wrapper suppresses output
  and errors from those external-root Snapper calls, so the host's visible
  `home`/`root` journal messages do not establish that Kingston snapshots
  succeeded. Current Kingston snapshot and qgroup state still requires a
  privileged read.

## Stale quota display and cleanup deferral (2026-10-18)

- Extended the QEMU fixture with the latest-upstream Snapper PR #1203 build
  and the candidate Btrfs module for the exact in-use kernel
  `7.1.13+deb13-amd64`. The guest identified Snapper 0.13.2. Binary hashes:
  `snapper` `6fd4b8705d2e348d6349354b865d1dec097f182ce3fd19d93c28c83c9c89a4ae`,
  `libsnapper.so` `c33ac5b0da525ae3488f286825d54bb96fea228f0b5d502c7a365eb006f549a6`,
  and compressed Btrfs module
  `de0ef9b7a9b0b0ee609fbbae2e234ba940bfcb70f94d4fc903bc48b370059b96`.
- Before the fixture's explicit reconciliation, Btrfs reported
  `WARNING: qgroup data inconsistent, rescan recommended`, with no scan in
  progress. The shared per-filesystem limiter already recorded the tracker
  setup scan. For both `root` and `home`, `snapper list --columns
  number,used-space` returned a used-space value and printed an explicit
  warning that it was displaying last-known values; neither output contained
  `n/a`.
- With `SPACE_LIMIT="1 MiB"`, `snapper cleanup timeline` explicitly reported
  `quota cleanup skipped (qgroup quota counters are stale; quota cleanup
  deferred)` for each config. Fixture assertions confirmed neither config's
  snapshot count changed and the completed rescan count remained three
  (two baseline setup scans plus one shared tracker scan). Thus listing stale
  values and deferring quota-based deletion did not start another rescan.
- The fixture then explicitly reconciled qgroups and continued through its
  hourly snapshot, clean listing, quota cleanup, and full-rescan counter
  comparison checks, ending `SNAPPER-QUOTA: PASS`. This verifies the deferred
  stale-data behavior in QEMU; it does not mean the locally built Snapper or
  candidate kernel module is deployed on the host. Serial log:
  `/var/tmp/qgroup-perfs-cap/serial-stale.log`.

## Suspend-marker integration audit (2026-10-18)

- `force-suspend` writes an epoch deadline to
  `/var/tmp/force-suspend-btrfs-rescan-until` immediately before requesting
  suspend. The timeline wrapper contains code to read this marker only inside
  its currently commented-out explicit-rescan block. The latest-upstream
  Snapper `QGroupRescanLimiter` does not read the marker, so this marker alone
  cannot defer Snapper's internal rescan path.
- The installed timeline service override runs
  `/usr/local/sbin/snapper-timeline-all-roots`; the packaged timer uses
  `OnCalendar=hourly`. The only file found in the system sleep-hook directories
  was the packaged unattended-upgrades hook; there is no custom hook to renew
  the rescan hold after resume. The system bus was inaccessible in this
  sandbox, so the loaded timer state and actual resume/catch-up ordering were
  not verified. No marker or unit file was changed at the time of this audit.

## Rescan hold and resume integration follow-up (2026-10-18)

- The current Snapper PR #1203 head is
  `bbccc0a4f62b4245031a521b310a2cec86122b44`, based on the current official
  upstream `master` tip
  `5a2dd6a8559c1a04c5575bf184acb347dce0d8f7`. GitHub reports the PR open,
  with all seven CI checks successful and no review decision or reviews yet.
  The local Snapper build uses this head, which is based on the latest
  upstream source rather than a distribution source package.
- This head adds `QGROUP_RESCAN_HOLD_FILE`. When qgroups are inconsistent and
  no scan is already running, Snapper reads an absolute-path marker containing
  a future epoch deadline and defers a new automatic scan. An absent marker
  disables this hold. An already-running scan is not canceled by the hold.
  All configurations sharing a filesystem must use the same marker path.
- QEMU exercised the hold with the exact in-use kernel release
  `7.1.13+deb13-amd64`: a future marker prevented a new scan while Snapper
  displayed last-known quota values as stale and deferred quota cleanup; an
  expired marker allowed the next eligible scan. The follow-up snapshot,
  cleanup, and full-rescan counter comparison ended `SNAPPER-QUOTA: PASS`.
  Serial log SHA-256 is
  `ccc25bfc622e77c111625369c98cc65dfd2b8bdf03cd6aba2c11e62320ae2df0`.
- Built uninstalled local Snapper 0.13.2 packages from PR head `bbccc0a4` in
  `/mnt/kingston/builds/rebroad/src/snapper.build/`; Btrfs quota support is
  enabled. The `snapper` package SHA-256 is
  `3b7deeaa558dae32ecfa7faa244b001f4093d1c84ed5b03b0ac13699bc7ad81b`, and
  the `libsnapper` package SHA-256 is
  `f96831af49be95f0f78e289432dd1f24ff3b46971dcc17f44f3f03a24d6300cb`. The
  full `make check` passed 30 tests with 2 optional skips and no failures.
  `apt-get -s` planned to upgrade `snapper` to this local build, install its
  matching packages, remove nothing, and leave the old library eligible for a
  later autoremove. Nothing was installed on the host.
- A live read-only check still reports kernel `7.1.13+deb13-amd64` and
  `/usr/bin/snapper` 0.10.6 from package `0.10.6-1.2`. This is the current
  migration baseline, not the target runtime. The host must ultimately run our
  locally built Snapper based on the latest upstream source and carrying the
  reviewed changes.
- The sleep guard is committed and pushed in the home repository as
  `e5ee5f77` (`systemd: renew qgroup hold on resume`). It stops the timeline
  timer before sleep and refreshes an expired marker before restarting the
  timer. The service and `QGROUP_RESCAN_HOLD_FILE` setting have not been
  installed on the host, and actual post-resume/catch-up ordering remains
  unverified. Host rollout stays gated on upstream review and system-level
  accounting and resume checks.

## Kingston-independent suspend marker (2026-10-18)

- Live mount inspection showed `/var/tmp` is a symlink to
  `/mnt/kingston/@/var/tmp` on `/dev/sdb1`. `force-unmount-kingston.sh`
  unmounts nested mountpoints before `/mnt/kingston`, so the old marker path
  could disappear when the user unmounted Kingston before `force-suspend`.
  The old script did not stop when its marker write failed.
- Changed `force-suspend` and `snapper-timeline-sleep` to share
  `/home/rebroad/.local/state/snapper/qgroup-rescan-hold-until`, on the local
  NVMe-backed home filesystem. `force-suspend` creates the directory, writes
  a temporary file with mode 0644, and atomically renames it into place. It
  now refuses to suspend if this hold cannot be written. The fix is pushed in
  home-repository commit `50e72c5fe62b6307d46f5a985798836ca5766f2d`.
- Shell syntax checks passed. A mocked-command exercise verified that an
  inaccessible marker path prevents any suspend call, a writable path stores
  a future epoch deadline readable by Snapper, and the post-resume helper
  refreshes an expired deadline before restarting the timer. No real suspend
  or host service change was performed.
- `systemd-analyze --root=... verify` accepted the committed
  `snapper-timeline-sleep.service`; `systemctl --root=... enable` created its
  `sleep.target.requires` link in a temporary root. On the live host,
  `/usr/lib/systemd/system-sleep` contains only the packaged
  unattended-upgrades hook, `/etc/systemd/system-sleep` is absent, and no
  Snapper sleep service is installed. Unprivileged system-bus access failed,
  and `/usr/bin/sudo -n` requires a password, so live activation and resume
  ordering remain unverified. The currently installed Snapper also does not
  honor the hold marker; deploy the locally built Snapper and shared config
  before enabling this guard.

## Later-kernel qgroup fix recheck (2026-10-18)

- Fetched the current official kernel.org refs: Linux mainline
  `32c52ec87d6245ee2d12ed5dd509e40062939b50`, Btrfs maintainer `for-next`
  `2789b2c034d7c0c8687355921a38c5ac41a565fa`, stable `linux-7.1.y`
  `81d3924095fd017e473332a9b6dd6dd0e3d9a59b`, and stable `linux-7.2.y`
  `a2de78ee6ed8bf8cd99d177c74865a6e8c3cb6ea` (Linux 7.2.11).
- In all four `fs/btrfs/qgroup.c` files, quick qgroup inheritance still
  returns to the full-rescan path when the source has a different parent
  (`list->group->qgroupid != parentid`), and the existing same-parent
  exclusivity guard (`parent->excl != parent->rfer`) remains. None contains
  the proposed exact shared-parent optimization. The change is not already
  present in these later upstream or stable refs.
- The replacement patch remains local and still requires the user's DCO
  sign-off before submission. The source check does not establish that the
  proposed optimization is required to fix accounting corruption; prior QEMU
  evidence only shows the exact Snapper hierarchy avoids the repeated
  inconsistency fallback with the candidate module.

## linux-btrfs use-case clarification (2026-10-18)

- A maintainer's reply to the earlier patch thread said the previous response
  still did not describe the original situation and required reading the
  Snapper code to understand the proposed hierarchy.
- Replied in the existing thread with the concrete user-facing problem:
  hourly Snapper timeline runs for `root` and `home` repeatedly start qgroup
  rescans. The configs explicitly opt into `QGROUP=1/100` and `QGROUP=1/101`;
  the live source qgroups `0/256` and `0/257` have no parent. The reply showed
  both the current inherited-snapshot layout and the paired Snapper candidate's
  two-child shared-parent layout.
- Reported the differential QEMU evidence: after tracker setup, three hourly
  root/home rounds on the stock 7.1.13 module produced six inconsistency
  warnings and scans; the candidate module started no additional scans for the
  same rounds. A later full rescan left counters unchanged in both cases.
  Clarified that no accounting corruption or unrelated filesystem stall has
  been demonstrated, that the kernel change is a rescan-avoidance optimization,
  and that it does not cancel an already-running scan.
- No replacement patch was attached. The replacement remains gated on the
  user's DCO sign-off, and the Snapper PR remains open for upstream review.
- A prior correction sent on 2026-10-17 was rejected by the vger list manager
  because Gmail included an HTML MIME part. A later 2026-10-18 reply used only
  `text/plain` and clarified the original use case; Gmail has no later list
  rejection or maintainer reply as of this check. Do not treat the earlier
  rejected correction as delivered.

## Twenty-four hourly Snapper rounds on the candidate module (2026-10-18)

- Rechecked Snapper PR #1203 and upstream `master`: the PR is still open at
  `bbccc0a4f62b4245031a521b310a2cec86122b44`, based on the current upstream
  tip `5a2dd6a8559c1a04c5575bf184acb347dce0d8f7`; all seven CI checks pass,
  and no review decision is recorded.
- Extended the existing exact-kernel QEMU fixture to advance through 24
  consecutive hourly root/home snapshot rounds, from 02:00 on October 17 to
  01:00 on October 18. This is simulated guest-clock coverage, not a 24-hour
  elapsed-time run. The guest kernel reported
  `7.1.13+deb13-amd64`; it ran Snapper 0.13.2 from PR #1203 with Btrfs module
  SHA-256 `de0ef9b7a9b0b0ee609fbbae2e234ba940bfcb70f94d4fc903bc48b370059b96`.
- One qgroup inconsistency warning occurred during tracker setup, before the
  hourly rounds. The fixture reconciled it before beginning those rounds. No
  further inconsistency warning appeared during the 24 rounds; clean quota
  listings did not start scans. Both configs reached 25 snapshots before
  quota-aware timeline cleanup reduced each to one snapshot. A full rescan
  afterward left the recorded quota counters unchanged, and the fixture ended
  `SNAPPER-QUOTA: PASS`.
- Serial log:
  `/var/tmp/qgroup-perfs-cap/longrun/serial-24h.log`, SHA-256
  `d8f9914e8d1f5db9c2517e91eb39fe1520591bd18cf159064e997c2e42af476d`.
  This is QEMU evidence only; the locally built latest-upstream Snapper and
  candidate module are not deployed on the host.

## Snapper rescan-limiter test coverage review (2026-10-18)

- Inspected the clean Snapper checkout at PR #1203 head
  `bbccc0a4f62b4245031a521b310a2cec86122b44`. Its
  `testsuite/qgroup-rescan-limiter.cc` includes coverage for persistent
  per-filesystem state shared across limiter instances, independent filesystem
  UUIDs, and the 24-hour boundary (the rounded reservation blocks a second
  scan until 24 hours and one second after the first request).
- The same test file covers the `05:00-21:00` local-time window, its exclusive
  end, a window crossing midnight, active-scan reservation refresh, malformed
  state failing closed, and concurrent reservations where only one process
  wins. The current PR's CI checks passed; this was a source review, not a new
  local test run. Prior full local `make check` results are recorded above.
- This unit coverage verifies limiter calculations and coordination. It does
  not replace host verification that every Kingston Snapper config uses the
  shared state directory and time window, or the QEMU and post-resume checks.

## Host timeline containment and Snapper PR formatting (2026-10-18)

- Rechecked the live `snapper-timeline.timer`: it is active, with the last
  trigger at 07:00 BST and the next scheduled run at 08:00 BST. Its service
  override invokes `/usr/local/sbin/snapper-timeline-all-roots`; that wrapper
  still creates timeline snapshots, while its explicit Kingston rescan block
  remains commented out. The independent timer run can still enter Snapper's
  own qgroup logic, so the wrapper alone is not full containment.
- The host's `/usr/bin/snapper --version` reports 0.10.6. This is the current
  pre-migration state only; the required host runtime remains our locally
  built Snapper from latest upstream with the reviewed fix. The root/home
  configs could not be read in this inspection, so their rescan-window and
  hold-file settings remain unverified. `btrfs quota rescan -s /mnt/kingston`
  returned `Operation not permitted` in this command context; current scan
  state was therefore not established.
- Corrected the indentation defects found in the new production C++ portions
  of Snapper PR #1203. The amended head is
  `1d26f1890c0742bfbc04f56d4f1d1d9c8a256fe0`; the correction is whitespace
  only (`git diff --ignore-all-space` is empty and `git diff --check` passes).
  After the push, Codespell and five of six build/test checks passed. Tumbleweed
  Clang failed during package installation: openSUSE metadata requests timed
  out and zypper could not find `clang`, before compilation began. A targeted
  rerun was refused because the GitHub account lacks repository-admin rights.
  To verify the affected toolchain path, configured a separate build with
  Debian Clang 19.1.7 under
  `/mnt/kingston/builds/rebroad/src/snapper.build/clang-src`. The complete
  `make -j2` build and `make -j2 check VERBOSE=1` test step passed: 30 passed,
  2 skipped, 0 failed across five suites. The full log is
  `clang-src/full-clang-check.log` (SHA-256
  `0e4c73c563effdaae229f91220dab37b0b8fe899e106627d10e913ea0d0ace4c`). This
  validates the local Clang compile/test path but does not clear the failed
  GitHub CI check, which remains red and could not be rerun with this account.
  The PR remains open and has no review decision.

## Running Btrfs module package identity recheck (2026-10-18)

- The running release is `7.1.13+deb13-amd64`; `btrfs` is present in
  `/proc/modules`. `/usr/sbin/modinfo` reports the on-disk module path as
  `/lib/modules/7.1.13+deb13-amd64/kernel/fs/btrfs/btrfs.ko.xz`, with matching
  vermagic and signer `Build time autogenerated kernel key`.
- `dpkg-query -S` identifies that file as owned by
  `linux-modules-7.1.13+deb13-amd64`, and `dpkg -V` reports no package-file
  differences. Parsed the module's GNU build ID and compared it byte-for-byte
  with `/sys/module/btrfs/notes/.note.gnu.build-id`; they match, showing that
  the loaded Btrfs module is the same build as the installed package file.
- Secure Boot is enabled. The `dkms` package remains removed (`rc`), and
  `mokutil --test-key /var/lib/dkms/mok.pub` reports that the existing key is
  not enrolled. This confirms the stock baseline and that DKMS is not yet a
  ready deployment path; it does not verify candidate-module signing,
  enrollment, initramfs selection, or upgrade behavior.

## Exact-release isolated DKMS build and signing (2026-10-18)

- Used Debian DKMS 3.2.2 extracted under the Linux sibling build tree and a
  source copy from the current kernel checkout. The isolated `dkms.conf`
  builds `btrfs` for `7.1.13+deb13-amd64`, enables DKMS autoinstall, and places
  the module under `updates/dkms`. The actual DKMS build completed against
  `/lib/modules/7.1.13+deb13-amd64/build`; `/usr/sbin/modinfo` reports matching
  `7.1.13+deb13-amd64` vermagic. Build log:
  `linux.build/dkms-isolated/dkms-tree/btrfs/7.1.13-candidate/7.1.13+deb13-amd64/x86_64/log/make.log`.
- Rebuilt and signed the module using the Debian `sign-file` tool and a
  disposable key/certificate generated under `linux.build/dkms-isolated`.
  `modinfo` reports signer `Isolated DKMS test only`. The private key and
  certificate were removed after signing; the signed artifact was installed
  into the isolated DKMS install tree. A synthetic test module tree containing
  both this candidate and a copy of the packaged Btrfs module was indexed with
  `depmod`; it warned that the synthetic tree lacked `modules.order`,
  `modules.builtin`, and `modules.builtin.modinfo`. `modprobe --show-depends`
  selected `updates/dkms/btrfs.ko` ahead of `kernel/fs/btrfs/btrfs.ko.xz`.
  This tests module path selection, not full initramfs or boot precedence.
- The test did not load the candidate or change host module files, initramfs,
  DKMS registration, or enrolled keys. To exercise DKMS's install-file logic
  without root access, the extracted DKMS script was copied into the build
  tree and only its `check_root` guard was bypassed; source, DKMS state, and
  install roots were redirected into that isolated tree. The kernel headers
  and `sign-file` tool were read from the host. Thus this verifies compilation,
  test-key signing, install placement, and module path selection,
  but not installation under the real root-owned tree, trust of a host-enrolled
  key, initramfs behavior, or APT kernel-upgrade behavior. DKMS remains a
  candidate path, not a verified durable host deployment.

## Btrfs qgroup selftest coverage audit (2026-10-18)

- Inspected `fs/btrfs/tests/qgroup-tests.c` in the in-use `v7.1.13` checkout
  and the fetched Btrfs `for-next` tree at
  `2789b2c034d7c0c8687355921a38c5ac41a565fa`. Both exercise extent-reference
  accounting, but neither calls the snapshot quick-inherit path or covers the
  proposed shared-parent topology. Existing topology checks are exact-kernel
  QEMU integration tests recorded above, not an in-tree regression test.
- No test code was added in this audit. Before kernel-patch resubmission,
  decide whether the QEMU cases are sufficient for upstream review or add a
  maintainable regression test for the shared-parent success case and the
  differing/multiple-parent fallback cases.

## Exact-release Btrfs qgroup selftests (2026-10-18)

- Added in-tree qgroup sanity tests to the in-use `7.1.13+deb13-amd64`
  checkout. The shared-parent case checks referenced, exclusive, and
  compressed counters after quick inheritance. Fallback cases cover different
  source/target parents, multiple source parents, a target with multiple
  parents, and an additional child under the shared parent. The test wrapper
  takes `qgroup_lock`, matching the production caller.
- Built a test-only Btrfs module against the exact release headers and symbol
  table. `BTRFS_FS_RUN_SANITY_TESTS` is a bool depending on `BTRFS_FS`; the
  exact Debian config builds Btrfs as a module, so `olddefconfig` disables the
  test option. For this isolated test build only, temporarily enabled the
  generated config macro and restored the generated config afterward. The
  module vermagic is `7.1.13+deb13-amd64`; its SHA-256 is
  `304d144be3beb800a7d7441ad70c077b855e08d435e642b44c4d71abab5ad3d9`.
- Booted the test module in QEMU using the exact Debian kernel image. The
  kernel banner reports `7.1.13+deb13-amd64`. Qgroup sanity tests ran at all
  five nodesizes from 4 KiB through 64 KiB; the shared-parent and fallback
  markers appeared for each size, and module initialization completed with
  `QGROUP-SANITY: PASS`. The unsigned test module tainted this QEMU guest only;
  no host module or initramfs was changed.
- Serial log:
  `/var/tmp/qgroup-root-cause-7.1.13/qgroup-sanity-retry1-20261018/qemu-lockfix.log`,
  SHA-256 `01ad48903fc8b04b0e11a1cf8760986505e1031cdf6b35a302ce25e815dfec1d`.
  The user's DCO sign-off for the revised kernel patch remains pending; do not
  resubmit it before that gate.

## Btrfs selftest port to current for-next (2026-10-18)

- Rechecked the live Btrfs `for-next` ref; it remains
  `2789b2c034d7c0c8687355921a38c5ac41a565fa`. Applied the candidate kernel
  patch and the new qgroup selftests to an extracted copy of that exact source
  tree. Both applied without fuzz; line offsets differed because the source
  files have moved. This was a temporary patch-application check only; the
  main checkout remains on the exact in-use `7.1.13+deb13-amd64` source.
- A mixed-version module build using the for-next Btrfs subtree and the
  in-use kernel's generated headers failed in unrelated newer Btrfs APIs:
  `struct bvec_iter` lacks `bi_offset`, and the older memory-cgroup headers
  lack `mem_cgroup_shrink_is_root`. This does not test the qgroup patch. Do
  not build or boot another kernel for acceptance; keep runtime tests on the
  exact in-use release and use upstream review/CI for the submission base.
- The exact-release sanity tests passed in QEMU as recorded above. The
  replacement kernel patch remains gated on the user's DCO sign-off.

## Latest-upstream Snapper PR formatting and rebuild (2026-10-18)

- Reviewed the added C++ in Snapper PR #1203 against the repository's
  `.editorconfig` and surrounding source. Corrected over-indented rescan and
  hold-file blocks in the implementation and the new limiter tests. The
  six-commit PR history contains no standalone fixup after autosquashing these
  corrections into the final logical commit.
- Synced the Snapper checkout into its existing sibling build tree with
  `cpto --no-lngit`. The full configured GCC build completed, and
  `make -C testsuite check TESTS=qgroup-rescan-limiter.test` passed (1 test,
  0 failures).
- The PR remains open without a review decision. Updated head is
  `000d4fe0b57541e35fd5f4ce64114be16ddd489b`, based on upstream master
  `5a2dd6a8559c1a04c5575bf184acb347dce0d8f7`. The seven CI checks were
  queued at 09:07 UTC; their final results are recorded below.
- Staging through the local `git add` wrapper ran `ws --diff-only`, which
  rewrote mixed tabs and spaces in ways that disagreed with nearby source
  layout. After manually reviewing the intended indentation, the changes were
  staged with the wrapper's explicit `AGENT_GIT_ADD_BYPASS=1` option.

## Kernel submission patch prepared for DCO review (2026-10-18)

- Reconstructed the tested qgroup implementation and sanity tests as one
  mail-formatted patch against Btrfs `for-next`
  `2789b2c034d7c0c8687355921a38c5ac41a565fa`. The artifact is in the sibling
  build tree at
  `linux.build/submissions/0001-btrfs-qgroup-shared-parent-fast-inherit.patch`;
  SHA-256 is
  `b3175a799058e29ee377566ce1c733af32083232ddf0d4456529a4e31e284390`.
- Verified the patch applies to a clean archive of that exact `for-next` base,
  `git diff --check` passes, and
  `checkpatch.pl --strict --no-tree --no-signoff` reports zero errors or
  warnings across 377 lines. It contains the qgroup implementation and the
  shared-parent and conservative-fallback selftests.
- The patch intentionally has no `Signed-off-by` trailer. The exact patch is
  ready for the user's DCO review; do not add the trailer or submit it until
  that sign-off is confirmed.

## Current latest-upstream Snapper package build (2026-10-18)

- Ran the committed local package recipe from
  `codex/local-debian-package-builder` (`49876e92e1308f4caa2b1e27c20fee200efcd293`)
  against PR #1203 head `000d4fe0b57541e35fd5f4ce64114be16ddd489b`, after
  confirming it contains the current official upstream `master` tip. The
  build and all test suites completed: 30 passed, 2 skipped, 0 failed.
- The 11 generated Debian packages are under
  `linux.build/local-package-builds/0.13.2-000d4fe0b575-20261018T092215Z/`.
  The packaged binary reports Snapper 0.13.2 with `btrfs-quota`; the package
  version is `0.13.2-1+local1.20261018092242.g000d4fe0b575`.
- The APT simulation proposes one upgrade and ten new packages, with no
  removals and four unrelated packages not upgraded. No package was installed;
  `dpkg-query` still reports the pre-migration host package. Generated files
  remained in the Snapper sibling build tree, and the source checkout stayed
  clean. Host deployment remains gated on review and acceptance.

## Snapper PR CI and `ws` tab-stop correction (2026-10-18)

- Rechecked upstream master and PR #1203 at 09:13 UTC. The base remains
  `5a2dd6a8559c1a04c5575bf184acb347dce0d8f7`, and the PR head remains
  `000d4fe0b57541e35fd5f4ce64114be16ddd489b`. All seven checks pass: Debian,
  Fedora, Leap, Ubuntu, Tumbleweed GCC, Tumbleweed Clang, and Codespell. The PR
  remains open with no review decision.
- Corrected the PR description's stale label for the hold-file QEMU run: it
  identifies `bbccc0a4` as the tested prior head and states that current head
  `000d4fe0` differs only in whitespace, with a full local package build/test
  and all seven CI checks passing on the current head.
- Traced the bad indentation from `ws`'s output-tab-size override: it treated
  EditorConfig `indent_size=4` as a tab stop despite `tab_width=8`. Removed
  that override; an isolated Git fixture now converts an eight-column indent
  to one tab, and the script passes a Python syntax check. The fix is committed
  as `6f03ace4` on `/home/rebroad` `master` and is present at `origin/master`.
  The home-repository checkout has unrelated modified files, which were left
  untouched.

## Sleep/resume qgroup hold and service installation (2026-10-18)

- The post-resume helper previously refreshed the qgroup hold only when a
  marker already existed. That left normal sleep without a prior `force-suspend`
  unprotected: a timer catch-up could invoke Snapper's internal rescan path.
  The helper now creates a hold before stopping the timeline timer and ensures
  an unexpired hold before restarting it after resume. It fails closed if it
  cannot create or refresh that hold.
- The system unit previously executed `/home/rebroad/bin/snapper-timeline-sleep`
  as root. It now executes `/usr/local/libexec/snapper-timeline-sleep`;
  `bin/install-snapper-timeline-sleep` installs the helper and system unit as
  root-owned files, reloads systemd, and enables the sleep hook. The root-owned
  helper delegates marker creation and refresh to `rebroad` via `runuser`, so
  it does not write into the user's state directory as root; it retains root
  only for system timer control. The unit requires the mount containing the
  hold-file directory.
- Added `bin/test_snapper_timeline_sleep.py` coverage for marker creation,
  preserving a future marker, renewing an expired marker, inactive timers,
  fail-closed pre-sleep and resume paths, and installer destinations. All seven
  tests pass; `sh -n` passes for both shell scripts and `git diff --check`
  passes. `systemd-analyze verify` could not fully validate the unit here: it
  reported the expected absent not-yet-installed `/usr/local/libexec` helper
  and a sandbox permission error opening the unrelated
  `/etc/systemd/system/memory_guardian.service`.
- Committed and pushed to `rebroad/home-rebroad` branch
  `codex/snapper-timeline-sleep-guard` as `17d09379`, a normal fast-forward
  after `fa151915`. The host service remains uninstalled and unenabled; verify
  its live ordering and prove no resume catch-up starts a scan after the
  reviewed Snapper build is deployed.
- Refreshed upstream PR #1203 on 2026-10-18. It remains open at head
  `000d4fe0b57541e35fd5f4ce64114be16ddd489b`, based on
  `5a2dd6a8559c1a04c5575bf184acb347dce0d8f7`; all seven CI checks pass and it
  still has no review decision or submitted reviews. The exact Btrfs patch's
  DCO sign-off remains pending.

## Current upstream qgroup-inheritance recheck (2026-10-18)

- Checked the live Btrfs maintainer refs: `for-next` remains
  `2789b2c034d7c0c8687355921a38c5ac41a565fa`; its `master` is now
  `70dd4ee72eb2d5793c62e71c14e3aba78e5a4e56`. The formal candidate remains
  based on the unchanged `for-next` commit.
- Fetched mainline Linux `master` at
  `58161ead29e50d70a317ea26b472e0c7508e69da` and read its
  `fs/btrfs/qgroup.c`. `qgroup_snapshot_quick_inherit()` still requires the
  source and new parent to be the same single parent and otherwise returns the
  rescan fallback. It contains neither the two-child shared-parent path nor
  the candidate's counter derivation. The reported behavior is therefore not
  already fixed in current Btrfs maintainer `master` or mainline `master`.
- Rechecked Snapper PR #1203: it remains open at
  `000d4fe0b57541e35fd5f4ce64114be16ddd489b`, based on official upstream
  `master` `5a2dd6a8559c1a04c5575bf184acb347dce0d8f7`; all seven checks pass,
  with no review decision or submitted reviews. No source checkout or patch
  was changed during this recheck.

## Goal-state refresh (2026-10-18)

- Queried the official Snapper repository and PR API. `master` is still
  `5a2dd6a8559c1a04c5575bf184acb347dce0d8f7`, matching PR #1203's base.
  PR #1203 remains open at
  `000d4fe0b57541e35fd5f4ce64114be16ddd489b`, with no reviews or review
  decision and all seven CI checks successful.
- The current host reports kernel `7.1.13+deb13-amd64`; `snapper --version`
  reports Snapper `0.10.6`, libsnapper `7.2.0`, and Btrfs quota support, and
  `dpkg-query` reports `snapper 0.10.6-1.2`. This confirms the locally built
  latest-upstream Snapper has not yet become the host runtime.
- The managed shell could not connect to the system D-Bus, so this check did
  not establish the live timer or sleep-unit state. Do not treat timer status
  as refreshed by this observation.

## Shared-parent tracker-union regression (2026-10-18)

- Strengthened the in-tree shared-parent sanity fixture so the source has
  `4 * nodesize` referenced bytes, the existing snapshot parent has
  `2 * nodesize`, and their common tracker has `6 * nodesize`. The assertions
  now prove the new snapshot parent takes the union count from the tracker,
  which differs from either child, rather than accidentally matching the
  source count. Compressed counters remain covered.
- Synced the source change into the external Linux build tree with `cpto` and
  built the test-enabled Btrfs module against the installed
  `7.1.13+deb13-amd64` headers and `Module.symvers`. The module vermagic is the
  exact in-use release; module SHA-256:
  `56dbd77ce6dde35053bbffb5f35e105f0ba2b9445918eb8970fa3ec14ffc82bf`.
- Booted that module in QEMU with the exact Debian kernel image and 4 GiB guest
  memory. Both shared-parent and fallback tests ran at all five nodesizes
  (4-64 KiB), ending in `QGROUP-SANITY: PASS`. Serial log:
  `/var/tmp/qgroup-root-cause-7.1.13/shared-parent-union-20261018/qemu-4g.log`,
  SHA-256 `8111b36fceecdfbc928e0428a067c533cb70b65bc37d4d04fbca134e7a7bfab1`.
- Regenerated the mail patch against Btrfs `for-next`
  `2789b2c034d7c0c8687355921a38c5ac41a565fa`. Its SHA-256 is
  `0673884246f1448c0d730533367aafa65bebee79db4162fde9f7c94e291b8f8f`.
  A zero-fuzz dry run succeeds; `checkpatch.pl --strict --no-tree
  --no-signoff` reports zero errors and warnings. Standard strict checkpatch
  reports only the missing `Signed-off-by` trailer. The patch remains unsigned
  and unsubmitted pending the user's DCO sign-off for this exact revision.

## Snapper companion-validation note refreshed (2026-10-18)

- Updated PR #1203's kernel-companion paragraph to include the exact
  `for-next` base, the strengthened tracker-union test, its exact-release
  five-nodesize QEMU pass, and the still-pending DCO sign-off. The published
  head and base are unchanged; all seven checks remain successful, with no
  reviews or review decision.
- After review of the description, replaced the full hashes in its validation
  references with concise Markdown links to the corresponding commits in
  `openSUSE/snapper`, `rebroad/snapper`, and the Btrfs maintainer tree. Verified
  that no unlinked 40-character commit hashes remain in the text and that the
  PR head is unchanged.
- Replaced the validation history with current-state results only: latest
  upstream base, current local build/tests, seven passing CI checks, and the
  relevant exact-kernel QEMU results. Removed references to earlier PR heads
  and historical test comparisons. Re-read the published description and
  confirmed the current head and all seven successful checks.
- Removed the host-specific preferred rescan window from the PR. The published
  description now discusses the configurable window generically and contains
  no host-preference, Kingston, or personal-path references.
- Removed the duplicate kernel-base hyperlink in the published description:
  only the Btrfs maintainer repository name links to the repository, while
  `for-next` is plain branch text. Verified the sentence contains one link.

## Ancestor-counter overflow hardening (2026-10-18)

- Review found that the fast path checked the directly updated qgroup but did
  not preflight every ancestor that receives the counter increment. It now
  checks referenced and exclusive counters on the complete affected chain
  before mutating any qgroup; overflow retains the rescan fallback with no
  partial counter updates. The in-tree regression test sets each of the four
  ancestor counters to its overflow boundary and verifies the target,
  tracker, and ancestor counters remain unchanged.
- Built the test-enabled module against the exact Debian
  `7.1.13+deb13-amd64` headers and symbol table. Its vermagic matches the
  running release; module SHA-256:
  `ad78440a50fb0ad81638690aec99b6bdfca4a3ef8b514c73bcc7a9d2e5e893db`.
- Booted the exact Debian kernel image with a 4 GiB QEMU guest. Shared-parent,
  topology-fallback, and ancestor-overflow tests ran at all five nodesizes
  (4-64 KiB), ending in `QGROUP-SANITY: PASS`. Serial log:
  `/var/tmp/qgroup-root-cause-7.1.13/qgroup-sanity-overflow-20261018/qemu.log`,
  SHA-256 `08a11a7ce419d451bfb6c1903b24f7e16c13f34bc599f1dda7f7ae21cb138132`.
- Rechecked the live Btrfs `for-next` ref before regenerating the combined
  patch; it remains at the same commit recorded above. The unsigned draft now
  includes the ancestor preflight and regression test, applies to that base,
  and passes `checkpatch.pl --strict --no-tree --no-signoff` with zero
  warnings. Standard strict checkpatch reports only the missing human
  `Signed-off-by` line. The patch has an `Assisted-by` trailer and remains
  unsubmitted pending the user's review and DCO certification for this exact
  revision. Patch SHA-256:
  `64781dca15601157ad574b0115ab737e4d5d1f3539af761ace4fb02afd239c0c`.

## Exact-7.2.6 direct and tracker overflow coverage (2026-10-19)

- Review found the overflow tests covered the four ancestor counters, but not
  the fast path's separate preflight of the snapshot group's `excl` and
  `excl_cmpr`, or the four counters on the shared tracker itself. Extended the
  existing test to trigger overflow in those six counters and verify that all
  snapshot, tracker, and ancestor counters remain unchanged.
- The test-enabled external Btrfs module rebuilt against
  `/usr/src/linux-headers-7.2.6+deb13-amd64`; sanity tests were enabled for
  this build. Its uncompressed module SHA-256 is
  `fb2d000cd4a26ad7b832bb145a6aa23eff9d649e84ef7aec151e5fd627241196`.
- Booted the exact Debian 7.2.6 kernel in QEMU. Shared-parent, topology
  fallback, and counter-overflow tests ran at nodesizes 4, 8, 16, 32, and 64
  KiB; no selftest failure appeared, and the four-group workload reached
  `HOST-TOPOLOGY: CLEANUP-COMPLETE`. The serial log SHA-256 is
  `e26868e65def4e28a13c52d6501507fcd129730b00e4ab4d69ef3deb30fb799a` at
  `/var/tmp/linux.build/qgroup-san-overflow-7.2.6-20261019/qemu-rerun.serial.log`.
  This verifies the added overflow cases and this QEMU workload; host runtime
  and full Secure Boot acceptance remain open.

## Cross-config rescan policy enforcement (2026-10-18)

- The latest-upstream Snapper candidate now enumerates `SNAPPER_CONFIGS` when
  qgroups are inconsistent and no scan is active. For every nonempty `QGROUP`,
  it resolves the configured subvolume's Btrfs filesystem UUID and compares
  that config's rescan window and hold-file path with the initiating config.
  A same-filesystem mismatch, unreadable config, invalid window, or unresolved
  subvolume defers the new scan; the stale-value and cleanup-deferral behavior
  remains in place. An already-running scan still follows the existing wait
  path.
- Added unit coverage for matching policies, mismatched windows, mismatched
  hold paths, and ignoring configs on other filesystems. The full Snapper build
  completed; `make check` exited successfully with 30 passes, 2 optional skips,
  and no failures. The core testsuite passed 20/20, and the focused limiter
  binary passed 8 cases and 108 assertions.
- Ran an exact-kernel QEMU case on `7.1.13+deb13-amd64` with the stock Debian
  Btrfs module (SHA-256
  `6ba4e90c38b021af552252af72fb5b0ed56ce027e348a422604feb1c2661ecfc`). At
  07:00, root allowed `00:00-24:00` and home allowed `05:00-21:00`. Creating a
  root snapshot marked qgroups inconsistent; Snapper logged the policy
  mismatch, started no scan beyond the two baseline setup/reconciliation
  completions, and `snapper list` returned numeric last-known usage with its
  stale warning. Btrfs reported no scan in progress; the fixture ended
  `POLICY-MISMATCH: PASS`. Serial log SHA-256:
  `e1e4953ce173d2812ed360355ea0ad5ea150919fd267027c09192068e4ff31ed`.
- Repeated the full two-config quota acceptance workload using the current
  Snapper PR head `476f0814`, Snapper 0.13.2, and the paired candidate Btrfs
  module on exact kernel `7.1.13+deb13-amd64`. Root and home used matching
  `00:00-24:00` windows. Tracker setup for both configs started one automatic
  shared-filesystem scan; hourly snapshots and quota cleanup completed, and the
  final qgroup counters matched a full rescan. The log ended
  `SNAPPER-QUOTA: PASS`; serial log SHA-256:
  `1574899662080c0445c0271170ef99d1767e4af7231ab76baff5fbbc200ffdb4`.
- The updated Snapper PR head has all seven GitHub CI checks successful.
  Generated artifacts remain in the sibling build tree.

## Live deployment gate rechecked (2026-10-18)

- Read-only host checks confirm the running kernel remains
  `7.1.13+deb13-amd64`. The active `snapper-timeline.timer` is enabled and
  active, while `snapper-timeline-sleep-guard.service` is not installed and
  the shared rescan-hold marker is absent. The locally built Snapper and its
  shared configuration policy are therefore not active on the host yet.
- The host still reports the distribution Snapper package as installed. This
  is only current pre-deployment state; it does not meet the goal's required
  runtime. Passwordless sudo is unavailable in this session, so the protected
  `/etc/snapper/configs` policy values could not be refreshed. Keep deployment
  gated until PR review, host-level access, and the remaining acceptance and
  upgrade checks are resolved.

## Kernel DCO and AI-assistance policy checked (2026-10-18)

- Checked the current kernel submission guide and AI coding-assistant and
  generated-content guidance. A human submitter must personally review the
  AI-assisted contribution, ensure it meets licensing requirements, add
  their own `Signed-off-by`, and take responsibility for it. The DCO also
  makes the signer's right to submit the work under the applicable open-source
  license and the permanent public contribution record explicit.
- The current unsigned patch includes `Assisted-by: Codex:GPT-6`, consistent
  with the kernel's tool-attribution guidance, and has no `Signed-off-by`
  trailer. The user must decide whether they can make the DCO certification
  for this exact patch revision after reviewing it. No sign-off was inferred
  from the earlier authorization or from the prior sign-off for a different
  revision.

## Production-form module build and QEMU acceptance (2026-10-18)

- Rechecked the exact-header external Btrfs build after suspecting its
  `btrfs_run_sanity_tests` symbol meant the developer tests were enabled. The
  running kernel's config has `CONFIG_BTRFS_FS_RUN_SANITY_TESTS` unset; the
  external module contains no `tests/*.o` objects or Btrfs test functions. The
  symbol is the inline disabled-config stub, whose disassembly returns zero.
  The same no-op stub, rather than test code, is present in the module from the
  earlier 24-hour simulated Snapper workload. The prior production-form concern
  was therefore a false alarm.
- Built against the running `7.1.13+deb13-amd64` headers using the current
  patched `fs/btrfs/qgroup.c` (source and external-build copy SHA-256
  `b1177fe5d78f7e3300159ecfa5ec8cb17e54d60d75c8ebd81d8936a69c1fc760`). The
  unsigned module SHA-256 is
  `aabb3ee6015a33ca934a7b6a6a313ce2eebd44c43b9574d16100ec8ce6d36f1`; the
  signed module SHA-256 is
  `203891dd131aac27c93a419522990ded3a8a2859f94472761ea9c9d0c2f32ea9`.
  Its vermagic is `7.1.13+deb13-amd64 SMP preempt mod_unload`.
- Verified that the enrolled `Rebroad` MOK certificate and its local private
  key have matching public-key fingerprints, and `mokutil --test-key` reports
  the certificate enrolled. OpenSSL CMS verification of the appended module
  signature against that certificate succeeds. No private-key material was
  added to the source or build trees.
- Replaced the module in a fresh initramfs fixture with this exact signed
  artifact, compressed using xz CRC32 as required by the kernel's module
  decompressor, and ran the Snapper 0.13.2 acceptance workload with the exact
  Debian kernel image. The log reports the expected tracker-setup inconsistency,
  then no further inconsistency during stale-data handling, 24 simulated
  hourly rounds, quota cleanup, and full-rescan counter comparison; it ends
  `SNAPPER-QUOTA: PASS`. Serial log SHA-256:
  `eaca98e9f25c733ad3403fdbb479f226e7a47c428f28c4897dbbfbbb12df1853`.
- An initial direct-kernel QEMU boot did not import the MOK certificate and
  logged `module verification failed: signature and/or required key missing`;
  that run was not Secure Boot acceptance evidence. Replaced it with an OVMF
  Secure Boot boot through the Microsoft-signed shim and Debian-signed GRUB,
  using a disposable variable store with the enrolled MOK certificate in
  `MokList`. The exact kernel logged EFI Secure Boot lockdown and loaded the
  `Rebroad's module signing key` certificate from `UEFI:MokListRT`.
- Forced `module.sig_enforce=1` for the test. The signed Btrfs module loaded
  and mounted the test filesystem without a signature warning. The fixture
  then attempted to load an otherwise identical unsigned module; the kernel
  rejected it with `Loading of unsigned module is rejected`, and the fixture
  confirmed the enforcement parameter and rejection before continuing.
  Snapper 0.13.2 completed the stale-data and cleanup checks, all 24 simulated
  hourly rounds, and the full-rescan counter comparison under enforcement,
  ending `SNAPPER-QUOTA: PASS`.
- The enforced-boot initramfs SHA-256 is
  `6174dffd03ef6ef656733cd262e35e7396c118a06e0d34c6ac78f6f0ff7d2e0b`; its
  compressed signed Btrfs module SHA-256 is
  `0c7f44d9aa377f82baf0620bfebe2548a2768272755a59d3cebc079001ec6a08`.
  Serial log SHA-256:
  `9d62d4a261cfb85c542c301c3018bb2629cfa1fe0f19016f8a2063380e8bb95f`.
  This proves Secure Boot trust and signature enforcement in QEMU for this
  exact kernel and artifact; host installation, rollback, and APT-upgrade
  behavior remain unverified.

## Host DKMS package install and rollback verification (2026-10-18)

- Added and committed a local DKMS package recipe for the paired Btrfs change.
  The package was built from committed source revision
  [`2c0473752cda`](https://github.com/rebroad/linux/commit/2c0473752cdad7484c90b9265f46cb54ded98b2e)
  against the exact in-use Debian kernel release, `7.1.13+deb13-amd64`.
  Generated package and DKMS build artifacts remain in the Linux sibling build
  tree.
- An isolated DKMS build of the package completed and produced a module signed
  by `Rebroad's module signing key`. Its `sig_key` is
  `79:BC:F6:D4:0C:64:F7:5A:78:CB:ED:BE:1F:4C:E8:1A:53:22:DE:29` (the enrolled MOK
  fingerprint was checked against the enrolled-key list).
- Installed the package using `sudo dpkg -i` without unloading the currently
  running Btrfs module or rebooting. `dkms status` reports the candidate
  installed for `7.1.13+deb13-amd64`; `modprobe --show-depends btrfs` selects
  `/lib/modules/7.1.13+deb13-amd64/updates/dkms/btrfs.ko.xz`. Its signer and
  key ID match the enrolled key.
- The refreshed initramfs contains the candidate at
  `usr/lib/modules/7.1.13+deb13-amd64/updates/dkms/btrfs.ko.xz`. Extracting
  that entry confirmed its SHA-256 matches the installed compressed module:
  `fbba2737463a52be6c2dd02afc5c762617fb4f4b7e3d7e5a9df177147767d6ef`.
- Exercised package removal and reinstall with `sudo`. Removal restored the
  stock module and refreshed initramfs images for both installed kernel
  versions; reinstall selected the signed candidate again. The current host
  package is `7.1.13+rebroad1.g2c0473752cda`.
- This verifies package install/rollback and next-load module selection, not
  live use: the currently loaded module remains the stock module until reboot.
  A planned boot, host qgroup workload, and a full kernel APT upgrade/reinstall
  path remain outstanding. No reboot was performed.

## DKMS coverage for every installed kernel (2026-10-18)

- Updated the package lifecycle to build the module for every version under
  `/lib/modules` before installing any of them, sign and install the module for
  each version with matching headers, refresh each kernel's initramfs, then
  remove stale DKMS registrations whose versioned source symlink no longer
  exists. This prevents a package upgrade from leaving the previous version
  registered as broken.
- Built package version `7.1.13+rebroad1.gdec6cc4831f2` from source commit
  [`dec6cc4831f2`](https://github.com/rebroad/linux/commit/dec6cc4831f2ee1b869a4f96f16a44f6329b3d35).
  Package SHA-256:
  `ec8ccc85f1f44c0a64dbdbdd8776634158e6e694803f304c8f385ccf59d365e6`.
- Installed the package with `sudo dpkg -i`. DKMS completed signed builds for
  both installed kernels, `7.1.8+deb13-amd64` and `7.1.13+deb13-amd64`. The
  compressed modules have SHA-256 values
  `70b84bb8423610039f985f80994510a44f9d959b956caf8b4f80267ce68c53fd` and
  `93010ea930e36b4c920c820300e99cc9b43ce5d75411dec59b42789ad37793f4`,
  respectively. Each reports signer `Rebroad's module signing key`, the
  enrolled key ID, and vermagic matching its kernel release. `modprobe`
  selects `updates/dkms/btrfs.ko.xz` for both versions.
- Full `lsinitramfs` listings completed successfully and confirmed each image
  contains the corresponding `usr/lib/modules/<release>/updates/dkms/btrfs.ko.xz`
  entry. DKMS status contains only the current package version, installed for
  both kernels; the prior broken registrations are gone.
- Tested `sudo dpkg -r` rollback across both kernels. DKMS restored the original
  packaged Btrfs module for each version, `modprobe` selected the stock module,
  and both refreshed initramfs images contained their stock module path. Then
  reinstalled the candidate package and repeated the per-kernel checks. No
  reboot occurred; the running `7.1.13+deb13-amd64` kernel still has the module
  loaded from before these on-disk changes.
- APT simulation with `-t trixie-backports` selects kernel
  `7.2.6+deb13-amd64` and its headers. A build-only probe using the downloaded
  Debian 7.2.6 headers failed with source/API mismatches, including changed
  Btrfs tracepoint signatures and `struct btrfs_log_ctx` being incomplete for
  the 7.1.13 source. The new kernel was not installed or booted. This proves
  the current DKMS source cannot yet carry the fix across the next backports
  kernel update; its source must be ported or regenerated before that upgrade.

## Debian 7.2.9 DKMS source compatibility probe (2026-10-18)

- APT indexes now offer Debian backports kernel `7.2.9-1~bpo13+1`. Downloaded
  its `linux-source-7.2`, exact amd64/common headers, and `linux-kbuild` packages
  into `linux.build/upgrade-probe-7.2.9`; nothing was installed on the host.
- Applying the current qgroup patch from the `v7.1.13` baseline to the Debian
  7.2.9 Btrfs source succeeded for `fs/btrfs/qgroup.c`, `qgroup.h`, and
  `tests/qgroup-tests.c`. The full external Btrfs module then built against
  the exact Debian 7.2.9 headers with sanity-test objects disabled. The
  resulting module reports vermagic `7.2.9+deb13-amd64 SMP preempt mod_unload`
  and SHA-256
  `8ce39bc95187781985ff8cd65411a6f5abd10f0ef51d5d7d1c266de6b192231c`.
- As a control, the currently packaged 7.1.13 DKMS source was built against
  those same 7.2.9 headers and failed with the expected Btrfs tracepoint API
  and `btrfs_log_ctx` errors. Thus the patch can be carried to a matching 7.2
  source tree, but the installed DKMS package still cannot build the 7.2.9
  module. Kernel-release-matched source selection and package integration,
  signing, installation, initramfs inclusion, and boot verification remain
  outstanding. The 7.2.9 kernel was not installed or booted.

## Release-matched DKMS sources and 7.2.6 APT upgrade (2026-10-18)

- Added a source map to the DKMS package. It selects the committed 7.1.13
  source for `7.1.8+deb13-amd64` and `7.1.13+deb13-amd64`, and exact sources
  for `7.2.6+deb13-amd64` and `7.2.9+deb13-amd64`. The build script checks
  that every installed kernel has a source mapping, applies the qgroup patch
  to additional source trees, and fingerprints the mapping and sources in the
  local package version. The DKMS pre-build selector fails clearly when an
  exact kernel release is absent from the packaged map.
- The exact Debian `7.2.6-1~bpo13+1` source accepted the qgroup patch in
  `fs/btrfs/qgroup.c`, `qgroup.h`, and `tests/qgroup-tests.c`, then built
  against the exact `7.2.6+deb13-amd64` headers. The module reports matching
  vermagic. A build from the source selected out of the generated package
  also completed against those headers. The corresponding 7.2.9 source
  variant was likewise patched and built against 7.2.9 headers.
- APT simulation showed `linux-image-amd64` and `linux-headers-amd64` would
  move to 7.2.6, with 5 upgrades, 7 new packages, and no removals. The 7.2.9
  source and headers were available, but no 7.2.9 image candidate was offered.
- Built and installed package
  `7.1.13+rebroad1.z20261018.154420.g29a221f567b0.m87a66389.s3a8cfb46`,
  SHA-256 `ca7718763394f360b7d8087e05f66b46b6d14ab8fb08e8a7c609ac49277d2beb`.
  The `z` timestamp segment makes future local package versions sort after the
  previous commit-hash-only version under dpkg's version rules.
- The actual APT upgrade to backports kernel 7.2.6 completed successfully.
  Its header post-install hook ran DKMS, selected the 7.2.6 source variant,
  built and signed Btrfs, and installed it under
  `/lib/modules/7.2.6+deb13-amd64/updates/dkms/`. The image post-install then
  generated the matching initramfs and GRUB entry. APT reported 5 upgraded,
  7 newly installed, and 0 removed packages; `dpkg --audit` is empty.
- DKMS reports the current package installed for all three kernel releases:
  `7.1.8+deb13-amd64`, `7.1.13+deb13-amd64`, and `7.2.6+deb13-amd64`.
  `modprobe --show-depends` selects each release's `updates/dkms/btrfs.ko.xz`;
  each module's vermagic matches its kernel and its signer is `Rebroad's
  module signing key`, with sig_key
  `79:BC:F6:D4:0C:64:F7:5A:78:CB:ED:BE:1F:4C:E8:1A:53:22:DE:29`. The compressed
  module SHA-256 values are:

  - 7.1.8: `396da85c29d4a5b2798dd573bb67eca25cbd22145984bec317d5e02345fd8304`
  - 7.1.13: `0b9ff5e9ac2531ecf25fc5ef2c7c7c5df0a107501d33aa20141674b50c5509f5`
  - 7.2.6: `f50e898b36ccb15189fb7ac63b7c3fdb04f5fa88e3627880329f5ecd4e423a10`

  Full initramfs listings contain the corresponding module path for all three
  releases.
- The running kernel remains `7.1.13+deb13-amd64`; no reboot was performed.
  `/vmlinuz` now points to 7.2.6, making that the default next-boot kernel.
  Thus the new module is installed and signed for next boot, but it has not
  been loaded or exercised on the host. Boot-verify the candidate at a planned
  reboot.

## Host Snapper runtime, scheduling, and installed-kernel coverage (2026-10-18)

- The host now runs locally built Snapper
  `0.13.2-1+local1.20261018133430.g476f0814f665` and matching libsnapper from
  the PR #1203 source. `snapper --version` reports Snapper 0.13.2, libsnapper
  8.2.0, and `btrfs-quota` support.
- Root-repo commit `99d432f` added the rescan-window and hold settings but
  removed the installed timeline and cleanup unit files. The remaining
  `/etc/cron.hourly/snapper.upstream` name contains a dot, so
  `run-parts --test /etc/cron.hourly` excludes it; the timer symlinks were
  dangling. The hourly service stopped resolving after the package upgrade.
- Restored host scheduling with local units under `/etc/systemd/system`.
  The timeline timer is enabled for `OnCalendar=hourly`, and its service runs
  `/usr/local/sbin/snapper-timeline-all-roots`. That wrapper now creates
  default root/home snapshots with the installed Snapper CLI instead of the
  removed `/usr/lib/snapper/systemd-helper`, and retains the external-root
  loop. Its explicit Btrfs rescan block remains commented out. Cleanup is
  enabled daily at 21:41, with a dry-run helper covering the configured
  number, timeline, and empty-pre-post algorithms for root and home. The boot
  snapshot timer is enabled for the next boot and was not manually run.
- The host root/home configs and mounted Kingston root/home configs all use
  `QGROUP_RESCAN_WINDOW="05:00-21:00"` and the shared
  `/home/rebroad/.local/state/snapper/qgroup-rescan-hold-until` marker.
  Kingston's root and home qgroups are `1/100` and `1/101`; the marker is set
  to epoch `1792378800`, which is 2026-10-19 04:00 BST. The systemd timer's
  next timeline run is at 18:00 BST and the next cleanup run at 21:41 BST.
  No snapshot or cleanup service was manually run during deployment.
- Enabled a sleep.target service and a system-sleep hook that share one
  root-owned timer controller under `/usr/local/libexec`. It refreshes an
  expired marker by invoking the root-owned hold writer as `rebroad`, then
  restarts the timer only if it was active before sleep. A delegated refresh
  while the marker was still in the future left its SHA-256 unchanged. The
  two Btrfs filesystems both report `no rescan operation in progress`. A real
  suspend/resume and its catch-up ordering are still unverified.
- Committed and pushed these local scheduler and resume changes to the root
  config repository as `e6f893c8c` (`Restore Snapper schedules and sleep
  guard`). The staged diff was limited to Snapper units/helpers and passed
  `git diff --cached --check` plus a redacted scan for common credential and
  private-key patterns.
- Fresh host inspection found exactly three installed kernel-image/header
  releases: `7.1.8+deb13-amd64`, `7.1.13+deb13-amd64`, and
  `7.2.6+deb13-amd64`. DKMS reports the current signed package installed for
  all three. For each release, `modinfo -k` selects
  `updates/dkms/btrfs.ko.xz`, reports matching vermagic, and signer
  `Rebroad's module signing key`; each matching initramfs contains that module
  path. Secure Boot is enabled. The running kernel is 7.1.13; 7.2.6 remains
  the default next boot and has not been booted.
- Tested reversible stock-module rollback for 7.2.6: removing its DKMS
  registration restored the stock module, which `modprobe` selected with the
  matching vermagic. Reinstalling the DKMS package rebuilt and signed the
  candidate, restoring hash
  `f50e898b36ccb15189fb7ac63b7c3fdb04f5fa88e3627880329f5ecd4e423a10` and its
  initramfs entry. The running 7.1.13 module was untouched.

## Explicit quota-cleanup disable during investigation (2026-10-18)

- Source review found that empty `SPACE_LIMIT` is not a disable setting in
  Snapper 0.13.2. The cleanup parameter starts with its default `0.5`; parsing
  an empty string logs a parse error and leaves that default unchanged.
  `MaxUsedLimit::is_enabled()` disables quota-aware cleanup when the fraction
  is at least `1.0`.
- Changed `SPACE_LIMIT` to `"1.0"` in the host root/home configs and the
  mounted Kingston root/home configs. Owners and mode `0640` were preserved;
  the shared rescan window and hold path and the configured `FREE_LIMIT` were
  unchanged. No cleanup was run while making this change.
- Committed the host config correction as `d2b3d529f` and pushed it to the
  root config repository's configured remote. Committed the Kingston config
  changes as `56484aa`; that repository has no configured remote. An unrelated
  staged deletion in the Kingston repository was left untouched.
- At 17:47 BST, `btrfs qgroup show -re` warned that both `/` and
  `/mnt/kingston` had inconsistent qgroup data, while `btrfs quota rescan -s`
  reported no scan in progress on either filesystem. The restored hourly
  timeline service then completed its scheduled 18:00 BST run successfully.
- That run created three `timeline` snapshots for each of the host `root` and
  `home` configs between 18:00:01 and 18:00:05. The host root `/` and
  `/mnt/p8/@` have the same Btrfs subvolume ID 262; `/home` and
  `/mnt/p8/@home` both have ID 263. The `/mnt/p8` filesystem-root config path
  and its `@/etc/snapper/configs` path both led the wrapper to those same
  targets. Thus the hourly wrapper had been creating redundant snapshots
  through multiple views of the same Btrfs subvolumes. This explains the
  duplicate snapshots, but is not yet proof of the underlying qgroup
  inconsistency cause.
- Updated the root-repo timeline wrapper to record each target by its device,
  Btrfs subvolume ID, and Snapper config before creating a snapshot. The
  external-root loop now retains that state across mountpoints and config
  directories. A no-side-effect check against live paths selected `/` and
  `/home` once, skipped `/mnt/p8/@` and `/mnt/p8/@home` as duplicates, and kept
  `/mnt/kingston/@` and `/mnt/kingston/@home` eligible as distinct targets.
  `sh -n` passed. Installed wrapper SHA-256:
  `e82b938e2b90fb4758692e331067fd5cadad6804814e686340ec0ee36d1d9070`.
  Committed and pushed to the `/` repo as `19f05f689`. Confirm the next
  scheduled run creates one snapshot per config/subvolume and still snapshots
  the separate Kingston filesystem.
- After the 18:00 run, both filesystems still warned that qgroup data was
  inconsistent, and neither had a rescan in progress. The shared hold was
  active, so this run is not evidence that accounting recovered.
- The first scheduled cleanup is still pending at 21:41 BST. Verify its logs
  show no empty-limit parse warnings, and that inconsistent qgroups cause the
  quota-aware cleanup pass to be skipped without suppressing count/time-based
  retention cleanup.

## Four independent snapshot groups on two filesystems (2026-10-18)

- The required accounting is four distinct snapshot collectives: p8-root,
  p8-home, Kingston-root, and Kingston-home. A qgroup ID is local to its Btrfs
  filesystem, so the same level-1 IDs can be reused on the two filesystems as
  long as root and home have different IDs within each filesystem.
- Built an isolated two-device QEMU workload using the exact Debian
  `7.1.13+deb13-amd64` kernel image and the installed Snapper package from
  commit `476f0814f665` (Snapper 0.13.2, libsnapper 8.2.0, `btrfs-quota`). The
  guest binary and library hashes were respectively
  `3e1e9bab1e82c7e5a77b45e965cd5e746e78c6ba77ae9c3b0f5245812fa70402` and
  `8290bbb047da6344e621193261a52666d16a810724d7341d3a1ec80e273cab3e`. Each
  filesystem had separate root and home configs with separate snapshot
  QGROUPs (`1/0` and `1/1`). The configs and source subvolumes were paired
  under their own level-2 tracker. Different file sizes made the four
  exclusive totals distinguishable.
- With the stock Debian Btrfs module (SHA-256
  `6ba4e90c38b021af552252af72fb5b0ed56ce027e348a422604feb1c2661ecfc`), each
  root snapshot marked its filesystem inconsistent and Snapper completed one
  rescan per filesystem. The home snapshots then marked both filesystems
  inconsistent again. The second round ran with those flags still set, and
  the per-filesystem limiter prevented another scan. `snapper` reported the
  group values as stale. In a matching one-filesystem control, a full rescan
  changed the home group's exclusive counter from 1,130,496 to 1,146,880
  bytes, confirming the stale value was materially wrong.
- Repeated the comparison with the current host-installed, signed candidate
  Btrfs module (SHA-256
  `0b9ff5e9ac2531ecf25fc5ef2c7c7c5df0a107501d33aa20141674b50c5509f5`). The
  same four-config workload completed two snapshot rounds with no new scan
  and no inconsistency warning. Each config had two snapshots and retained a
  separate exclusive total:

  | Collective | QGROUP | Referenced bytes | Exclusive bytes |
  | --- | --- | ---: | ---: |
  | p8-root | 1/0 | 6,586,368 | 2,260,992 |
  | p8-home | 1/1 | 4,358,144 | 1,146,880 |
  | Kingston-root | 1/0 | 8,814,592 | 3,375,104 |
  | Kingston-home | 1/1 | 4,292,608 | 1,114,112 |

- A full rescan on each filesystem left all four referenced and exclusive
  totals unchanged. Candidate serial log:
  `linux.build/qgroup-four-groups-candidate-20261018/serial.log`; stock
  comparison:
  `linux.build/qgroup-four-groups-stock-20261018/serial.log`. The candidate
  module signature was not trusted by the disposable QEMU guest, so the guest
  logged module-verification failure and became tainted; signature enforcement
  was not enabled for this accounting test.
- This proves that separate root/home snapshot groups satisfy the four-total
  reporting requirement in the tested layout, and that the candidate kernel
  fast path prevents the repeated inconsistency seen with the stock module.
  It does not prove that every Snapper-only design must fail. The p8 host
  configs were last observed sharing `QGROUP=1/100`; they must be moved to
  distinct groups before host accounting can satisfy this requirement. A
  Snapper-only alternative and the safe migration of the p8 qgroup hierarchy
  remain to be assessed.

## Live root/home qgroup topology audit (2026-10-18)

- Read the active p8 and Kingston Snapper config files and Btrfs qgroup
  hierarchy. The live kernel is `7.1.13+deb13-amd64`; no qgroup rescan was
  running on either filesystem during the audit.
- Kingston is already configured with distinct groups: root `1/100` and home
  `1/101`. Their level-2 trackers separately pair the live root/home
  subvolume with its snapshot group (`2/1` for root, `2/0` for home).
  Structural membership maps to 69 root and 15 home snapshots, plus the
  corresponding `.snapshots` directory in each group.
- p8 root and home both still use `1/100`. That group has 79 root and 28 home
  snapshot subvolumes, plus both `.snapshots` directories. Its current level-2
  tracker `2/0` pairs the live root subvolume with this combined snapshot
  group; p8 home has no separate tracker. The migration must separate the
  existing home membership as well as direct future snapshots to a home
  group, and establish the matching tracker without merging root and home.
- Both filesystems report qgroup data inconsistent. Their stored referenced
  and exclusive byte counters are stale and were not used as measurements.
  The audit establishes the current grouping problem but does not identify
  which snapshot operation originally marked either filesystem inconsistent.

## Reproduce and migrate the p8 shared root/home group in QEMU (2026-10-18)

- Used the exact Debian `7.1.13+deb13-amd64` kernel image and the same Snapper
  0.13.2 executable and libsnapper hashes recorded above. QEMU loaded the
  signed candidate Btrfs module, SHA-256
  `0b9ff5e9ac2531ecf25fc5ef2c7c7c5df0a107501d33aa20141674b50c5509f5`; guest
  signature enforcement was off, as in the earlier accounting test.
- Configured the p8 root and home Snapper configs to share `1/0`, while the
  root source and snapshot group were tracked under `2/0`. The first root
  snapshot left the filesystem consistent. The following home snapshot
  produced `BTRFS warning (device vda): qgroup marked inconsistent, qgroup
  inherit needs a rescan`; no rescan had started. This reproduces the p8
  shared-group/tracker mismatch with the candidate kernel, independent of the
  stock-kernel fallback seen in the earlier QEMU comparison.
- Migrated the fixture's existing home snapshot memberships from `1/0` to
  `1/1`, added a level-2 tracker `2/1` containing the live home source and
  home snapshot group, changed the home config to `1/1`, and ran one full
  rescan. Subsequent root and home snapshots started no additional rescan and
  emitted no new inconsistency warning. After two snapshots per config, the
  group's counters were:

  | Collective | QGROUP | Referenced bytes | Exclusive bytes |
  | --- | --- | ---: | ---: |
  | p8-root | 1/0 | 6,586,368 | 2,260,992 |
  | p8-home | 1/1 | 4,374,528 | 1,163,264 |

- A further full rescan left both groups' referenced and exclusive counters
  unchanged. The test ended `P8-MIGRATION: PASS`; serial log:
  `linux.build/qgroup-p8-shared-to-separate-candidate-20261018/serial.log`.
  This validates the membership move and separate tracker in the disposable
  fixture; it does not mean the p8 host has been changed.
- Kernel journal chronology on the host ties earlier inconsistency events to
  the hourly Snapper service: on 2026-10-16 the service started at 12:42:29,
  logged its home and root timelines, and the kernel marked a qgroup
  inconsistent at 12:42:32; on 2026-10-17 the service started at 11:16:47,
  logged home and root timelines, and the kernel marked a qgroup inconsistent
  at 11:16:49. The timestamps identify the service-level trigger, while the
  controlled p8 reproduction identifies the home snapshot as the trigger for
  the shared p8 group.
- At the live audit time, 2026-10-18 18:59 BST, the host had no active rescan.
  The last completed scans in the retained journal were on device `sda1` at
  2026-10-16 12:42:29 and device `sdb1` at 2026-10-17 11:16:47; each was
  followed seconds later by a new inconsistency. The logs checked here do not
  establish the historical device-name-to-filesystem mapping. The
  force-suspend marker was active until 2026-10-19 04:00 BST, which deferred
  new scans; the configured rescan window opens at 05:00. No manual host
  rescan or group migration was started during that audit because activation
  of the candidate module had not been verified.
- The host had booted `7.1.13+deb13-amd64` on 2026-10-14 15:47 BST. Its signed
  candidate module was installed later, on 2026-10-18 16:47 BST, and the
  loaded module's build ID differed from that installed candidate. The host
  is not yet proven to be running this candidate; verify the loaded module at
  a planned reboot before applying the p8 migration. The 2026-10-16/17 kernel
  events predate the candidate installation.

## Fresh live host audit (2026-10-18 19:46 BST)

- The host is still running `7.1.13+deb13-amd64`. The installed signed DKMS
  module is `updates/dkms/btrfs.ko.xz`, SHA-256
  `0b9ff5e9ac2531ecf25fc5ef2c7c7c5df0a107501d33aa20141674b50c5509f5`, build
  ID `dbacb384412daefbc812969624941d88b79396b7`. The loaded module's sysfs
  build ID is `059c7530edfb1e54ce3b71e44d1f4aa3a4216e17`, so it is not the
  installed candidate. Do not migrate p8 until a planned boot verifies the
  candidate is loaded.
- `/` is p8 subvolume `@` on `/dev/nvme0n1p5`; `/mnt/kingston` is `/dev/sdb1`.
  Both filesystems report inconsistent qgroup data, and `btrfs quota rescan
  -s` reports no scan in progress on either filesystem.
- On p8, the live root source `0/262` and snapshot group `1/100` are under
  tracker `2/0`; the live home source `0/263` has no tracker. Both Snapper
  configs still use snapshot QGROUP `1/100`, and both `.snapshots` subvolumes
  are members of that group. The p8 migration from the QEMU fixture has not
  been applied to the host.
- Kingston's live root and home sources are under separate trackers, with
  root snapshot QGROUP `1/100` under `2/1` and home snapshot QGROUP `1/101`
  under `2/0`. Its root/home separation is already present.
- Snapper 0.13.2 is installed from local commit `017efa14`. The live root and
  home configs have the shared force-suspend hold path, `QGROUP_RESCAN_DAILY_LIMIT=no`,
  `QGROUP_RESCAN_WINDOW=05:00-21:00`, and `SPACE_LIMIT=1.0`. The hold marker is
  absent, so the temporary hold is not active. No rescan was started during
  this read-only audit.
- Refreshed GitHub state for Snapper PR #1203: it remains open against
  `openSUSE/snapper` master at `5a2dd6a8559c1a04c5575bf184acb347dce0d8f7`;
  all seven reported CI checks pass and no review decision is recorded.

## DKMS source-selector and failure-path audit (2026-10-18)

- The installed DKMS package is present and reports the patched module
  installed for all three installed releases: 7.1.8, 7.1.13, and 7.2.6. Its
  packaged source map also includes exact 7.2.9 source for a future candidate.
- Ran the installed source selector in a disposable `/var/tmp` directory.
  For `7.1.13+deb13-amd64`, it selected the packaged 7.1.13 source and copied
  a matching `Makefile`. For unmapped `7.3.0+deb13-amd64`, it exited 1 with
  `no matching Btrfs source is packaged` before copying source files. The
  disposable output was removed.
- Source inspection confirms the unsupported-release failure is propagated:
  DKMS `PRE_BUILD` invokes the selector; `dkms_autoinstaller` returns failure
  when `dkms autoinstall` fails; `/etc/kernel/postinst.d/dkms` propagates that
  status; and Debian's `linux-run-hooks` executes post-install hooks with
  `run-parts --exit-on-error`. This indicates an unsupported kernel image
  post-install can fail and leave dpkg needing recovery. The complete failed
  kernel-package transaction was not reproduced. This package failure mode is
  not an acceptable safety mechanism; an APT-level pre-install policy and its
  interaction with unrelated security upgrades remain to be designed and
  tested, as tracked in `GOAL.md`.

## Live host gate check (2026-10-18 19:13 BST)

- `sudo btrfs quota rescan -s /` and the corresponding Kingston query both
  reported no rescan in progress. Both filesystems still report inconsistent
  qgroup data, so their stored quota counters remain stale.
- The live root and home Snapper configs both use `QGROUP=1/100` and have the
  shared `05:00-21:00` rescan window and force-suspend marker configured. The
  marker deadline is 2026-10-19 04:00 BST. This blocks new scans until that
  deadline; it does not block a qgroup-layout change by itself.
- The installed candidate module has SHA-256
  `0b9ff5e9ac2531ecf25fc5ef2c7c7c5df0a107501d33aa20141674b50c5509f5` and
  build ID `dbacb384412daefbc812969624941d88b79396b7`. The currently loaded
  module has build ID `059c7530edfb1e54ce3b71e44d1f4aa3a4216e17`, so candidate
  activation remains unverified and the p8 migration has not been run.

## Paired shared-versus-distinct QGROUP test on stock Btrfs (2026-10-18)

- Repeated a paired QEMU workload twice using the exact Debian
  `7.1.13+deb13-amd64` kernel image (SHA-256
  `b03e297715d838016b69362ecda036f13bcd663077982efa6087d084155c6c4b`), the
  stock Btrfs module from the stock initrd override (SHA-256
  `6ba4e90c38b021af552252af72fb5b0ed56ce027e348a422604feb1c2661ecfc`), and
  Snapper 0.13.2 executable/library hashes
  `3e1e9bab1e82c7e5a77b45e965cd5e746e78c6ba77ae9c3b0f5245812fa70402` and
  `8290bbb047da6344e621193261a52666d16a810724d7341d3a1ec80e273cab3e`.
- In each guest, p8 root and home configs shared QGROUP `1/0`; Kingston root
  and home used distinct QGROUPs `1/0` and `1/1`. Both filesystems began with
  the same source data sizes, Snapper setup sequence, and two root/home
  snapshot rounds. Before the workload, removed all level-2 tracker-parent
  relations from both filesystems and recorded qgroup trees showing no parents.
  Snapper then recreated tracker relationships as snapshots were made. The
  only configured treatment difference was whether the two configs on a
  filesystem shared their snapshot QGROUP.
- On both repetitions, the p8 root snapshot made qgroup inconsistency visible
  before the following home snapshot. The distinct-ID Kingston root snapshot
  also made its filesystem inconsistent before its home snapshot. Across the
  two filesystems, the first round ended with three inconsistency events and
  the second with four; the scan-completion count rose from four after setup
  to five and then six. Thus sharing the root/home ID was not necessary for
  inconsistency in this workload. Since the p8 flag was already set by the
  root snapshot, this run cannot assign an additional onset to the home
  snapshot.
- Before the final full rescan, p8 root and home both reported the same stale
  combined QGROUP value, `7,569,408` referenced and `2,260,992` exclusive
  bytes. The full rescan changed that shared value to `10,944,512` referenced
  and `3,407,872` exclusive bytes. On the distinct-ID Kingston filesystem,
  the full rescan yielded separate exclusive values of `2,260,992` for root
  and `1,146,880` for home. The shared-ID layout therefore cannot meet the
  required independent root/home accounting even apart from its
  inconsistency.
- Both repetitions produced the same event sequence and counters. Run 1
  serial log and fixture: `linux.build/qgroup-p8-shared-stock-20261018/`;
  repeated run: `linux.build/qgroup-p8-shared-stock-repeat-20261018/`. Both
  use the shared initrd and test script from the first fixture. These are
  QEMU results only. The test rules out shared IDs as the sole cause, but does
  not rule out a distinct Snapper-only layout or establish that the kernel
  change is necessary.

## Snapper post-create QGROUP assignment alternative (2026-10-18)

- Tested a Snapper-only alternative on the exact stock kernel/module and
  Snapper 0.13.2 build recorded above: temporarily clear each config's
  `QGROUP`, create the snapshot without Btrfs qgroup inheritance, then assign
  the new subvolume into its configured level-1 QGROUP with
  `btrfs qgroup assign --no-rescan`. Restore the config QGROUP afterward. The
  test used four distinct groups and ran two root/home snapshot rounds on both
  filesystems.
- The assignment command returned successfully and no full rescan completed
  during the rounds. However, each assignment printed `quotas may be
  inconsistent, rescan needed`; `btrfs qgroup show` then reported inconsistent
  data. Before the final full rescan, the four groups returned stale values
  (referenced, exclusive bytes): root `(0, 2,228,224)`, home
  `(0, 1,114,112)`, Kingston-root `(0, 3,342,336)`, and Kingston-home
  `(0, 1,081,344)`. The full rescan
  changed them respectively to `6,586,368/2,260,992`,
  `4,358,144/1,146,880`, `8,814,592/3,375,104`, and
  `4,292,608/1,114,112`. Thus deferring qgroup assignment until after
  snapshot creation still makes accounting stale until a rescan and does not
  meet the accurate-counter requirement.
- The guest's `qgroup marked inconsistent` kernel warning count remained zero;
  the evidence for inconsistency is the qgroup inconsistency status reported
  by Btrfs and the stale values that changed after the full rescan. The scan
  count stayed at four during the snapshot rounds and increased only for the
  final per-filesystem rescans. Serial log, init script, and images are in
  `linux.build/qgroup-postassign-stock-20261018/`.

## Snapper shared-QGROUP tracker source path (2026-10-18)

- Source inspection of `snapper/snapper/Btrfs.cc::prepareQGroupTracking()`
  explains the shared root/home QGROUP mismatch. The first config creates a
  level-2 tracker containing its live source and the configured snapshot
  QGROUP. When a second config uses that same QGROUP, its source has no parent
  while the snapshot QGROUP already has one. Snapper only adds the missing
  source if the tracker contains exactly the existing QGROUP; because it
  already contains the first config's source too, that condition fails.
  Snapper then sees an existing parent and returns `Consistent` without
  pairing the second source with the shared QGROUP.
- `Btrfs::createSnapshot()` still passes the configured QGROUP to the snapshot
  inheritance ioctl (`BtrfsUtils.cc::create_snapshot()`). The second source
  therefore reaches Btrfs with no parent while the inherited QGROUP is under
  the first source's tracker. This fails the candidate kernel's safe
  shared-parent preconditions and takes its conservative rescan fallback,
  matching the candidate-module QEMU reproduction where root stayed
  consistent and the following home snapshot marked the shared group
  inconsistent.
- This establishes that sharing a QGROUP causes a real Snapper tracker
  mismatch and prevents separate root/home totals. It does not explain the
  stock-module failures with distinct QGROUPs: those configs have separate
  two-member trackers, and the matching four-group QEMU test passes with the
  candidate fast path but marks qgroups inconsistent on stock. The evidence
  therefore points to two related but distinct issues: shared IDs are an
  invalid layout for the required accounting and mishandle tracker setup;
  stock Btrfs also cannot maintain the valid distinct-ID layout without
  rescanning.

## Snapper-only alternative assessment and kernel necessity (2026-10-18)

- The required Snapper layout has a snapshot-only level-1 QGROUP and a
  separate tracker containing that QGROUP plus the live source. On stock
  `7.1.13`, the existing snapshot quick-inherit path only handles a source
  whose direct parent is the target QGROUP, with the target's exclusive and
  referenced counters equal. In the required layout, source and target are
  siblings under a level-2 tracker, so stock Btrfs uses the conservative
  rescan path. Making the source a member of the snapshot QGROUP to satisfy
  the old fast path would include live-source extents in the snapshot-only
  collective and violate the required accounting.
- Two Snapper-only workarounds were tested on stock Btrfs. Leaving snapshots
  untracked still marks qgroups inconsistent. Creating snapshots without
  QGROUP inheritance and assigning them afterward marks quota accounting
  inconsistent until a full rescan; its stale counters do not match the
  post-rescan values. Thus neither preserves current independent counters
  without rescanning.
- The candidate adds a fast path only for the exact safe sibling layout:
  source has one parent; target has that same sole parent; and the common
  tracker contains exactly the source and target. It checks target, common
  parent, and ancestor counter overflow before changing counters. Different
  or multiple parents, extra tracker members, missing source membership, and
  overflow retain the rescan fallback. The QEMU four-group workload on the
  exact kernel passed with the candidate and failed on stock; the shared-ID
  layout still falls back because its home source lacks the common tracker.
- The exact-release qgroup sanity tests passed at nodesizes 4, 8, 16, 32, and
  64 KiB, checking referenced, exclusive, compressed, and ancestor counters,
  as well as different/multiple-parent fallbacks and ancestor overflow without
  partial updates. The serial log is
  `/var/tmp/qgroup-root-cause-7.1.13/shared-parent-union-20261018/qemu-4g.log`
  and ends `QGROUP-SANITY: PASS`.
- Conclusion, scoped to Snapper's Btrfs QGROUP accounting on
  `7.1.13+deb13-amd64`: the kernel companion is required to preserve accurate
  snapshot-only exclusive totals across repeated snapshots without a full
  rescan after each snapshot. This does not claim that no custom userspace
  extent-accounting design could be written; that would be a different
  accounting implementation and is outside the required Snapper QGROUP
  interface. Public upstream submission and host rollout remain separate
  gates.

## Live pre-reboot module and Snapper audit (2026-10-18)

- The host is running `7.1.13+deb13-amd64` with Secure Boot enabled. The
  `modinfo`-selected Btrfs module is the signed candidate at
  `/lib/modules/7.1.13+deb13-amd64/updates/dkms/btrfs.ko.xz`, SHA-256
  `0b9ff5e9ac2531ecf25fc5ef2c7c7c5df0a107501d33aa20141674b50c5509f5`, vermagic
  `7.1.13+deb13-amd64 SMP preempt mod_unload`, signer `Rebroad's module
  signing key`. The matching 7.1.13 initramfs contains the same module hash.
- The loaded module is still the stock build ID
  `059c7530edfb1e54ce3b71e44d1f4aa3a4216e17`. No boot setting was changed and
  no reboot was initiated. The verified one-shot GRUB entry for the running
  kernel is
  `gnulinux-7.1.13+deb13-amd64-advanced-d09493d6-16e4-4253-83b7-a5334dd892c7`.
  Activate the candidate only at the next planned reboot, using that one-shot
  entry, then confirm its loaded build ID before the qgroup migration.
- `/usr/bin/snapper` is package
  `snapper 0.13.2-1+local1.20261018183503.g017efa146426`; the local source
  checkout is commit `017efa1464260504f2781f383758f72ebe743449`. The live
  executable SHA-256 is
  `d3579b4ebdf75b2f45aea66f0a125415f4b53d4fa539fe6cf85550d49af9016a`; the
  loaded `libsnapper.so.8.2.0` SHA-256 is
  `a792a8c13937aaec4d91526aeb54311e51c50393e5f15970c93f8d3b36889b77`.
- No qgroup rescan is running. Both `/` and `/mnt/kingston` still report
  `qgroup data inconsistent`; their displayed counters are stale and must not
  be treated as current measurements. p8 root and home still share `1/100`.
  Kingston root uses `1/100` and home uses `1/101`. Both filesystems have the
  `05:00-21:00` rescan window and shared hold path configured; the daily limit
  is disabled on p8 and no hold marker currently exists. No qgroup membership,
  counter, or host configuration was changed during this audit.

## Reversed-order shared-ID QEMU comparison (2026-10-18)

- Ran the same fresh two-filesystem Snapper workload twice under the exact
  `7.1.13+deb13-amd64` kernel image: once with the stock Btrfs module
  (`6ba4e90c38b021af552252af72fb5b0ed56ce027e348a422604feb1c2661ecfc`) and
  once with the candidate module
  (`0b9ff5e9ac2531ecf25fc5ef2c7c7c5df0a107501d33aa20141674b50c5509f5`). Both
  runs used the same Snapper executable and library hashes
  `3e1e9bab1e82c7e5a77b45e965cd5e746e78c6ba77ae9c3b0f5245812fa70402` and
  `8290bbb047da6344e621193261a52666d16a810724d7341d3a1ec80e273cab3e`.
  Each run started from newly formatted QEMU filesystems with no snapshots,
  clean qgroup state, and zero inconsistency flags. The p8 configs used one
  shared snapshot QGROUP (`1/0`); Kingston used separate root and home groups
  (`1/0` and `1/1`). The workload created the home snapshot first on both
  filesystems, then the root snapshot, and recorded qgroup trees before and
  after a full rescan.
- With the stock module, the first home snapshot marked p8 (`vda`) inconsistent
  and the first Kingston-home snapshot also marked Kingston (`vdb`)
  inconsistent. Thus the shared root/home ID is not necessary for the stock
  module's qgroup inconsistency in this workload. The subsequent root snapshot
  caused no new p8 warning; Kingston-root did mark Kingston inconsistent.
- With the candidate module, neither first home snapshot marked qgroups
  inconsistent. The following p8-root snapshot marked p8 inconsistent, while
  Kingston-root did not produce a warning. Before that p8-root snapshot,
  Snapper had placed the home source and shared snapshot QGROUP under one
  tracker. The root source had no parent, so this second config reused a
  snapshot QGROUP already tracked with the home source; the inheritance then
  caused `qgroup inherit needs a rescan`. This shows a shared-ID/tracker
  interaction that depends on which config first establishes the tracker.
- After full rescans, p8 root and home displayed the same shared-QGROUP value,
  while Kingston root and home retained distinct values. The shared-ID layout
  therefore still cannot provide independently queryable p8-root and p8-home
  exclusive totals, even in cases where it avoids an inconsistency warning.
- The shared p8 ID was configured after `setup-quota` had initially allocated
  separate level-1 groups; the unused `1/1` qgroup remained present. The test
  began with fresh filesystems and no tracker parents, and Snapper built the
  runtime tracker hierarchy during the home-first snapshot sequence. This
  probes the configuration transition and order-dependent tracker behavior,
  but it does not reproduce every detail of the host's existing qgroup tree.
  Root-first cases are recorded in the earlier paired QGROUP comparison; this
  run does not add root-only or cleanup-path coverage beyond those fixtures.
- Serial logs and fresh filesystem images are in
  `linux.build/qgroup-shared-home-first-stock-20261018/` and
  `linux.build/qgroup-shared-home-first-20261018/`. Both QEMU runs completed
  and both full rescans cleared the inconsistency flags. Continue the remaining
  root-only and topology-matched cases before deciding whether the kernel
  companion is required for the host's intended distinct-group layout.

## Separate expected qgroup fallback from a kernel correctness bug (2026-10-18)

- The stock-module four-group QEMU run demonstrates that shared root/home IDs
  are not necessary for a qgroup inconsistency flag: distinct root and home
  groups still triggered `qgroup inherit needs a rescan` on both filesystems.
  The full scans completed and cleared the flags. This alone does not show
  incorrect final accounting or a kernel correctness defect.
- Snapper's current `Btrfs::prepareQGroupTracking()` creates a level-2 tracker
  containing the live source qgroup and the snapshot-only level-1 qgroup, then
  calls `quota_rescan_if_needed()` before the snapshot operation. The snapshot
  is created with the configured level-1 group as its inheritance target.
  `quota_rescan_if_needed()` starts and waits for a full scan when it sees the
  filesystem's inconsistency flag and no scan is already running. Thus a
  snapshot can make qgroups inconsistent, and a later Snapper invocation can
  rescan before taking its next snapshot. The paired QEMU logs show scans
  completing between such snapshot operations. This is a plausible mechanism
  for recurring hourly scans; root-only and home-only repeated-operation
  cases remain to be measured directly.
- In the tested distinct-group layout, the source and target are siblings
  under the same level-2 tracker. The candidate module has a bounded quick
  accounting path for that exact two-member hierarchy; the stock module takes
  the conservative full-rescan path. That behavior is consistent with a
  safety fallback when the stock code cannot update exclusive counters
  incrementally. The QEMU evidence does not establish that the stock kernel
  leaves wrong counters after a completed rescan. Treat the candidate as a
  rescan-avoidance optimization unless additional evidence shows a correctness
  failure or that the required operating constraints cannot be met otherwise.
- These controlled results establish that a shared root/home level-1 group
  cannot provide the four separately queryable snapshot totals and can leave
  Snapper's tracker hierarchy mismatched. They do not establish that sharing
  is the cause of all inconsistency events. The root-only, home-only, and
  both-order cases were completed in the later matrix recorded below; the
  host-matched four-group hierarchy remains to be tested.

## Stock-kernel matrix and Snapper's deferred-rescan child path (2026-10-18)

- Repeated the manually constructed shared/distinct QGROUP matrix on the
  running release kernel image `7.1.13+deb13-amd64`
  (SHA-256 `b03e297715d838016b69362ecda036f13bcd663077982efa6087d084155c6c4b`).
  The guest loaded the stock Btrfs module
  (`6ba4e90c38b021af552252af72fb5b0ed56ce027e348a422604feb1c2661ecfc`) and
  the latest-upstream-based Snapper source with the current local Btrfs
  tracking change. The guest reported Snapper 0.13.2 / libsnapper 8.2.0 and
  verified their loaded hashes: `snapper`
  `917fdd6b8e18aed76de840639d4a8f6daca389ad895e2b3f0c3249f760b89d3f`,
  `libsnapper.so.8.2.0`
  `c34dfac310cd204ef4e38b0d62cd5af835ce5c2674ab3f0fda719e50e6ccdb8d`.
- The full shared matrix completed with `MATRIX: PASS`. In its rate-limit
  case, root and home both used snapshot QGROUP `1/100`, the automatic window
  was `00:00-24:00`, and `QGROUP_RESCAN_DAILY_LIMIT` was enabled. Root's first
  snapshot marked qgroups inconsistent. Before home’s first snapshot, Snapper
  performed one rescan; that snapshot marked qgroups inconsistent again.
- A focused `--debug` rerun confirmed that the next timeline snapshot, whose
  parent is the prior snapshot (`num_parent != 0`), enters
  `prepareQGroupTracking()`: Snapper logged that the rescan was deferred until
  `2026-10-19 20:34:30 UTC` under the one-per-24-hours policy, then logged that
  it created the snapshot while accounting remained inconsistent. The scan
  count stayed at one, and `snapper list` printed
  `qgroup data is inconsistent; displaying last-known used-space values`.
  This validates the guard on both parentless and timeline-child snapshots;
  the earlier source version only checked the parentless path.
- Before an explicit full rescan, the shared group still showed the stale
  `3,162,112 referenced / 16,384 exclusive` counters. After the full rescan,
  `1/100` showed `7,389,184 / 49,152`; the inconsistency flag cleared. Thus a
  deferred scan leaves quota status explicitly stale and a later full scan
  recomputes the aggregate. It does not show that the kernel's conservative
  fallback is incorrect, nor does this rate-limit test identify why each
  snapshot requests that fallback.
- Full and focused logs, guest overlay, and filesystem images are under
  `/var/tmp/linux.build/qgroup-matrix-20261018/stock/latest-snapper/` and
  `/var/tmp/linux.build/qgroup-matrix-20261018/stock/latest-snapper-rate-debug/`.
  The focused serial log is the evidence for the deferral message and stale
  `snapper list` behavior. Continue with the host-matched four-group hierarchy,
  including cleanup/deletion and tracker-parent relationships, before deciding
  whether the kernel companion is operationally needed.

## Host-shaped four-group testing on kernel 7.2.6 and p8 group split (2026-10-18)

- After reboot, the host runs `7.2.6+deb13-amd64` and loads the signed candidate
  Btrfs module from `/lib/modules/7.2.6+deb13-amd64/updates/dkms/btrfs.ko.xz`.
  Its SHA-256 is
  `f50e898b36ccb15189fb7ac63b7c3fdb04f5fa88e3627880329f5ecd4e423a10`; signer
  `Rebroad's module signing key`; `/proc/modules` marks it out-of-tree.
- Repeated the fresh host-shaped four-group QEMU workload on the exact 7.2.6
  kernel image. Both runs used Snapper executable hash
  `917fdd6b8e18aed76de840639d4a8f6daca389ad895e2b3f0c3249f760b89d3f` and
  libsnapper hash
  `c34dfac310cd204ef4e38b0d62cd5af835ce5c2674ab3f0fda719e50e6ccdb8d`.
  The stock run loaded the Debian module at the 7.2.6 `updates/dkms` path,
  SHA-256 `9cd15b503d5f11fc8b8cdab89c7fcfc97467368718e8a3ea60468ec207f5536c`;
  the candidate run used the signed module hash above. The kernel, Snapper
  binaries, two fresh Btrfs filesystems, source changes, tracker topology,
  order, and eight-snapshot workload were matched. QEMU used TCG because KVM
  is unavailable in this environment.
- With stock Btrfs, the distinct four-group layout produced eight
  `qgroup marked inconsistent, qgroup inherit needs a rescan` warnings and six
  automatic rescans before the explicit final scans (`PRE-FULL scans=6`). With
  the candidate, it produced no warning and no automatic scan (`PRE-FULL
  scans=0`). Explicit final rescans completed in both guests and the runs ended
  `HOST-TOPOLOGY: COMPLETE`. This confirms that distinct root/home groups do
  not by themselves prevent the stock module's conservative fallback in this
  workload; the candidate fast path avoids those repeated scans for the tested
  two-member tracker hierarchy. It does not show stock counters remain wrong
  after a completed scan, and the exact-topology cleanup/deletion path remains
  untested.
- The first stock log used a stale 7.1.13 path in its diagnostic hash command.
  Before recording the result, corrected that path and reran the stock case on
  fresh disks. The corrected serial log reports the exact 7.2.6 kernel and
  stock-module hash above with the same six pre-full scans, eight warnings, and
  successful completion. The corrected log and QEMU stderr are
  `/var/tmp/linux.build/qgroup-host-topology-20261018/stock-7.2.6-corrected.serial.log`
  and `stock-7.2.6-corrected.qemu.stderr`; the candidate evidence is in
  `candidate-7.2.6.serial.log` and `candidate-7.2.6.qemu.stderr` in the same
  directory.
- Read-only inspection after reboot found p8 root `0/262` under tracker `2/0`,
  p8 home source `0/263` with no tracker, root `.snapshots` directory `0/271`,
  home `.snapshots` directory `0/272`, and 15 extant home snapshot
  subvolumes. All home snapshot subvolumes and `0/272` were children of shared
  group `1/100`; both Snapper configs still named `1/100`.
- Following the user's request for separate p8 collectives, moved the 15 home
  snapshot qgroups and `0/272` from `1/100` to new `1/101`, created tracker
  `2/1` containing home source `0/263` and group `1/101`, and changed only
  `/etc/snapper/configs/home` to `QGROUP="1/101"`. Root remains `1/100` under
  `2/0`. A full quota rescan was explicitly started after these qgroup
  membership changes because Btrfs marks quota accounting inconsistent when
  qgroup parent/child assignments change. The rescan took several minutes;
  `btrfs quota rescan -s /` then reported no operation in progress and
  `btrfs qgroup show /` no longer reported inconsistent data.
- Final live verification showed p8 root and home independently queryable as
  `1/100` and `1/101`, with root and home trackers `2/0` and `2/1`. At the
  verification read, raw counters were respectively `185190010880 referenced /
  19866832896 exclusive` bytes for root and `287781203968 referenced /
  21184958464 exclusive` bytes for home. Snapper root and home list commands
  returned without the stale-quota warning. These are live counters and can
  change with normal filesystem activity. Kingston's groups were not changed.
  The later exact-kernel QEMU cleanup workload below exercises the four-group
  topology; live-host snapshot and cleanup acceptance remains to be checked.

## Exact 7.2.6 host-topology cleanup and deletion workload (2026-10-18)

- Reused the exact `7.2.6+deb13-amd64` kernel image, the same latest-upstream
  Snapper executable and library hashes, and the matched stock and candidate
  Btrfs modules from the host-topology test. Each run used two fresh Btrfs
  filesystems with four independent snapshot collectives: p8-root, p8-home,
  Kingston-root, and Kingston-home. The guest changed 1 MiB of source data
  before each of two snapshots per config, then ran timeline cleanup with a
  one-snapshot hourly limit and synchronously deleted the remaining snapshots.
- Stock Btrfs completed the eight-snapshot creation phase with six automatic
  rescans and eight `qgroup inherit needs a rescan` warnings. Timeline cleanup
  deleted one snapshot in each config; synchronous deletion removed the
  remaining snapshot in each config. Neither cleanup nor deletion increased
  the scan or fallback-warning counts: they remained at six and eight. The
  candidate completed the same workload with zero automatic scans or fallback
  warnings, including cleanup and deletion.
- Explicit full rescans completed on both filesystems in both runs, cleared
  the inconsistency state, and produced qgroup trees for all four independent
  collectives. The candidate full rescans logged no warning. An additional
  explicit full rescan on each stock filesystem then logged
  `qgroup info item update error -2`; both scans completed and the final
  `btrfs qgroup show` output did not report inconsistent data. The warning
  needs investigation, but this fixture did not leave the measured counters
  stale. It does not independently verify every nonempty source/snapshot
  exclusive value or prove that repeated later snapshots preserve them.
- The counter sequence shows that the first reconciliation scan on each
  filesystem cleared the inconsistent flag without a warning. Before that
  scan, all four snapshot groups still showed stale values: root `1/100`
  `4,243,456 referenced / 49,152 exclusive` bytes and home `1/101`
  `3,178,496 / 32,768` bytes, on both filesystems. After the first scan and
  before the extra rescan, all four groups showed `16,384 / 16,384` bytes,
  matching their only remaining child, the empty `.snapshots` directory; the
  source subvolumes showed `4,210,688 / 4,210,688` bytes. A second explicit
  rescan on each filesystem then emitted the `-ENOENT` warning, completed, and
  left those same counters and a clear inconsistency state. Thus this fixture
  shows the first full scan restores the expected empty-group totals; the
  warning is specific to the redundant second scan and did not leave the
  measured counters stale.
- Source inspection identified the failing item as qgroup `0/260`, the first
  root snapshot subvolume removed by timeline cleanup. The transaction-commit
  warning occurs when `btrfs_run_qgroups()` tries to update a dirty in-memory
  qgroup whose info item is absent. The subsequent diagnostic trace found why
  the stale object survives, and a disposable-build behavior test removed the
  warning; see “Trace qgroup removal after snapshot cleanup” below. A
  production kernel patch and exact-source validation remain outstanding.
- `~/bin/snapper-exponential-retention` was not used in this QEMU workload;
  Snapper's built-in timeline cleanup and synchronous deletes reproduced the
  warning without it. The script itself deletes snapshots with Snapper and
  does not explicitly request a quota rescan. Its optional `btrfs filesystem
  du` queries are read-only; its `btrfs quota rescan -s` report command only
  queries scan status. Thus it is not necessary for the reproduced warning,
  though its snapshot deletions could exercise the same Btrfs lifecycle on the
  host. The inspected user's crontab and targeted cron/systemd paths contained
  no invocation of this script; this does not rule out a manual invocation or
  another scheduler outside those paths.
- The guests reported `HOST-TOPOLOGY: COMPLETE` and `no rescan operation in
  progress` at the end. Logs, disposable disk images, and initrd overlays are
  in `/var/tmp/linux.build/qgroup-cleanup-20261018/`; the serial logs are
  `stock.serial.log` and `candidate.serial.log`. The minimal initrd lacks
  systemd, so Snapper's attempt to enable the timeline timer was not part of
  this direct snapshot/cleanup harness. QEMU used TCG; this is not a live-host
  cleanup acceptance run.

## Trace qgroup removal after snapshot cleanup (2026-10-18)

- A diagnostic build from the exact `7.2.6+deb13-amd64` source reproduced the
  second-rescan `-ENOENT` on both independent filesystems. The failing object
  was qgroup `0/260`, the first root snapshot. The trace now identifies the
  cause: `btrfs_qgroup_cleanup_dropped_subvolume()` calls
  `btrfs_remove_qgroup()`, which deletes the qgroup info item and starts
  removing its relation to `1/100`. Relation removal successfully deletes
  both on-disk relation items and removes the in-memory relation, but
  `quick_update_accounting()` returns `1` because the parent counters need a
  full rescan (`qgroup->excl != qgroup->rfer`). That path has already marked
  qgroups inconsistent. `btrfs_remove_qgroup()` treats this positive
  “rescan required” result like an error and exits before removing/freeing the
  deleted snapshot's in-memory qgroup. A later rescan visits that stale object
  and tries to update its deleted info item, producing `-ENOENT`.
- The behavior was implemented in `fs/btrfs/qgroup.c` on the exact v7.2.6
  source tag. `__del_qgroup_relation()` now reports whether it actually
  removed the in-memory relation and checks `del_relation_rb()`'s result;
  `btrfs_remove_qgroup()` treats a positive accounting result as nonfatal
  only after confirmed relation removal. The positive rescan-required result
  remains visible to the public relation-deletion path, and the inconsistency
  flag remains set for the required full scan.
- The complete external Btrfs module built against the installed
  `7.2.6+deb13-amd64` headers. QEMU booted the exact Debian 7.2.6 kernel under
  TCG and loaded that module, confirmed by its compressed hash in the guest.
  The four-collective workload completed timeline cleanup and synchronous
  deletion for all four configs. Neither operation added scans or warnings;
  the final full rescans finished without the stale-qgroup `-ENOENT` warning,
  reported no scan in progress, and cleared the inconsistency flags. After
  rescanning, all four empty snapshot groups reported the expected 16 KiB
  `.snapshots` directory total, and all four source groups reported
  4,210,688 bytes. `git diff --check` passed. This validates the specific
  deletion failure in the disposable workload; kernel review and a durable
  regression test remain outstanding.
- This change did not reduce the six automatic scans from snapshot creation
  or the eight ordinary `qgroup inherit needs a rescan` warnings. Those are a
  separate fallback path and still require investigation against the
  accounting requirements. The cleanup trace establishes a Btrfs teardown
  bug, not that the deletion warning caused the hourly rescan frequency.
- At the investigation time, the current `torvalds/linux` master tip still
  had the unconditional `if (ret) goto out` after `__del_qgroup_relation()`
  in [`fs/btrfs/qgroup.c`](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/tree/fs/btrfs/qgroup.c?id=f909e534f5e34feb2ea2701d54df63e21aa506fc).
  The reproduced path is therefore not already fixed in that upstream tip.
  Diagnostic source, module, serial logs, and test image artifacts are in
  `/var/tmp/linux.build/qgroup-id-trace/`; the stock trace is
  `removal-trace2.serial.log` and the original diagnostic run is
  `removal-fix2.serial.log`. The exact-source patched module's follow-up run
  is `removal-current-patch/serial.log`; its build is in
  `/mnt/kingston/builds/rebroad/src/linux.build/qgroup-removal-7.2.6/`.
  Both QEMU runs used TCG and disposable filesystems; this is not yet
  production-kernel validation. The patched workload still had six automatic
  snapshot-creation scans, so the ordinary fallback issue remains open.

## Port and test shared-parent quick inherit on 7.2.6 (2026-10-19)

- Ported the snapshot quick-inherit path for the required four-group
  hierarchy to the exact v7.2.6 source checkout, alongside the qgroup-removal
  fix above. The fast path applies only when the source and snapshot qgroups
  have one common parent with exactly those two members. It preflights all
  four counters on the updated group and its ancestors before changing any
  counters; other parent layouts and overflow retain the full-rescan path.
- Added in-tree Btrfs sanity coverage for the eligible shared-parent case,
  different and multiple parent topologies, extra shared-parent members, and
  overflow in each counter on an ancestor. The complete external module built
  against `/usr/src/linux-headers-7.2.6+deb13-amd64` with
  `CONFIG_BTRFS_FS_RUN_SANITY_TESTS` enabled. QEMU booted the exact Debian
  `7.2.6+deb13-amd64` kernel under TCG. Its module-load log ran the qgroup
  sanity cases at all five configured node sizes and proceeded to the
  workload, showing the tests returned successfully. The guest-confirmed
  compressed module hash is
  `d1767f4363941786aacfd4629c1af42f0e449e1b8422b16a7880bf742e85d623`.
- In the same four-config QEMU workload, the candidate module produced zero
  automatic scans and zero inconsistency warnings across eight snapshots,
  timeline cleanup, and synchronous deletion. The paired exact-source
  baseline module, which included the deletion fix but not shared-parent
  quick inherit, produced six automatic scans across those snapshots. Neither
  module started additional scans or warnings during cleanup/deletion. The
  candidate's four later scans were explicit full-rescan controls. Both
  modules completed with no scan in progress; the candidate's final qgroup
  tree showed 16,384 bytes for each empty snapshot group and 4,210,688 bytes
  for each source group. The test-enabled module is in
  `/mnt/kingston/builds/rebroad/src/linux.build/qgroup-removal-7.2.6/`.
- Added a forced full-rescan comparison before cleanup in both root-first and
  home-first order. Before and after the rescan, each snapshot collective on
  both filesystems reported 4,243,456 referenced and 49,152 exclusive bytes;
  the scan reported no inconsistency warning. Thus the fast-path values
  matched full-rescan accounting for this nonempty two-snapshot workload.
  The paired stock-module runs in both operation orders also finished their
  full rescans with those same counters for each snapshot collective. The
  generated payload independently totals 4 MiB per source: a 2 MiB `stable`
  file plus two 1 MiB `change-*` files, so the reported 4,243,456-byte
  referenced total is the 4 MiB payload plus 49,152 bytes of filesystem
  metadata. Independently inspected the persisted candidate p8 filesystem
  image with `btrfs inspect-internal dump-tree`: its qgroup tree lists
  `0/258`, `0/260`, and `0/262` as the members of `1/100`; the extent tree
  identifies one unique 16 KiB metadata block (`refs 1`) for each of those
  roots, at bytenrs 32243712, 31047680, and 31965184 respectively. Their sum
  is exactly 49,152 bytes, matching `1/100`'s exclusive counter. The image is
  `/var/tmp/linux.build/qgroup-host-topology-20261018/fs-p8-candidate-726.img`
  (SHA-256 `7ca2ebbc9a677d13c87c7b0e3ba1b937c699ac1b6c63b269557a3733026c9f77`).
  This reconciles the tested image's metadata counter; it is not a substitute
  for repeated-cycle or live-host verification.
  The final source's comparison logs are
  `/var/tmp/linux.build/qgroup-id-trace/removal-current-patch/candidate-final.serial.log`
  and `candidate-final-home-root.serial.log` in the same directory.
- This demonstrates rescan avoidance for the tested hierarchy while
  preserving explicit fallback cases. It does not establish incorrect stock
  counters: the stock path still completes rescans. Longer repeated cycles
  remain before deciding whether the optimization is safe to retain. The
  separate qgroup deletion regression still needs durable coverage.

## Trace the stock snapshot-rescan cycle (2026-10-19)

- In the exact 7.2.6 Btrfs source, `qgroup_snapshot_quick_inherit()` only
  handles the existing fast path when the source's direct parent is the
  requested snapshot QGROUP. In the tested layout, the source subvolume and
  snapshot QGROUP are siblings under a level-2 tracker, so that check returns
  the positive “rescan needed” result. `btrfs_qgroup_inherit()` propagates it
  to `need_rescan` and calls `qgroup_mark_inconsistent()` after releasing the
  qgroup lock.
- The matching latest-upstream Snapper source calls
  `Btrfs::prepareQGroupTracking()` before `create_snapshot()`. When the
  tracker relations already match the expected source/snapshot hierarchy,
  that method calls `quota_rescan_if_needed()`. If the previous snapshot set
  the inconsistent flag, Snapper starts and waits for a full scan before it
  creates the next snapshot. That next snapshot reaches the same conservative
  kernel fallback. The six stock scans in the eight-snapshot test therefore
  correspond to three subsequent snapshots on each of its two filesystems;
  the first snapshot on each starts the cycle, and no extra scan is triggered
  after the final snapshot.
- The stock serial logs show the first snapshot's
  `qgroup inherit needs a rescan` warning with no completed scan yet, followed
  by a completed scan during the next snapshot operation and another
  inheritance warning. This matches the source call order and the scan count.
  The candidate fast path avoids setting inconsistency for this topology, so
  Snapper's pre-snapshot check sees consistent accounting and starts no scan.
- This traces the repeated rescans for the tested hierarchy to a conservative
  kernel fallback followed by Snapper's pre-snapshot consistency check. It
  does not show that the full scan repairs incorrect counters, nor establish
  that every host rescan follows this path. Both stock and candidate full
  rescans report the same measured nonempty counters in both tested operation
  orders. Live correlation and longer repeated cycles remain open.

## Eight-round host-topology QEMU cycles (2026-10-19)

- Ran fresh four-collective filesystems through eight snapshot rounds per
  config (32 snapshots total, 16 on each filesystem), followed by an explicit
  full rescan on each filesystem. Both root-first and home-first orders used
  the exact `7.2.6+deb13-amd64` kernel and Snapper 0.13.2 executable hash
  `917fdd6b8e18aed76de840639d4a8f6daca389ad895e2b3f0c3249f760b89d3f`.
  The stock Btrfs module hash was
  `9cd15b503d5f11fc8b8cdab89c7fcfc97467368718e8a3ea60468ec207f5536c`; the
  candidate module hash was
  `f50e898b36ccb15189fb7ac63b7c3fdb04f5fa88e3627880329f5ecd4e423a10`.
  All runs completed successfully under QEMU TCG.
- With the candidate module, both operation orders completed all 32 snapshots
  with zero automatic scans and zero inconsistency warnings. The two explicit
  final scans completed. For all four independent collectives, the counters
  before and after those scans were unchanged at 10,633,216 referenced and
  147,456 exclusive bytes. The captured p8 image's qgroup tree assigns the
  `.snapshots` subvolume and eight snapshots to each snapshot group. Its extent
  tree shows nine unique 16 KiB metadata blocks (`refs 1`) per group, totaling
  147,456 bytes; the 10 MiB file payload plus this metadata totals the
  reported 10,633,216 referenced bytes. This independently reconciles the
  candidate's counters for this fixture.
- With the stock module, both operation orders completed 30 automatic scans
  before the two explicit final scans, for 32 completed scans total. The
  counters for the collective belonging to the *last* snapshot in the order
  were short immediately before the final scans: 9,568,256 referenced and
  131,072 exclusive bytes, versus 10,633,216 and 147,456 afterward. The
  shortfall was 1,064,960 referenced and 16,384 exclusive bytes. The other
  collective already matched the post-rescan value. Reversing snapshot order
  moved the shortfall from home to root on both filesystems. Thus the full scan
  clears the inconsistency and accounts for the newest snapshot; this test
  does not indicate a persistent post-rescan accounting error. It does show
  that the stock path leaves the most recently snapshotted collective with
  stale counters until the next full scan.
- The stock harness's warning total is based on the current kernel `dmesg`
  buffer, so its 25/26 count is not used as a total warning count. The scan
  counts come from the completed-scan messages after the harness clears the
  buffer at workload start. The operation-level serial lines confirm rescans
  continue through the sequence.
- The four serial logs are
  `/var/tmp/linux.build/qgroup-repeated-20261019/candidate-root-home-run2.serial.log`,
  `candidate-home-root-run2.serial.log`,
  `stock-verified-root-home.serial.log`, and
  `stock-verified-home-root.serial.log`. The tested initrd images and fresh
  Btrfs disk images are preserved in the same directory. This longer sequence
  supports the source-level explanation of the rescan cycle and demonstrates
  candidate counter stability for the tested topology. The next section
  records repeated cleanup and deletion; hold/window behavior during the
  extended sequence and live-host correlation remain unverified.

## Eight-round cleanup and synchronous deletion (2026-10-19)

- Extended the eight-round four-collective workload through Snapper timeline
  cleanup and synchronous deletion on the exact 7.2.6 kernel in both
  root-first and home-first orders. The same
  Snapper 0.13.2 executable was used for both module variants. Timeline cleanup
  was configured with `TIMELINE_MIN_AGE=0` and
  `TIMELINE_LIMIT_HOURLY=2-2`; `SPACE_LIMIT=1.0` left quota-based cleanup out
  of this test. Each config had eight snapshots before cleanup, one afterward,
  then zero after deleting the remaining snapshot with `snapper delete --sync`.
- The candidate module
  (`f50e898b36ccb15189fb7ac63b7c3fdb04f5fa88e3627880329f5ecd4e423a10`)
  entered cleanup with two scans, both explicit full-rescan controls, and zero
  inconsistency warnings in either order. Cleanup and all four synchronous
  deletes added no scans or warnings in either order. The qgroup-removal-only
  baseline module
  (`9cd15b503d5f11fc8b8cdab89c7fcfc97467368718e8a3ea60468ec207f5536c`)
  entered cleanup after 30 automatic scans and two explicit scans; cleanup and
  synchronous deletion added no scans in either order. Its warning count was
  25/26 in the retained `dmesg` buffer; these counts are not treated as total
  warning counts. Neither module logged `qgroup info item update error -2`.
- After deleting all snapshots, each `1/100` and `1/101` group contained only
  its `.snapshots` subvolume and reported 16,384 referenced / 16,384 exclusive
  bytes. Final explicit full rescans completed on both filesystems; those four
  group counters were unchanged afterward and both scans cleared without a
  qgroup error. The baseline's final snapshot counters were reconciled by the
  full scan before cleanup, as in the paired eight-round creation run.
- The candidate serial logs are
  `/var/tmp/linux.build/qgroup-repeated-cleanup-20261019/candidate-cleanup-root-home.serial.log`
  and
  `/var/tmp/linux.build/qgroup-repeated-cleanup-home-root-20261019/candidate-cleanup-home-root.serial.log`.
  The baseline serial logs are
  `/var/tmp/linux.build/qgroup-repeated-cleanup-stock-20261019/stock-cleanup-root-home.serial.log`
  and
  `/var/tmp/linux.build/qgroup-repeated-cleanup-stock-home-root-20261019/stock-cleanup-home-root.serial.log`.
  All four show `HOST-TOPOLOGY: CLEANUP-COMPLETE`. This demonstrates repeated
  cleanup and synchronous deletion across the four independent groups and
  both operation orders in these QEMU cases. The separate qgroup-removal patch
  review, durable in-kernel regression coverage, and live-host cleanup
  validation were open at the time; the first two are covered by the next
  section.

## Upstream qgroup teardown fixes and 7.2.6 backport (2026-10-19)

- Checked the live Btrfs maintainer `for-next` ref
  (`2789b2c034d7c0c8687355921a38c5ac41a565fa`). It already contains the
  reviewed [positive-rescan teardown fix](https://git.kernel.org/pub/scm/linux/kernel/git/kdave/linux.git/commit/?id=dd906477cc2c33c82ec17e6301bd4be4ea588565),
  which matches the observed `btrfs_remove_qgroup()` failure, and a follow-up
  [tolerated `-ENOENT` return fix](https://git.kernel.org/pub/scm/linux/kernel/git/kdave/linux.git/commit/?id=727bb633fea9a3b37061b837c85647218dc28485).
  The live stable `linux-7.2.y` branch was at `v7.2.11`; source checks of
  `v7.2.6`, `v7.2.9`, `v7.2.10`, and `v7.2.11` found neither change. Do not
  file a duplicate upstream report. Release-matched local modules still need
  these backports until the selected kernel packages include them.
- Updated the exact 7.2.6 source to use the maintainer fix's semantics:
  positive rescan-required status does not abort qgroup teardown, and a
  tolerated missing qgroup info item does not leak `-ENOENT` when there are no
  relations. Added in-tree sanity coverage for both cases. It verifies the
  rescan-required call returns `1` while removing the qgroup and relation, and
  that removing a qgroup whose on-disk item is absent returns success.
- The test-enabled external module built against the exact
  `/usr/src/linux-headers-7.2.6+deb13-amd64` headers. QEMU booted the exact
  Debian 7.2.6 kernel under TCG; both cases passed at all five configured
  metadata node sizes (4, 8, 16, 32, and 64 KiB), and the guest completed the
  four-group eight-round snapshot/cleanup/deletion workload. It reached
  `HOST-TOPOLOGY: CLEANUP-COMPLETE`; no test failure, module-load failure, or
  `qgroup info item update error -2` appeared. The guest-confirmed compressed
  module SHA-256 is
  `c9ca139550f1b057f96239b77f369666abcf8216d586afa7a2a66bd794d3bd88`.
- The serial log is
  `/var/tmp/linux.build/qgroup-removal-7.2.6/upstream-backport-test-rerun.serial.log`;
  the test module and initrd overlay are in
  `/var/tmp/linux.build/qgroup-removal-7.2.6/`. This is exact-kernel QEMU
  validation, not the signed DKMS rollout. Port the backport to each installed
  release-matched source variant and verify its signed module and initramfs;
  live-host cleanup validation remains open.

## Snapper rescan hold, window, and stale quota values (2026-10-19)

- Used the latest-upstream Snapper 0.13.2 executable from the Snapper PR branch
  (guest SHA-256
  `917fdd6b8e18aed76de840639d4a8f6daca389ad895e2b3f0c3249f760b89d3f`) with
  the exact Debian `7.2.6+deb13-amd64` kernel and stock Btrfs module in QEMU
  TCG. A stock snapshot created the expected inconsistent-qgroup state. All
  four configs had matching `QGROUP_RESCAN_WINDOW=05:00-21:00`, the same hold
  path, and the daily cap disabled.
- With a future hold deadline, `snapper list --columns number,used-space`
  showed the `Used Space` column, the stale-values warning, and the last-known
  16 KiB value; the scan count remained zero. Replacing the deadline with an
  expired timestamp while leaving the production window closed also kept the
  stale value visible and the scan count at zero. After changing all four
  configs to an open window, the expired marker permitted one scan; the list
  retained the 16 KiB value without a stale warning and quota status reported
  no scan in progress. The harness failed if quota was reported unavailable,
  if either deferral started a scan, or if recovery failed to start exactly one.
- The guest then completed the eight-round four-group timeline cleanup and
  synchronous deletion sequence, reaching
  `HOST-TOPOLOGY: CLEANUP-COMPLETE`. No qgroup info item `-ENOENT` error
  appeared. The serial log is
  `/var/tmp/linux.build/qgroup-rescan-gates-20261019/production-window-stock.serial.log`;
  the initrd, two disposable Btrfs images, and test harness are alongside it.
  This verifies the hold/window behavior and stale quota display in this QEMU
  scenario. Repeated hold cycles across all four configs and live-host
  correlation remain open.

## APT kernel upgrade to 7.2.9 and DKMS verification (2026-10-18)

- The host's `apt upgrade` transaction (started at 22:27) installed and
  configured the Debian backports 7.2.9 kernel and headers.
  `/var/log/apt/history.log` records completion at 22:33:42, and
  `dpkg --audit` is empty. Although the
  terminal displayed repeated `Tried to start delayed item ... but failed`
  warnings before Ctrl+C, the package logs show the kernel post-install
  completed. APT 3.0.3 is installed on Debian 13; the warning is associated
  with Debian APT issue #1111554, but the host's logs do not preserve the
  download-stage detail needed to identify the specific triggering transfer.
- The real 7.2.9 header hook ran the installed DKMS selector, compiled and
  signed `btrfs-qgroup/7.1.13+rebroad1.z20261018.154420.g29a221f567b0.m87a66389.s3a8cfb46`,
  and installed `/lib/modules/7.2.9+deb13-amd64/updates/dkms/btrfs.ko.xz`.
  Current DKMS status lists successful installs for all four installed
  releases: 7.1.8, 7.1.13, 7.2.6, and 7.2.9.
- For 7.2.9, `modprobe --show-depends -S` selected the DKMS module,
  `modinfo` reported vermagic `7.2.9+deb13-amd64 SMP preempt mod_unload` and
  signer `Rebroad's module signing key` (key ID
  `79:BC:F6:D4:0C:64:F7:5A:78:CB:ED:BE:1F:4C:E8:1A:53:22:DE:29`), and the
  compressed module hash was
  `aab0c4b4e297f6814b167381956c6147d63c8adef5d1dde8aed8e5122acdce5f`. The
  generated `/boot/initrd.img-7.2.9+deb13-amd64` contains that DKMS module.
  Secure Boot is enabled. The host remains running 7.2.6; the following
  exact-release QEMU test validates 7.2.9 without changing the host's running
  kernel.
- Then booted the exact Debian `7.2.9+deb13-amd64` image in QEMU through OVMF,
  Microsoft's signed shim, Debian GRUB, and the enrolled `Rebroad` MOK
  certificate. The kernel logged Secure Boot lockdown and
  `module.sig_enforce=1`; it loaded the signed DKMS Btrfs module from
  `updates/dkms`, with the same compressed module hash listed above. An
  unsigned 7.2.9 Btrfs module with matching vermagic was rejected. The guest
  ran the Snapper 0.13.2 stale-quota, hold-file, repeated snapshot, quota
  cleanup, and full-rescan comparison workload and ended
  `SNAPPER-QUOTA: PASS`. This validates the 7.2.9 module and Snapper workload
  under Secure Boot in QEMU, but does not replace the separate four-group
  accounting investigation on the in-use 7.2.6 kernel or a host reboot test.
  The initrd hash is
  `0c7cba5b07ed456bf12edaaa85a497ea4da44d95c13ec1565853a50ef8141e29`; the
  serial log hash is
  `5112524883654068a6776bb74f4bd3d1e0618ef19cfb873b15d969bddb98a5bb`. Both
  and the disposable ESP/filesystem images are under
  `/var/tmp/linux.build/qgroup-prod-validation-729/`.

## Timeline target deduplication runtime check (2026-10-19)

- The active `snapper-timeline.service` unit runs
  `/usr/local/sbin/snapper-timeline-all-roots`. Its SHA-256 matches the copy
  recorded by root-repo commit `19f05f689` (`fix(snapper): dedupe timeline
  targets`). This confirms the installed runtime is using that committed
  script rather than the separate home-bin copy.
- The system journal shows eight hourly service runs from 18:00 on 2026-10-18
  through 01:00 on 2026-10-19. All eight started and finished; 28 duplicate
  target skip messages were logged, and no failure messages appeared. This
  verifies repeated runtime execution of the deduplication path.
- This read-only check did not establish the exact number of new snapshots per
  target, inspect live qgroup accounting, or verify suspend/resume ordering.
  Those checks remain open in `GOAL.md`.

## Live DKMS selection and production-config module build (2026-10-19)

- `uname -r` reports `7.2.6+deb13-amd64`; installed kernel directories are
  7.2.6 and 7.2.9. `/usr/sbin/dkms status` reports the Btrfs DKMS package
  installed for both. `modprobe --show-depends -S` selects
  `updates/dkms/btrfs.ko.xz` for each release.
- Both selected modules have the expected release-specific vermagic and a
  PKCS#7 signature from the enrolled `Rebroad` module key. Their compressed
  hashes are `f50e898b36ccb15189fb7ac63b7c3fdb04f5fa88e3627880329f5ecd4e423a10`
  (7.2.6) and
  `aab0c4b4e297f6814b167381956c6147d63c8adef5d1dde8aed8e5122acdce5f`
  (7.2.9). They match the previously recorded pre-teardown-backport builds;
  the new backport is not yet deployed in the installed DKMS modules.
- Synced the committed 7.2.6 Btrfs source into the external build tree and
  built a production-configuration module against
  `/usr/src/linux-headers-7.2.6+deb13-amd64` with
  `CONFIG_BTRFS_FS_RUN_SANITY_TESTS=n`. It built successfully with vermagic
  `7.2.6+deb13-amd64 SMP preempt mod_unload`; SHA-256 of the unsigned `.ko` is
  `d1082f81fb340a755f0d671d2088ebc4d8c55487c521cd0da24d9f8074c46c87`. Symbol
  inspection found only the no-op `btrfs_run_sanity_tests` stub and no linked
  qgroup test functions. The artifact is under
  `/mnt/kingston/builds/rebroad/src/linux.build/qgroup-production-7.2.6-20261019/`.
- This verifies the production-config compile, not a signed installation or
  runtime load. The shell's `sudo -n` request required a password, so this
  audit could not recheck privileged live module state, Secure Boot policy,
  initramfs contents, or qgroup accounting. Backporting, signing, deployment,
  and exact-kernel runtime verification remain open.

## 7.2.9 teardown backport, regression test, and DKMS package staging (2026-10-19)

- The exact 7.2.9 Btrfs source shipped in the installed DKMS package lacks the
  two teardown fixes. Its required source change is the upstream two-line
  backport: reset a tolerated missing qgroup item result to success, and only
  treat negative relation-removal results as errors. Added the same in-kernel
  regression cases used on 7.2.6 to the 7.2.9 qgroup selftests.
- Built the production-configuration 7.2.9 module against
  `/usr/src/linux-headers-7.2.9+deb13-amd64` with sanity tests disabled. It has
  vermagic `7.2.9+deb13-amd64 SMP preempt mod_unload`; the unsigned module's
  SHA-256 is
  `5cd3e338bbad4a426900734ca4ef37abade7a1d0a1f1ec2586a12993c45ae554`.
- Built a separate test-enabled module from that 7.2.9 source and booted the
  exact Debian 7.2.9 kernel under QEMU TCG with the module loaded. The two new
  teardown cases passed at node sizes 4, 8, 16, 32, and 64 KiB; the guest
  reported `QGROUP-SELFTEST: MODULE-LOAD-PASS`. This direct-kernel test did not
  enable Secure Boot; signing and Secure Boot acceptance remain package gates.
  The test module SHA-256 is
  `11c8e588730e655438396f8e63ceb732d99885d1135d9825af3cab1e62836b25` and its
  serial log is
  `/mnt/kingston/builds/rebroad/src/linux.build/qgroup-test-7.2.9-20261019/qemu-final.serial.log`.
- Built DKMS package version
  `7.2.6+rebroad1.z20261019.g89f68effaaf87` at
  `/mnt/kingston/builds/rebroad/src/linux.build/dkms-package-20261019/btrfs-qgroup-dkms_7.2.6+rebroad1.z20261019.g89f68effaaf87_all.deb`.
  Its source map selects the updated 7.2.6 and 7.2.9 trees for their exact
  releases. Extracting the package and running each selector chose the
  expected source, including the teardown test. Package SHA-256 is
  `5e313fb7aa0b1532f7a5d470a041d970a10ca719eaa61acf93ae4e5a000aa8e9`.
- The package contains the public module certificate only; it does not contain
  the private signing key. The package is staged but not installed. The
  installed signed modules still have the previous hashes recorded above;
  package installation, DKMS build/sign, initramfs verification, and host
  runtime checks remain open in `GOAL.md`.

## Updated DKMS installation and 7.2.9 Secure Boot acceptance (2026-10-19)

- Installed `btrfs-qgroup-dkms` version
  `7.2.6+rebroad1.z20261019.g89f68effaaf87`. `dpkg --audit` is empty and DKMS
  reports successful installs for the currently installed
  `7.2.6+deb13-amd64` and `7.2.9+deb13-amd64` releases. For each release,
  `modprobe --show-depends -S` selects
  `/lib/modules/<release>/updates/dkms/btrfs.ko.xz`, with matching vermagic
  and signer `Rebroad's module signing key`. The compressed module hashes are
  `8d3c3c14834cc820fe4ba59004eb3041caeb0e91b3b8256f76d10d9736899f75` for
  7.2.6 and `2b94d9a03652ad61fdf8c019fa15b85581121680304ada9dc594be7ff8837e4a`
  for 7.2.9. Full `lsinitramfs` listings completed successfully with no
  stderr and contain each matching DKMS module.
- At 11:41 BST the host was still running `7.2.6+deb13-amd64`. Its loaded
  Btrfs build-ID note was `258e41d21460c34eaca2b1cfbed8a8f651d2a4bc`, while
  the installed 7.2.6 module's build ID was
  `46d2150765693e6b09846490c74ebdf710c0661b`. The updated 7.2.6 module is
  therefore installed and selected for the next load, but is not yet active in
  the running kernel. Reboot and compare the loaded build ID before claiming
  the teardown backport is active on the host.
- A first Secure Boot QEMU attempt reused a filesystem image containing the
  `root` and `home` subvolumes, so the init script stopped at
  `Could not create subvolume: File exists`; it did not reach the workload.
  Recreated a disposable 1 GiB Btrfs image and reran the exact Debian
  7.2.9 kernel under OVMF Secure Boot. The guest loaded the 7.2.9 DKMS module
  with hash above, confirmed `module.sig_enforce=1`, rejected an unsigned
  Btrfs module, exercised hold/expiry, stale quota display, cleanup, repeated
  snapshots, and full-rescan counter comparison, and ended
  `SNAPPER-QUOTA: PASS`. The serial log is
  `/var/tmp/linux.build/qgroup-prod-validation-729-dkms-20261019-freshfs/secureboot-dkms-serial.log`
  (SHA-256 `2a20b0f40161997587dda9444fa45e9a9900b16735f54478ee510a2d54c39d47`).
  Its Snapper executable hash was
  `be394f2d436828d52fa9ef7e70d85652f7316ee262ea5a8d40a713ad11b46742`; the
  current `7d4db17085ce` Snapper build is validated under 7.2.9 Secure Boot
  below.
- At the same live audit, both filesystem inconsistency flags were `0` and
  Kingston had no rescan in progress. No APT package holds or custom kernel
  pre-install guard are configured; `dpkg --audit` is clean. An unmapped DKMS
  release still fails through Debian's kernel package hooks and can leave the
  image package unconfigured. The pre-install update-safety policy, host boot
  of the new module, host rollback, accounting validation, and real
  suspend/resume remain open in `GOAL.md`.

## Exact 7.2.6 Secure Boot acceptance for the updated module (2026-10-19)

- Booted the exact `7.2.6+deb13-amd64` kernel from the disposable OVMF Secure
  Boot fixture, with `module.sig_enforce=1`. The guest loaded the updated DKMS
  Btrfs module with SHA-256
  `8d3c3c14834cc820fe4ba59004eb3041caeb0e91b3b8256f76d10d9736899f75`, matching
  the installed 7.2.6 module. A second module with the same 7.2.6 vermagic and
  code but with its appended PKCS#7 signature removed was rejected as unsigned.
- Snapper completed the hold/defer and expiry checks, reported last-known quota
  values as stale, deferred quota cleanup, created repeated root/home
  snapshots, performed quota-aware cleanup, and compared counters before and
  after a full rescan. The guest reported `SNAPPER-QUOTA: PASS` and powered
  down normally. The Btrfs filesystem image was freshly formatted, so the
  workload began without pre-existing subvolumes.
- The serial log is
  `/mnt/kingston/builds/rebroad/src/linux.build/qgroup-prod-validation-726-dkms-20261019/secureboot-dkms-serial.log`
  (SHA-256 `77e5d1c97a9710057ec43ae6f063d59557e342469baa512cb70ff7495466858a`).
  Its generated initramfs SHA-256 is
  `a732b343d401f353cd120fece3e240097a82a88bf66625ef26302947019a9f13`.
- This proves the updated module passes the exact-release Secure Boot QEMU
  workload. The running host still has a different module build ID loaded;
  host activation, rollback, and accounting checks remain open in `GOAL.md`.
  This earlier Secure Boot fixture used the previous Snapper executable
  (SHA-256 `be394f2d436828d52fa9ef7e70d85652f7316ee262ea5a8d40a713ad11b46742`);
  current Snapper is revalidated under Secure Boot below.

## Current Snapper package build and host runtime audit (2026-10-19)

- The official Snapper `master` fetched for this audit is
  `5a2dd6a8559c1a04c5575bf184acb347dce0d8f7`. PR #1203 is open with that exact
  base and head `7d4db17085ce12fcd8e7c371d3aae2ff61a44cf0`; all seven PR checks
  report success. The local Snapper checkout is clean at that head.
- Built the local Debian package from the current PR head using the
  `codex/local-debian-package-builder` recipe. Its source sync, configure,
  `make check`, package build, and binary feature audit completed successfully
  in `/mnt/kingston/builds/rebroad/src/snapper.build/local-package-builds/0.13.2-7d4db17085ce-20261019T003621Z/`.
  The Snapper testsuite log records 20 passed, 0 failed, and 0 errors. The
  optional zypp-plugin shell tests were skipped because Ruby and ShellCheck
  are not installed.
- The `snapper` package is
  `0.13.2-1+local1.20261019003646.g7d4db17085ce`, SHA-256
  `0c472e7d295c551d3b635f8334c0cc3c889f400aaa45889613be876f25cdca93`; the
  matching `libsnapper` package has SHA-256
  `07231bafde012b18fad6103e35e7a9b2c537d5d683d82ac781af811e343af7d7`.
  The candidate executable reports Btrfs quota support. An APT simulation
  installing only these two packages upgrades `snapper` and `libsnapper` with
  no package additions or removals.
- The installed host Snapper package is still
  `0.13.2-1+local1.20261018183503.g017efa146426`; it has not yet been upgraded
  to the current PR head. The running kernel is `7.2.6+deb13-amd64`. Read-only
  module inspection found the loaded Btrfs build ID matches the selected
  signed DKMS module at `/lib/modules/7.2.6+deb13-amd64/updates/dkms/`, whose
  compressed SHA-256 remains the pre-teardown-backport value
  `f50e898b36ccb15189fb7ac63b7c3fdb04f5fa88e3627880329f5ecd4e423a10`.
- `sudo -n` reports that a password is required, and the configured
  `ssh-askpass` cannot open the sandbox display. The packages were not
  installed; daemon restart, post-install config verification, and live
  Snapper acceptance remain open in `GOAL.md`.

## Repeated rescan-hold cycles across four configs (2026-10-19)

- Ran the latest-upstream Snapper build in QEMU with the exact Debian
  `7.2.6+deb13-amd64` kernel and the baseline Btrfs module from
  `/lib/modules/7.2.6+deb13-amd64/updates/dkms/` (compressed module SHA-256
  `9cd15b503d5f11fc8b8cdab89c7fcfc97467368718e8a3ea60468ec207f5536c`). The
  test used disposable copies of the p8 and Kingston Btrfs images and the
  distinct four-group layout.
- For each of `root`, `home`, `kingston-root`, and `kingston-home`, completed
  two cycles. Each cycle created a snapshot, confirmed `snapper list` displayed
  last-known used-space values while the hold marker was active, confirmed the
  closed `05:00-21:00` window continued to defer scans after marker expiry, and
  then opened the window. Both deferrals kept quota values visible, reported
  stale status, and started no scan; opening the window completed exactly one
  scan. The guest reported
  `RESCAN-HOLD-CYCLES: PASS cycles=8 configs=4 scans=9` (including the initial
  recovery scan) and `HOST-TOPOLOGY: CLEANUP-COMPLETE` after the existing
  eight-round timeline cleanup and synchronous-deletion workload. QEMU exited
  successfully with empty stderr; the serial log contains no `FAIL:` marker or
  qgroup info-item `-ENOENT` error.
- This validates repeated hold/window transitions and cleanup behavior in this
  QEMU scenario; it is not a Secure Boot test or live-host validation. The
  pre-full-rescan counters for p8-home and Kingston-home increased when the
  full rescan reconciled the last-snapshot shortfall, as seen in earlier stock
  runs; independent counter reconciliation and host correlation remain open.
- Artifacts are under
  `/mnt/kingston/builds/rebroad/src/linux.build/qgroup-rescan-hold-cycles-20261019/`.
  The serial log SHA-256 is
  `52df308808bb6966c3e1a733b3aa044a2bd97dadb9775c31745c367a483cc07e`; the
  test initrd SHA-256 is
  `21205c8983e2861557e89194031c2dc0d23cff6caea955a16e084b9f1f24b8bf`; and
  the test harness SHA-256 is
  `4534f65d38a1b97d1fc124237d9e94c6145ccb937cc827a7a61782a22874189e`.

## Live rescan-policy and timeline-service audit (2026-10-19)

- The running kernel is `7.2.6+deb13-amd64`. In the real host view, `/`,
  `/mnt/p8`, `/home`, and `/mnt/kingston` are mounted read-write; the
  unprivileged sandbox mount view reports them as read-only.
- The active p8 configs, `/etc/snapper/configs/root` and `home`, both contain
  `QGROUP_RESCAN_DAILY_LIMIT="no"`,
  `QGROUP_RESCAN_WINDOW="05:00-21:00"`, and the shared hold file
  `/home/rebroad/.local/state/snapper/qgroup-rescan-hold-until`. The installed
  timeline wrapper still has its explicit `btrfs quota rescan` block commented
  out.
- `snapper-timeline.timer` is active, with last trigger at 02:00 BST and next
  trigger at 03:00 BST. The 00:00, 01:00, and 02:00 services exited
  successfully and logged duplicate-target skips for the already-seen p8
  root/home paths. Read-only `info.xml` metadata confirms exactly one timeline
  snapshot per target directory per run: p8-root IDs 3847-3849, p8-home
  2794-2796, Kingston-root 2712-2714, and Kingston-home 2505-2507. The qgroup
  totals and whether any of these runs followed a real resume remain
  unverified.
- The captured kernel journal from 22:00 through 03:00 contains no qgroup
  inconsistency or rescan entries during the 23:00-02:00 timeline runs. It
  contains one earlier qgroup scan-completion message at 22:27 on
  `nvme0n1p5`. This is an absence-of-log evidence only; it does not prove the
  counters match a full scan or establish what the read-only Kingston qgroup
  state is.
- The Kingston configs are at
  `/mnt/kingston/@/etc/snapper/configs/{root,home}` (root-owned mode 0640), not
  `/mnt/kingston/etc/snapper/configs/`. Their policy values could not be read
  without sudo. `btrfs quota rescan -s` and `btrfs qgroup show` likewise
  returned `Operation not permitted` in the escalated non-root shell. No live
  scan-state or qgroup-counter conclusion is drawn from this audit.
- The installed Snapper/libSnapper package is still
  `0.13.2-1+local1.20261018183503.g017efa146426`; the current PR-head build
  remains uninstalled pending sudo authentication. These checks and remaining
  gates are tracked in `GOAL.md`.

## Live qgroup state via read-only Btrfs sysfs (2026-10-19 02:24 BST)

- Mapped sysfs filesystem UUID `d09493d6-16e4-4253-83b7-a5334dd892c7`
  (device `259:5`, p8 `/dev/nvme0n1p5`) and
  `ee36ee29-e720-4f55-a7a7-abc0e7a8185e` (device `8:1`, Kingston
  `/dev/sda1`). The local kernel's `fs/btrfs/sysfs.c` confirms that the
  read-only per-qgroup `referenced` and `exclusive` files expose the live
  `rfer` and `excl` counters under `qgroup_lock`, and `qgroups/inconsistent`
  reads the Btrfs inconsistency flag.
- p8 reported `inconsistent=0`. Its `1/100` counters were
  `187287556096 referenced / 23325188096 exclusive` bytes; `1/101` were
  `288737132544 / 21641932800` bytes. The tracker groups `2/0` and `2/1`
  reported `187313635328 / 85175504896` and
  `288814657536 / 288812109824` bytes, respectively.
- Kingston reported `inconsistent=1`. Group `1/100` reported
  `144916480 referenced / 2330951680 exclusive` bytes, and `1/101` reported
  `559206400 / 4080107520` bytes. Exclusive exceeds referenced for both
  groups, so these values are not trustworthy while the inconsistency flag is
  set. Trackers `2/0` and `2/1` reported `712634368 / 710557696` and
  `145063936 / 145063936` bytes. Historical config evidence maps Kingston
  root/home to `1/100` and `1/101`; the current root-owned configs could not be
  reread without sudo.
- The loaded Btrfs module build ID
  (`258e41d21460c34eaca2b1cfbed8a8f651d2a4bc`) matches the selected 7.2.6 DKMS
  module; its compressed SHA-256 is
  `f50e898b36ccb15189fb7ac63b7c3fdb04f5fa88e3627880329f5ecd4e423a10`. No
  `btrfs-qgroup-rescan` worker was visible. This captures the live flags and
  counters but does not identify when Kingston became inconsistent or prove
  what its counters become after a full rescan; those privileged checks remain
  open in `GOAL.md`.

## Kingston full-rescan reconciliation and post-rescan timeline cycle (2026-10-19)

- At 09:34 BST, the host was running `7.2.6+deb13-amd64`; both filesystems had
  no rescan in progress. Kingston's `qgroups/inconsistent` flag was `1`, and
  `btrfs qgroup show` warned that its qgroup data was inconsistent. The
  configured local window was open (05:00-21:00), both Kingston configs had
  `QGROUP_RESCAN_DAILY_LIMIT="no"`, and the shared hold marker was absent.
- Started a controlled full Kingston rescan with `btrfs quota rescan -w`.
  The kernel logged completion at 09:47:09 BST and explicitly reported that it
  cleared the inconsistency flag. The rescan status then reported no operation
  in progress. Kingston's `qgroup show` no longer warned, both snapshot groups
  had exclusive counters below their referenced counters, and p8 remained
  consistent throughout. This reconciled the previously impossible stale
  Kingston counters; it does not identify when or which operation first made
  them stale.
- The 10:00 BST hourly service completed successfully and created one timeline
  snapshot in each of p8-root, p8-home, Kingston-root, and Kingston-home.
  At 10:02, both filesystem inconsistency flags were still `0`, both rescan
  status queries reported no scan in progress, and the kernel journal contained
  no new qgroup event after the Kingston scan-completion message. This is one
  live post-rescan snapshot cycle on the 7.2.6 host, not yet evidence of stable
  behavior over repeated cycles or of the original onset cause.
- The host's installed package is now
  `0.13.2-1+local1.20261019003646.g7d4db17085ce` for both `snapper` and
  `libsnapper`. The installed binary reports Snapper 0.13.2, libsnapper 8.2.0,
  and Btrfs quota support; `snapper list-configs` lists p8 `root` and `home`.
  The daemon started on demand, and the 10:00 timeline run completed. The four
  live configs retain separate qgroups (`1/100` root, `1/101` home),
  `SPACE_LIMIT="1.0"`, the 05:00-21:00 window, the shared hold path, and the
  disabled daily limit.
- This evidence establishes a successful counter reconciliation and one
  candidate-host snapshot cycle afterward. Repeat the live observation and
  compare with the controlled stock-kernel QEMU results before treating the
  recurring inconsistency cause as fully resolved. A real suspend/resume,
  quota cleanup, package rollback/reinstall, and kernel-upgrade acceptance
  remain open in `GOAL.md`.

## Live sleep/resume guard wiring audit (2026-10-19 10:07 BST)

- The root-owned `snapper-timeline-sleep.service` is enabled and required by
  `sleep.target`. The root-owned `/usr/lib/systemd/system-sleep/98-snapper-timeline`
  hook is also installed; it invokes the same
  `/usr/local/libexec/snapper-timeline-sleep` helper with systemd's `pre` or
  `post` argument. This supersedes the earlier audit that found only the
  unrelated unattended-upgrades sleep hook.
- Static source inspection shows the helper records the timer's prior active
  state under `/run`, stops the timer before sleep, refreshes the shared rescan
  hold before restarting the timer after resume, and removes the state file.
  The service and system-sleep hook therefore share an idempotency guard. The
  `sleep.target` dependency is present, `snapper-timeline-sleep.service` is
  enabled, the timeline timer is active and enabled, and the state file and
  hold marker were absent at inspection.
- This verifies installed wiring and static ordering only. No real
  suspend/resume was initiated, so systemd's runtime ordering and the absence
  of a catch-up rescan remain to be verified on a real resume.

## Kingston post-snapshot qgroup counter reconciliation (2026-10-19)

- The sudo journal records `btrfs quota rescan -w /mnt/kingston` at 09:35:08
  and 10:12:22 BST. The local `btrfs-quota(8)` documentation says `-w` starts
  a rescan and waits, and may join one already in progress. The retained output
  of the 09:34:56 status command shows Kingston's inconsistency flag was `1`
  and no rescan was in progress. Immediately before the 10:12 command, the
  flag was `0` and no rescan was in progress. Kernel messages record scan
  completions at 09:47:09 and 10:23:32. The `-w` diagnostics therefore started
  both scans; neither was started by Snapper or its hourly timer. Exclude both
  from evidence about Snapper's automatic scan frequency.
- After the 10:00 BST hourly Snapper run created the four configured snapshots,
  Kingston's inconsistency flag was clear and no scan was in progress. At
  10:12:21 BST, a diagnostic full scan was manually started with
  `btrfs quota rescan -w /mnt/kingston` to compare the live counters against a
  full recomputation. Snapper and its hourly timer did not start this scan.
- The scan completed at 10:23:32 BST. The kernel logged
  `qgroup scan completed (inconsistency flag cleared)`, and a subsequent status
  query reported no rescan operation in progress. Thus Kingston was consistent
  by the Btrfs inconsistency flag after completion.
- Before the scan, groups `1/100`, `1/101`, `2/0`, and `2/1` had respective
  `(referenced, exclusive)` byte counters `(35,910,082,560,
  15,672,426,496)`, `(325,860,507,648, 18,670,075,904)`,
  `(325,870,014,464, 200,180,613,120)`, and `(35,910,098,944,
  35,719,372,800)`. Afterward they reported `(35,910,082,560,
  15,672,426,496)`, `(325,860,507,648, 18,670,256,128)`,
  `(325,870,194,688, 200,180,793,344)`, and `(35,910,098,944,
  35,719,372,800)`, respectively. The `1/101` and its tracker parent `2/0`
  each gained 180,224 exclusive bytes; the root group `1/100` and its parent
  `2/1` were unchanged.
- The pre-scan inconsistency flag was clear, and the full scan returned a
  different value for the home snapshot group's exclusive accounting without
  reporting an inconsistency. Because the scan ran for about 11 minutes while
  Kingston remained mounted and active, this comparison cannot distinguish
  pre-existing counter drift from legitimate filesystem changes during the
  scan. It does not show that Snapper triggered the difference, establish that
  the pre-scan counters were wrong, or identify the earlier cause of
  Kingston's inconsistency. More repeated live cycles and independent
  accounting reconciliation remain necessary.

## Second post-rescan live Snapper cycle (2026-10-19 11:00 BST)

- The hourly `snapper-timeline.service` completed at 11:00:02. On Kingston it
  created home snapshot 2516 (subvolume 5515) and root snapshot 2723
  (subvolume 5516). Their qgroups were respectively `0/5515` under snapshot
  group `1/101` and `0/5516` under `1/100`, preserving separate home/root
  accounting.
- At 11:00:23, both p8 and Kingston had a clear qgroup inconsistency flag, and
  `btrfs quota rescan -s` reported no operation in progress for either
  filesystem. There were no new kernel qgroup-rescan messages after the
  manually started Kingston scan completed at 10:23:32.
- This is the second observed hourly snapshot cycle after Kingston's
  reconciliation scan. It shows the candidate host did not request or require
  another rescan for these two hourly runs. It does not establish why Kingston
  became inconsistent before the 09:35 `-w` command or prove long-term
  stability.

## Third post-rescan live Snapper cycle (2026-10-19 12:00 BST)

- The 12:00:05 `snapper-timeline.service` run used the required locally built
  Snapper 0.13.2 / libsnapper 8.2.0 package. Kingston root snapshot 2724 and
  home snapshot 2517 were created as Btrfs subvolumes 5518 and 5517,
  respectively. Their qgroups were attached to the separate root/home groups
  `1/100` and `1/101`, under trackers `2/1` and `2/0`.
- At 12:00:49, both p8 and Kingston had `inconsistent=0`; Btrfs reported no
  Kingston rescan in progress, and the kernel journal had no qgroup-rescan
  messages after the 10:23:32 completion. The timeline service completed at
  12:00:06; its journal only reported duplicate p8 targets.
- This cycle ran with the previously loaded 7.2.6 shared-parent fast-path
  module, build ID `258e41d21460c34eaca2b1cfbed8a8f651d2a4bc`. The newly
  installed and signed module has build ID
  `46d2150765693e6b09846490c74ebdf710c0661b`, so this observation does not
  validate that newest module. Reboot and verify the loaded build ID before
  attributing subsequent live results to it.
- Together with the 10:00 and 11:00 runs, this is a third hourly snapshot
  cycle after Kingston's reconciliation without a new inconsistency flag or
  automatic rescan. The observation remains limited to these cycles; it does
  not explain the earlier inconsistency or independently validate every live
  qgroup counter.

## Historical Kingston snapshot/rescan feedback loop on stock Btrfs (2026-10-16/17)

- The retained previous-boot journal identifies the running kernel as stock
  Debian `7.1.13+deb13-amd64`. It maps both `/dev/sda1` and, after device
  renumbering, `/dev/sdb1` to Kingston UUID
  `ee36ee29-e720-4f55-a7a7-abc0e7a8185e`.
- At 18:07:52 on Oct 16, the kernel logged that Kingston's qgroup scan had
  completed and cleared the inconsistency flag. The waiting
  `snapper-timeline.service` then finished and immediately started again;
  `snapper-timeline-all-roots` ran the home and root timelines. One second
  later, Btrfs logged `qgroup marked inconsistent, qgroup inherit needs a
  rescan`. The wrapper observed no scan in progress and logged `quota rescan
  started` at 18:07:55.
- The same sequence repeated at 19:37:59/19:38:01. At 21:38:51, a further
  scan completed, the timeline job ran, and Btrfs marked qgroups inconsistent
  again; the wrapper deferred the next scan because the 21:30-04:00 suspend
  window had begun. These ordered kernel, systemd, and wrapper messages show
  that the scan itself was not setting the inconsistency flag: a subsequent
  Snapper timeline snapshot triggered Btrfs's snapshot-inheritance fallback,
  and the wrapper then started another full scan. The log names both home and
  root timeline commands but does not identify which individual snapshot
  operation emitted the kernel warning.
- A privileged copy of Kingston's configs was saved at 10:34 on Oct 17,
  before the 11:16 timeline run. It shows root `QGROUP="1/100"` and home
  `QGROUP="1/101"`. At 11:16:47, Kingston's scan completed and the timer
  service restarted; the wrapper ran home and root timelines, and Btrfs logged
  the same inheritance warning at 11:16:49. Thus this behavior occurred with
  separate root/home snapshot groups, not only with a shared ID.
- This is direct host evidence for the stock-kernel snapshot/rescan loop and
  rules out shared root/home IDs as a necessary cause of that loop. It does
  not prove the counters were wrong after a completed scan. The journal does
  not reveal the original first transition to inconsistent state, and these
  events were on 7.1.13; current-kernel acceptance remains on 7.2.6.

## Qgroup tracking layout and snapshot race source review (2026-10-19)

- The upstream Btrfs documentation says qgroups can form hierarchies and
  describes a tracking qgroup used to preserve correct exclusive-space
  accounting when snapshots are created. The host's separate per-config
  snapshot groups and per-config parent trackers are consistent with that
  documented model; root and home use different snapshot groups. This is
  evidence against the mere existence of parent/tracking groups being a
  Snapper misconfiguration, but does not by itself prove live counter accuracy.
  See the [Btrfs qgroup design documentation](https://btrfs.readthedocs.io/en/latest/Qgroups.html).
- A live hierarchy read at 10:32 BST found both p8 and Kingston flags clear.
  On p8, snapshot groups `1/100` and `1/101` have tracker parents `2/0` and
  `2/1` respectively; on Kingston, root `1/100` is under `2/1` and home
  `1/101` under `2/0`. Each tracker has the source subvolume qgroup and its
  corresponding snapshot group as children. This matches the intended separate
  four-collective layout.
- Source review of `fs/btrfs/transaction.c` (`qgroup_account_snapshot()`)
  found an upstream comment explaining that flushing delayed refs before
  inheritance narrows, but does not eliminate, a race: the source tree can
  still change before or during `btrfs_qgroup_inherit()`. This is a plausible
  separate route to wrong counters and was not exercised by the prior serial
  snapshot workloads.
- Paired QEMU stress runs on the exact `7.2.6+deb13-amd64` kernel then created
  32 snapshots per module across the four separate root/home configs, with four
  concurrent writers modifying the source subvolume during each snapshot.
  Both used a full scan before starting the writers and another after stopping
  them, so the writer overlap tested snapshot accounting rather than writing
  during a rescan. The stock module (`9cd15b503d5f11fc8b8cdab89c7fcfc97467368718e8a3ea60468ec207f5536c`)
  emitted the expected `qgroup inherit needs a rescan` warning for all 32
  snapshots; its counters changed on each post-snapshot scan. The candidate
  module (`f50e898b36ccb15189fb7ac63b7c3fdb04f5fa88e3627880329f5ecd4e423a10`)
  emitted no inconsistency warnings, started no extra automatic scans beyond
  the 64 explicit per-snapshot scans, and had no changes to snapshot-group or
  tracker counters across any of those scans.
- After each run, `btrfs check --readonly --force --qgroup-report` returned
  success for both filesystem images and matched all 50 stored/computed
  counter pairs per image (zero mismatches). Thus the stock counters matched
  an independent extent walk after rescanning, and candidate counters matched
  it without accounting for a scan-required flag. The source-accounting race
  was not reproduced by this workload; this does not prove the race impossible
  or establish why Kingston previously became inconsistent. Serial logs,
  offline reports, initrd overlay, and disposable images are in
  `/var/tmp/linux.build/qgroup-concurrent-race-heavy-20261019/`. Continue to
  treat this as a bounded negative result pending live correlation and any
  stronger reproduction evidence.

## Snapper PR #1203 closed without merge (2026-10-19)

- A live GitHub check found PR #1203 in `CLOSED` state, with no merge commit.
  The PR head is the current local Snapper branch and the official `master`
  still equals the PR's base. Its seven CI checks had passed, but the PR is not
  active and must not be described as open.
- A fresh fetch and GitHub API check on 2026-10-19 verified official
  `upstream/master` at `5a2dd6a8559c1a04c5575bf184acb347dce0d8f7`, matching
  the PR base OID; PR #1203 remains closed at that base. No rebase or new
  submission was performed.
- The upstream maintainer's closing comment states that a single snapshot may
  leave qgroup values incorrect, so a rescan is needed to obtain correct values
  regardless of the time since the prior scan. They saw no benefit in the gate
  patch and suggested disabling qgroups if they cause problems.
- The tested stock-module QEMU results support the need to rescan for stock
  qgroup counters in the tested topology. The candidate-module QEMU runs
  matched offline `btrfs check --qgroup-report` counters without requiring the
  inconsistency fallback, but the concurrent source-accounting race was not
  reproduced. This evidence is relevant to the maintainer's claim but does not
  establish the candidate's correctness for all workloads. No new upstream
  comment or PR was sent after closure.
- The four separately queryable exclusive-space groups are a project
  requirement, so disabling qgroups is not an acceptable resolution. Snapper's
  hold/window/daily-limit behavior remains an operational policy; deferral must
  keep counters explicitly stale and prevent quota-based cleanup from using
  them. Live Kingston accounting has since been checked on the previously
  loaded shared-parent fast-path module; reassess upstream follow-up after
  activating the newer installed module and checking p8/live host accounting.

## Pre-reboot module and GRUB audit (2026-10-19 12:18 BST)

- The running kernel is `7.2.6+deb13-amd64`; its loaded Btrfs build ID is
  `258e41d21460c34eaca2b1cfbed8a8f651d2a4bc`. The newly installed 7.2.6 DKMS
  module has build ID `46d2150765693e6b09846490c74ebdf710c0661b`, matching
  vermagic `7.2.6+deb13-amd64 SMP preempt mod_unload` and signer `Rebroad's
  module signing key`. `modprobe --show-depends` selects that module under
  `/lib/modules/7.2.6+deb13-amd64/updates/dkms/`, and its path is in the 7.2.6
  initramfs.
- `GRUB_DEFAULT=0` selects the main Debian menu entry, which points to
  `7.2.9+deb13-amd64`. Its selected DKMS module has build ID
  `29eef0f63dbf1853b12c4714903b7f53be56015f`, matching its kernel vermagic and
  the enrolled signing key; a complete `lsinitramfs` listing returned zero
  with empty stderr and included that module. The 7.2.6 kernel image and
  initramfs remain present in Advanced options. Secure Boot is enabled,
  `dpkg --audit` is empty, and Kingston has no active qgroup rescan.
- A reboot will select 7.2.9 by default, not the currently running 7.2.6.
  The 7.2.9 module passed exact-release QEMU Secure Boot acceptance, but its
  live host activation and qgroup behavior remain unverified. Boot 7.2.6
  explicitly afterward to verify that release's newly installed module and
  rollback path. No reboot was initiated during this audit.

## Isolated APT kernel-pin transaction simulation (2026-10-19)

- The live host has APT `3.0.3` installed and selected as its candidate from
  Trixie. Its kernel meta-package candidate is `7.2.9-1~bpo13+1`; the Debian
  `6.12` security and stable candidates remain visible. No kernel package is
  held and no production kernel preference file is installed.
- To test the proposed fail-safe without changing host APT state, an isolated
  local repository and dpkg status database modeled installed kernel
  `7.2.9-1` and a new, unsupported `7.3.0-1` release, plus an unrelated
  `security-demo` update. With exact supported versioned image, modules,
  binary, base, and headers names allowlisted before the broad negative pin,
  APT 3.0.3 assigned the supported image priority `990` and the unsupported
  image/modules priority `-1`; the unsupported packages had no installation
  candidate. The simulated upgrade visibly kept back the kernel meta-packages
  while upgrading `security-demo` from `1.0` to `2.0`. An explicit simulated
  install of the unsupported kernel image failed with “no installation
  candidate.”
- The no-pin control simulated installing the unsupported image, modules,
  binary, and base packages. This confirms the pin's effect on APT's
  transaction resolver and that an unrelated upgrade can proceed. The test
  used a synthetic package graph based on the live Debian kernel dependency
  shape; it does not validate every future package naming change or an actual
  Debian repository transaction. The test repository and status database are
  under `/var/tmp/kernel-pin-sim.TIW8w3/`; no host package or APT configuration
  was changed.
- Ran an actual `apt-get install linux-image-7.3.0+deb13-amd64` against that
  isolated repository and status database. APT exited 100 with “no
  installation candidate”; the isolated dpkg status hash and host
  `/boot/grub/grub.cfg` hash were unchanged. No package transaction or kernel
  hook ran.
- The previously requested APT `3.1.8` was a Debian testing version; it is not
  available from this host's configured Trixie sources. Debian's tracker
  records its migration to testing on 2025-10-07, while the Trixie source
  package remains `3.0.3` ([tracker entry](https://tracker.debian.org/news/1675790/apt-318-migrated-to-testing/),
  [Trixie package page](https://packages.debian.org/source/stable/apt)). Do not
  add a testing source as part of the kernel-pin deployment without an explicit
  decision about that cross-suite APT upgrade.

## Current unsigned qgroup kernel patch draft (2026-10-19)

- Verified the remote Btrfs `for-next` tip is
  `2789b2c034d7c0c8687355921a38c5ac41a565fa`. The latest tested
  shared-parent patch applies to that tree with
  `git apply --check`.
- Refreshed
  `linux.build/submissions/0001-btrfs-qgroup-shared-parent-fast-inherit.patch`
  from the tested implementation. The earlier draft omitted the current
  preflight of affected qgroup ancestors and its overflow coverage. The new
  draft includes the ancestor preflight and tests for ambiguous, extra-member,
  and overflow layouts. `checkpatch.pl --no-signoff --strict` reports zero
  errors, warnings, or checks; the diff touches only `qgroup.c`, `qgroup.h`,
  and `qgroup-tests.c`.
- The patch has a `base-commit` footer for the verified `for-next` tip and has
  no `Signed-off-by` trailer. It remains a local draft and was not sent.

## Live qgroup and module follow-up (2026-10-19 12:45 BST)

- The kernel journal from 09:00 through 12:45 contains the Kingston scan
  completion messages at 09:47 and 10:23, with no later Btrfs qgroup scan
  event. The 12:00 `snapper-timeline.service` completed successfully and its
  wrapper logged only duplicate-target skips. The process list showed no
  `btrfs-qgroup-rescan` worker at the time of this check. This does not prove
  qgroup consistency: a scan's absence and a successful snapshot service are
  not counter validation.
- A direct `btrfs qgroup show -reF /mnt/kingston` and `btrfs quota rescan -w`
  both returned `Operation not permitted`. In this session Kingston is exposed
  read-only and its device cannot be queried. The last direct host status
  available in this investigation, at 12:31 BST, reported clear qgroup flags
  and no scan; the current qgroup flag and counters could not be refreshed.
- The runtime remains kernel `7.2.6+deb13-amd64` with loaded Btrfs build ID
  `258e41d21460c34eaca2b1cfbed8a8f651d2a4bc`. The installed 7.2.6 and 7.2.9
  DKMS module build IDs are `46d2150765693e6b09846490c74ebdf710c0661b` and
  `29eef0f63dbf1853b12c4714903b7f53be56015f`, respectively. The host reports
  the locally built Snapper package `0.13.2-1+local1.20261019003646.g7d4db17085ce`.

## Resume hold deadline configuration fix (2026-10-19)

- Static review found that `/usr/local/libexec/snapper-timeline-sleep` invokes
  `/usr/local/libexec/snapper-rescan-hold refresh` before restarting the
  timeline timer after resume, but the hold helper hardcoded the next 04:00 or
  16:00 deadline. It did not read the configured
  `FORCE_SUSPEND_RESCAN_RESUME_TIME`; it also ignored
  `FORCE_SUSPEND_RESCAN_HOLD_FILE`, so a customized hold path could leave
  Snapper ungated after resume.
- Fixed the tracked root-repository helper to read both values from
  `/etc/default/force-suspend`, preserving explicit environment overrides and
  the 04:00 default. It validates the local `HH:MM` deadline, leaves any later
  active hold intact, and calculates the next configured deadline. Commit
  [`433f4dd5b`](https://github.com/rebroad/btcdevlaptop/commit/433f4dd5b309c5a023e3c38defdacde21406e538)
  contains only this helper and is pushed to the root-repository `master`.
- Shell syntax and isolated checks passed for the configured 04:00 default, an
  overridden 13:00 deadline, a custom hold-file path, preservation of a later
  active hold, and fail-closed handling of an invalid time. The installed
  helper was then checked with the real 04:00 default and an isolated 13:00
  override. `systemd-analyze verify` passed for the sleep guard, timeline timer,
  and timeline service when run with permission to read included root-owned
  units; `sh -n` passed for both helpers and the system-sleep hook. This
  verifies static configuration and deadline calculation; a real
  suspend/resume cycle and timer catch-up behavior remain unverified.

## Production APT kernel guard (2026-10-19)

- Installed `/etc/apt/preferences.d/99-btrfs-qgroup-kernel.pref`. It assigns
  priority 990 only to the exact package versions for supported 7.2.6 and
  7.2.9 builds, then assigns priority -1 to other versioned Debian kernel
  image, modules, binary, base, headers, and kbuild packages. The regex leaves
  Debian's `linux-image-amd64`, `linux-headers-amd64`, and
  `linux-base-amd64` meta-packages visible; when a future meta-package depends
  on a blocked kernel ABI, APT can report it kept back instead of beginning a
  DKMS build that has no source mapping. The allowlist must be extended only
  after the release-matched source, signed module, initramfs, and acceptance
  checks are ready.
- With the live Debian package lists and APT 3.0.3, `apt-cache policy` kept the
  7.2.6 and 7.2.9 image/module packages at priority 990 and showed the 6.12
  security image and headers at priority -1 with no installation candidate;
  the current package index has no separate 6.12 modules package. A simulated
  supported 7.2.9 install remained valid; an explicit simulated install of
  6.12 failed for lack of a candidate. Live `apt-get -s upgrade` and
  `full-upgrade` had no available upgrades to perform, and `dpkg --audit` was
  empty. No package transaction was run against the host.
- Reused the disposable local-repository transaction with the production
  preference structure adjusted to its synthetic package-version strings. An
  unsupported 7.3.0 kernel caused `linux-image-amd64`,
  `linux-headers-amd64`, and `linux-base-amd64` to be visibly kept back, while
  the unrelated `security-demo` package upgraded from 1.0 to 2.0. The no-pin
  control and the transaction dependency shape are documented in the earlier
  isolated simulation section; this test does not cover every future Debian
  package-name or dependency change.
- The preference file is committed and pushed in the root-configuration repo
  as [`a070de595`](https://github.com/rebroad/btcdevlaptop/commit/a070de595c5ae0cae552dcb9da1a0453255fe2d1).
  It contains package policy only; no secrets or unrelated staged files were
  included. The guard intentionally delays kernel updates until a matching
  module build is prepared, while the synthetic transaction showed unrelated
  upgrades proceed.

## Kingston live qgroup status and counter reconciliation (2026-10-19 13:40 BST)

- Read-only host checks confirmed `/mnt/kingston` is `/dev/sda1`, mounted
  read-write as Btrfs. Its sysfs qgroup inconsistency flag was `0`, and
  `btrfs quota rescan -s /mnt/kingston/@` reported no rescan in progress.
- The kernel journal records qgroup scan completions at 09:47:09 and 10:23:32.
  The sudo journal identifies their initiators: it records
  `btrfs quota rescan -w /mnt/kingston` at 09:35:08 and again at 10:12:22.
  These explicit diagnostic requests precede their respective completions.
- The hourly Snapper service ran from 10:00:01 to 10:00:02. Kingston root and
  home snapshots were created at 10:00:02, but the service completed ten
  minutes before the second explicit diagnostic rescan request. Therefore
  these two scans were not initiated by the hourly Snapper service; their
  timing must not be used as evidence that the 10:00 snapshots triggered them.
- At 13:24 BST Kingston was consistent and no scan was running. This resolves
  the initiators for these two diagnostic scans; it does not replace the
  separate historical evidence of automatic rescans in the stock-kernel
  snapshot cycle or identify that cycle's original onset.
- The installed Snapper package reports
  `0.13.2-1+local1.20261019003646.g7d4db17085ce`. The hourly service ran the
  locally installed `/usr/local/sbin/snapper-timeline-all-roots` at
  13:00:05-13:00:07. Kingston root and home snapshots were present for the
  11:00, 12:00, and 13:00 runs, with no automatic rescan recorded after the
  10:23 diagnostic scan.
- At 13:27:42, with the Kingston inconsistency flag clear and no scan in
  progress, an explicitly requested `btrfs quota rescan -w /mnt/kingston`
  started a diagnostic full scan. It completed at 13:40:24; the flag remained
  clear. All four qgroup referenced/exclusive pairs were identical before and
  after:

  | Qgroup | Referenced bytes | Exclusive bytes |
  | --- | ---: | ---: |
  | `1/100` | 35,910,164,480 | 15,672,508,416 |
  | `1/101` | 326,054,203,392 | 18,852,720,640 |
  | `2/0` | 326,071,951,360 | 200,382,541,824 |
  | `2/1` | 35,910,180,864 | 35,719,454,720 |

- This shows the loaded 7.2.6 shared-parent fast path's Kingston counters
  matched a full rescan after the three hourly snapshot cycles. It does not
  validate p8 or the newer installed teardown backport, which is not yet loaded.
- The running kernel is `7.2.6+deb13-amd64`; its loaded Btrfs module build ID
  is `258e41d21460c34eaca2b1cfbed8a8f651d2a4bc`. The installed DKMS module is
  signed by `Rebroad's module signing key`, is present in the 7.2.6 initramfs,
  and has build ID `46d2150765693e6b09846490c74ebdf710c0661b`. The installed
  build differs from the loaded module, so its qgroup-teardown backport has
  not yet been exercised on the host; activation requires a reboot.

## p8 live qgroup follow-up (2026-10-19 14:02 BST)

- A diagnostic `btrfs quota rescan -w /mnt/p8` was explicitly started at
  13:42:31 and completed at 13:58:06. The p8 inconsistency flag was `0` before
  and after. This was a manually requested diagnostic scan, not a Snapper-
  initiated scan. At the 14:00 check there was no rescan in progress on either
  p8 or Kingston; the 14:00 Snapper timeline service completed successfully.
- p8's four qgroup counters changed during the diagnostic scan. A subsequent
  `btrfs filesystem sync /mnt/p8` also changed them, and two more sync/read
  samples about two seconds apart still differed. The exact readings are in
  `/var/tmp/linux.build/p8-qgroup-live-after-20261019.txt`,
  `/var/tmp/linux.build/p8-qgroup-live-after-sync-20261019.txt`,
  `/var/tmp/linux.build/p8-qgroup-live-repeat-sync-a.txt`, and
  `/var/tmp/linux.build/p8-qgroup-live-repeat-sync-b.txt`. The filesystem was
  live during these reads, so they do not establish a counter error: ordinary
  transactions may have been updating qgroups. They also do not establish
  correctness. Capture a quiescent state and compare against an independent
  full accounting report before drawing a conclusion about p8.
- The host's sudo audit records confirm the p8 scan command was requested
  explicitly at 13:42:31. The only Kingston scan that day completed at
  13:40:24 after the explicit diagnostic command at 13:27:42. Neither was
  initiated by the 14:00 timeline service.

## Live four-config qgroup and policy audit (2026-10-19 14:06 BST)

- The installed Snapper is 0.13.2 with Btrfs quota support. The default
  `snapper list-configs` reports only the installed p8 `root` and `home`
  configs. The hourly wrapper separately discovers the Kingston configs under
  `/mnt/kingston/@/etc/snapper/configs` and runs them with that root, so all
  four configured roots are covered.
- The p8 root/home configs use distinct snapshot qgroups `1/100` and `1/101`;
  the Kingston root/home configs also use distinct `1/100` and `1/101` on
  their separate filesystem. All four currently agree on
  `QGROUP_RESCAN_DAILY_LIMIT=no`, `QGROUP_RESCAN_WINDOW=05:00-21:00`, and the
  same configured hold-file path.
- At this check, both filesystem inconsistency flags were `0`, and
  `btrfs quota rescan -s` reported no scan in progress on either filesystem.
  This confirms the live mapping and policy configuration, not long-term
  counter correctness or suspend/resume behavior.
- The 14:00:05-14:00:06 hourly run created the next timeline snapshot in all
  four roots: p8 root `3863`, p8 home `2808`, Kingston root `2726`, and
  Kingston home `2519`. The wrapper's duplicate-target messages refer to the
  extra p8 mount/config discovery after the default-root snapshots; they do
  not indicate that the intended targets were skipped. No qgroup scan started
  during or after this run, and both filesystem inconsistency flags remained
  clear at 14:06.
- The p8 counter samples after its 13:58 diagnostic scan spanned ongoing live
  filesystem updates and the 14:00 snapshot operations. Their changes cannot
  be assigned to the rescan itself or treated as an accounting mismatch.

## Post-snapshot live qgroup baseline (2026-10-19 14:11 BST)

- A read-only sample was captured at
  `/var/tmp/linux.build/live-qgroup-sample-20261019-1410.txt` on the running
  7.2.6 host with Btrfs module build ID
  `258e41d21460c34eaca2b1cfbed8a8f651d2a4bc`. Both p8 and Kingston had
  inconsistency flag `0`, with no rescan in progress.
- The four qgroup referenced/exclusive pairs per filesystem are preserved in
  the sample for a later post-reboot comparison. p8's totals changed relative
  to the 14:01 read while both flags remained clear, confirming its live
  counters continued to move. The system was active, so this sample does not
  establish whether p8 accounting matches an independent full report.

## Snapper rescan trigger source audit (2026-10-19 14:13 BST)

- In the current local Snapper source (`7d4db17085ce`),
  `Btrfs::prepareQGroupTracking()` calls `quota_rescan_if_needed()` before
  creating a quota-tracked snapshot. That helper first reads Btrfs scan and
  inconsistency status. When no scan is running and the inconsistency flag is
  clear, it calls `sync(fd)` and returns `Consistent`; it does not issue the
  rescan ioctl. When the flag is set and policy permits, it issues
  `BTRFS_IOC_QUOTA_RESCAN` and waits for completion. A pre-existing scan is
  waited on instead of starting a second one.
- Snapper's quota query uses the same helper. Thus Snapper does not initiate a
  full scan unconditionally on each hourly run: it initiates one only after
  seeing the Btrfs inconsistency flag, subject to the hold/window/daily policy.
  The stock-kernel feedback cycle therefore starts when snapshot inheritance
  sets that flag; the next Snapper operation reacts to it. The clean-status
  `sync(fd)` can flush ordinary pending filesystem work, so live qgroup counter
  changes around snapshots or quota queries cannot be attributed to the
  rescan without a quiescent comparison.
- Source reviewed at `snapper/Btrfs.cc:343-406`,
  `snapper/Btrfs.cc:420-455`, and `snapper/BtrfsUtils.cc:894-1018`.

## Shared hold-path source audit (2026-10-19 14:14 BST)

- The p8 and Kingston Snapper configs, `/etc/default/force-suspend`, and the
  `force-suspend` fallback all name
  `/home/rebroad/.local/state/snapper/qgroup-rescan-hold-until`.
- Although Snapper prefixes the alternate Kingston root when locating its
  config and sysconfig files, it passes `QGROUP_RESCAN_HOLD_FILE` unchanged to
  `QGroupRescanLimiter::hold_active()`. That function opens the absolute path
  directly. Thus Kingston's alternate-root invocation reads the same host
  marker as p8; it does not look for a copy under Kingston's `/home`.
- `force-suspend` writes the deadline via a temporary file and renames it into
  place with mode `0644`. `hold_active()` rejects non-regular files and
  group/other-writable modes, so that mode passes its file-safety check. This
  verifies path and format compatibility by source inspection; it is not a
  live end-to-end suspend test.
- The existing repeated-cycle QEMU harness also covers the alternate-root
  behavior: its Kingston configs live under `/mnt/kingston/etc`, its list and
  create commands use `snapper --no-dbus --root /mnt/kingston`, and they share
  the same absolute `/run/snapper-qgroup-rescan-hold` with the default-root
  configs. The four-config hold/window cycle passed. This is behavioral
  evidence for alternate-root hold lookup in QEMU, while a real host
  suspend/resume remains untested.
- Source reviewed at `snapper/BtrfsUtils.cc:963-979`,
  `snapper/QGroupRescanLimiter.cc:312-345`, and
  `/home/rebroad/bin/force-suspend:58-99`.

## Kingston live rescan check (2026-10-19 14:25 BST)

- On the running `7.2.6+deb13-amd64` host, Kingston's Btrfs inconsistency
  flag was `0`, and `btrfs quota rescan -s /mnt/kingston` reported no scan
  in progress. Its four configured groups remained present: snapshot groups
  `1/100` and `1/101`, under trackers `2/1` and `2/0` respectively.
- The scan the user observed was no longer running at this check. The sudo
  audit records an explicit `btrfs quota rescan -w /mnt/kingston` at 13:27:42;
  the kernel recorded completion at 13:40:24 with the inconsistency flag
  cleared. The 14:00 timeline run completed at 14:00:06 and no Kingston scan
  started then. The evidence attributes that scan to the explicit diagnostic
  command, not the Snapper timeline service. Its counters were not independently
  reconciled in this check.

## Historical journal coverage audit (2026-10-19)

- Persistent journals retain system boots back to 2026-08-13, but the kernel
  journal contains no Btrfs entries before the current boot on 2026-10-18.
  Thus the earlier qgroup inconsistency flags and scan initiators cannot be
  reconstructed from retained kernel messages.
- The oldest retained Kingston scan-related sudo records are from 2026-08-17
  23:51:43 (`btrfs quota rescan status /mnt/kingston`) followed on
  2026-08-18 00:00:23 by an explicit `btrfs quota rescan -w /mnt/kingston`.
  The command was run from `/mnt/kingston/@home/rebroad/src/codex`; later
  status and rescan commands followed at 00:02-00:06. These records establish
  an explicit scan request, not the onset or cause of inconsistency.
- The earliest retained Snapper timeline failure is 2026-08-13 08:08:32.
  Its journal has the wrapper's `home` and `root` start messages and systemd's
  exit status, but no qgroup, quota, inconsistency, or rescan diagnostic. Do
  not infer a qgroup cause from those generic service failures.

## Four-config Snapper list check (2026-10-19 14:32 BST)

- Ran the installed local Snapper binary's `list` operation for p8 root/home
  and Kingston root/home. All four returned their timeline snapshots through
  the expected configs.
- Kingston home is a separate top-level `@home` subvolume, while its Snapper
  config is under `@/etc`. The timeline wrapper temporarily bind-mounts
  `@home` at `@/home` before invoking Snapper with `--root /mnt/kingston/@`.
  My first manual list omitted that wrapper setup and failed with “subvolume is
  not a btrfs subvolume”; repeating the check with the wrapper's bind mount
  succeeded. The temporary mount was removed immediately afterward.
- After all four list operations, p8 and Kingston both had inconsistency flag
  `0` and no rescan in progress. This verifies live config/path operation; it
  does not independently validate qgroup counter accuracy, cleanup, or
  suspend/resume behavior.

## APT kernel security-track audit (2026-10-19 14:34 BST)

- The live APT index selects installed `7.2.9-1~bpo13+1` for
  `linux-image-amd64` and `linux-headers-amd64`; `apt-get -s full-upgrade`
  reports no package changes, and `apt list --upgradable` is empty.
- The installed kernel preference file assigns Debian's available
  `linux-image-6.12.113+deb13-amd64` and matching headers priority `-1`, so
  they have no installation candidate. Debian's tracker identifies
  `6.12.113-1` as a high-urgency Trixie security update, while the latest
  package index here offers the separate 7.2.9 stable-backports build. The
  available stable-security kernel is a different, older kernel series than
  the installed backports kernel.
- This does not by itself prove the installed 7.2.9 lacks any particular fix,
  nor that APT is proposing a downgrade for this host. The selected 7.2.9
  source's coverage of the security fixes in 6.12.113 has not been verified.
  Do not treat “no APT upgrades” or available non-kernel upgrades as proof of
  kernel security-update coverage. Compare the relevant fixes; if the
  selected branch lacks them, prepare and validate a signed matching module
  for the security kernel before allowing it through the kernel guard.
- Sources: [Debian's 6.12.113 stable-security announcement](https://tracker.debian.org/news/1811640/accepted-linux-612113-1-source-into-stable-security/),
  [Debian's 7.2.9 backports announcement](https://tracker.debian.org/news/1812073/accepted-linux-729-1bpo131-source-into-stable-backports/).

## DSA-6393 and installed-module follow-up (2026-10-19)

- Rechecked the live host with elevated access because the unprivileged
  filesystem view does not expose the host's `/lib/modules` contents. The
  running kernel remains `7.2.6+deb13-amd64`; the loaded Btrfs module build ID
  is `258e41d21460c34eaca2b1cfbed8a8f651d2a4bc`. Only kernel image packages
  `7.2.6-1~bpo13+1` and `7.2.9-1~bpo13+1` are installed. DKMS reports the
  `btrfs-qgroup` module installed for both releases. For each release,
  `modprobe --show-depends` selects
  `/lib/modules/<release>/updates/dkms/btrfs.ko.xz`, `modinfo` reports the
  `Rebroad's module signing key`, and the matching initramfs contains
  that DKMS module. `linux-image-amd64` remains at 7.2.9 as both installed and
  candidate; the available 6.12.113 security kernel remains pinned at -1 and
  is not an installation candidate.
- The 12 CVEs referenced by [DSA-6393-1](https://security-tracker.debian.org/tracker/DSA-6393-1)
  are each marked fixed by 7.2.9 or earlier in Debian's tracker:
  [CVE-2025-21807](https://security-tracker.debian.org/tracker/CVE-2025-21807)
  (7.2.6), [CVE-2026-46093](https://security-tracker.debian.org/tracker/CVE-2026-46093)
  (7.2.6), [CVE-2026-53027](https://security-tracker.debian.org/tracker/CVE-2026-53027)
  (7.1.12), [CVE-2026-53226](https://security-tracker.debian.org/tracker/CVE-2026-53226)
  (7.2.9), [CVE-2026-53392](https://security-tracker.debian.org/tracker/CVE-2026-53392)
  (7.2.8), [CVE-2026-53399](https://security-tracker.debian.org/tracker/CVE-2026-53399)
  (7.2.9), [CVE-2026-53402](https://security-tracker.debian.org/tracker/CVE-2026-53402)
  (7.1.13), [CVE-2026-63815](https://security-tracker.debian.org/tracker/CVE-2026-63815)
  (7.2.9), [CVE-2026-63816](https://security-tracker.debian.org/tracker/CVE-2026-63816)
  (7.2.9), [CVE-2026-63818](https://security-tracker.debian.org/tracker/CVE-2026-63818)
  (7.2.6), [CVE-2026-64187](https://security-tracker.debian.org/tracker/CVE-2026-64187)
  (7.2.8), and [CVE-2026-64189](https://security-tracker.debian.org/tracker/CVE-2026-64189)
  (7.2.8). The DSA page itself lists Trixie's 6.12.107 and 6.12.113 packages
  as fixed; the individual tracker records show these same fixes in Debian's
  7.2 series by 7.2.9. This supports keeping the selected 7.2.9 backport for
  these fixes, rather than enabling 6.12.113 solely for DSA-6393. The exact
  Debian `~bpo13+1` source patch set was not compared byte-for-byte against the
  fixed Debian source records, and the comparison does not establish that
  7.2.9 contains every later stable-security fix.
- Debian's tracker reports 7.2.11 migrated to testing on 2026-10-18, while
  the host's configured stable-backports index still selects 7.2.9. Before
  changing the kernel allowlist or claiming ongoing security coverage, compare
  each newer Debian security advisory against the actual selected backports
  source.
- Compared the exact `debian/patches` directories from Debian's official
  `linux_7.2.9-1.debian.tar.xz` and the host-targeted
  `linux_7.2.9-1~bpo13+1.debian.tar.xz`. All 78 files, including `series`, are
  byte-for-byte identical. Their SHA-256 hashes are respectively
  `2f0002dcc877aa7577e4cb5af2f56996e668bd9f033ef3c90475f7196f3b80b1` and
  `12617f6c507319252e7dc5d68d36d880bcb8e32dd44e26260ce2b06fb898f8df`.
  The backport changelog says it is a rebuild for trixie-backports, and its
  Debian patch set adds no delta to the 7.2.9-1 source patch set. This supports
  the previously recorded tracker result for DSA-6393; it does not establish
  coverage of later advisories. The archives and extracted comparison are in
  `/mnt/kingston/builds/rebroad/src/linux.build/debian-source-audit-20261019/`.

## Live qgroup status check (2026-10-19 14:49 BST)

- On the running `7.2.6+deb13-amd64` host, `btrfs quota rescan -s` reported no
  scan in progress on either `/` (`/dev/nvme0n1p5`) or `/mnt/kingston`
  (`/dev/sda1`). The quota-tree status item for each filesystem had `flags ON`
  and the no-scan sentinel, with no `INCONSISTENT` flag. This establishes their
  status at this observation only; it does not validate the recorded counters
  against a quiescent full-accounting report.

## Live qgroup inventory (2026-10-19 16:40 BST)

- The documented read-only `btrfs quota rescan -s` check reported no scan in
  progress on either p8 or Kingston. Both kernel qgroup inconsistency flags
  read `0`.
- `btrfs qgroup show -pc --raw` displayed both configured snapshot collectives
  on each filesystem, along with their latest timeline snapshot rows:
  p8-root `1/100` / snapshot `0/6970` (snapshot 3868), p8-home `1/101` /
  snapshot `0/6971` (snapshot 2811), Kingston-root `1/100` / snapshot
  `0/5528` (snapshot 2729), and Kingston-home `1/101` / snapshot `0/5527`
  (snapshot 2522). This corrects the limited display from an earlier query
  that showed only Kingston's top-level qgroup.
- These are live stored counters with the inconsistency flags clear; they have
  not been reconciled against an independent full-accounting report while
  filesystem updates are quiesced. Do not treat this observation as completing
  the host accounting acceptance check.

## Exact 7.2.6 Snapper-only alternative comparison (2026-10-19 15:00 BST)

- Booted the exact Debian `7.2.6+deb13-amd64` kernel in QEMU TCG, with the
  stock Btrfs module (SHA-256
  `9cd15b503d5f11fc8b8cdab89c7fcfc97467368718e8a3ea60468ec207f5536c`) and
  Snapper 0.13.2 / libsnapper 8.2.0. The test used freshly formatted p8-like
  and Kingston-like filesystems, four independent snapshot collectives, and
  two snapshot rounds per config. The kernel image SHA-256 is
  `21c3ef4de887b1d65443d44f6b8a5a35c9a41314275a6bae45f532e2929e1521`.
- On p8, the untracked-snapshot alternative temporarily cleared `QGROUP` for
  each Snapper snapshot and left it unset. The first snapshot marked qgroups
  inconsistent; no scan ran during either round. After the explicit final
  rescan, groups `1/100` and `1/101` still contained only their respective
  `.snapshots` subvolumes (16,384 referenced / 16,384 exclusive bytes). The
  snapshot leaf qgroups were unparented. This alternative avoids assigning
  snapshots to the configured collectives, so it cannot report their
  snapshot-only totals.
- On Kingston, the post-assignment alternative also cleared `QGROUP` while
  creating snapshots, then assigned each new snapshot qgroup to its configured
  group with `btrfs qgroup assign --no-rescan`. The assignment reported that
  quotas may be inconsistent; `btrfs qgroup show` confirmed inconsistent data.
  No scan ran during either round. Before the final rescan the group values
  were stale (`1/100`: 16,384/16,384; `1/101`: 49,152/49,152). After the scan,
  both separate collectives reported 4,243,456 referenced / 49,152 exclusive
  bytes. Post-assignment therefore preserves membership but leaves quota
  accounting stale until a full scan.
- The run ended `SNAPPER-ALT-726: PASS` for harness completion. It confirms on
  the exact currently used kernel that neither workaround meets the
  requirement to avoid scans while retaining current, separately queryable
  snapshot totals. It changes no host filesystem. The serial log is
  `/mnt/kingston/builds/rebroad/src/linux.build/qgroup-snapper-alternatives-7.2.6-20261019/final.serial.log`
  (SHA-256
  `8ae6c24e3e751ce090367202bd1b50e760dbabec6c6fae9cfcef892461ed5acd`); the
  init script, fresh images, and initrd overlay are alongside it.

## DKMS signing-key package audit (2026-10-19)

- The installed DKMS package lists PEM and DER certificate files, not a private
  key. `file` identifies both as X.509 certificates; a private-key parse of the
  PEM certificate fails as expected. The DKMS signing configuration points to
  a separate user-owned private key, whose mode is `0600`.
- Compared the public key derived from that private key with the public key in
  the installed certificate. They match. The private key contents and exact
  pathname were not printed or recorded. The installed package file list does
  not include the private key.

## Live Snapper package reinstall check (2026-10-19 15:09 BST)

- APT/dpkg logs show the current local Snapper build was upgraded at 09:01 from
  `0.13.2-1+local1.20261018183503.g017efa146426`; both `snapper` and
  `libsnapper` reached `status installed` after configuration. APT recorded
  the transaction as completed at 09:01:30.
- Reinstalled the exact locally built `snapper` and `libsnapper` packages,
  version `0.13.2-1+local1.20261019003646.g7d4db17085ce`, using APT. The
  transaction reinstalled only those two packages; `dpkg --audit` remained
  empty. The installed Snapper reports 0.13.2 / libsnapper 8.2.0 and includes
  the `btrfs-quota` feature.
- After reinstall, `snapper list-configs` worked over D-Bus and returned the
  default `root` and `home` configs. Read-only snapshot listing worked for
  those configs and for Kingston's alternate root using `--no-dbus`. The
  APT transaction created its normal `apt` pre/post snapshots (3865 and 3866).
- The four config files, timeline service, service override, timer, and
  `/usr/local/sbin/snapper-timeline-all-roots` retained their pre-reinstall
  SHA-256 values. The timer remained active and its service still executes the
  customized wrapper. All four configs retained their distinct `1/100` and
  `1/101` QGROUPs, shared hold path, `05:00-21:00` window, disabled daily cap,
  and `SPACE_LIMIT="1.0"`.
- Immediately after the transaction, both `/` and `/mnt/kingston` reported no
  qgroup rescan in progress and `btrfs qgroup show` emitted no inconsistency
  warning. This covers the reinstall and its two `apt` snapshots while the
  previously loaded module was still active; it does not test cleanup, host
  rollback, or the newly installed module after reboot.

## Keep the local Snapper runtime across Debian package updates (2026-10-19 16:42 BST)

- Installed and committed `/etc/apt/preferences.d/99-snapper-local.pref` in
  the root configuration repository (`77531529b`, pushed to its configured
  origin). It pins Debian-origin `snapper` and `libsnapper` versions to
  priority `-1`, preventing Debian packages from replacing the locally built
  latest-upstream runtime.
- `apt-cache policy` shows the installed local build remains the candidate at
  priority 100 and Debian's current 0.10.6 package is blocked at `-1`.
  `apt-get -s full-upgrade` reported no package changes, and a simulation of
  installing the current local package pair completed without a plan to remove
  or replace them. The preference is limited to these two package names.
- No newer Debian Snapper candidate was available for a live upgrade test; the
  rule matches Debian's release Origin and therefore also applies to later
  Debian-origin versions. It does not build or publish local packages: each
  later Snapper build still needs to be installed from its generated package.
  A host rollback/runtime check and a later local-build upgrade check remain
  open.

## Host cleanup scheduling and quota-limit semantics (2026-10-19 16:50 BST)

- The enabled `snapper-cleanup.timer` runs daily at 21:41. Its installed helper
  reads `SNAPPER_CONFIGS="root home"` and its dry-run lists the number,
  timeline, and empty-pre-post cleanup commands for those two default configs.
  It does not include Kingston's alternate-root configs. The packaged
  `/etc/cron.hourly/snapper.upstream` file is not selected by `run-parts`, and
  neither root nor the user's crontab schedules the exponential-retention
  script. That script exists as a manual tool; no automated Kingston cleanup
  schedule was found.
- All four configs currently enable number/timeline/empty-pre-post cleanup,
  set `SPACE_LIMIT="1.0"`, and set `FREE_LIMIT="0.2"`. In the installed
  Snapper source, `MaxUsedLimit::is_enabled()` returns false for fractional
  `SPACE_LIMIT` values at 1.0, which disables quota-aware cleanup. It does not
  disable number/timeline cleanup or the free-space cleanup path. When
  quota-aware cleanup is enabled, `Cleaner::is_quota_satisfied()` defers it on
  stale counters before calculating used-space limits.
- This was a read-only source/config/service audit plus the cleanup helper's
  built-in dry-run; no cleanup ran. The intended Kingston retention mechanism
  and live cleanup behavior on all four roots remain unverified.
- Ran `/home/rebroad/bin/snapper-exponential-retention --dry-run` for root and
  home on both p8 and Kingston. It would keep 9 timeline snapshots per config
  and delete 25 p8-home, 25 p8-root, 29 Kingston-home, and 29 Kingston-root
  snapshots (108 total). No deletion was applied. A post-run check still
  reported no rescan in progress and inconsistency flags `0` on both
  filesystems. This preview does not prove that actual deletion preserves
  accurate counters, and on p8 it overlaps with the separate built-in cleanup
  timer; test and reconcile those paths before applying it.

## Scheduled four-root snapshot cycle (2026-10-19 17:00 BST)

- The hourly timer ran `snapper-timeline.service` at 17:00:03 and the service
  exited successfully at 17:00:04. The live qgroup tree showed four new
  snapshot leaves: p8-root snapshot 3869 (`0/6972` under `1/100`), p8-home
  2812 (`0/6973` under `1/101`), Kingston-root 2730 (`0/5530` under `1/100`),
  and Kingston-home 2523 (`0/5529` under `1/101`).
- After the run, `btrfs quota rescan -s` reported no scan in progress on p8 or
  Kingston, and both qgroup inconsistency flags were `0`. This is one more
  successful scheduled four-root snapshot cycle with the currently running
  kernel and local Snapper build; it does not independently verify the stored
  counters.
- The p8 collective counters changed between the 16:40 and 17:00 readings,
  including the new snapshots and intervening filesystem activity. The
  independent full-accounting comparison therefore remains open.

## Isolated Snapper package rollback cycle (2026-10-19)

- In a disposable `/var/tmp` dpkg root, installed the previous local package
  pair (`g017efa146426`), upgraded to the current pair (`g7d4db17085ce`),
  downgraded to the previous pair, and restored the current pair. `dpkg-query`
  showed the expected package versions after every transition, and the final
  isolated `dpkg --audit` was empty. The temporary root was removed afterward;
  the host package database was not used.
- This deliberately forced dependency checks, disabled triggers, and ran
  maintainer scripts without a chroot, so it verifies dpkg unpack/configure and
  version rollback only. It does not validate dependency resolution, host
  daemon behavior, conffile migration, or runtime rollback; those host checks
  remain open in `GOAL.md`.

## Live four-root timeline cycle after Snapper reinstall (2026-10-19 15:31 BST)

- Ran `/usr/local/sbin/snapper-timeline-all-roots` once on the host. Snapper
  created p8 root snapshot 3867 and home snapshot 2810, plus Kingston root
  snapshot 2728 and home snapshot 2521. All four configs kept their distinct
  snapshot-only qgroups: the new root leaves were under `1/100`, and the new
  home leaves were under `1/101` on each filesystem.
- `btrfs qgroup show --raw -p` reported p8 snapshot leaf qgroups `0/6968`
  (root, 161,874,595,840 referenced / 81,920 exclusive bytes) and `0/6969`
  (home, 267,491,127,296 / 16,384 bytes). Kingston's corresponding leaves were
  `0/5526` (root, 20,237,672,448 / 16,384 bytes) and `0/5525` (home,
  307,165,753,344 / 16,384 bytes), with the expected parent groups.
- Immediately after the cycle, both filesystems reported no qgroup rescan in
  progress and `btrfs qgroup show` emitted no inconsistency warning. This adds
  one four-root host cycle after the package reinstall. The loaded module was
  still the older `258e41d2` build, not the newly installed DKMS module, and
  this observation does not independently reconcile counters against a full
  accounting scan.
- The scheduled 16:00 `snapper-timeline.service` run started and finished
  successfully at 16:00:05-16:00:07. Its journal contained four duplicate
  target skips for the p8 root/home configs. A direct read-only listing then
  confirmed fresh timeline snapshots on all four roots: p8 root `3868`, p8 home
  `2811`, Kingston root `2729`, and Kingston home `2522`, at 16:00:05-07. At
  16:00:16 both filesystems had inconsistency flags `0` and no rescan in
  progress. This proves one current four-root snapshot cycle, but does not
  independently reconcile counters or exercise cleanup.
- At 16:06, `dpkg-query` confirmed both `snapper` and `libsnapper` remain at
  `0.13.2-1+local1.20261019003646.g7d4db17085ce`. All four root/home configs
  still had separate `1/100` and `1/101` snapshot groups, the shared hold path,
  the `05:00-21:00` window, the daily limit disabled, and `SPACE_LIMIT="1.0"`.
  Both filesystems still reported no rescan in progress and inconsistency flag
  `0`. The loaded Btrfs module was not revalidated by this check.

## Host module and qgroup baseline (2026-10-19 16:13 BST)

- The current boot started at 2026-10-18 22:03:46, before the signed DKMS
  module and refreshed initramfs were installed at 11:13 and 11:14 on
  2026-10-19. The loaded module's build ID remains
  `258e41d21460c34eaca2b1cfbed8a8f651d2a4bc`; the installed 7.2.6 DKMS module
  is signed by `Rebroad's module signing key`, has build ID
  `46d2150765693e6b09846490c74ebdf710c0661b`, is selected by `modprobe`, and
  is present in both 7.2.6 and 7.2.9 initramfs images. DKMS reports both
  releases installed. Therefore the replacement is prepared but its build is
  not active in this boot.
- A read-only sample at
  `/mnt/kingston/builds/rebroad/src/linux.build/host-qgroup-baseline-20261019-1613.txt`
  records both filesystems' inconsistency flags, rescan status, four qgroup
  counter pairs, running kernel, loaded module build ID, and Snapper version.
  Its SHA-256 is
  `f5d838e2674084373f17c028da81b30437c46a2055067eaf5f812bbe8336639b`.
  At capture time both filesystems had inconsistency flag `0`, no scan in
  progress, and both configured snapshot groups plus their two tracker groups
  were present.
- Two p8 read-only counter samples 47 seconds apart showed qgroup counters
  changing, so the filesystem was not quiesced and this does not provide the
  required independent accounting reconciliation. The Kingston counters were
  unchanged between those samples.
- GRUB is configured with `GRUB_DEFAULT=0`; its first normal kernel entry is
  7.2.9, followed by 7.2.6, with no saved-entry override. The next default boot
  is therefore prepared to use the signed 7.2.9 DKMS module, subject to
  post-boot build-ID verification.
- The 13:40:24 Kingston scan was explicitly started by
  `btrfs quota rescan -w /mnt/kingston` at 13:27:42, as recorded by sudo audit.
  It was a diagnostic scan, not a scan initiated by the Snapper timeline
  service. The scan completed with the inconsistency flag clear.

## Live post-resume hold-path audit (2026-10-19 16:16 BST)

- The four host Snapper configs still use the same hold marker and `04:00`
  release time. `snapper-timeline-sleep.service` is enabled, runs its pre-sleep
  action before `sleep.target`, and runs its post action when stopped. The
  executable system-sleep hook calls the same helper, so repeated post actions
  share its marker check. The post action refreshes the hold before restarting
  `snapper-timeline.timer`.
- A smoke test of the installed hold writer against a temporary `/var/tmp`
  marker produced the next `04:00` deadline (`2026-10-20 04:00 BST`) and kept
  that deadline unchanged on a second refresh. The live hold file was not
  touched. This is not a real suspend/resume test; timer catch-up behavior and
  the live Snapper rescan path after resume remain open.

## Linux source checkout overlay cleanup (2026-10-19 16:24 BST)

- The Linux repo root had Btrfs-only copies in its top-level `Kconfig` and
  `Makefile`, plus 142 untracked files. The copies were not used by DKMS:
  `PRE_BUILD` selects the versioned `kernel-sources/<release>/fs/btrfs` tree
  from `/usr/src` and copies it into DKMS's external build directory. No kernel
  or DKMS build was active during cleanup.
- Before removing the misplaced copies, they were archived with `cpto` into
  `/mnt/kingston/builds/rebroad/src/linux.build/btrfs-root-overlay-7.2.9-20261019`.
  The archive manifest verifies all 145 entries. Among the source files,
  123 matched the packaged 7.2.6 and 7.2.9 sources, and 19 matched 7.2.9
  exactly. The unmatched `qgroup.c.orig` backup was retained in the archive.
- The 142 untracked root-level files were then removed, and the Linux top-level
  `Kconfig` and `Makefile` were restored from `HEAD`. The actual tracked
  `fs/btrfs` sources and installed DKMS sources were left unchanged; the Linux
  checkout reported clean afterward.

## Installed-kernel module coverage preflight (2026-10-19 16:26 BST)

- Package status (`dpkg-query` `ii` entries), `/boot/vmlinuz-*`, and
  `/lib/modules/*` confirm the only installed kernel releases are
  `7.2.6+deb13-amd64` and `7.2.9+deb13-amd64`. Old package records for other
  kernel versions are not installed images. DKMS reports a signed Btrfs module
  installed for each of the two actual releases.
- Secure Boot is enabled. For the default 7.2.9 entry, the signed DKMS module
  has vermagic `7.2.9+deb13-amd64 SMP preempt mod_unload`, signer
  `Rebroad's module signing key`, compressed SHA-256
  `2b94d9a03652ad61fdf8c019fa15b85581121680304ada9dc594be7ff8837e4a`, and
  build ID `29eef0f63dbf1853b12c4714903b7f53be56015f`. `modprobe` selects it,
  and the same DKMS module path is present in the 7.2.9 initramfs. GRUB's first
  normal entry is 7.2.9 and 7.2.6 remains available as the next entry.
- This confirms preboot coverage for every installed release, not successful
  runtime activation. The running kernel remains 7.2.6 with build ID
  `258e41d21460c34eaca2b1cfbed8a8f651d2a4bc`; post-boot verification is still
  required.

## Current Snapper hold and stale-quota validation on exact 7.2.6 (2026-10-19)

- Rebuilt an isolated QEMU rootfs from the current local Snapper packages built
  from commit `7d4db17085ce`. The guest reported Snapper 0.13.2 / libsnapper
  8.2.0; the copied executable and library hashes were
  `5fc79ea4fb066ed4eee9f1a7792eac0eee5ff97e302899892426ec673b9e8ff5` and
  `7d6b80cfb3f407f27fef6fe238d564496d6f69f8bb3ad10a28d83162d817393d`.
- Booted the exact Debian `7.2.6+deb13-amd64` kernel with the exact installed
  DKMS Btrfs module (compressed hash
  `8d3c3c14834cc820fe4ba59004eb3041caeb0e91b3b8256f76d10d9736899f75`, build
  ID `46d2150765693e6b09846490c74ebdf710c0661b`) and a fresh disposable Btrfs
  image. This direct-kernel run used `module.sig_enforce=0`; it did not test
  Secure Boot enforcement.
- The fixture registered both Snapper configs, matched their rescan windows
  and hold-file paths, and disabled their daily limits to isolate the hold.
  After `btrfs qgroup assign --no-rescan` made qgroup data inconsistent, each
  config listed last-known used-space values with a stale warning, deferred
  quota cleanup, and created a timeline-child snapshot. After each Snapper
  operation, the completed-scan count was unchanged and
  `btrfs quota rescan -s` reported no operation in progress. The test then
  expired the hold; the next quota query started exactly one automatic scan.
  Repeated snapshots, quota cleanup, and the final full-rescan comparison
  passed with `SNAPPER-QUOTA: PASS` and no shared-policy mismatch warning.
- The normalized serial log is
  `/mnt/kingston/builds/rebroad/src/linux.build/qgroup-current-snapper-7d-726-child-hold-20261019/qemu-current-snapper-hold-idle.txt`
  (SHA-256
  `e0a7ad3c1d131ec309e24e8e5cfd2ac0729a4b1ccac6d80a730aca0f51142dd6`); the
  binary serial log is alongside it (SHA-256
  `99c47adc460e0e4df9b62b32da0d07ab63acc29028d1a5bf9197f9065e2f5569`). The
  initrd SHA-256 is
  `3786557157bb0aa92afa0a3041d5e06126b4eaa68b39a6ec504404559252a977`. These
  results cover the current Snapper code and exact 7.2.6 module in QEMU; they
  do not replace host suspend/resume or live four-filesystem accounting and
  cleanup validation. A separate Secure Boot run with this current Snapper
  build follows.

## Current Snapper under Secure Boot on exact 7.2.6 (2026-10-19)

- Repeated the current-Snapper workload through OVMF Secure Boot using copied
  MOK-enrolled firmware variables, the exact Debian `7.2.6+deb13-amd64` kernel,
  and a fresh disposable Btrfs filesystem. The guest command line set
  `module.sig_enforce=1`; the kernel logged Secure Boot lockdown, the signed
  DKMS Btrfs module loaded, and an otherwise matching unsigned module was
  rejected. The init script verified the active `sig_enforce` parameter.
- The guest used Snapper 0.13.2 / libsnapper 8.2.0 from local source commit
  `7d4db17085ce`, verified by executable hash
  `5fc79ea4fb066ed4eee9f1a7792eac0eee5ff97e302899892426ec673b9e8ff5` and
  library hash
  `7d6b80cfb3f407f27fef6fe238d564496d6f69f8bb3ad10a28d83162d817393d`. The
  loaded Btrfs module hash was
  `8d3c3c14834cc820fe4ba59004eb3041caeb0e91b3b8256f76d10d9736899f75` (build
  ID `46d2150765693e6b09846490c74ebdf710c0661b`).
- Both configs were listed in `SNAPPER_CONFIGS` and used identical rescan
  windows and hold-file paths; their daily limit was disabled to isolate the
  hold. After `btrfs qgroup assign --no-rescan` made qgroup data inconsistent,
  both configs listed last-known quota values with a stale warning, deferred
  quota cleanup, and created timeline-child snapshots. The rescan count stayed
  unchanged and `btrfs quota rescan -s` reported no operation in progress after
  each Snapper operation. Expiring the hold allowed one automatic scan; the
  repeated-snapshot, cleanup, and final full-rescan comparison then passed as
  `SNAPPER-QUOTA: PASS`.
- The normalized serial log is
  `/mnt/kingston/builds/rebroad/src/linux.build/qgroup-current-snapper-secureboot-7d-726-20261019/qemu-secureboot.txt`
  (SHA-256
  `65acedbdc87661db2c1742ca46b29ea78c017778e712f9252f797404d4ab2457`); the
  binary log is alongside it (SHA-256
  `2fa9e15af0d5e3d2a4e9273ead833a05e924e945676c1a1e3fcc099df9cba2cd`). The
  initrd SHA-256 is
  `7cbda0d37ae33f4b745cddf27b6e601460ddaac3643363ade5d3e53875738c21`. This
  validates current Snapper and module signature enforcement for the tested
  two-config QEMU workload; it does not cover host suspend/resume or the
  four-filesystem host accounting cycle.

## Current Snapper under Secure Boot on exact 7.2.9 (2026-10-19)

- Repeated the current-Snapper workload through OVMF Secure Boot with copied
  MOK-enrolled firmware variables, the exact Debian `7.2.9+deb13-amd64` kernel,
  and a fresh disposable Btrfs filesystem. The guest command line set
  `module.sig_enforce=1`; the kernel logged Secure Boot lockdown, the signed
  DKMS Btrfs module loaded, and an otherwise matching unsigned module was
  rejected. The init script verified the active `sig_enforce` parameter.
- The guest used Snapper 0.13.2 / libsnapper 8.2.0 from local source commit
  `7d4db17085ce`, verified by executable hash
  `5fc79ea4fb066ed4eee9f1a7792eac0eee5ff97e302899892426ec673b9e8ff5` and
  library hash
  `7d6b80cfb3f407f27fef6fe238d564496d6f69f8bb3ad10a28d83162d817393d`. The
  loaded Btrfs module hash was
  `2b94d9a03652ad61fdf8c019fa15b85581121680304ada9dc594be7ff8837e4a`.
- Both configs were listed in `SNAPPER_CONFIGS` and used identical rescan
  windows and hold-file paths; their daily limit was disabled to isolate the
  hold. After `btrfs qgroup assign --no-rescan` made qgroup data inconsistent,
  both configs listed last-known quota values with a stale warning, deferred
  quota cleanup, and created timeline-child snapshots. The rescan count stayed
  unchanged and `btrfs quota rescan -s` reported no operation in progress after
  each Snapper operation. Expiring the hold allowed one automatic scan; the
  repeated-snapshot, cleanup, and final full-rescan comparison then passed as
  `SNAPPER-QUOTA: PASS`.
- The normalized serial log is
  `/mnt/kingston/builds/rebroad/src/linux.build/qgroup-current-snapper-secureboot-7d-729-20261019/qemu-secureboot.txt`
  (SHA-256
  `8c263a413601ca8b367241a6a32fcfacfefe177637fede21bd58f9c282e5b111`); the
  binary log is alongside it (SHA-256
  `1c7800ac9b8c6b22fc47cd5c569f049cc08845ba064e478d85ef67e8c382ceee`). The
  initrd SHA-256 is
  `51a6cb5adb664e3a9967c298ce76cc185e881ac2e60381d73a10f7f3bd1090d5`. This
  validates current Snapper and module signature enforcement for the tested
  two-config QEMU workload; it does not cover host suspend/resume or the
  four-filesystem host accounting cycle.

## Live collective audit and unparented p8 root snapshot (2026-10-19 17:03 BST)

- The running host was still on `7.2.6+deb13-amd64`, with local Snapper and
  libsnapper `0.13.2-1+local1.20261019003646.g7d4db17085ce`. Neither p8 nor
  Kingston had an active qgroup rescan.
- Read-only `forget --collective` queries reported `CONSISTENT` for p8-home
  (`1/101`, 35 snapshots), Kingston-root (`1/100`, 93 snapshots), and
  Kingston-home (`1/101`, 39 snapshots). The p8-root query did not return a
  collective: it reported that snapshot 2176 had no single aggregate parent
  qgroup.
- Snapshot 2176 is still listed by Snapper config `root`, description
  `verify var-tmp symlink exclusion`, created 2026-08-16 20:00:20 BST. Its
  Btrfs subvolume ID is `0/3978`, path
  `@/.snapshots/2176/snapshot`; it is not a child of `1/100`. The other p8
  root snapshot leaves shown in the qgroup inventory are children of `1/100`,
  whose tracker `2/0` contains the live source `0/262` and `1/100`.
- The three successful statuses do not prove all four collectives are
  accurate: p8-root remains incomplete until the intent and safe treatment of
  snapshot 2176 are established. No snapshot or qgroup was changed during this
  audit. The next timeline run was scheduled for 18:00 and cleanup for 21:41;
  the default cleanup timer still excludes Kingston's alternate-root configs.

## Add retained snapshot 2176 to p8-root collective (2026-10-19 17:23 BST)

- Snapshot 2176 remains in Snapper config `root`, so it belongs in the
  required p8-root snapshot-only collective. The available August journal did
  not retain its creation command, so why it was initially ungrouped remains
  unknown.
- Assigned Btrfs subvolume qgroup `0/3978` to snapshot qgroup `1/100` on p8 and
  requested a rescan. The rescan completed at 17:22:53 BST; the kernel logged
  `qgroup scan completed (inconsistency flag cleared)`. Neither p8 nor Kingston
  has a scan in progress now.
- The post-scan `forget --collective` queries report `CONSISTENT` for all four
  required collectives: p8-root `1/100` (87 snapshots, 28.90 GiB exclusive),
  p8-home `1/101` (35 snapshots, 21.66 GiB), Kingston-root `1/100` (93
  snapshots, 14.60 GiB), and Kingston-home `1/101` (39 snapshots, 18.89 GiB).
  The p8 qgroup inventory confirms `0/3978` is now a child of `1/100`, itself
  under tracker `2/0` with live source `0/262`.
- This restores a queryable four-collective state after a full scan; it does
  not establish long-term counter stability through subsequent snapshots and
  cleanup, nor does it replace the planned quiescent independent comparison.

## Kingston retention-path audit (2026-10-19 17:24 BST)

- The hourly wrapper reads Kingston's alternate-root `root` and `home`
  configs and creates timeline snapshots. Those configs have
  `TIMELINE_CLEANUP="yes"`, but the enabled 21:41 `snapper-cleanup.timer`
  launches a helper that reads `/etc/sysconfig/snapper` (`root home`) and
  invokes cleanup without an alternate `--root`. It therefore does not clean
  the Kingston configs.
- No root crontab or systemd timer schedules
  `snapper-exponential-retention`; `/etc/cron.hourly/snapper.upstream` is not
  selected by `run-parts`. The custom retention tool's read-only preview
  proposed retaining 9 and deleting 30 snapshots in each Kingston config (60
  total); the p8 preview proposed 52 deletions. No cleanup was applied.
- The active configs select built-in Snapper cleanup; the exponential tool is
  a separate, unscheduled alternative and should not be mixed into the cleanup
  timer. The exact-kernel four-config QEMU harness already exercises
  `snapper --root /mnt/kingston -c <config> cleanup timeline` and subsequent
  synchronous deletion, then confirms the four qgroup counters are unchanged
  by a full rescan. Thus the alternate-root cleanup command is QEMU-verified;
  the host timer's omission of Kingston and live cleanup/counter behavior
  remain open.

## Schedule configured cleanup for mounted alternate roots (2026-10-19 17:35 BST)

- Extended the tracked root-repository helper
  `/usr/local/libexec/snapper-cleanup-all-roots` to discover mounted
  `/mnt/*` Snapper config roots, invoke each enabled cleanup algorithm with
  `snapper --root`, ensure the alternate home bind points at its Btrfs
  subvolume, and suppress duplicate targets by device and Btrfs root ID. This
  prevents the p8 alias from being cleaned twice while adding Kingston's
  alternate-root `root` and `home` configs.
- `sh -n` passed. The installed helper's `SNAPPER_CLEANUP_DRY_RUN=1` output
  contains the six enabled cleanup commands for default `root`/`home` and six
  for Kingston `root`/`home`; it reports and skips p8 aliases. No cleanup
  algorithm was invoked during the dry-run.
- Installed helper SHA-256 is
  `4fbe339470bb47f5143726e65d5f66391d6d29a5bbd289fc3f349b919be12d42`.
  Root config-repository commit `7c69972fb` contains only this helper change
  and was pushed to `origin/master` after confirming the remote parent and
  reviewing the commit for private data.
- At 17:35 the cleanup service was inactive with successful last result; the
  next timer was 21:41. Both filesystems had no scan in progress, and all four
  collective reports remained `CONSISTENT`. No live cleanup has run through
  the new Kingston path yet; verify the first scheduled cleanup and compare
  counters afterward before closing live cleanup coverage.

## Retained journal boundary for the first host inconsistency (2026-10-19)

- `journalctl --list-boots` retains host boots back to 2026-08-15, but the
  earliest Btrfs qgroup entry in the retained kernel journal is
  `qgroup scan completed (inconsistency flag cleared)` on 2026-10-18 22:27:29
  for `nvme0n1p5`. No earlier `qgroup marked inconsistent` or rescan event
  appears in the retained kernel log. No rotated `kern.log` or `syslog` files
  are present.
- Therefore the retained logs do not identify the event that first made
  Kingston inconsistent. The controlled QEMU snapshot reproductions identify
  a repeatable trigger for the tested hierarchy, but do not prove that it was
  the original cause on the host.

## Refreshed kernel and Snapper package candidates (2026-10-19 17:43 BST)

- Refreshed the configured APT indexes. `linux-image-amd64` remains at
  `7.2.9-1~bpo13+1`; no newer kernel candidate appeared. The simulated full
  upgrade reports zero packages to upgrade, install, or remove. DKMS has
  installed Btrfs modules for both `7.2.6+deb13-amd64` and
  `7.2.9+deb13-amd64`.
- The installed local Snapper and libsnapper `0.13.2-1+local1.20261019003646.g7d4db17085ce`
  remain APT candidates. Debian-origin Snapper remains pinned at priority `-1`.
  No package transaction was applied.

## Live four-root timeline-service cycle (2026-10-19 17:46 BST)

- Confirmed no active `force-suspend` hold, then ran the installed
  `snapper-timeline.service` once. It completed successfully from 17:46:07 to
  17:46:08. The wrapper logged duplicate p8 mount aliases and created one
  snapshot for each unique config target.
- New snapshots: p8-root 3870 (`0/6974` under `1/100`), p8-home 2813
  (`0/6975` under `1/101`), Kingston-root 2731 (`0/5532` under `1/100`), and
  Kingston-home 2524 (`0/5531` under `1/101`). The live qgroup tree shows p8
  `1/100` and `1/101` under trackers `2/0` and `2/1`; Kingston's root and home
  groups remain separately attached to `2/1` and `2/0` respectively.
- All four `forget --collective` results reported `CONSISTENT`: p8-root 88
  snapshots / 28.98 GiB exclusive, p8-home 36 / 21.67 GiB, Kingston-root 94 /
  14.60 GiB, and Kingston-home 40 / 18.89 GiB. Neither filesystem had a scan
  in progress, and the kernel journal had no qgroup scan or inconsistency
  event during the cycle.
- The loaded module was still 7.2.6 build ID `258e41d2`, not the newer signed
  DKMS replacement. This adds a successful live snapshot round on the active
  module; post-reboot validation and the scheduled cleanup run remain open.

## Scheduled four-root timeline cycle (2026-10-19 18:00 BST)

- The scheduled `snapper-timeline.timer` fired at 18:00:02; the service
  completed successfully at 18:00:04. The wrapper skipped duplicate p8 mount
  aliases and created one snapshot for each unique target: p8-root 3871,
  p8-home 2814, Kingston-root 2732, and Kingston-home 2525.
- Their Btrfs subvolume IDs are respectively `0/6976`, `0/6977`, `0/5534`,
  and `0/5533`. The live qgroup tree places them under the intended parent
  groups: root snapshots under `1/100` and home snapshots under `1/101`.
- Both filesystem inconsistency flags were `0`; `btrfs quota rescan -s`
  reported no scan in progress on either filesystem. No qgroup scan or
  inconsistency event appeared in the kernel journal for the cycle. Current
  exclusive counters were p8-root 31,131,078,656 bytes, p8-home
  23,299,461,120 bytes, Kingston-root 15,672,688,640 bytes, and Kingston-home
  20,291,358,720 bytes.
- This is one additional scheduled snapshot round on the loaded 7.2.6 module.
  It does not validate repeated cleanup behavior, the newer signed module at
  runtime, or the host suspend/resume hold path.

## Regenerate GRUB entries from installed kernels (2026-10-19 18:04 BST)

- The generated GRUB menu contained stale 7.1.13 and 7.1.8 entries, but their
  kernel images, initramfs files, and `/lib/modules` trees were absent. The
  installed 7.2.9 target and 7.2.6 rollback images and initramfs files were
  present.
- Ran `update-grub`. The regenerated menu contains the default Debian entry
  loading 7.2.9, plus Advanced options for 7.2.9 and 7.2.6 and their recovery
  entries; the nonexistent 7.1 entries are gone. Windows entries were also
  retained. `grub-script-check /boot/grub/grub.cfg` passed, and
  `GRUB_DEFAULT=0` remains set.
- The running kernel remains 7.2.6. This prepares the intended next boot but
  does not verify live activation of the signed 7.2.9 Btrfs module.

## Unmapped kernel source selector check (2026-10-19 18:09 BST)

- Ran the installed DKMS source selector from `/var/tmp` with the unsupported
  release `7.3.0+deb13-amd64`. It exited 1 with
  `no matching Btrfs source is packaged`; the selector did not copy source or
  modify a kernel build tree.
- `apt-get -s full-upgrade` selected no package changes, and `dpkg --audit`
  remained empty. The live APT pin continues to keep unsupported kernel
  releases out of the upgrade plan.
- This verifies the source-map rejection and current APT transaction plan,
  not a full unsupported Debian kernel package install or the resulting
  `dpkg` recovery path. Actual APT rejection is tested in the isolated APT
  transaction section above; simulated DKMS-hook failure and recovery are
  tested below.

## Isolated Debian kernel-hook failure and recovery test (2026-10-19)

- Created a minimal Debian trixie root under the external Linux build tree at
  `/mnt/kingston/builds/rebroad/src/linux.build/dpkg-failure-chroot/` using
  `mmdebstrap`. The host package database and boot files were not used by the
  test transaction.
- Installed a synthetic 7.2.6 rollback image, then a synthetic
  `linux-image-7.2.9+deb13-amd64` package carrying the exact installed Debian
  7.2.9 image `postinst`. The chroot supplied Debian's real
  `linux-run-hooks`, Perl, `run-parts`, and `linux-update-symlinks`.
- The simulated `dkms` postinst hook exited 42. `dpkg -i` exited 1 and
  `dpkg-query` reported `install ok half-configured`. The actual postinst had
  already moved `/vmlinuz` to the candidate before invoking hooks. The hook log
  contained only `dkms`; later initramfs and GRUB hooks did not run, and the
  generated GRUB menu fixture still selected the rollback kernel.
- After changing the simulated DKMS hook to succeed, `dpkg --configure -a`
  completed the package. The retry ran DKMS, initramfs, and GRUB hooks in order,
  and the chroot's `dpkg --audit` was empty.
- A final host audit emitted no `dpkg --audit` findings. The host remained on
  `7.2.6+deb13-amd64`, and both installed 7.2.6 and 7.2.9 image packages
  remained configured. This test validates Debian's failure and recovery
  behavior, but it exposes the unresolved half-configured-package and
  `/vmlinuz`-symlink risk; it does not establish a safe failure design.

## DKMS package postinst failure test (2026-10-19)

- Inspected the installed DKMS package's own `postinst`. It uses `set -eu`,
  validates the enrolled signing certificate, then builds modules for every
  installed kernel before installing any of them and updating initramfs images.
  A failed build therefore aborts configuration of the DKMS package itself.
- Exercised the package's actual `postinst` from its built `.deb` in a separate
  Debian trixie chroot. Stubbed the signing checks and made the first DKMS build
  return 42; no host key material or host package database was used. `dpkg -i`
  exited 1, `dpkg-query` reported `install ok half-configured`, and `dpkg
  --audit` identified `btrfs-qgroup-dkms` as half-configured. The host's
  `dpkg --audit` remained empty and the running kernel remained 7.2.6.
- Inspected Debian DKMS 3.2.2's `autoinstall()` implementation: it skips a
  module already installed for the target kernel before checking `AUTOINSTALL`
  or attempting a build. The live DKMS status and `modprobe --show-depends`
  confirm the APT-allowlisted 7.2.6 and 7.2.9 releases already have and select
  their signed DKMS modules. The active APT pin rejects unsupported 7.3.0.
  This supports keeping prepared releases out of the build path during kernel
  postinst, but does not solve failures while installing or upgrading the DKMS
  package itself.
- Test harness and isolated root remain in the external Linux build tree at
  `/mnt/kingston/builds/rebroad/src/linux.build/`. A safe release process still
  needs to build and verify a candidate module before dpkg begins changing
  kernel-package state, then gate boot/initramfs selection on that verified
  module.

## Prebuilt DKMS archive import experiment (2026-10-19)

- Used DKMS `mktarball` to export the already-built, signed 7.2.6 and 7.2.9
  modules together with their source into a 17 MiB archive in the external
  build tree. The archive contains one `btrfs.ko.xz` for each release and no
  signing key.
- Imported the archive with `ldtarball` into a disposable DKMS tree. DKMS
  marked the module built without invoking a build. Its normal install step
  initially rejected the compressed `.ko.xz` in the imported build tree;
  after decompressing it only in that scratch tree, `dkms install` copied it
  into the scratch install tree. `modinfo` confirmed the 7.2.6 vermagic and
  enrolled-key signer.
- This demonstrates that a tested module artifact can be carried into a
  separate DKMS tree without compiling during installation. It does not yet
  solve package source maintenance, signing/verification for new releases, the
  current package `prerm` removal behavior, dpkg failure recovery, or initramfs
  activation. The experiment changed no host module files or DKMS state.

## Source-controlled DKMS preflight prototype (2026-10-19)

- Added `scripts/local-btrfs-qgroup-dkms-preflight`. It accepts an explicit
  module version, external output directory, and exact kernel release list;
  builds in an alternate DKMS tree; verifies each module's release vermagic,
  signer metadata, and enrolled public certificate; stages it in a scratch
  install tree; and emits a separate DKMS archive per kernel release. For
  staged headers, it copies the DKMS source into the external build tree and
  adjusts only that scratch `dkms.conf` to use DKMS's `$kernel_source_dir`.
  It does not install to the host module tree or change host DKMS/dpkg state.
- Ran it for the installed `7.2.6+deb13-amd64` and
  `7.2.9+deb13-amd64` headers. Both signed builds passed; each archive imported
  into a fresh alternate DKMS tree and `dkms install` staged the module.
  `modinfo` confirmed matching vermagic and the expected signer for both.
- A combined multi-release archive did not import both releases reliably with
  the installed DKMS implementation: its archive-load loop reports
  redeclaration errors for readonly loop-local variables and skipped the
  second release. Separate one-release archives avoid that behavior. Importing
  each archive into a fresh tree passed. All generated files stayed in the
  external Linux build tree.
- The installed DKMS config hardcodes `/lib/modules/${kernelver}/build`, which
  ignores DKMS's `--kernelsourcedir` option. After adjusting a scratch copy of
  that config, a preflight build succeeded when the 7.2.9 headers were supplied
  through an alternate staged-header path. This validates the path handling,
  not a real downloaded candidate `.deb`; no newer kernel candidate is
  available in the current APT policy, which selects the already-installed
  7.2.9 backport.
- This proves repeatable module preparation and archive import for the two
  currently supported releases and the staged-header mechanism. It does not
  yet build or install a Debian package, run before an APT kernel transaction,
  gate boot or initramfs state, or handle a new release whose source mapping is
  not yet prepared.

## Live qgroup status and corrected `-F` interpretation (2026-10-19 19:07 BST)

- `btrfs quota rescan -s /mnt/kingston` reported no scan in progress. The
  Kingston and p8 qgroup `inconsistent` flags were both `0`.
- The full qgroup tables contain all four snapshot collectives. Current
  exclusive bytes were p8-root (`1/100`) 31,266,009,088; p8-home (`1/101`)
  23,498,055,680; Kingston-root (`1/100`) 15,672,770,560; and Kingston-home
  (`1/101`) 20,302,884,864. These are live readings and can change with
  filesystem activity.
- An earlier diagnostic used `btrfs qgroup show -F` against the filesystem
  mount root and mistakenly treated the filtered result as the complete
  inventory. Installed btrfs-progs documents `-F` as listing qgroups that
  impact the given path, including ancestral groups; the mount-root query
  therefore showed only `0/5`. The default full listing confirmed `1/100` and
  `1/101` are present on both filesystems. The prior claim that Kingston's
  snapshot qgroups were absent was incorrect.

## APT pre-install hook feasibility (2026-10-19)

- The installed APT is 3.0.3. Its local `apt.conf(5)` documents
  `DPkg::Pre-Install-Pkgs` as running before dpkg and receiving the filenames
  of packages about to be installed; protocol versions 2 and 3 include package
  action and version metadata. This is a candidate place to stage incoming
  kernel headers and run the module preflight before package state changes.
- Feasibility is not implementation: no APT hook has been installed or tested
  against a kernel transaction. The hook must also arrange for the later DKMS
  kernel hook to consume the verified module without rebuilding it, and failed
  preflight must leave package and boot state unchanged.

## APT hook ordering and DKMS prebuilt install test (2026-10-19)

- Reflink-copied the existing disposable Debian root into the external build
  tree, configured an APT 3.0.3 `DPkg::Pre-Install-Pkgs` version-3 hook, and
  installed a tiny local test package through APT. When the hook returned 42,
  APT returned 100 before dpkg unpacked the package; `dpkg-query` showed it was
  absent and neither its `postinst` marker nor the hook's before-dpkg marker
  existed. With the failure marker removed, APT completed and the package's
  `postinst` verified that the hook had run first. The hook received the
  expected `VERSION 3` package-action records.
- In an alternate DKMS tree, `dkms autoinstall` failed when the built module
  existed only as `btrfs.ko.xz`. After decompressing the signed module to
  `btrfs.ko` in that scratch tree, `autoinstall` installed it without a build;
  `modinfo` verified the target release vermagic and expected signer. This is
  the behavior needed for the later kernel postinst to consume a preflighted
  module.
- Both tests changed only disposable data under the external build tree. They
  establish hook ordering and DKMS's built-module install behavior, not a real
  kernel APT transaction. The source-controlled hook, exact incoming header
  package extraction, real DKMS-tree prebuild, failure cleanup, and boot and
  initramfs gates remain unimplemented and unverified.

## Source-controlled APT DKMS preflight (2026-10-19)

- Added `scripts/local-btrfs-qgroup-apt-preflight` and its APT configuration
  snippet. The hook requires APT protocol v3, skips non-kernel transactions,
  validates the exact image and header package metadata, and fails closed when
  matching headers or kbuild files are missing. It extracts incoming arch,
  common, and kbuild packages under `/var/tmp`, rewrites Debian's staged
  absolute header paths, then calls the DKMS helper before dpkg runs.
- Extended `scripts/local-btrfs-qgroup-dkms-preflight` with a prepare mode for
  an already registered DKMS source. It stages a signed, uncompressed module
  in the target DKMS tree without installing it into `/lib/modules`. When a
  new build fails, it removes only the newly created release subtree; it
  refuses to overwrite a pre-existing incomplete DKMS state.
- Invoked the hook with a synthetic APT v3 record for a dummy
  `linux-image-7.2.9+deb13-amd64` package and the actual Debian 7.2.9 arch and
  common header packages. Both paths passed: using the matching installed
  `linux-kbuild` files and extracting a `linux-kbuild` package fixture from
  the installed Debian files. In each case, a fresh disposable copy of the
  host DKMS tree received a signed, uncompressed module. `modinfo` reported
  `7.2.9+deb13-amd64 SMP preempt mod_unload` and signer `Rebroad's module
  signing key`.
- A DKMS install into a separate external install tree consumed the prepared
  module without changing its build log. A simulated compiler failure removed
  only the new release directory. A non-kernel transaction was skipped, and a
  kernel image without matching headers was rejected before DKMS.
- `apt-config -c scripts/local-btrfs-qgroup-apt-preflight.conf dump` parsed the
  snippet and showed the hook configured for protocol version 3. All fixtures,
  extracted packages, and DKMS copies stayed in the external Linux build
  tree; the failed helper's diagnostic scratch directory remained in
  `/var/tmp`. The live APT configuration, host DKMS tree, module tree, boot
  selection, and package database were not changed.
- This is direct invocation with a constructed APT protocol record, not a
  complete APT kernel transaction. The generic APT hook ordering was tested
  separately above. The source-controlled hook is not installed or enabled on
  the host. It currently rejects a changed DKMS source package in the same
  transaction as a kernel image; install that source update separately, then
  retry the kernel transaction. Debian's actual kernel postinst path,
  transaction rollback, boot/initramfs gating, and same-transaction module
  source updates remain open.
## Btrfs stall diagnosis evidence (2026-10-19)

- The host booted Debian kernel `7.2.6+deb13-amd64` with the out-of-tree
  `btrfs-qgroup/7.2.6+rebroad1.z20261019.g89f68effaaf87` DKMS module loaded.
  Its packaged source map selects the 7.2.6 Btrfs source for this release.
- A live capture found a Kingston `btrfs-transaction` thread sleeping in
  `btrfs_commit_transaction+0xb87`, while unrelated writers accumulated in
  `wait_current_trans`. Disassembly of the installed module mapped this
  instruction to `schedule()` in the wait for
  `extwriter_counter_read(cur_trans) == 0`: the transaction was waiting for
  external writers to drain before continuing the commit.
- At the same time, `btrfs-cleaner` was observed blocked in
  `read_extent_buffer_pages`; an earlier capture of Btrfs ordered-write
  workers showed metadata reads/tree-lock waits, including a stack through
  `btrfs_qgroup_trace_extent_post`. These observations connect qgroup work to
  some blocked ordered completion, but do not establish that it held the
  external writer count or caused the transaction delay.
- Both filesystem commit counters advanced during observation and the active
  transaction later completed. At one sample, Kingston's current commit age
  was about 236 seconds; a later sample caught a second current commit at
  about 264 seconds. Peak recorded commit durations were about 307 seconds on
  p8 and 376 seconds on Kingston. D-state pressure eased afterward; latest
  samples had no blocked tasks. Btrfs device error counters were zero.
- The changed source is limited to `fs/btrfs/qgroup.c`, its header, and qgroup
  sanity tests; `transaction.c` has no diff from the module's source baseline.
  This weakens a direct link to the external-writer wait, but qgroup accounting
  executes during ordered-write completion and remains a possible indirect
  contributor. The evidence does not identify which external writer delayed
  the observed transaction, nor distinguish a software dependency from
  transient metadata/storage latency. The transaction stalls are therefore
  still an open diagnosis, not a verified kernel-patch regression or exoneration.

## Live Btrfs stall recapture (2026-10-20 03:16-03:28 BST)

- The host was still running `7.2.6+deb13-amd64` with the custom
  `btrfs-qgroup/7.2.6+rebroad1.z20261019.g89f68effaaf87` DKMS module loaded.
  Decompressed module hashes at capture time were
  `12bcdc0d2aac7cd28f6e2de3d97bcbeaf44ddd9d076499fdd9fc7bebed56bf1f`
  (custom) and
  `c9a0c7fe32dc8e75bc632a8aebc8c4caaea1c238cdb71d2417b3127be83fe392`
  (saved Debian module in DKMS's `original_module` directory). No rescan was
  active on either filesystem.
- At 03:16, `btrfs subvolume list -d` counted 30 deleted subvolumes on p8 and
  23 on Kingston. The p8 and Kingston commit counters were 3,149 and 2,577;
  their last completed commits took 30.8 s and 75.7 s, and recorded maxima
  were 307.0 s and 625.5 s. At 03:25 the counters had advanced to 3,156 and
  2,582. The p8 commit was then 30.5 s into its current critical section;
  Kingston's latest commit had taken 53.0 s. This shows slow commits and
  progress, rather than a permanently stuck commit.
- A 03:25 SysRq task dump and direct `/proc` stack reads found many unrelated
  tasks in `wait_current_trans`, including systemd, systemd-journald,
  ZeroTier, Python, XScreenSaver, psensor, a SQLx worker, and Btrfs
  endio-write workers. One cleaner was also waiting in
  `btrfs_drop_snapshot()` at `start_transaction()`. Another cleaner was in
  `btrfs_drop_snapshot() -> walk_down_tree() -> do_walk_down() ->
  btrfs_qgroup_trace_subtree() -> btrfs_read_node_slot() ->
  read_extent_buffer_pages()`.
- In this kernel source, `read_extent_buffer_pages()` waits
  uninterruptibly for `EXTENT_BUFFER_READING` to clear after submitting an
  asynchronous metadata read; the read completion callback clears that bit.
  Thus the captured qgroup backref walk was waiting for a metadata read
  completion. The capture does not show why that completion took so long, or
  establish that this cleaner caused the separate `wait_current_trans`
  backlog. The Btrfs device error counters were zero. At 03:27, I/O PSI was
  `some avg10=1.56 avg60=1.84 avg300=3.28` and `full avg10=1.21 avg60=1.57
  avg300=2.95`; a process snapshot at that time contained no D-state tasks.
- The custom source delta remains limited to `fs/btrfs/qgroup.c`,
  `fs/btrfs/qgroup.h`, and qgroup sanity tests. The observed transaction,
  snapshot-drop, backref-walk, and metadata-read functions are not changed by
  this patch. This narrows the suspected path but does not rule out indirect
  effects or prove an upstream defect. Existing eight-round QEMU cleanup
  cases use only 2 MiB of stable data per subvolume and one 1 MiB changed file
  per snapshot; they prove accounting/cleanup behavior, not stall performance.
  The later matched stress comparison and host CPU profile are recorded below;
  they add evidence but do not settle whether the custom changes contribute to
  the stalls.

## Matched snapshot-deletion stress and host CPU profile (2026-10-20 05:13-05:21 BST)

- Ran paired QEMU workloads with the exact Debian 7.2.6 kernel and saved stock
  Btrfs module versus the exact custom module loaded on the host. Each run used
  four source subvolumes, 4,096 metadata-heavy files per source, and 32
  snapshots per configuration (128 total), followed by deletion of the old
  snapshots and cleanup. The guest disks were tmpfs-backed; QEMU used TCG, so
  this did not reproduce host NVMe latency.
- The stock run recorded 127 distinct qgroup-inconsistency events and the
  expected rescan fallback. The custom run recorded no inconsistency warning
  during deletion and no post-delete rescan; qgroup reports remained
  consistent. Both runs completed without a blocked-task report or a long
  commit. Maximum sampled commit times were 233 ms stock and 223 ms custom.
  Custom final qgroup deletion took 1, 9, 6, and 1 seconds for the four
  configurations; stock cleanup took at most 3 seconds. The longer custom
  cleanup is consistent with the patch continuing qgroup-relation removal
  after a positive rescan-needed result, whereas stock exits that loop early;
  this does not explain the host's long transaction by itself.
- A short host `perf` sample (101 cycle samples over 8 seconds, zero lost
  samples) captured the active `btrfs-cleaner` in
  `btrfs_drop_snapshot()` -> `walk_down_tree()` ->
  `btrfs_qgroup_trace_subtree()` -> `btrfs_qgroup_trace_extent_post()` ->
  `btrfs_find_all_roots_safe()` / `find_parent_nodes()`. The profile included
  `read_extent_buffer`, `btrfs_bin_search`, and allocation work in this path.
  A preceding sample showed the cleaner consuming nearly one CPU core. This
  confirms expensive qgroup backref traversal is active during snapshot
  deletion on the host; it does not show that this cleaner held the external
  writer count during the long commit.
- The qgroup subtree/backref functions, snapshot-drop traversal, metadata
  read wait, and transaction external-writer wait have no source changes in
  our patch. The patch still could affect the amount or timing of this work
  indirectly. The paired QEMU test did not reproduce the host stall and is
  not sufficient to clear the patch or to prove a general performance bound.
  Remaining: capture the external writer that keeps the transaction's writer
  count nonzero and compare it against a representative large-tree workload
  with realistic storage latency before attributing or fixing the cause.

## Later upstream Btrfs path review (2026-10-20)

- Compared the exact upstream v7.2.6 source with stable v7.2.11 and mainline
  v7.3 for the observed qgroup, backref, snapshot-drop, metadata-read, and
  transaction paths. Through v7.3, `find_parent_nodes()` and the
  `btrfs_commit_transaction()` external-writer wait are unchanged; the qgroup
  and extent-tree changes do not alter the captured subtree/backref walk.
  No later upstream fix for the observed long snapshot-drop/backref traversal
  or writer-drain stall was identified in those versions.
- Stable v7.2.11 includes upstream commit `cacf358322929`, which prevents
  forced relocation-root creation during `qgroup_account_snapshot()`. Its
  report concerns extent-reference corruption during balance relocation and
  is distinct from the captured `btrfs_drop_snapshot()` backref traversal.
  No balance is currently active on either host filesystem; historical
  balance activity has not been established.
- Mainline v7.3 also includes `690c2accacb1`, concerning an
  `EXTENT_BUFFER_READING`/reference-count race during unmount validation. It
  prevents a false warning while checking extent-buffer release; it does not
  change the metadata-read completion wait observed in the qgroup backref
  stack, so it is not evidence that the captured wait is fixed.
- These source comparisons reduce the chance that the exact observed path was
  already fixed by v7.2.11 or v7.3; they do not rule out a different later
  fix, a Debian-specific patch, or a storage-dependent regression. Do not
  publish a kernel bug report until the external writer is identified and
  the complete later stable/mainline history is rechecked.

## Host transaction profile identifies qgroup commit work (2026-10-20 05:41 BST)

- During a p8 transaction, `cur_commit_ms` reached 8,340 ms and the transaction
  thread stack was `btrfs_commit_transaction+0xb87`, the wait for
  `extwriter_counter_read(cur_trans) == 0`. Numerous unrelated processes and
  Btrfs endio-write workers were blocked in `wait_current_trans`.
- A 10-second `perf` capture of the transaction thread had 311 cycle samples
  and no lost samples. The sampled call chain was
  `btrfs_commit_transaction()` -> `btrfs_qgroup_account_extents()` ->
  `btrfs_find_all_roots()` -> `find_parent_nodes()`. Perf's children view
  attributed 100% of sampled work to qgroup extent accounting, 91.94% to
  `btrfs_find_all_roots()`, and 89.50% to `find_parent_nodes()`; the backref
  walk repeatedly searched metadata with `btrfs_search_slot()` and
  `read_block_for_search()`. At 05:41:26, the same commit was 20,655 ms old;
  it completed at 30,986 ms. No qgroup inconsistency warning or active rescan
  appeared in the subsequent read-only checks.
- Source inspection explains the likely patch interaction. On inconsistency,
  `qgroup_mark_inconsistent()` sets `BTRFS_QGROUP_RUNTIME_FLAG_NO_ACCOUNTING`.
  Both `btrfs_qgroup_trace_extent_post()` and the qgroup-accounting loop skip
  their backref walks while that flag is set. The shared-parent fast path
  avoids the inconsistency fallback, so full qgroup accounting remains active
  and can make these walks part of transaction commits. Our patch does not
  change the walkers; it changes whether the runtime reaches the fallback that
  disables them. This makes the patch a likely indirect contributor to the
  observed commit cost, although the QEMU workload was too small to reproduce
  a comparable long commit.
- The initial external-writer drain preceded the qgroup-accounting samples;
  this capture does not identify the writer that delayed the drain. The perf
  recording and read-only watch output were kept on `/run` tmpfs. The earlier
  matched QEMU run used TCG and tmpfs-backed disks, so it cannot establish
  performance on the host's storage.
- Remaining: compare the same larger snapshot/deletion workload with stock
  fallback accounting and the custom consistent-accounting path; quantify how
  dirty extents and tree size affect commit time; then design and test an
  accounting path that preserves accurate four-group counters without holding
  unrelated writers behind a long commit. Identify the external writer in the
  initial wait as well. No kernel bug report is ready until this behavior is
  reproduced and the tradeoff is resolved.

## Larger four-group snapshot stress on the exact 7.2.6 kernel (2026-10-20)

- Repeated the stock/custom comparison with the same Debian
  `7.2.6+deb13-amd64` kernel image, Snapper executable
  (`917fdd6b8e18aed76de840639d4a8f6daca389ad895e2b3f0c3249f760b89d3f`), and
  libsnapper (`c34dfac310cd204ef4e38b0d62cd5af835ce5c2674ab3f0fda719e50e6ccdb8d`).
  The stock module hash was
  `9cd15b503d5f11fc8b8cdab89c7fcfc97467368718e8a3ea60468ec207f5536c`; the
  custom module hash was
  `8d3c3c14834cc820fe4ba59004eb3041caeb0e91b3b8256f76d10d9736899f75`.
- Each 2 GiB TCG guest used two sparse 4 GiB disks in tmpfs, created 32,768
  metadata files in each of four live source subvolumes, and created 32
  Snapper snapshots in each of the four independent configs (128 snapshots
  total). The workload then ran timeline cleanup and synchronous deletion.
  The complete compressed serial logs are in
  `/mnt/kingston/builds/rebroad/src/linux.build/qgroup-stall-ab-20261020/` as
  `32k-stock.serial.log.gz` and `32k-custom.serial.log.gz`.
- The stock run began with the guest's dmesg counters cleared. By cleanup it
  reported 126 completed qgroup scans and 128 inconsistency warnings. Its
  final explicit full scans each emitted `qgroup info item update error -2`
  immediately before `qgroup scan completed (inconsistency flag cleared)`.
  The custom run had zero scan completions and zero inconsistency warnings
  through snapshot creation, cleanup, and deletion; only the harness's four
  explicit full scans after the workload appeared in its scan counter.
- This final stock warning matches a separate teardown defect in the 7.2.6
  source. `btrfs_remove_qgroup()` deletes the on-disk qgroup item, then exits
  when relation removal returns the positive “rescan needed” result, leaving
  the qgroup in memory. A later `btrfs_run_qgroups()` then tries to update the
  absent info item and gets `-ENOENT`. The branch's
  `d9fe2dab48f08` teardown fix continues removing the qgroup after that
  positive result; the custom run did not emit this warning. This explains
  that specific warning sequence, not the earlier per-snapshot inconsistency
  that triggered the fallback.
- The last synchronous root-snapshot deletion took 6 seconds with stock
  accounting and 80 seconds with the custom module; home and Kingston deletes
  took 1–6 seconds in both runs. The kernel's `max_commit_ms` reached 1,360 ms
  stock and 1,221 ms custom. Thus the custom deletion's longer elapsed time
  consisted of work not reflected by a single long transaction in this guest.
  Neither run reproduced the host's 30.986-second commit. The custom result
  supports continued investigation of the cost of retaining full qgroup
  accounting but does not establish that the fast-inherit change caused the
  host stall. TCG and tmpfs disks also do not model host NVMe latency.
- The function-graph attempts on the custom deletion selected the tracer but
  left tracefs recording disabled. The completed qgroup-only attempt reported
  zero trace entries; the broader attempt was stopped before it dumped a
  trace. Their 532- and 956-second deletion timings are untrusted and excluded
  from the comparison above. A short guest probe confirmed that `function_graph`
  and the Btrfs qgroup functions are available; the function list includes a
  `[btrfs]` suffix. A corrected low-overhead profile must match that naming,
  explicitly enable `tracing_on`, and verify nonzero trace entries before its
  output or timings are used. The failed trace logs and probe are also retained
  in the same build directory as `32k-custom-trace-disabled-*.serial.log.gz`
  and `tracefs-probe.serial.log.gz`.

## Matched qgroup function trace during snapshot deletion (2026-10-20)

- Re-ran the exact 32,768-file four-group workload with the same Debian
  `7.2.6+deb13-amd64` image and Snapper userspace, once with the stock module
  and once with the custom module. The function-graph filter targeted
  `btrfs_qgroup_trace_subtree`, used a 10 ms threshold, and explicitly enabled
  tracefs recording; the guest printed `recording=1` before root deletion.
  Both completed trace buffers were captured in the external build directory
  as `32k-stock-qgroup-trace.serial.log.gz` and
  `32k-custom-qgroup-trace.serial.log.gz`.
- The custom trace contained 4,100 output lines. At the 10 ms threshold it
  recorded 134 `btrfs_qgroup_trace_subtree()` calls, 910
  `btrfs_qgroup_trace_extent()` calls, 882
  `btrfs_qgroup_trace_extent_post()` calls, 878
  `btrfs_find_all_roots()` calls, and 59 `find_parent_nodes()` calls. Several
  `btrfs_qgroup_trace_subtree()` calls exceeded one second under tracing.
  These are traced durations, not uninstrumented performance measurements;
  nested durations are inclusive and should not be summed.
- The stock trace contained one `btrfs_qgroup_trace_subtree()` return over the
  same threshold (192.8 ms) and no `btrfs_find_all_roots()` or
  `find_parent_nodes()` return over 10 ms. During that run the guest reported
  126 completed qgroup scans and 128 inconsistency warnings by cleanup. The
  custom guest reported no inconsistency warning or rescan before or during
  deletion.
- This difference matches the source control flow. `qgroup_mark_inconsistent()`
  sets `BTRFS_QGROUP_RUNTIME_FLAG_NO_ACCOUNTING`; while set,
  `btrfs_qgroup_trace_extent_post()` returns before calling
  `btrfs_find_all_roots()`, and commit-time qgroup extent accounting skips its
  backref walk too. The custom shared-parent fast path prevents that fallback,
  so full qgroup accounting and `find_parent_nodes()` backref work remain
  active. The trace reproduces the same backref function observed in the
  30.986-second host transaction profile. This strongly implicates our fast
  path as a contributor to host qgroup accounting cost and possibly the stalls;
  it does not prove that it is the sole cause or explain the initial
  external-writer wait.
- The traced root deletion took 526 seconds custom and 2 seconds stock, but
  function-graph overhead materially distorts elapsed and per-call timings.
  Use the untraced 80-second versus 6-second comparison above for the workload
  result, while treating this run as call-path evidence only. The host commit
  remains unreproduced at representative tree size and storage latency. A live
  read-only check confirmed the host is on `7.2.6+deb13-amd64` with the loaded
  Btrfs build ID beginning `258e41d2`; neither filesystem had a rescan in
  progress.

## Stock 7.2.9 host boot and source baseline (2026-10-20)

- The host now reports `7.2.9+deb13-amd64`. Its GRUB command line selects
  `/@/boot/vmlinuz-7.2.9+deb13-amd64`; the selected stock initramfs contains
  Debian's stock `btrfs.ko.xz`. The running module's build ID is
  `c2d998d4752632e0f5cf36eaab134a3e73b18940`, matching the saved Debian stock
  module. The installed DKMS module at
  `/lib/modules/7.2.9+deb13-amd64/updates/dkms/btrfs.ko.xz` has a different
  build ID and is not loaded. This corrects the earlier inference based only
  on the module present under `updates/dkms`.
- The user reports that the host became responsive after rebooting through
  the stock GRUB entry. At the post-boot capture there were no D-state tasks.
  This supports the modified Btrfs runtime as a likely contributor, but does
  not isolate it: both the kernel release and Btrfs module changed, and reboot
  cleared the prior runtime state.
- The working source branch is `codex/qgroup-root-cause-7.2.9`, rebased onto
  upstream tag `v7.2.9` in the existing `~/src/linux` checkout. The sole
  external build tree was reconfigured from
  `/boot/config-7.2.9+deb13-amd64` and normalized with `olddefconfig`.
  Kbuild reports the exact release `7.2.9+deb13-amd64`. `olddefconfig` warned
  that `ANDROID_BINDER_IPC=m` is invalid for the upstream Kconfig, so the
  normalized config is not byte-identical to Debian's build config. The exact
  Debian source archive was downloaded for review; its Btrfs code patch adds
  only the RAID5/6 warning and taint in `fs/btrfs/super.c`, with no qgroup
  source changes. The modified Btrfs aggregate object compiled successfully
  in the external build tree after this reconfiguration and checkpatch reported
  no issues. A loadable `.ko`, QEMU run, and host installation have not been
  produced from this tree.

## User-reported hang on stock 7.2.9 (2026-10-20)

- The user reported a system hang lasting about eight minutes and ending around
  11:56, after booting the stock `7.2.9+deb13-amd64` kernel and Btrfs module.
  At the earlier 11:48 status check, both `/` and `/mnt/kingston` reported no
  qgroup rescan in progress. Current status queries also report no scan.
- The kernel journal from 11:45 to 11:58 contains no blocked-task report,
  hung-task warning, transaction-wait stack, NVMe timeout, or I/O error. The
  system journal has no journald watchdog report in that interval. The kernel
  logged qgroups becoming inconsistent at 11:40:17 and a qgroup scan pause at
  11:57:35, shortly after the estimated end of the hang; that timing does not
  prove the scan caused the hang.
- There were no D-state tasks when inspected after the event. Without a stack
  captured during the freeze, it cannot be determined whether this was the
  earlier Btrfs transaction-stall failure mode. Since this occurred with the
  stock module, our modified module is not necessary for every system hang.
  Record a live blocked-task stack, Btrfs transaction progress, device latency,
  and rescan status during the next occurrence before assigning cause.
- Separately, the 12:00 Snapper timeline service ran from 12:00:00.606 to
  12:03:42.201, consuming 5.211 seconds of CPU. The installed
  `/usr/local/sbin/snapper-timeline-all-roots` did snapshot creation and
  subvolume-root-ID checks; its explicit Kingston rescan section is commented
  out. It differs from `/home/rebroad/bin/snapper-timeline-all-roots`, so the
  installed file is the relevant runtime source. At 12:03:42 it logged only
  duplicate timeline targets before exiting successfully.
- Psensor's rolling `history.ini` contains a matching 141-second gap in all
  six local sensor streams, from 12:00:00 to 12:02:21. This confirms a
  common sampling/event-loop pause, rather than a single sensor failing. The
  kernel logged `qgroup scan paused` at 12:00:00.648 and 12:03:33.620, then
  marked Kingston qgroups inconsistent at 12:03:41.920. The pause and slow
  timeline run overlap, but there is still no stack identifying the blocked
  operation; the history gap may be a second/continuing pause beyond the
  user's approximate 11:56 end time. Treat this as strong correlation with
  snapshot-time filesystem activity, not proof that a qgroup rescan caused it.
- The user also observed the Psensor application become unresponsive during
  the recent event. This is consistent with the shared sensor-sampling gap,
  but does not identify whether Psensor was blocked on Btrfs or its event loop
  stopped running for another reason.
- A follow-up capture-readiness check found no D-state tasks after the event,
  no Btrfs tracepoint directory under the running kernel's tracefs, and no
  active qgroup rescan. `kernel.sysrq` was `438`, which did not permit SysRq-W
  (`w`, dump blocked tasks). It is now `446`, adding only that bit while
  preserving the previous mask. This is a runtime setting and must be checked
  again after reboot. The two filesystems expose `commit_stats`; at this check
  their latest commits were 24 ms and 276 ms, while one lifetime maximum was
  140.825 seconds. That maximum has no timestamp and cannot be attributed to
  the reported hang. After enabling the bit, a SysRq-W request was accepted
  and the kernel logged `sysrq: Show Blocked State`; no blocked tasks were
  present to print during this check. On the next event, capture SysRq-W
  output, blocked task stacks, repeated commit stats, device latency, and
  qgroup rescan status while the stall is active.

## Exact 7.2.9 four-group stock and modified QEMU comparison (2026-10-20)

- Ran the same four-independent-qgroup topology on the exact Debian
  `7.2.9+deb13-amd64` kernel image in three 4 GiB TCG guests with two virtual
  CPUs: Debian stock Btrfs, our modified module with
  `shared_parent_quick_inherit=1` on both filesystems, and that same module
  with the switch set to `0` on both filesystems. Each guest created 32,768
  metadata files in each of four source subvolumes, 32 Snapper snapshots in
  each of four configs, then performed timeline cleanup and synchronous
  deletion. The guests used the same Snapper 0.13.2 executable
  (`917fdd6b8e18aed76de840639d4a8f6daca389ad895e2b3f0c3249f760b89d3f`) and
  libsnapper (`c34dfac310cd204ef4e38b0d62cd5af835ce5c2674ab3f0fda719e50e6ccdb8d`).
- The stock module's loaded build ID was
  `c2d998d4752632e0f5cf36eaab134a3e73b18940`. With the custom switch enabled,
  the loaded module build ID was `31c49b216d8a830d72da6158aff81f0d2b3be023`
  (raw module SHA-256
  `ea8f6a9ce850605d433697fca44c97d77e51f9b8d1c1b956035b7e667024b416`). Both
  custom sysfs values were read back and verified before snapshot creation.
  The QEMU kernel and module verification emitted an explicit success marker
  in every completed run.
- Stock and custom-with-switch-0 each emitted four distinct
  `qgroup marked inconsistent` warnings (two on each filesystem), then
  completed one automatic qgroup rescan on each filesystem. The custom
  fast-path run emitted no inconsistency warnings or automatic rescans during
  snapshot creation, timeline cleanup, or deletion; its counters stayed
  consistent through that workload. Explicit full rescans were run afterward
  in all cases to leave the guest counters independently refreshed.
- The synchronous `snapper delete --sync` phase after timeline cleanup took
  9 seconds with stock, 7 seconds with custom fallback accounting, and 114
  seconds with the custom fast path enabled. The other three delete phases
  took 1-4 seconds with stock, 1-7 seconds with fallback, and 1-15 seconds
  with the fast path. These figures include already-queued asynchronous
  snapshot cleanup that the synchronous delete had to wait behind; they do
  not isolate the final snapshot's own deletion cost. During the runs,
  sampled maximum transaction commit times were 516/639 ms for stock,
  920/762 ms for custom fallback, and 2,781/3,662 ms for the fast path (two
  filesystems per run). These measurements strongly support the tradeoff seen
  in the earlier host profile: preventing the inconsistency fallback keeps
  accounting active, but the resulting snapshot-drop/backref accounting can
  be much more expensive. They do not reproduce the host's 30.986-second
  transaction.
- This test does not prove that the patch caused every host stall. The guest
  uses TCG and small synthetic filesystems, so timings are not representative
  of Kingston or p8 storage and scale. SysRq-W was sampled during the runs but
  did not capture a blocked-task stack; this comparison identifies the cost
  difference, not the exact wait responsible for the long deletion. Continue
  with a representative tree/storage workload and capture the relevant guest
  and host stacks before changing the fast-path design or installing it on the
  host.
- The first custom run did not reach the workload because the existing module
  output directory contained stale Btrfs source copies, so that artifact
  lacked the runtime sysfs switches. The comparison was rerun after building
  in a fresh external output directory and confirming the new toggle strings
  in the module. The valid artifacts and logs are under
  `/mnt/kingston/builds/rebroad/src/linux.build/qgroup-module-load-7.2.9-20261020/`;
  `stock.serial.log`, `custom-fast.serial.log`, and
  `custom-fallback.serial.log` each contain the full guest transcript.

## Isolated 7.2.9 snapshot cleanup trace (2026-10-20)

- Repeated the four-config workload with explicit `btrfs subvolume sync` on
  both filesystems after timeline cleanup. This separates asynchronous drop
  backlog time from the remaining `snapper delete --sync`. Stock measured 16
  seconds to drain the queue and 2 seconds for the final root deletion;
  custom fallback measured 9 and 1 seconds; custom fast measured 128 and 3
  seconds. Each mode completed the four-root workload successfully. The
  fallback and stock runs had already completed two automatic rescans and
  reported four inconsistency warnings before cleanup; the counts did not
  increase during cleanup. The fast run had no inconsistency warnings or
  rescans and retained accurate accounting through cleanup. These repeated
  measurements strongly indicate that the earlier 114-second synchronous
  phase was dominated by previously queued snapshot drops, not the final root
  deletion.
- A function-graph trace enabled only after draining the fast-path cleanup
  queue recorded no `btrfs_qgroup_trace_subtree()` or backref calls over its
  10 ms threshold during the isolated final root deletion. An earlier
  un-drained trace run's five-second progress samples bracketed its queue
  drain at about 102 seconds; the direct timer in the matched repeat measured
  128 seconds.
- The earlier instrumented run began tracing after timeline cleanup but
  without draining that queue. Its 531-second synchronous phase was therefore
  also a measurement of the cleanup backlog under heavy tracing overhead. The
  trace contains 115 subtree return entries (106 with parseable durations;
  105 exceed one second, maximum 5.84 seconds), 4,751
  `btrfs_find_all_roots_safe()` returns over 10 ms, and 122
  `find_parent_nodes()` returns over 10 ms. These function-graph durations are
  nested and some run concurrently, so their sums must not be treated as wall
  time. They show the qgroup subtree/backref path is active during the queued
  drop workload, but the trace does not yet measure its isolated per-snapshot
  cost.
- The isolated guest completed with exit status 0 and the four-root topology
  completion marker. The drain-separated guest logs are
  `stock-drain.serial.log`, `fallback-drain.serial.log`, and
  `fast-drain.serial.log`; their QEMU stderr logs have matching names. The
  tested initramfs images are `initrd-current-stress-stock-drain.cpio` and
  `initrd-current-stress-custom-trace-isolated-timed.cpio`. The earlier
  isolated trace log is `custom-isolated.serial.log`, using
  `initrd-current-stress-custom-trace-isolated.cpio`. All are generated
  artifacts in the external build tree, not source changes.
- Next inspect whether correct qgroup membership and extent root information
  can be reused or accounted incrementally across snapshot drops, avoiding
  repeated full backref walks without weakening qgroup accuracy.

## Separate accurate snapshot accounting from deletion fallback (2026-10-20)

- On the exact 7.2.9 guest kernel, the custom module build ID
  `31c49b216d8a830d72da6158aff81f0d2b3be023` loaded and passed its in-guest
  verification. The four-group workload created 32 Snapper snapshots for each
  of p8-root, p8-home, Kingston-root, and Kingston-home (128 total), with
  `shared_parent_quick_inherit=1`. Both filesystem inconsistency flags stayed
  clear. Before deletion, each complete `btrfs qgroup show -pc --raw` table was
  byte-for-byte unchanged by a waited full rescan, proving the counters matched
  the rescanned values in this guest workload.
- The snapshot-cycle timer includes qgroup status and table queries, a 1 MiB
  source change, Snapper snapshot creation, and `sync`; it is not a measurement
  of the snapshot ioctl alone. Across 128 cycles it measured 380 ms minimum,
  1.31 s median, 2.11 s p95, and 2.28 s maximum. Sampled maximum transaction
  commit time was 974 ms. SysRq-W sampling found no blocked-task report or
  qgroup-rescan worker. These are TCG guest timings, not host-latency
  measurements.
- As a same-kernel control, `shared_parent_quick_inherit=0` produced 128 cycles
  at 360 ms minimum, 550 ms median, 690 ms p95, and 810 ms maximum. Both
  filesystems were marked inconsistent during snapshot creation, and each
  qgroup table differed from the one after a completed full rescan. Thus the
  tested fast path preserves accurate counters, with a measurable timing cost
  in this end-to-end harness; the test does not establish whether that cost is
  acceptable on the host.
- After the accuracy check, the test set
  `drop_subtree_threshold=0` on both guest filesystems to force the deletion
  fallback, then timeline-cleaned and synchronously deleted the 128 snapshots.
  Both filesystems became inconsistent, with the stale-data warning visible;
  no additional scan completed during cleanup or deletion. The four cleanup
  commands took 620-810 ms each and the four synchronous delete commands took
  1.31-5.32 s each. A subsequent explicit full rescan took 2.53 s on Kingston
  and 2.55 s on p8. Threshold zero is a test-only forcing mechanism, not a
  proposed production setting; it does not prove that the default threshold
  will make this workload inconsistent on deletion.
- This run demonstrates that, for the tested 7.2.9 hierarchy and workload, an
  optional snapshot fast path can preserve accurate qgroup totals while a
  deletion fallback later marks them stale. It does not prove acceptable
  latency at host scale: QEMU used TCG because `/dev/kvm` is unavailable, and
  the sources contained 32,768 metadata files each. Artifacts and full serial
  logs are under
  `/mnt/kingston/builds/rebroad/src/linux.build/qgroup-module-load-7.2.9-20261020/accuracy-latency-test/`.

## Accurate snapshots with a deletion-only stale policy on exact 7.2.9 (2026-10-20)

- Extended the same exact 7.2.9 custom-module/Snapper QEMU setup to
  131,072 metadata files per live subvolume and three snapshots per config.
  With 16 KiB nodes, all four source roots were level 2. With 4 KiB nodes, all
  four were level 3. In both runs the default `drop_subtree_threshold=3` was
  left unchanged. Each filesystem's complete qgroup table matched byte for
  byte after a waited full rescan, and snapshot cleanup plus synchronous
  deletion left both filesystems consistent. The whole-tree root level alone
  therefore did not establish that the deletion fallback had been reached.
- Source inspection explains the distinction: the threshold comparison in
  `btrfs_qgroup_trace_subtree()` uses the level of a shared child subtree
  passed from `maybe_drop_reference()` in the drop walk, not the source tree's
  top-level root height. For a root at level 3, the tested shared subtree
  levels did not reach the default threshold 3.
- Then, after snapshot tables had again matched full rescans and both
  inconsistency flags were clear, set the test-only sysfs threshold to 2 on
  both filesystems. Snapper timeline cleanup reduced each config from three
  snapshots to one without marking qgroups inconsistent. Deleting the final
  snapshot in each config marked both filesystems inconsistent (two warnings
  total), and did not start another rescan. A later explicit full rescan
  restored consistent status and refreshed the four separate snapshot-only
  qgroups. This shows the requested accuracy-through-snapshots and
  stale-on-deletion policy can coexist in this tested layout when the
  deletion threshold is configured to 2; threshold 2 is experimental, not
  yet a production recommendation.
- With the threshold-3 and threshold-2 4 KiB-node runs, respectively, the 12
  end-to-end snapshot cycles measured 370/390 ms minimum, 585/580 ms median,
  and 740/690 ms maximum. Those cycles include status and
  qgroup-table queries, a 1 MiB source change, Snapper creation, and `sync`.
  Synchronous deletion times by config were 26.72/7.38 seconds (p8 root),
  4.55/1.38 seconds (p8 home), 18.27/3.11 seconds (Kingston root), and
  4.25/1.33 seconds (Kingston home). The threshold-2 deletions were faster
  in these runs, but TCG timing variation and the synthetic 4 KiB-node tree
  prevent attributing the full difference to the threshold or projecting it
  to host storage. No user-visible-stall claim follows from these guest runs.
- A privileged read-only inspection of the live 7.2.9 host's current source
  trees reported p8 root/home levels 2/3 and Kingston root/home levels 2/3.
  This is direct evidence for the live source roots at that time, not a capture
  of the child-subtree levels during actual host snapshot deletion. The
  modified module remains off the host.
- Logs and images for the 16 KiB default-threshold run are in
  `default-threshold-scale/`; the 4 KiB default-threshold run is in
  `default-threshold-4k/`; and the threshold-2 policy run is in
  `optional-delete-fallback/`, all under
  `/mnt/kingston/builds/rebroad/src/linux.build/qgroup-module-load-7.2.9-20261020/`.
- A matched stock-module control used the exact Debian 7.2.9 kernel image and
  stock Btrfs module build ID `c2d998d4752632e0f5cf36eaab134a3e73b18940`, the
  same custom Snapper build, four qgroups, 131,072-file roots, 4 KiB nodes,
  three snapshots per config, TCG, and the same timed snapshot-cycle procedure.
  Its 12 cycles measured 390 ms minimum, 535 ms median, and 830 ms maximum.
  Both filesystem qgroup tables differed from their post-rescan tables after
  snapshot creation, while the modified fast-path/threshold-2 run's tables
  matched. The 45 ms median difference favors the stock module in this small
  guest sample, but it is not a host-storage comparison; hold-file policy
  suppressed automatic rescans during both runs. This is evidence for
  feasibility in the measured workload, not a host-level verdict.
- A temporary kprobe in the threshold-2 guest recorded 2,403 calls to
  `btrfs_qgroup_trace_subtree()` during cleanup and deletion: 1,347 at level 0,
  1,048 at level 1, and 8 at level 2; none were at level 3. This confirms why
  whole-tree root level 3 did not reach the default threshold 3 in this test,
  while threshold 2 did. The trace was enabled only for deletion and was not
  used for the timing comparison. Its log is in
  `trace-delete-subtree-levels/`; the stock baseline log is in
  `stock-131k-baseline/` under the same external build directory.
- A host-count-sized run used 79 p8-root snapshots, 28 p8-home snapshots, 82
  Kingston-root snapshots, and 28 Kingston-home snapshots, matching the live
  counts measured on the host. It completed 217 snapshot cycles with the fast
  path enabled and the test-only threshold set to 2. Both complete qgroup
  tables matched their full-rescan tables; the scans took 90.28 and 108.83
  seconds. Snapshot creation remained consistent, and timeline cleanup
  completed without stale accounting. The first final synchronous deletion did
  not complete within the one-hour TCG timeout. At timeout, commit statistics
  showed a 110.16-second lifetime maximum and a 43.79-second latest completed
  commit; repeated SysRq-W requests were emitted, but no blocked-task stack was
  captured in the serial log. This is a negative scalability result for the
  tested design, not proof that an optimized design is impossible. The full log
  and 8 GiB guest images are in `host-snapshot-counts/` under the same external
  build directory.
- A second host-count run used the same 217 snapshot counts but 32,768
  metadata files per source and a test-only `drop_subtree_threshold=1`.
  Snapshot qgroup tables again matched full rescans (13.29 s and 12.87 s),
  and all 217 snapshot cycles completed without inconsistency. Timeline
  cleanup marked one filesystem stale, after which the four remaining deletes
  took 9.59 s, 1.32 s, 1.37 s, and 1.29 s. This is substantially better than
  the threshold-2 one-hour timeout at the same snapshot population, but the
  smaller tree, TCG execution, and cleanup-time stale transition leave
  production suitability unproven. Its artifacts are in
  `host-counts-threshold-1/` under the same external build directory.
- The decisive threshold-1 run combined the same 217 snapshot counts with
  131,072 metadata files per source and 4 KiB nodes (all four roots level 3).
  All 217 snapshot cycles remained consistent and both complete qgroup tables
  matched their full-rescan results; the scans took 75.73 s and 81.65 s.
  Timeline cleanup finished with both filesystems still consistent. The four
  final synchronous deletes then marked both filesystems inconsistent and
  completed in 15.46 s, 1.46 s, 6.45 s, and 1.31 s. No automatic scan ran
  during cleanup or deletion; the later explicit rescans restored the status.
  This is the strongest controlled evidence that accurate stats for routine
  snapshots and a deletion-triggered stale state can coexist at the current
  snapshot population. It remains a TCG guest result and does not establish
  host NVMe latency or make threshold 1 a production recommendation. The
  log and images are in `host-counts-131k-threshold-1/` under the same external
  build directory.
- `drop_subtree_threshold` is already an upstream Btrfs sysfs control in the
  7.2.9 baseline (default 3); changing it in these guests did not require a
  new kernel patch. The custom change under test is the shared-parent snapshot
  fast-inherit path. This separates the optional deletion stale-policy choice
  from the kernel change needed by the tested four-qgroup snapshot hierarchy.
  Across all 217 snapshot cycles, the modified run measured 240 ms minimum,
  1.34 s median, 3.01 s p95, and 3.32 s maximum. Per-config medians were
  1.66 s (p8 root), 975 ms (p8 home), 1.845 s (Kingston root), and 865 ms
  (Kingston home). These include the source change, Snapper create, and `sync`;
  they are not isolated ioctl timings. The guest images and initramfs were
  stored on the mounted Kingston Btrfs filesystem, so these runs include that
  device's backing-file I/O path; TCG still prevents treating them as direct
  host workload latency measurements, and they say nothing about p8 NVMe.
- A matched stock 7.2.9 control used the same 217 snapshot counts, 32,768-file
  roots, Snapper build, qgroup layout, Kingston-backed guest images, and TCG.
  Its 217 snapshot cycles measured 240 ms minimum, 320 ms median, 400 ms p95,
  and 770 ms maximum. Both complete qgroup tables differed from their later
  full-rescan tables, and inconsistency warnings accumulated during cleanup
  and deletion. The accurate threshold-1 run therefore costs roughly 1.02 s
  of median end-to-end cycle time in this harness, while satisfying the
  independent counter check that stock fails. The stock log and images are in
  `host-counts-stock-32k/` under the same external build directory.

## Stock-host blocked-task evidence (2026-10-20)

The stock 7.2.9 host captured blocked-task dumps during the reported midday
stall. At 12:50:27, a `find` process (PID 203534 in that historical dump) was
in `read_extent_buffer_pages()` -> `btrfs_read_extent_buffer()` and waiting in
`bit_wait_io`; its caller chain continued through `read_block_for_search()` and
`btrfs_read_locked_inode()` into `path_openat()`. No task in that dump was in
qgroup accounting, `btrfs_commit_transaction()`, or `wait_current_trans()`.
This is direct evidence of a Btrfs metadata-read I/O wait during that event,
not evidence that qgroup accounting caused it. A separate HID IRQ thread was
also in a D state, but that stack was unrelated to Btrfs. The evidence narrows
the host diagnosis while leaving the qgroup-scan and transaction paths open for
capture during a future event.

## Meaning of the recurring `qgroup scan paused` log (2026-10-20)

In the exact 7.2.9 source, `btrfs_qgroup_rescan_worker()` emits
`qgroup scan paused` only when `rescan_should_stop()` returns true. That
function stops the worker when the filesystem is closing, remounting, qgroups
are disabled, or the runtime cancel-rescan flag is set. The message therefore
does not by itself mean that accounting is slow or that a qgroup lock blocked
other workloads. The host's repeated hourly messages need attribution to one
of those stop conditions before they can be used as stall evidence.

## Host timeline/rescan correlation (2026-10-20)

The 20:00 local timeline run started at 20:00:05 and finished at 20:01:07,
a 62-second service interval. It created root snapshot 3905 at 20:00:05 and
home snapshot 2840 at 20:00:36. The kernel logged `qgroup scan paused` at
20:00:36 and 20:01:07. The following 21:00 run created root snapshot 3906 and
home snapshot 2841 at 21:00:05 and finished immediately, with no qgroup pause
message. This is temporal correlation between the first snapshot run while
qgroups were inconsistent and the long service/rescan activity; it is not by
itself proof that the snapshot ioctl caused the pause. The exact stop condition
and the rescan caller still require a live trace.

## Scheduled cleanup did not exercise deletion (2026-10-20)

The 21:41 BST `snapper-cleanup.service` run started at 21:41:01 and exited
successfully at 21:41:04 (3.181 seconds). Its only output was duplicate-target
messages for the p8 paths; it emitted no qgroup or transaction messages. The
latest listed root/home timeline snapshots remained 3906/2841, and both live
filesystems still reported `qgroups/inconsistent=1`. This scheduled run did
not delete a snapshot and therefore provides no host deletion-accounting
measurement.

## Follow-up timeline run did not start a rescan (2026-10-20)

The 22:00 BST timeline service completed in about one second and created root
snapshot 3907 and home snapshot 2842. It emitted no qgroup kernel messages, and
a temporary return probe on `btrfs_qgroup_rescan_worker()` recorded zero worker
returns. Both filesystems remained `qgroups/inconsistent=1`. This follow-up
weakens the hypothesis that every snapshot creation starts a rescan; the long
20:00 run appears to have involved a particular pre-existing or state-transition
condition rather than a repeatable per-snapshot cost.
