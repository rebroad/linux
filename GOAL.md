# Goal: fix Snapper-triggered Btrfs qgroup inconsistency

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
   branch as the development base. The durable host fix must install the
   modified Snapper built from that latest upstream baseline, replacing the
   currently installed Snapper package. The distribution-installed Snapper is
   only the current-state baseline for diagnosis and migration; it is not the
   intended or acceptable final host runtime. The host must run our locally
   built and maintained Snapper based on the latest upstream source. The host
   currently runs kernel
   release `7.1.13+deb13-amd64`; use that exact release for all remaining
   kernel investigation and acceptance testing. The stock-module and
   candidate-module QEMU comparisons use that release. Testing other kernel
   versions is outside this goal. The latest-line Snapper changes stop clean
   quota queries from starting unnecessary rescans. The query-path
   follow-up is committed and pushed (`9d9c8820` and `46fcfbea`) and QEMU-tested
   on the recorded Snapper baselines. No qgroup counter corruption has been demonstrated;
   a full rescan agrees with incrementally maintained counters. On the stock
   kernel, the reproduced snapshot-only qgroup layout takes the conservative
   rescan fallback; the exact two-member shared-parent optimization avoids those
   snapshot-triggered scans while preserving the existing same-parent
   exclusivity guard and passing quota cleanup. The kernel change is an
   optimization for this proven topology, not a repair for demonstrated bad
   accounting. The shared parent is created only by the candidate Snapper
   `prepareQGroupTracking()` change. A fresh stock-module run of current PR
   #1203 showed the tracking setup and first hourly snapshot still mark qgroups
   inconsistent. Snapper's limiter then enforces the scan ceiling, returns
   last-known values as stale, and defers quota cleanup; this contains the
   repeated scans but does not keep qgroups consistent. The same latest-line
   Snapper workload with the candidate kernel module completed three hourly
   rounds without inconsistency and passed quota cleanup. The Snapper-only PR
   therefore does not meet the consistency requirement; continue with the
   paired kernel change unless a Snapper-only hierarchy can be shown to keep
   the counters accurate while preserving snapshot-only quota scope. The RFC,
   differential results, correction, and
   formal kernel patch have been sent to `linux-btrfs`. Maintainer feedback
   arrived on 2026-10-18: clarify the qgroup layouts and opt-in policy, avoid
   unsupported tracker terminology, disclose AI assistance, and test the
   different-parent fallback. The fallback passes QEMU checks on the exact
   in-use kernel. A concise corrected patch and response are prepared locally;
   review them before any further mailing-list follow-up. The
   revised kernel patch is regenerated against current Btrfs `for-next`
   (`2789b2c034d7c0c8687355921a38c5ac41a565fa`) and applies cleanly there.
   Kernel build and runtime acceptance remain on the exact in-use
   `7.1.13+deb13-amd64` release. The Snapper companion is on the fork's
   `codex/upstream-qgroup-tracking-clean-pr3` branch as clean-history upstream
   PR [#1203](https://github.com/openSUSE/snapper/pull/1203), replacing closed
   drafts #1201 and #1202. PR #1203 is ready for review; at the latest check
   (2026-10-18), all CI checks passed and no review or maintainer feedback was
   recorded. Keep it paired with the kernel change through review. Add a
   documented `QGROUP_RESCAN_WINDOW=HH:MM-HH:MM` setting;
   configure every host Snapper config sharing Kingston to `05:00-21:00`
   local time, while retaining the per-filesystem rolling 24-hour cap.
2. **Deploy the locally built Snapper.** Replace the host's currently
   installed Snapper with our locally built Snapper produced from the latest
   upstream baseline, including the reviewed qgroup fix. Keep deployment
   gated until the Snapper change and, if required, its
   paired kernel change have review and the full accounting/quota checks pass.
   Build and maintain a repeatable local Debian package from the Snapper
   checkout based on latest upstream. The repository's Debian packaging
   cannot be used unchanged: it disables Btrfs quota support, and its install
   manifests do not match the current build's file paths. Build the package
   with quota enabled, verify that feature in the resulting binary, and test
   it through an APT simulation. Keep the build recipe and its packaging
   changes in the Snapper source checkout, and put generated package and
   build files in its sibling build tree. The first uninstalled local package
   build and its remaining recipe work are recorded in `GOAL-done.md`.
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
4. **Finish accounting and recovery coverage.** QEMU now covers compressed
   and incompressible data, externally shared snapshots, partial overwrites,
   truncation, create/delete churn, timeline cleanup, concurrent tracker
   allocation, orphan and one-sided tracker recovery, and interrupted scans
   with complete trackers. The latest-upstream Snapper build is the primary
   acceptance target. Results from older Snapper builds remain historical
   baseline evidence only.
   The latest-line build must repair an interrupted config-only tracker,
   complete successive hourly snapshots and timeline cleanup, preserve
   counters across a full rescan, and pass quota-limit cleanup with the
   `7.1.13+deb13-amd64` candidate module. On the current PR #1203 head, the
   hourly root/home workload, used-space listing, quota-limit cleanup, and
   post-cleanup counter comparison passed with that module; the exact fixture
   and results are recorded in `GOAL-done.md`. Extend coverage only for
   additional Btrfs layouts needed to support the paired patch, using the
   same kernel release.
5. **Investigate reported stalls independently.** A bounded read-error trace
   captured failed metadata reads from a detached-USB Btrfs instance during
   directory enumeration by a long-lived Codex app-server thread. A lingering
   working-directory reference pins that old filesystem despite no mountinfo
   entry for it; querying its scrub state returns `EIO`, and no qgroup rescan
   was active there. The app-server and its code-mode child still have cwd
   references on the detached filesystem; the orphaned app-server is adopted
   by PID 1, while both processes remain in the active X11 `session-5.scope`.
   This explains how the cwd references can outlive the original launcher.
   Determine whether there is a safe way to release them without ending the
   active user session, and whether the detached-device read errors explain
   any reported application stalls. Keep this investigation separate from the
   Snapper qgroup trigger; neither trace timing nor an inconsistency warning
   proves the rescan caused the system-wide stall.
6. **Preserve temporary host containment.** Confirm the timeline wrapper's
   explicit `btrfs quota rescan` commands remain disabled while snapshots
   continue. This wrapper is one rescan initiator; Snapper's quota-query code
   can independently start a rescan when it finds inconsistent qgroups.
   Btrfs snapshot inheritance can mark qgroups inconsistent, but does not
   itself start a rescan. Keep those state changes distinct when tracing
   future scans. Restore the original `SPACE_LIMIT="0.5"` settings only after
   both changes are deliberately deployed and their initialization scan,
   quota accounting, and cleanup behavior are verified.

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
and rescan rate. Any remaining limitation or unverified stall hypothesis is
documented explicitly.

## Completed evidence

See [`GOAL-done.md`](GOAL-done.md) for completed investigation, reproduction
results, kernel baseline, and temporary containment details. That file is
historical reference; the items above are the active work.
