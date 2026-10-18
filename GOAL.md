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
Preserve accurate accounting and expected cleanup behavior. Avoid unnecessary
full rescans by correcting their cause, not by hiding inconsistency or
weakening accounting. Any automatic full rescans that remain necessary must be
limited to a configurable local-time window and at most one per filesystem in
any rolling 24-hour period, including across multiple Snapper configurations
and repeated triggers. The host preference is 05:00-21:00 local time; all
Snapper configurations sharing a filesystem must use the same window. A rate
limit must never report stale counters as consistent. When a rescan is
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
   seven CI checks pass, and upstream review is pending. Keep this PR paired
   with the kernel change through review. The current source, CI, and local
   validation evidence is recorded in `GOAL-done.md`; refresh upstream state
   before rebasing or starting new work.

   **PR description practice:** Follow the target repository's PR template and
   conventions. Keep the description focused on the current implementation,
   current validation, and current limitations. Include prior revisions,
   superseded failures, or historical test comparisons only when the
   repository's PR template or guidance asks for them. Keep project history in
   `GOAL-done.md` or linked evidence. When a commit reference is needed, use a
   concise descriptive Markdown link to the exact commit in its repository,
   rather than displaying a bare full hash.

   `QGROUP_RESCAN_HOLD_FILE` defers new automatic scans while a shared
   absolute-path marker has a future deadline; it does not cancel an
   already-running scan. Set `QGROUP_RESCAN_HOLD_FILE=/home/rebroad/.local/state/snapper/qgroup-rescan-hold-until`
   and the same `QGROUP_RESCAN_WINDOW=05:00-21:00` on every Kingston Snapper
   config, retaining the rolling 24-hour per-filesystem cap. Before starting a
   new scan, Snapper now checks the window and hold path for every configured
   nonempty `QGROUP` on that filesystem. A mismatch or inability to inspect
   the configured policies defers the scan and leaves quota data stale; an
   already-running scan is still waited for. This runtime check complements
   deployment verification that every Kingston config uses the intended
   shared values.

   The Snapper-only candidate does not keep qgroups consistent with the stock
   module in the reproduced snapshot workload. The paired Btrfs change avoids
   that inconsistency fallback for the tested shared-parent topology; no
   counter corruption has been demonstrated, so this is a scan-avoidance
   optimization, not a repair for proven bad accounting. Preserve the existing
   conservative fallback for other layouts. QEMU comparisons and the
   `linux-btrfs` discussion are documented in `GOAL-done.md`.

   The kernel companion is based on the Btrfs maintainer tree's
   [`for-next` branch](https://git.kernel.org/pub/scm/linux/kernel/git/kdave/linux.git).
   Its exact-release QEMU tests, including ancestor-counter overflow fallback,
   and current patch checks are recorded in `GOAL-done.md`. The patch has not
   been submitted. Review the exact patch and obtain the user's DCO sign-off
   before adding a `Signed-off-by` trailer or sending it to the mailing list;
   this public-submission gate does not block local testing or deployment.
   The unsigned mail-formatted draft is
   `linux.build/submissions/0001-btrfs-qgroup-shared-parent-fast-inherit.patch`.
2. **Deploy and maintain our latest-upstream Snapper build — 65% done.** Install our
   locally built Snapper from the latest upstream baseline, including our
   qgroup fix, as the host's active Snapper runtime. Debian packaging
   is only the installation format for our build; the distribution-provided
   Snapper is not the target runtime or a runtime dependency.
   Keep local deployment gated until technical review, the full accounting and
   quota checks, Secure Boot signing, rollback, and kernel-upgrade behavior are
   verified. Upstream PR review and DCO sign-off are separate
   publication gates and are not prerequisites for local use.
   Rebuild from the latest reviewed Snapper source with the committed local
   Debian package recipe, verify quota support in the binary, and repeat the
   APT simulation before deployment. The recipe is
   `scripts/build-local-debian-package.sh` on the Snapper fork's
   `codex/local-debian-package-builder` branch; it is separate from upstream
   PR #1203. It keeps generated files in the Snapper sibling build tree. The
   successful uninstalled build and test evidence are in `GOAL-done.md`.
   Keep the timeline wrapper's explicit rescan block
   disabled and `SPACE_LIMIT` empty during investigation.
3. **Make the fix durable across APT upgrades — 65% done.** Prefer a Snapper-only
   deployment if that fully fixes the cause and satisfies the rescan ceiling.
   If a kernel/module change is required, choose and document a maintainable,
   APT-managed deployment for the paired kernel and Snapper changes. It must
   automatically apply/build and activate the Btrfs fix on every kernel
   upgrade or reinstall, and ensure an upgrade cannot silently leave or boot
   an unpatched module; Snapper package upgrades/reinstalls must also retain
   its fix. For Snapper, the host runtime must remain our locally built and
   maintained version based on latest upstream; do not switch it back to a
   distribution-provided Snapper binary. For the kernel/module, prefer reviewed
   Debian/upstream packages when available; if locally maintained packages are
   needed, define how they are built, installed, and kept current. Do not
   depend on a manually copied kernel module or silently hold back security
   updates.
   A standalone locally built image is insufficient: Btrfs is shipped in the
   versioned `linux-modules-*` package, and the matching `linux-image-*`
   package requires that exact version. APT metadata and the Debian-source
   rebuild/repository findings are recorded in `GOAL-done.md`; the paired
   package and update workflow remains to be selected and verified. An
   isolated Debian DKMS build against the exact running kernel headers
   succeeded and resolved ahead of the packaged module in a synthetic module
   tree. The candidate is signed with the enrolled `Rebroad` MOK key and passed
   exact-kernel QEMU testing with Secure Boot and signature enforcement
   enabled. The reviewed local DKMS package recipe is committed, built, and
   installed for the running kernel; it is also built and installed for every
   kernel currently present on the host: `7.1.8+deb13-amd64` and
   `7.1.13+deb13-amd64`. Both module files are signed by the enrolled key,
   selected by `modprobe` for their respective kernel releases, and included
   under `updates/dkms` in their matching initramfs images. Package removal and
   reinstall have now verified restoration of the stock module and reselection
   of the candidate for both kernels. A follow-up lifecycle revision also
   removes stale DKMS registrations from prior versioned source directories;
   package upgrade, clean DKMS status, removal rollback, and reinstall all pass.
   Neither candidate module has been booted. The current APT backports candidate
   is kernel `7.2.6+deb13-amd64`; a compile-only probe showed that the current
   7.1.13 Btrfs source does not build against its changed internal APIs. The
   7.2.6 kernel is not installed. Debian's kernel hook chain propagates DKMS
   build failures from image post-install, so validate an upgrade path that
   neither leaves APT
   failing nor permits booting an unpatched Btrfs module when a future kernel
   build is unsupported.

   **Next steps for safe local production use:**
   - Completed for all currently installed kernels: build, sign, and install
     the candidate for 7.1.8 and 7.1.13; verify per-kernel module selection,
     initramfs inclusion, package upgrade cleanup, and stock-module rollback.
     The host has not booted either candidate module yet. Evidence and hashes
     are in `GOAL-done.md`.
   - Port or regenerate the paired Btrfs source for the next APT kernel version
     before upgrading to it. The 7.1.13 DKMS source fails to compile against
     the available 7.2.6 headers due to Btrfs internal API changes. Verify
     automatic DKMS signing and initramfs ordering for the next installed
     kernel, then prove an unsupported build cannot silently boot an unpatched
     module or leave kernel package configuration broken. Preserve normal
     security upgrades.
   - After review, activate the candidate at a planned reboot and verify the
     running kernel, loaded module version/signature, and Btrfs qgroup behavior
     on the host. Keep a tested route back to the stock module.
   - Simulate and perform the relevant kernel APT upgrade/reinstall path.
     Verify DKMS rebuild and signing for the new kernel, initramfs selection,
     and booted module; also prove a failed/unsupported build cannot silently
     boot the stock unpatched module or leave kernel package configuration
     broken. Preserve normal kernel security upgrades.
   - Install the locally built latest-upstream Snapper package only after the
     same review of its package contents, config migration, and rollback path.
     Verify the active binary and library are the locally built versions,
     with the rescan window and hold settings applied to every Kingston
     configuration. Restore quota cleanup limits only after accounting and
     cleanup are verified under the paired host runtime.

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
   `GOAL-done.md`. Have a tested rollback path ready before host installation.
   The exact-release checkout now has
   maintainable qgroup selftests for the shared-parent fast path and the
   differing/multiple-parent fallbacks; they passed in QEMU on the exact
   kernel. The tests and candidate kernel patch now apply to the current Btrfs
   `for-next` submission base. Keep runtime kernel testing on the exact
   in-use release; do not build or boot a different kernel for acceptance.
   Add coverage only for Btrfs layouts needed by the patch or not already
   covered.
5. **Preserve temporary host containment, including after resume — 80% done.** The
   timeline wrapper's explicit `btrfs quota rescan` commands are currently
   disabled while snapshots continue; the current host check is recorded in
   `GOAL-done.md`. This wrapper is one rescan initiator;
   Snapper's quota-query and snapshot-tracking code can independently start a
   rescan when it finds inconsistent qgroups. Btrfs snapshot inheritance can
   mark qgroups inconsistent, but does not itself start a rescan. Keep those
   state changes distinct when tracing future scans. The active hourly
   `snapper-timeline.timer` uses `OnCalendar`; systemd catches up calendar
   events that elapse during suspend when the system resumes. Prevent that
   catch-up run from accidentally starting a fresh qgroup scan, including
   through Snapper's internal rescan path. PR #1203 now teaches Snapper's
   internal limiter to honor the force-suspend marker through
   `QGROUP_RESCAN_HOLD_FILE`; configure the shared local-home marker path in
   every Kingston config. `force-suspend` and its resume helper now use this
   path because `/var/tmp` resolves inside Kingston and is unmounted by
   `force-unmount-kingston.sh`; the suspend command now fails closed if it
   cannot write the hold. The sleep/resume guard is pushed to the home
   repository branch `codex/snapper-timeline-sleep-guard` at `17d09379`. The
   system unit executes a root-owned helper under `/usr/local/libexec`; that
   helper delegates hold-file writes to `rebroad` and retains root only for
   timer control. Its installer installs and enables the unit. Seven isolated
   helper and installer tests pass. It is not installed or enabled on the
   host. Install it with the built Snapper configuration, then verify
   post-resume ordering and prove no catch-up invocation starts a fresh scan.
   Restore the original
   `SPACE_LIMIT="0.5"` settings only after both changes are deliberately
   deployed and their initialization scan, quota accounting, and cleanup
   behavior are verified.

## Acceptance

Repeated Snapper-style snapshots and cleanup, including externally shared
extents, keep qgroup data consistent; reference and exclusive counters match a
full rescan, and quota limits retain their existing snapshot-only scope.
Unnecessary rescans do not recur, and any automatic full rescans that remain
necessary start only inside the configured local-time window and no more than
once per filesystem in any rolling 24-hour period across all Snapper
processes and configurations. If a rescan is deferred, users can still see the
last-known quota numbers and their stale status; quota-based deletion waits
until the numbers are current. The host's configured preference is
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
