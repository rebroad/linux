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

Find and fix the cause of Snapper-triggered Btrfs qgroup inconsistency, and
leave the host with a persistent fix that survives normal package upgrades.
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

1. **Complete the paired upstream contributions — 70% done.** Develop and validate the
   Snapper fix against the latest revision in the official upstream repository
   (`openSUSE/snapper`), checking the upstream tip before rebasing or starting
   new work. Do not use a distribution package source or older downstream
   branch as the development base. The host's required Snapper runtime is our
   locally built and maintained version from latest upstream with our fix;
   install and verify that build after the local safety and acceptance gates.
   Use only the exact in-use kernel release `7.1.13+deb13-amd64` for remaining
   kernel investigation and acceptance testing.

   The Snapper companion is upstream PR [#1203](https://github.com/openSUSE/snapper/pull/1203),
   based on the latest official `openSUSE/snapper` master. It is open, all
   seven CI checks pass, and upstream review is pending. Keep PR #1203 active
   while validating the accounting design. The kernel change remains a
   candidate, not an assumed requirement: exact-release QEMU testing now shows
   that distinct per-config QGROUPs with the current Snapper still become
   inconsistent on the stock module, while the candidate module keeps four
   independent groups consistent. Test whether a Snapper-only design can meet
   the same four-group requirement before deciding that the kernel change is
   necessary. Results and limits are recorded in `GOAL-done.md`; refresh
   upstream state before rebasing or starting new work.

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

   Kingston already assigns root to `1/100` and home to `1/101`. On p8, both
   configs still use `1/100`; that group currently contains 79 root snapshots,
   28 home snapshots, and both `.snapshots` subvolumes. Migrate p8 so root and
   home have distinct snapshot QGROUPs, accounting for existing as well as
   future snapshots and keeping a separate source-plus-snapshot tracker for
   each config. Then verify p8-root, p8-home, Kingston-root, and Kingston-home
   independently against a full rescan. Root and home must not be combined
   into one snapshot QGROUP. Both filesystems currently report inconsistent
   qgroup data, so their stored byte counters are stale until rescanned.
   QEMU reproduced the p8 layout: the root snapshot stayed consistent, then
   the home snapshot in the shared root group logged `qgroup inherit needs a
   rescan`, even with the candidate module. After moving existing home
   snapshots to their own group, pairing that group and the live home source
   under a separate tracker, and rescanning, new root/home snapshots remained
   consistent and the exclusive counters matched a full rescan. This confirms
   the shared p8 group/tracker mismatch as a cause on p8. The host migration
   must wait until the candidate module is active. Run the migration's
   required full rescan inside the configured window; the disabled daily limit
   allows repeated rescans during investigation. Keep the hold path configured
   for `force-suspend`, which creates a temporary marker only when needed.

   The tested Snapper tracking layout gives each config a separate level-1
   snapshot QGROUP and pairs that QGROUP with its live source under a tracker.
   On stock `7.1.13`, inherited snapshots still mark qgroups inconsistent and
   a later full rescan changes stale exclusive counters. The candidate Btrfs
   fast path avoids those marks in the four-group QEMU workload and the
   counters then match a full rescan. This supports the candidate for the
   tested layout, but does not rule out a different Snapper-only design.
   Preserve the conservative fallback for layouts the fast path cannot prove
   safe. See `GOAL-done.md` for the controlled comparison.

   The kernel companion is based on the Btrfs maintainer tree's
   [`for-next` branch](https://git.kernel.org/pub/scm/linux/kernel/git/kdave/linux.git).
   Its exact-release QEMU tests, including ancestor-counter overflow fallback,
   and current patch checks are recorded in `GOAL-done.md`. The patch has not
   been submitted. Review the exact patch and obtain the user's DCO sign-off
   before adding a `Signed-off-by` trailer or sending it to the mailing list;
   this public-submission gate does not block local testing or deployment.
   The unsigned mail-formatted draft is
   `linux.build/submissions/0001-btrfs-qgroup-shared-parent-fast-inherit.patch`.
2. **Deploy and maintain our latest-upstream Snapper build — 80% done.** The host
   now runs our locally built Snapper from the latest upstream baseline,
   including our qgroup fix. Debian packaging
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
3. **Make the fix durable across APT upgrades — 75% done.** Prefer a Snapper-only
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
   module, and the kernel post-install included it in the new initramfs. All
   three installed kernel versions now have a signed module selected by
   `modprobe` and present in the matching initramfs. The default next boot is
   7.2.6; the machine is still running 7.1.13 and has not rebooted. The package
   also maps 7.2.9 in case that image release becomes available. Package build,
   module hashes, APT result, and per-kernel verification are in
   `GOAL-done.md`. The source selector deliberately fails for an unmapped
   release. Prepare and test source support before installing each new APT
   kernel candidate, and prove an unsupported build cannot silently boot an
   unpatched module or leave kernel package configuration broken while
   preserving security updates.

   **Next steps for safe local production use:**
   - Build, signing, module selection, and initramfs inclusion are verified for
     all three installed releases: 7.1.8, 7.1.13, and 7.2.6. Stock-module
     rollback and reinstall were also verified for 7.2.6. That kernel has not
     been booted; verify its loaded module at a planned reboot. Evidence and
     hashes are in `GOAL-done.md`.
   - The DKMS package now maps exact sources for 7.2.6 and 7.2.9, and the
     actual 7.2.6 header and image hooks passed. Before any later kernel
     release is installed, add its matching source and verify its DKMS build,
     signature, module selection, and initramfs. Prove an unmapped or failed
     build cannot silently boot stock Btrfs or leave package configuration
     broken; keep normal security upgrades available.
   - At a planned reboot, activate the 7.2.6 candidate and verify the running
     kernel, loaded module version/signature, and Btrfs qgroup behavior on the
     host. Keep a tested route back to stock Btrfs.
   - Verify the installed Snapper package after upgrade/reinstall and confirm
     every Kingston configuration retains the rescan window and hold settings.
     Restore quota cleanup limits only after accounting and cleanup are
     verified under the paired host runtime.

   Before considering the host rollout complete, verify the running kernel,
   loaded module, initramfs, Secure Boot signature, and active Snapper package
   contain the intended fixes after both package reinstall and kernel upgrade.
4. **Finish accounting and recovery coverage — 95% done.** Use the latest-upstream
   Snapper build as the primary acceptance target and the exact
   `7.1.13+deb13-amd64` kernel. Existing QEMU coverage and results are in
   `GOAL-done.md`. The exact-header external build has
   `CONFIG_BTRFS_FS_RUN_SANITY_TESTS` disabled. Although the module retains a
   `btrfs_run_sanity_tests` entry-point symbol, disassembly shows it is only
   the no-op stub; no Btrfs sanity-test objects or test functions are linked.
   The earlier concern that the QEMU-tested module ran developer tests at load
   time was incorrect. The current patched module, signed with the enrolled
   MOK key, has now passed the full Snapper 0.13.2 QEMU acceptance workload on
   the exact kernel; see the artifact hashes and serial log in `GOAL-done.md`.
   Follow-up QEMU acceptance now boots the exact kernel through OVMF and shim
   with Secure Boot enabled, imports the enrolled MOK certificate, and forces
   `module.sig_enforce=1`. The signed Btrfs module loads, while an unsigned
   copy is rejected. The full Snapper workload passes under enforcement; see
   `GOAL-done.md`. The candidate is installed on the host; finish Snapper
   package rollback verification and boot-time kernel verification before
   calling the rollout complete.
   The exact-release checkout now has
   maintainable qgroup selftests for the shared-parent fast path and the
   differing/multiple-parent fallbacks; they passed in QEMU on the exact
   kernel. The tests and candidate kernel patch now apply to the current Btrfs
   `for-next` submission base. Keep runtime kernel testing on the exact
   in-use release; do not build or boot a different kernel for acceptance.
   Add coverage only for Btrfs layouts needed by the patch or not already
   covered.
5. **Preserve temporary host containment, including after resume — 92% done.** The
   timeline wrapper's explicit `btrfs quota rescan` commands are currently
   disabled while snapshots continue; the current host check is recorded in
   `GOAL-done.md`. The 18:00 run exposed duplicate hourly snapshots: `/` and
   `/mnt/p8/@` resolve to the same Btrfs subvolume IDs, and the mounted config
   tree was discovered twice. The root repo wrapper now deduplicates by device,
   subvolume ID, and config; its live-target check passed, but the next
   scheduled run still needs to confirm one snapshot per target. This removes
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
   directly. The enabled sleep.target unit and system-sleep hook use one
   root-owned helper under `/usr/local/libexec` for timer control. Current host
   state is recorded in `GOAL-done.md`. No actual suspend/resume has yet been
   used to verify ordering or the timer's catch-up behavior. Verify that a real
   resume cannot start a fresh scan through either the wrapper or Snapper's
   internal path. The timer catch-up guard is separate from the `force-suspend`
   hold, whose release deadline is controlled by its own setting.
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
