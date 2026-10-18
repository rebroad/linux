# Goal: fix Snapper-triggered Btrfs qgroup inconsistency

The host's intended and required Snapper runtime is the locally built version
from our Snapper repository, based on the latest official upstream source and
carrying our reviewed changes. A distribution-provided Snapper binary is only
a diagnostic baseline during migration and must not be the host's final or
active runtime.

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

## Remaining work

1. **Complete the paired upstream contributions.** Develop and validate the
   Snapper fix against the latest revision in the official upstream repository
   (`openSUSE/snapper`), checking the upstream tip before rebasing or starting
   new work. Do not use a distribution package source or older downstream
   branch as the development base. The host's required Snapper runtime is our
   locally built and maintained version from latest upstream with the reviewed
   fix; install and verify that build after the review and acceptance gates.
   Use only the exact in-use kernel release `7.1.13+deb13-amd64` for remaining
   kernel investigation and acceptance testing.

   The Snapper companion is upstream PR [#1203](https://github.com/openSUSE/snapper/pull/1203),
   currently at `1d26f1890c0742bfbc04f56d4f1d1d9c8a256fe0` against upstream
   `master` `5a2dd6a8559c1a04c5575bf184acb347dce0d8f7`. It has no review
   decision. Codespell and five of six CI build/test checks pass. Tumbleweed
   Clang failed before compilation on package-mirror timeouts. A local Clang
   19.1.7 full compile and `make check` passed (30 passed, 2 skipped, 0
   failed), but the failed CI check remains red and was not rerun. Keep this PR
   paired with the kernel change through review.
   `QGROUP_RESCAN_HOLD_FILE` defers new automatic scans while a shared
   absolute-path marker has a future deadline;
   it does not cancel an already-running scan. Set the same
   `QGROUP_RESCAN_WINDOW=05:00-21:00` and hold-file path on every Kingston
   Snapper config, retaining the rolling 24-hour per-filesystem cap.

   The Snapper-only candidate does not keep qgroups consistent with the stock
   module in the reproduced snapshot workload. The paired Btrfs change avoids
   that inconsistency fallback for the tested shared-parent topology; no
   counter corruption has been demonstrated, so this is a scan-avoidance
   optimization, not a repair for proven bad accounting. Preserve the existing
   conservative fallback for other layouts. QEMU comparisons and the
   `linux-btrfs` discussion are documented in `GOAL-done.md`.

   The replacement kernel patch applies to Btrfs `for-next`
   `2789b2c034d7c0c8687355921a38c5ac41a565fa`, passes a zero-fuzz dry run and
   `checkpatch.pl --strict --no-tree --no-signoff`, and has exact-release QEMU
   fallback coverage. Standard `checkpatch.pl --strict` reports only the
   missing `Signed-off-by` trailer. The patch has not been resubmitted; obtain
   the user's DCO sign-off for this exact patch before adding that trailer or
   sending it.
2. **Deploy and maintain our latest-upstream Snapper build.** Install our
   locally built Snapper from the latest upstream baseline, including the
   reviewed qgroup fix, as the host's active Snapper runtime. Debian packaging
   is only the installation format for our build; the distribution-provided
   Snapper is not the target runtime or a runtime dependency.
   Keep deployment
   gated until the Snapper change and, if required, its
   paired kernel change have review and the full accounting/quota checks pass.
   Rebuild from the latest reviewed Snapper source with the committed local
   Debian package recipe, verify quota support in the binary, and repeat the
   APT simulation before deployment. The recipe is
   `scripts/build-local-debian-package.sh` on the Snapper fork's
   `codex/local-debian-package-builder` branch; it is separate from upstream
   PR #1203. It keeps generated files in the Snapper sibling build tree. The
   successful uninstalled build and test evidence are in `GOAL-done.md`.
   Keep the timeline wrapper's explicit rescan block
   disabled and `SPACE_LIMIT` empty during investigation.
3. **Make the fix durable across APT upgrades.** Prefer a Snapper-only
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
   external module build against the exact running kernel headers succeeded,
   making an APT-packaged DKMS module a competing option. Secure Boot is
   enabled, module signatures are enforced, and the probe module was
   unsigned; test signing, enrollment, initramfs selection, and upgrade
   behavior before choosing DKMS. Debian's kernel hook chain propagates DKMS
   build failures from image post-install, so prove an unsupported future
   kernel cannot leave APT upgrades failing or boot an unpatched Btrfs module.
   Before considering the host rollout complete, exercise the relevant APT
   upgrade/reinstall path and verify the running kernel, loaded module, and
   Snapper package contain the intended fix afterward. Preserve normal kernel
   security upgrades; do not rely on manual intervention after each APT
   kernel upgrade.
4. **Finish accounting and recovery coverage.** Use the latest-upstream
   Snapper build as the primary acceptance target and the exact
   `7.1.13+deb13-amd64` kernel. Existing QEMU coverage and results are in
   `GOAL-done.md`. After upstream review, rerun the full acceptance workload
   against the final paired source; add coverage only for Btrfs layouts needed
   by the patch or not already covered.
5. **Preserve temporary host containment, including after resume.** The
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
   `QGROUP_RESCAN_HOLD_FILE`; configure that option in every Kingston config
   and verify the shared path. The committed sleep/resume guard stops the
   timeline timer before sleep and refreshes an expired marker before
   restarting it, but the service and Snapper config are not installed on the
   host. Verify post-resume ordering and prove no catch-up invocation starts a
   fresh scan. Restore the original
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
