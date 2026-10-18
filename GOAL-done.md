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
