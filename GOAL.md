# Goal: fix Snapper-triggered Btrfs qgroup inconsistency

This is the active **to-do** document. It lists remaining work, with rough
completion percentages for partially completed items. Move verified completed
work and its evidence to [`GOAL-done.md`](GOAL-done.md), then remove that work
from this checklist. Percentages are progress estimates, not test results or
approval states. Keep this file focused on what remains to do; `GOAL-done.md`
is the record of completed work and useful historical evidence.

The required and accepted host runtime is the locally built Snapper from our
repository, based on the latest official upstream source and carrying our
reviewed changes. Any mention of the currently installed distribution version
describes historical pre-migration status only; it is not an acceptable target
runtime or an acceptance state. All deployment and acceptance work must target
our built Snapper.

Local testing and deployment are separate from public upstream submission.
Upstream review and DCO certification are required before publishing the
contributions; they are not prerequisites for installing the locally built
Snapper or modified Btrfs module. Local use instead requires technical review,
the exact-kernel acceptance workload, a valid Secure Boot signature from an
enrolled key, and a tested rollback and kernel-upgrade path.

Determine and fix the source of Snapper-triggered qgroup rescans. Controlled
QEMU tests show that sharing the root and home snapshot QGROUP is not required
for the stock kernel's conservative rescan fallback, and a shared QGROUP
cannot provide independently queryable root and home totals. The host's p8
groups have therefore been split; do not treat that change or the candidate
kernel fast path as proof that the root cause is fixed. Continue tracing which
Snapper/Btrfs operations set inconsistency, whether completed full scans
restore correct counters, and whether a Snapper-only change can meet the
accounting and operating requirements. Distinguish a conservative fallback
from incorrect counters and from a Snapper tracking/configuration error.
The 2026-10-19 02:24 BST live audit found Kingston's qgroup flag set and stale
counters. A controlled full scan cleared the flag and corrected those
counters; a later diagnostic scan adjusted the home collective by 180,224
exclusive bytes while no inconsistency was reported. The original onset time
remains unknown. Historical logs now directly show the repeated stock-kernel
cycle on Kingston: a scan completes, the hourly Snapper timeline job resumes
and creates snapshots, Btrfs marks qgroups inconsistent during snapshot
inheritance, and the wrapper starts another scan. A preserved Kingston config
pair shows distinct root/home QGROUPs (`1/100` and `1/101`) during a later
instance of this cycle, so a shared root/home snapshot group is not required
for it. On the 7.2.6 host, the loaded shared-parent fast-path module completed
the 11:00, 12:00, and 13:00 hourly cycles without a scan. A forced Kingston
rescan after those cycles changed none of the four snapshot/tracker counters.
The two earlier 09:47:09 and 10:23:32 scan completions came from explicit
diagnostic `btrfs quota rescan -w /mnt/kingston` commands logged at 09:35:08
and 10:12:22; the 10:00 Snapper timer finished at 10:00:02 and initiated
neither. These diagnostic scans are separate from the historical automatic
stock-kernel cycle. Longer current-kernel observation, p8 live reconciliation,
and the original onset remain open. The running Btrfs module is still build ID
`258e41d2`; the installed, signed 7.2.6 DKMS module is `46d21507` and is
included in the initramfs. The new teardown backport needs a reboot before live
validation. See `GOAL-done.md`.
For the tested 7.2.6 four-group hierarchy, the source-level cycle is now
identified: stock Btrfs marks accounting inconsistent on snapshot inheritance
because its quick path does not handle source and snapshot groups as siblings
under a common tracker. Before the next Snapper snapshot, `prepareQGroupTracking`
checks the existing hierarchy and calls `quota_rescan_if_needed`, which scans
and waits; the new snapshot then sets the flag again. The four-snapshot-per-
filesystem workload's six stock scans match three scans per filesystem after
the first snapshot. The previous-boot Kingston journal now directly confirms
the same scan/snapshot feedback cycle on stock 7.1.13, while the current 7.2.6
candidate host has had two post-rescan hourly cycles with no new scan. Continue
longer current-kernel observation and counter validation; this evidence does
not establish that every past inconsistency involved incorrect counters or
identify the original onset. Eight-round QEMU snapshot and cleanup/deletion
cycles confirm the scan and counter behavior with stock and candidate modules;
see `GOAL-done.md` for the source and log evidence.
The upstream Btrfs qgroup documentation describes hierarchical groups and a
tracking qgroup for calculating exclusive space at snapshot creation; the
current separate snapshot-group plus common-parent layout follows that model.
The same source tree's `qgroup_account_snapshot()` comment acknowledges a
remaining race window if the source tree changes between flushing delayed refs
and qgroup inheritance. A paired exact-7.2.6 QEMU run now exercised 32 snapshots
per module with four concurrent source writers. The stock module marked each
snapshot accounting inconsistent and its group counters changed on the full
rescan; the candidate module stayed consistent and all snapshot/tracker
counters were unchanged across the rescans. Offline `btrfs check --qgroup-report`
matched the stored and independently computed qgroup values for both modules.
This did not reproduce the source-accounting race; it does not prove that race
impossible or explain the earlier live Kingston inconsistency. The scripts,
counter comparisons, hashes, and limits are recorded in `GOAL-done.md`.
Once the cause is established, leave the host with a persistent fix that
survives normal package upgrades.
The required accounting has four independent snapshot collectives: p8-root,
p8-home, Kingston-root, and Kingston-home. Each Snapper config must keep its
own snapshot QGROUP so its exclusive-space total remains separately visible;
root and home do not need to share a snapshot QGROUP. Preserve accurate
accounting and expected cleanup behavior. Avoid unnecessary
full rescans by correcting their cause, not by hiding inconsistency or
weakening accounting. Keep both rescan gates configurable in Snapper: the
optional hold-file gate and the rolling 24-hour per-filesystem limit. Disable
the daily limit in the investigation host configs so scans may repeat. Keep
the shared hold-file path configured for `force-suspend`; it pauses new scans
only while its temporary marker exists, then expires at its configured local
time (04:00 by default). Keep the configured local-time window at 05:00-21:00
and identical across configs sharing a filesystem. A deferred rescan must
never report stale counters as consistent. When a rescan is
deferred, Snapper must still return last-known quota values with an explicit
stale status; `snapper list` should display them with a warning, and
quota-based cleanup must wait until the counters are consistent.

## Next steps

1. **Complete the host-topology Snapper QEMU investigation — 95% done.** Use the
   latest built Snapper from this repository and disposable QEMU filesystems.
   Compare root and home using one shared snapshot QGROUP ID with the same
   configs using distinct IDs. Start every case from fresh quota state, and
   make the qgroup membership and parent hierarchy match the intended
   configuration before creating snapshots; changing only a config's
   `QGROUP` string after quota setup is not sufficient evidence. Keep the
   kernel module, Snapper build, source data, snapshot sequence, cleanup
   behavior, and rescan policy identical within each comparison.

   Exercise root-only and home-only snapshots, then both orders (root followed
   by home and home followed by root). Record the first operation that sets
   qgroup inconsistency, Snapper's rescan behavior, qgroup membership and
   parent relationships, and counters before and after a full rescan. Repeat
   cases that produce different outcomes. First use the stock module for the
   running kernel; use the candidate module only as a paired comparison where
   it helps distinguish a Snapper layout problem from a kernel accounting
   problem. The manually configured stock-kernel matrix covers fresh shared
   and distinct root/home groups, root-only and home-only repeats, both
   operation orders, explicit-rescan controls, and a rate-limited follow-up
   snapshot. The host-shaped four-group workload has now also been run with
   both stock and candidate modules on the exact current 7.2.6 kernel. Stock
   triggered six automatic scans in eight snapshots; the candidate triggered
   none. The shared-parent fast path is now ported into the exact 7.2.6 source
   tree with Btrfs sanity tests for its eligible topology, fallback cases,
   and counter-overflow handling. A test-enabled module built against the
   installed headers passed those tests at load and completed the same
   workload with zero automatic scans and no inconsistency warnings; the
   matched baseline module with only the qgroup-deletion fix had six
   automatic scans. This supports keeping the fast path as a rescan-avoidance
   optimization for the tested hierarchy, not as evidence that stock
   accounting becomes incorrect after a full scan. Cleanup and synchronous
   deletion were then exercised for all four configs under the same topology.
   Neither operation added scans or warnings
   with either module. This confirms the shared ID is not required for stock's
   conservative fallback, while the candidate fast path avoids it for the
   tested four-group layout. Eight-round repeated QEMU operation and
   source-data/counter reconciliation now pass in both operation orders with
   the candidate; matched stock runs show that the last snapshot's collective
   remains short until a full rescan, and the shortfall moves with snapshot
   order. Eight-round timeline cleanup and synchronous deletion pass in both
   snapshot orders with the candidate and the qgroup-removal-only baseline.
   Live Kingston accounting after three hourly cycles now matches a full
   rescan under the loaded fast-path module. The p8 live comparison,
   hold/window host checks, and broader root-cause reconciliation remain. With
   the candidate module,
   a forced full rescan immediately after snapshots left nonempty qgroup
   counters unchanged in both root-first and home-first order: each snapshot
   group reported 4,243,456 referenced and 49,152 exclusive bytes. The
   49,152-byte metadata component is now reconciled against three unique
   16 KiB metadata tree blocks belonging to the `.snapshots` root and its two
   snapshots. The eight-round test now confirms the same relationship with
   ten MiB of payload and nine unique metadata blocks per snapshot collective;
   the independent extent-tree reconciliation is recorded in `GOAL-done.md`.
   QEMU verified the production `05:00-21:00` window and hold together on the
   stock 7.2.6 module: while held or outside the window, `snapper list`
   displayed the last-known 16 KiB value as stale and started no scan; after
   the marker expired and the window opened, one scan cleared stale status.
   The repeated-cycle QEMU check has now passed for all four configs, with two
   hold/recovery cycles per config. No scan started during a hold or closed
   window, and each release started exactly one scan. The same guest completed
   the eight-round cleanup/deletion workload. Live-host validation and broader
   root-cause reconciliation remain; evidence and test limits are in
   `GOAL-done.md`.

   Decide from these results whether sharing the root/home ID causes the
   inconsistency, contributes through Snapper's tracking hierarchy, or is
   unrelated. For every stock-kernel rescan, determine whether Btrfs is taking
   its conservative fallback for a hierarchy it cannot update incrementally,
   whether Snapper is invoking the rescan on the next snapshot, and whether a
   full rescan restores correct counters. A distinct-ID case that requests a
   rescan does not by itself prove a kernel defect or make the companion a
   correctness fix. Keep the companion only if the measured rescan frequency
   or user-visible behavior cannot meet the required accounting and operating
   constraints with the stock kernel; describe it as a fast-path optimization
   when that is what the evidence supports.
   Continue the host-matched four independent group workload (p8-root,
   p8-home, Kingston-root, Kingston-home). The exact 7.2.6 QEMU cleanup test
   changed source data before snapshots and exercised timeline cleanup plus
   synchronous deletion for every config; the evidence and limits are in
   `GOAL-done.md`. After the first full rescan, all four now-empty snapshot
   groups showed only the 16 KiB `.snapshots` directory, while the source
   groups showed their measured source data. The candidate's nonempty
   snapshot-group counters matched a forced full rescan in both operation
   orders, and the eight-round repeated-cycle checks now also match in both
   orders. The repeated eight-round timeline cleanup and synchronous deletion
   passed with the candidate and baseline modules, without additional scans or
   stale-qgroup errors; see `GOAL-done.md`. The qgroup teardown failure is
   already fixed in the Btrfs maintainer `for-next` branch; do not file a
   duplicate upstream report. Stable 7.2.6 and 7.2.9-7.2.11 still contain the
   affected code. The exact 7.2.6 checkout now backports both upstream
   teardown fixes and has sanity coverage for the rescan-required and missing
   info-item paths; both pass at all five node sizes in QEMU. Port and verify
   these fixes in every release-matched DKMS source variant before relying on
   them across installed kernels. Live-host cleanup validation and broader
   root-cause reconciliation remain.
   The second-rescan `qgroup info item update error
   -2` is traced to Btrfs snapshot-qgroup teardown: relation removal marks
   accounting inconsistent and returns a positive “rescan required” result,
   which caused `btrfs_remove_qgroup()` to exit after deleting the info item
   but before freeing the in-memory qgroup. The maintainer `for-next` branch
   already contains the reviewed fix and a follow-up for leaking a tolerated
   `-ENOENT`; neither appears in stable 7.2.6 or 7.2.9-7.2.11. Both are now
   backported and tested in this exact 7.2.6 source checkout. The in-kernel
   cases verify that positive rescan status still frees the qgroup and that a
   missing on-disk item does not leak as the return value. Keep this teardown
   fix separate from the six ordinary snapshot-creation fallback scans, which
   remain unresolved. Port the backport to every release-matched DKMS source
   variant and verify the installed modules. Do not raise a duplicate upstream
   report; evidence and source references are in `GOAL-done.md`.

   Then continue developing and validating the Snapper fix against the latest
   revision in the official upstream repository
   (`openSUSE/snapper`), checking the upstream tip before rebasing or starting
   new work. Do not use a distribution package source or older downstream
   branch as the development base. The host's required Snapper runtime is our
   locally built and maintained version from latest upstream with our fix;
   install and verify that build after the local safety and acceptance gates.
   The host has since rebooted into `7.2.6+deb13-amd64`; use that exact
   in-use release for all remaining kernel investigation and acceptance
   testing.

   Snapper PR [#1203](https://github.com/openSUSE/snapper/pull/1203) was closed
   without merge on 2026-10-19. The maintainer's stated concern is that qgroup
   values may be incorrect after a single snapshot, so a rescan is required for
   accurate values regardless of how recently the last scan ran; they saw no
   advantage in the gate patch and recommended disabling qgroups if necessary.
   Disabling qgroups does not meet the required four independent exclusive-space
   totals. Treat the hold and daily-limit gates as operational deferrals, not an
   accounting fix, and compare the maintainer's claim with the recorded QEMU
   counter reconciliation: the stock module's counters changed on rescans,
   while the candidate matched the offline qgroup report for the tested
   topology; the concurrent source race remains unreproduced. Keep the local
   Snapper behavior available for stale-status reporting, quota-cleanup safety,
   and urgent suspend, but do not describe PR #1203 as active or resolved. Decide
   whether a concise evidence-based upstream follow-up is justified after the
   newest installed kernel module is activated and live accounting is checked.
   The official master currently matches PR #1203's base. Review its latest tip
   before any rebase or new submission; details are in `GOAL-done.md`.

   **PR description practice:** Follow the target repository's PR template and
   conventions. Keep the description focused on the current implementation,
   current validation, and current limitations. Include prior revisions,
   superseded failures, or historical test comparisons only when the
   repository's PR template or guidance asks for them. Keep project history in
   `GOAL-done.md` or linked evidence. When a commit reference is needed, use a
   concise descriptive Markdown link to the exact commit in its repository,
   rather than displaying a bare full hash.

   Keep `QGROUP_RESCAN_HOLD_FILE` configurable (empty disables the hold) and
   add `QGROUP_RESCAN_DAILY_LIMIT` (default `yes`, `no` disables the rolling
   24-hour cap). For the investigation host, keep the shared hold path enabled
   so `force-suspend` can pause new scans until its deadline, and set the daily
   limit to `no`. The hold is inactive unless the marker exists; it must not
   prevent scans during the investigation otherwise. Use
   `FORCE_SUSPEND_RESCAN_RESUME_TIME` in
   `/etc/default/force-suspend` to configure the hold deadline time (default
   `04:00`). Retain `QGROUP_RESCAN_WINDOW=05:00-21:00`. Before scanning, Snapper
   must verify all three policy values agree across configs sharing a
   filesystem; a mismatch or unverifiable policy defers the scan and preserves
   stale status. An already-running scan is still waited for.

   The p8 host now has separate groups: root `1/100` under tracker `2/0`, and
   home `1/101` under tracker `2/1`. All 15 existing home snapshots and its
   `.snapshots` directory were moved, the home Snapper config was updated, and
   a full rescan completed with consistent accounting. Kingston remains root
   `1/100` and home `1/101`. Keep the four independent collectives and the
   rescan hold/window configuration; the investigation configs have the daily
   limit disabled. The candidate module is active on the current
   `7.2.6+deb13-amd64` kernel.

   On 2026-10-19, our diagnostic `btrfs quota rescan -w /mnt/kingston` commands
   started scans at 09:35 and 10:12, completing at 09:47 and 10:23. At 09:34:56
   the qgroup flag was set but the rescan status said none was running; before
   the 10:12 command, the flag was clear and again no scan was running. The
   `-w` commands therefore started both scans; neither is evidence of a
   Snapper-initiated scan or automatic scan frequency. The 09:47 scan cleared
   Kingston's inconsistency flag and corrected its stale
   counters. The 10:00 hourly run created all four
   configured snapshots; p8 and Kingston both still had clear inconsistency
   flags and Snapper did not start a rescan. A separate diagnostic full scan
   manually started on Kingston at 10:12 completed at 10:23 and adjusted the
   `1/101` and `2/0` exclusive counters by 180,224 bytes even though no
   inconsistency was reported before the scan. The 11:00 and 12:00 hourly runs
   each created Kingston root and home snapshots; both filesystems still had
   clear inconsistency flags, and neither had a scan in progress or a new
   kernel rescan event. The 12:00 cycle used the previously loaded fast-path
   module (build ID `258e41d2`), not the newly installed module (build ID
   `46d21507`). This is a third observed live snapshot cycle after Kingston's
   reconciliation, not proof that the condition stays fixed over longer
   operation or that it explains when Kingston first became inconsistent.
   See `GOAL-done.md`.

   The candidate kernel fast path has passed the documented four-group QEMU
   workload on both the former 7.1.13 release and current 7.2.6 release. On
   7.2.6, matched stock-module runs triggered repeated scans on distinct groups,
   while the candidate run did not. Treat this as evidence for the fast path's
   rescan-avoidance benefit, not as proof of incorrect stock accounting after
   a completed scan. Cleanup and deletion coverage is recorded in
   `GOAL-done.md`; verify the scan and accounting behavior against live-host
   operations, then decide whether the fast path is needed to meet the
   operating constraints. See `GOAL-done.md` for results and limits.

   The shared-parent fast-path kernel companion is based on the Btrfs
   maintainer tree's
   [`for-next` branch](https://git.kernel.org/pub/scm/linux/kernel/git/kdave/linux.git).
   The separate qgroup teardown fix is already present in that branch; the
   shared-parent fast path is not. Its exact-release QEMU tests, including
   ancestor-counter overflow fallback, and current patch checks are recorded
   in `GOAL-done.md`. The current code diff applies to the latest `for-next`
   tip and passes `checkpatch`; the local unsigned mail draft was refreshed
   from that tested implementation. The fast-path patch has not been
   submitted. Obtain the user's DCO sign-off before adding a
   `Signed-off-by` trailer or sending it to the mailing list; this
   public-submission gate does not block local testing or deployment. The
   draft is
   `linux.build/submissions/0001-btrfs-qgroup-shared-parent-fast-inherit.patch`.
2. **Deploy and maintain our latest-upstream Snapper build — 80% done.** The host
   now runs our locally built Snapper from the current PR head
   `7d4db17085ce`; package version
   `0.13.2-1+local1.20261019003646.g7d4db17085ce` is installed for both
   `snapper` and `libsnapper`. The live binary reports Snapper 0.13.2,
   libsnapper 8.2.0, and Btrfs quota support, and lists the p8 `root` and `home`
   configs. Verify config and daemon behavior after package reinstall, then
   finish full accounting and quota checks, rollback, and APT-upgrade behavior.
   Build, package, and live-runtime evidence is in `GOAL-done.md`. Debian packaging
   is only the installation format for our build; the distribution-provided
   Snapper is not the target runtime or a runtime dependency.
   Keep rollout completion gated until technical review, full accounting and
   quota checks, rollback, and APT-upgrade behavior are verified. Upstream PR
   review and DCO sign-off are separate publication gates and are not
   prerequisites for local use. Verify quota support after every package
   reinstall or upgrade, and repeat the APT simulation before changing the
   installed package. The recipe is
   `scripts/build-local-debian-package.sh` on the Snapper fork's
   `codex/local-debian-package-builder` branch; it is separate from upstream
   PR #1203. It keeps generated files in the Snapper sibling build tree. The
   successful build, package installation, and runtime evidence are in
   `GOAL-done.md`. Keep the timeline wrapper's explicit rescan block disabled
   and set `SPACE_LIMIT="1.0"` to disable quota-aware cleanup during
   investigation; an empty value leaves Snapper's default `0.5` limit active.
   Recheck the shared rescan window and hold marker after package configuration
   migrations.
3. **Make the fix durable across APT upgrades — 80% done.** Prefer a Snapper-only
   deployment if that fully fixes the cause and satisfies the rescan ceiling.
   If a kernel/module change is required, choose and document a maintainable,
   APT-managed deployment for the paired kernel and Snapper changes. It must
   automatically apply/build and activate the Btrfs fix on every kernel
   upgrade or reinstall. At all times, every kernel version installed under
   `/lib/modules` must have its matching signed Btrfs module built, selected,
   and included in that kernel's initramfs. This covers the running kernel,
   every older kernel retained for rollback, and each newly installed kernel
   before it can be selected for boot. An upgrade must not silently leave or
   boot an unpatched module;
   Snapper package upgrades/reinstalls must also retain its fix. For Snapper,
   the host runtime must remain our locally built and
   maintained version based on latest upstream; do not switch it back to a
   distribution-provided Snapper binary. For the kernel/module, prefer reviewed
   Debian/upstream packages when available; if locally maintained packages are
   needed, define how they are built, installed, and kept current. Do not
   depend on a manually copied kernel module or silently hold back security
   updates.
   A standalone locally built image is insufficient: Btrfs is shipped in the
   versioned `linux-modules-*` package, and the matching `linux-image-*`
   package requires that exact version. APT metadata and the Debian-source
   rebuild/repository findings are recorded in `GOAL-done.md`. The
   APT-managed DKMS package with release-matched sources is installed and has
   built modules for every currently installed kernel; its failure behavior
   for future unmapped releases and its long-term upgrade path remain to be
   verified. An
   isolated Debian DKMS build against the exact running kernel headers
   succeeded and resolved ahead of the packaged module in a synthetic module
   tree. The candidate is signed with the enrolled `Rebroad` MOK key and passed
   exact-kernel QEMU testing with Secure Boot and signature enforcement
   enabled. The APT-managed DKMS package now carries release-matched source
   variants: the 7.1 source for installed releases 7.1.8 and 7.1.13, plus
   exact 7.2.6 and 7.2.9 sources. The current APT image candidate was 7.2.6.
   Its exact source accepted the qgroup patch and built against its matching
   headers. The package was upgraded before performing the APT kernel upgrade;
   DKMS's real 7.2.6 header hook selected that source, built and signed the
   module, and the kernel post-install included it in the new initramfs. The
   three installed kernel versions verified at that time had signed modules
   selected by `modprobe` and present in their matching initramfs. A later APT
   upgrade installed 7.2.9; its DKMS build succeeded, the signed candidate is
   selected by `modprobe`, and the module is in its initramfs. The host is
   still running 7.2.6; exact 7.2.9 Secure Boot QEMU acceptance has passed.
   The updated DKMS package is now installed, with signed release-matched
   modules selected and present in both installed releases' initramfs images.
   Fresh exact-7.2.6 and exact-7.2.9 Secure Boot QEMU runs passed the full
   Snapper workload.
   The host still has the earlier Btrfs module loaded: its sysfs build ID
   differs from the installed 7.2.6 module, so the new teardown fix is not
   active until reboot. Verify its loaded build ID after boot, then test
   host operation and rollback. Package build, module hashes, QEMU log, and
   per-kernel checks are in `GOAL-done.md`. The installed selector passes for
   a supported release and returns an explicit error for an unmapped release.
   However, source
   inspection shows that this failure propagates through DKMS and Debian's
   `linux-run-hooks --exit-on-error`; an unsupported candidate can therefore
   leave the kernel image package unconfigured. This is not an acceptable
   fail-safe. The installed pre-install APT policy prevents an unsupported
   kernel from becoming bootable without entering a failing DKMS build or
   silently selecting stock Btrfs. Its held-back kernel meta-packages remain
   visible, and non-kernel security updates can proceed. Keep preparing exact
   source support before each new APT kernel candidate and test both the
   supported and unsupported paths end to end.
   The production preference file
   `/etc/apt/preferences.d/99-btrfs-qgroup-kernel.pref` is now installed. It
   allows exact Debian package versions for the supported 7.2.6 and 7.2.9
   kernel builds and denies other versioned kernel images, modules, binaries,
   bases, headers, and kbuild packages. The kernel image/header meta-packages
   remain visible to APT and are kept back when their required kernel is not
   allowed. On the live package lists, both supported releases remain
   candidates; the available 6.12 security image and headers have no
   installation candidate (the current index has no separate 6.12 modules
   package). `apt-get -s install` rejects the 6.12 image, the 7.2.9 image
   remains installable, simulated `apt-get upgrade` and `full-upgrade` report
   no package changes, and `dpkg --audit` is clean. A synthetic 7.3.0
   transaction using the production policy shape visibly kept the kernel
   meta-packages back while upgrading an unrelated security package. It holds
   kernel updates until their exact source, signed module, initramfs, and
   acceptance are ready; maintain the allowlist before each later release.
   Test artifacts and limits are in `GOAL-done.md`.

   The live system still has APT 3.0.3 installed and as its Trixie candidate.
   The previously requested 3.1.8 was a Debian testing version, not available
   from the configured Trixie sources ([Debian package tracker](https://tracker.debian.org/news/1675790/apt-318-migrated-to-testing/);
   [Trixie package page](https://packages.debian.org/source/stable/apt)). The
   kernel guard was tested with the installed Trixie APT 3.0.3; no testing
   source was added for this work.

   **Next steps for safe local production use:**
   - Build, signing, module selection, initramfs inclusion, and exact-release
     Secure Boot QEMU acceptance are verified for installed 7.2.6 and 7.2.9.
     The host still runs 7.2.6 with build ID `258e41d2` loaded; the installed
     7.2.6 DKMS module is signed, selected, and in its initramfs with build ID
     `46d21507`. `GRUB_DEFAULT=0` will boot 7.2.9 next; its signed DKMS module
     (build ID `29eef0f6`) is also selected and in its initramfs. The 7.2.6
     kernel and initramfs remain installed for rollback. After an approved
     reboot, verify the 7.2.9 loaded build ID and live qgroup behavior, then
     explicitly boot 7.2.6 to verify its replacement module and rollback path.
     Final accounting and live-host cleanup acceptance remain outstanding.
     Evidence and hashes are in `GOAL-done.md`.
   - The DKMS package now maps exact sources for 7.2.6 and 7.2.9, and the
     actual 7.2.6 header and image hooks passed. Maintain matching modules for
     every installed kernel, including the currently running release and
     rollback versions. Also prepare and validate the module for the next
     kernel version APT will install or select, before rebooting into it: add
     its matching source, verify the DKMS build and Secure Boot signature,
     confirm module selection and initramfs inclusion, and complete these
     checks before that release can be selected for boot. Repeat this for
     every later kernel version. Prove an unmapped or failed build cannot
     silently boot stock Btrfs or leave package configuration broken; keep
     normal security upgrades available.
   - Keep the verified boot selection and signed stock-module rollback path
     documented. Verify the new p8 groups through Snapper operations and
     cleanup, and retain the active 7.2.6 release as the acceptance kernel.
   - Verify the installed Snapper package after upgrade/reinstall and confirm
     every Kingston configuration under
     `/mnt/kingston/@/etc/snapper/configs/` retains the rescan window and hold
     settings. Use `sudo` for these root-owned configs and live qgroup queries;
     the unprivileged sandbox view reports Kingston read-only and denies
     qgroup ioctls. Restore quota cleanup limits only after accounting and
     cleanup are verified under the paired host runtime.

   Before considering the host rollout complete, verify the running kernel,
   loaded module, initramfs, Secure Boot signature, and active Snapper package
   contain the intended fixes after both package reinstall and kernel upgrade.
4. **Finish accounting and recovery coverage — 95% done.** Use the latest-upstream
   Snapper build as the primary acceptance target and the exact currently
   running kernel (`7.2.6+deb13-amd64`). Existing QEMU coverage and results are in
   `GOAL-done.md`. The exact-header external build has
   `CONFIG_BTRFS_FS_RUN_SANITY_TESTS` disabled. Although the module retains a
   `btrfs_run_sanity_tests` entry-point symbol, disassembly shows it is only
   the no-op stub; no Btrfs sanity-test objects or test functions are linked.
   The earlier concern that the QEMU-tested module ran developer tests at load
   time was incorrect. The current patched module, signed with the enrolled
   MOK key, has now passed the full Snapper 0.13.2 QEMU acceptance workload on
   the previous exact kernel; see the artifact hashes and serial log in
   `GOAL-done.md`. Re-run the Secure Boot acceptance workload against 7.2.6
   before considering production rollout complete.
   Follow-up QEMU acceptance now boots the exact kernel through OVMF and shim
   with Secure Boot enabled, imports the enrolled MOK certificate, and forces
   `module.sig_enforce=1`. The signed Btrfs module loads, while an unsigned
   copy is rejected. The full Snapper workload passes under enforcement; see
   `GOAL-done.md`. The candidate is installed and loaded on the host; finish
   Snapper package rollback verification and repeat Secure Boot acceptance on
   7.2.6 before calling the rollout complete.
   The exact-release checkout now has
   maintainable qgroup selftests for the shared-parent fast path and the
   differing/multiple-parent fallbacks; they passed in QEMU on the exact
   kernel. The tests and candidate kernel patch now apply to the current Btrfs
   `for-next` submission base. Keep runtime kernel testing on the exact
   in-use release; do not build or boot a different kernel for acceptance.
   The 2026-10-19 follow-up directly covers overflow in the target snapshot
   group's exclusive counters, the shared tracker's four counters, and all
   four ancestor counters; the exact-7.2.6 QEMU sanity run passed at all five
   nodesizes. See `GOAL-done.md`. Add further coverage only for Btrfs layouts
   needed by the patch or not already covered.
5. **Preserve temporary host containment, including after resume — 94% done.** The
   timeline wrapper's explicit `btrfs quota rescan` commands are currently
   disabled while snapshots continue; the current host check is recorded in
   `GOAL-done.md`. The 18:00 run exposed duplicate hourly snapshots: `/` and
   `/mnt/p8/@` resolve to the same Btrfs subvolume IDs, and the mounted config
   tree was discovered twice. The root-repo wrapper now deduplicates by device,
   subvolume ID, and config. The installed
   `/usr/local/sbin/snapper-timeline-all-roots` matches root-repo commit
   `19f05f689`. The system journal shows eight consecutive hourly runs
   completed from 18:00 on 2026-10-18 through 01:00 on 2026-10-19, with 28
   duplicate-target skip messages and no failure messages. A read-only
   `info.xml` audit also confirms exactly one timeline snapshot in each of the
   p8-root, p8-home, Kingston-root, and Kingston-home snapshot directories for
   each of the 00:00, 01:00, and 02:00 runs on 2026-10-19. This verifies the
   four intended targets for those runs. The kernel journal contains no
   qgroup inconsistency or rescan entries during these runs; it records one
   earlier scan completion at 22:27. This observation does not establish
   counter accuracy. Live qgroup totals and actual suspend/resume ordering
   remain unverified. This removes
   redundant snapshot triggers, but does not yet prove the qgroup
   inconsistency's underlying cause. This wrapper is one rescan initiator;
   Snapper's quota-query and snapshot-tracking code can independently start a
   rescan when it finds inconsistent qgroups. Btrfs snapshot inheritance can
   mark qgroups inconsistent, but does not itself start a rescan. Keep those
   state changes distinct when tracing future scans. The active hourly
   `snapper-timeline.timer` uses `OnCalendar`; systemd catches up calendar
   events that elapse during suspend when the system resumes. The sleep/resume
   guard is pushed to the home repository branch `codex/snapper-timeline-sleep-guard` at `17d09379`. The
   host now has the local timeline and daily cleanup timers restored under
   `/etc/systemd/system`; the hourly wrapper invokes the installed Snapper
   directly. The enabled `sleep.target` service and system-sleep hook both
   invoke the same root-owned helper under `/usr/local/libexec`; static review
   confirms it stops the timeline timer before sleep and refreshes the hold
   before restarting the timer. The resume hold helper formerly hardcoded
   04:00/16:00 and ignored `FORCE_SUSPEND_RESCAN_RESUME_TIME`; it is now fixed
   and verified to honor that setting and the configured hold-file path. The
   hooks share a `/run` state file to make duplicate calls idempotent. The timer
   and guard were enabled, and no stale sleep state or active hold marker was
   present at the latest audit. Actual suspend/resume ordering and timer
   catch-up behavior remain unverified. Verify that a real resume cannot start
   a fresh scan through either the wrapper or Snapper's internal path. The timer
   catch-up guard is separate from the
   `force-suspend` hold, whose release deadline is controlled by its own
   setting. See `GOAL-done.md` for the live audit.
   Restore the original
   `SPACE_LIMIT="0.5"` settings only after both changes are deliberately
   deployed and their initialization scan, quota accounting, and cleanup
   behavior are verified.

## Acceptance

Repeated Snapper-style snapshots and cleanup, including externally shared
extents, keep qgroup data consistent. The exclusive-space totals for p8-root,
p8-home, Kingston-root, and Kingston-home remain separately queryable and
match a full rescan; root and home never share one snapshot QGROUP. Quota
limits retain their existing snapshot-only scope.
After the accounting cause is fixed, unnecessary rescans do not recur.
Automatic full rescans start only inside the configured local-time window.
During investigation, the per-day cap is disabled, while `force-suspend` can
hold new scans until its configured deadline. If a rescan is deferred, users
can still see the last-known quota numbers and their stale status; quota-based
deletion waits until the numbers are current. The host's configured preference is
05:00-21:00 local time for every Snapper configuration sharing the filesystem;
the timeline wrapper's separate explicit rescan commands remain disabled.
Prefer a Snapper-only fix. If the kernel/module must change, it is automatically
reapplied and active after every kernel APT upgrade/reinstall, without blocking
security updates; the installed Snapper fix also survives its APT
upgrade/reinstall. Verify the running kernel, loaded module, Snapper package,
and rescan rate.

## Completed evidence

See [`GOAL-done.md`](GOAL-done.md) for completed investigation, reproduction
results, kernel baseline, and temporary containment details. That file is
historical reference; the items above are the active work.
