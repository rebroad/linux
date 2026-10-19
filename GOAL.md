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
   controlled QEMU matrix and source trace identify the stock-kernel fallback
   for the tested hierarchy; full evidence and limits are in `GOAL-done.md`.
   The shared-parent fast path remains a provisional optimization, not a claim
   of a general Btrfs correctness bug.

   Remaining: after activating the installed signed module, verify sustained
   four-root snapshot and cleanup behavior on the host. Reconcile p8 qgroup
   values against an independent full-accounting report while filesystem
   updates are quiesced. Retained logs do not establish the first historical
   inconsistency; do not infer its cause from the oldest diagnostic scan.

2. **Deploy and maintain our latest-upstream Snapper build — 80% done.** The
   host runs our locally built Snapper 0.13.2 from commit `7d4db17085ce`, based
   on the current official upstream tip; the checkout and package evidence are
   in `GOAL-done.md`. Keep this locally built runtime as the target.

   Verify that package reinstall/upgrade preserves Btrfs quota support, daemon
   behavior, the four configs and their rescan policies. Complete host stale-
   quota, cleanup, rollback, and APT-upgrade checks. During investigation keep
   the timeline wrapper's explicit rescan block disabled and `SPACE_LIMIT="1.0"`
   so quota-based cleanup remains disabled. Recheck the shared window and hold
   path after package configuration migrations. The build recipe is
   `scripts/build-local-debian-package.sh` on the Snapper fork's
   `codex/local-debian-package-builder` branch; generated files belong in its
   sibling build tree. This packaging work is separate from closed PR #1203.

3. **Make the fix durable across APT upgrades — 80% done.** Prefer a
   Snapper-only fix if it fully corrects the cause and meets the rescan limit;
   retain the kernel companion only if the evidence requires it. Keep any
   required Snapper and Btrfs changes under APT-managed installation. The
   signed DKMS package currently has exact sources for installed 7.2.6 and 7.2.9, and
   modules selected in both initramfs images. Before a kernel can be selected
   for boot, every installed release—including rollback kernels and the next
   APT candidate—must have a matching module built, signed, selected by
   `modprobe`, and present in its initramfs. Add and validate exact source
   support before each later kernel release.

   Remaining: after an approved reboot, verify the loaded 7.2.9 module and live
   accounting, then explicitly boot 7.2.6 and verify its replacement module
   and rollback path. Exercise supported and unsupported kernel transactions
   end to end: a failed or unmapped build must neither leave package
   configuration broken nor permit silent boot of stock Btrfs. Keep unrelated
   security updates available and maintain the visible APT kernel allowlist
   before each candidate. Verify the locally built Snapper fix also survives
   package reinstall/upgrade. The current APT policy, DKMS design, exact
   release tests, and known unsupported-release failure mode are documented in
   `GOAL-done.md`.

4. **Finish accounting and recovery coverage — 95% done.** Preserve four
   separately queryable snapshot collectives and verify their exclusive-space
   values against a full rescan. Exact-kernel QEMU snapshot, overflow, cleanup,
   stale-value, hold/window, Secure Boot, and recovery tests are documented in
   `GOAL-done.md`; run further QEMU coverage only for an uncovered Btrfs layout
   required by the patch.

   Remaining: complete the p8 independent accounting comparison, live cleanup
   and rollback checks under the paired host runtime, and verify the counters
   remain accurate through repeated snapshots and deletion. Restore the normal
   quota-cleanup limit (`SPACE_LIMIT="0.5"`) only after accounting and cleanup
   pass.

5. **Preserve temporary host containment, including after resume — 94% done.**
   The installed hourly wrapper has duplicate-target suppression; explicit
   `btrfs quota rescan` commands remain disabled. The enabled sleep-target
   service and system-sleep hook stop the timeline timer before sleep and
   refresh the shared hold before restarting it. The timer catch-up and hold
   configuration are separate controls; implementation and live audits are
   in `GOAL-done.md`.

   Remaining: verify on a real suspend/resume that timer catch-up cannot start
   a scan through either the wrapper or Snapper's internal quota path. Confirm
   the hold prevents new scans until its configured deadline, then allows a
   deferred scan when policy permits. Keep the original cleanup limits disabled
   until accounting, initialization scans, and cleanup behavior are verified.

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
