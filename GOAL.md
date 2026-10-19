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
For any future PR, follow the target repository's template and keep the text to
the current implementation, validation, and limitations. Include historical
material only when the repository asks for it; make commit references clickable
and avoid duplicate URLs. See `GOAL-done.md` for the closed PR history.

The reproducible stock-kernel cycle is identified for the tested hierarchy:
Btrfs marks qgroup accounting inconsistent during snapshot inheritance, and
Snapper's next quota-tracked operation checks that state and may start a full
scan. Distinct root/home snapshot QGROUPs still encounter the fallback, so
sharing their ID is not the cause. QEMU workload, source, and scan-attribution
evidence is in `GOAL-done.md`.

The host currently runs the shared-parent fast path on `7.2.6+deb13-amd64`
(build ID `258e41d2`). Its 11:00-14:00 hourly runs created all four snapshots
without a scan; a Kingston full rescan after the first three cycles changed no
qgroup counters. The p8 diagnostic scan and subsequent live counter readings
are inconclusive because filesystem activity continued during measurement. The
newer signed DKMS modules for installed 7.2.6 and 7.2.9 are not active; reboot,
live accounting validation, and rollback checks remain open. The first-ever
onset of the historical Kingston inconsistency is unknown. See `GOAL-done.md`
for the complete chronology and evidence.
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
The host's shared marker path is also used by Kingston's `--root` invocation:
Snapper opens the configured absolute path directly rather than prefixing it
with the alternate root. The current source/config match is recorded in
`GOAL-done.md`; a real suspend/resume hold test remains open.

## Next steps

1. **Finish root-cause and live-accounting validation — 95% done.** The
   controlled QEMU matrix and source trace are complete; results are in
   `GOAL-done.md`. The provisional module decision above is for the tested
   hierarchy and does not claim a general Btrfs correctness bug.

   Remaining: after the installed signed module is activated, validate
   sustained four-root snapshot/accounting behavior on the host. Reconcile p8
   counters against an independent report without concurrent updates; the
   current live sample is inconclusive. The reproducible stock-kernel cycle is
   understood, but the first-ever Kingston onset remains unknown.

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
