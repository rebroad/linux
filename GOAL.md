# Goal: diagnose and fix Btrfs qgroup inconsistency and system stalls

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
the existing quick-inherit path does not handle the source and snapshot-only
QGROUP as siblings under their two-member tracker, so Btrfs takes its
conservative full-rescan fallback and marks accounting inconsistent. Snapper's
next quota-tracked operation sees that flag and may start a full scan. Distinct
root/home snapshot QGROUPs still encounter this fallback, so sharing their ID
is not the cause. Repeated stock-kernel QEMU cycles showed the newest snapshot's
counters short until a full scan; the scan restored the values that the tested
fast path maintained directly. This is evidence of the cost of the supported
accounting topology, not a general Btrfs accounting-corruption bug. The
Snapper-only alternatives were also tested on the exact 7.2.6 stock module.
Untracked snapshots still marked qgroups inconsistent and did not contribute
to the snapshot collectives; post-creation assignment left stale counters until
a full scan. Together with the four-group QEMU matrix, this establishes that
the bounded kernel fast path is currently required to avoid recurring scans
while preserving four accurate, separate snapshot collectives through
Snapper's existing QGROUP interface. This is a hierarchy-specific accounting
limitation, not a general Btrfs corruption bug. QEMU workload, source, and
scan-attribution evidence is in `GOAL-done.md`.

The host now boots `7.2.9+deb13-amd64` through the explicit stock-Btrfs GRUB
entry. The loaded Btrfs build ID matches the Debian stock module embedded in
that entry's initramfs; the installed DKMS module is present on disk but is not
loaded. The host became responsive after rebooting into this stock setup. This
supports investigating our modified Btrfs runtime as a likely contributor, but
does not isolate the cause because both the kernel release and module changed
and the reboot cleared prior runtime state. The earlier 7.2.6 runtime and
snapshot-cycle observations are historical, not the current host state. Exact
module and boot evidence is in `GOAL-done.md`.

The user subsequently reported another roughly eight-minute system hang while
this stock 7.2.9 setup was running. Psensor's saved sensor history has a
141-second gap across all six local sensors from 12:00:00 to 12:02:21. The
12:00 Snapper timeline service overlapped that gap and ran for 3 minutes 42
seconds while consuming only 5.2 seconds of CPU. Btrfs logged a qgroup scan
pause at 12:00:00, another at 12:03:33, and an inconsistency warning at
12:03:41. This is strong temporal evidence of another filesystem stall during
the snapshot cycle on the stock module, but no blocked-task stack was captured
and the exact user-reported interval may differ. It shows our modified module
is not necessary for every stall. The user also observed Psensor itself become
unresponsive during the event. SysRq `w` was disabled by the host's prior mask;
it is now enabled at runtime while preserving the other mask bits. After any
reboot, re-enable it before diagnosis. During the next occurrence, capture the
SysRq `w` dump, relevant `/proc/*/stack` data, and transaction and rescan state.
Full event details are in `GOAL-done.md`.

The source branch is now based on upstream `v7.2.9`. The external build tree
has been reconfigured from `/boot/config-7.2.9+deb13-amd64`, and Kbuild reports
the exact running release `7.2.9+deb13-amd64`. Any kernel or module comparison
must use this baseline and distinguish the stock module from our modified
module. Independent quiescent counter validation and the onset of the
historical Kingston inconsistency remain open. See `GOAL-done.md` for the
earlier chronology and current boot evidence.
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

**First priority: diagnose and fix the Btrfs issues, including qgroup
inconsistency and system stalls.** Determine whether our Btrfs changes caused
or contributed to each issue; if not, identify the responsible kernel path or
dependency and fix the issue there. For the
stalls, investigate transaction waits, blocked writeback workers, and long
commits with live kernel stacks and commit-progress evidence. The 2026-10-20
captures found qgroup backref metadata reads during snapshot deletion and
unrelated tasks waiting at transaction start. A host CPU profile now confirms
the cleaner is spending substantial time in the unchanged qgroup subtree and
backref walk. A matched four-group QEMU workload on exact 7.2.9, with 32,768
metadata files per source and 32 Snapper snapshots per config, reproduced the
same stock/fallback inconsistency and automatic-rescan behavior. With the
custom fast path enabled, snapshots, timeline cleanup, and deletion stayed
consistent without automatic rescans; however, deleting one root snapshot
took 114 seconds versus 9 seconds with stock and 7 seconds with the custom
fallback. Sampled maximum commit times were also higher with the fast path
(2.8/3.7 seconds versus 0.5/0.6 seconds stock and 0.9/0.8 seconds fallback).
This strengthens the evidence that keeping full qgroup accounting active can
make snapshot deletion and commits much more expensive, even though the
fast-path code does not change the backref walker itself. The earlier matched
7.2.6 function-graph comparison traced the custom path through
`btrfs_qgroup_trace_subtree()` and `btrfs_find_all_roots()`; `NO_ACCOUNTING`
short-circuits those backref searches after inconsistency. These guest timings
use TCG and small synthetic filesystems, so they do not establish host-scale
latency or prove that our patch caused every stall. The 30.986-second host
commit remains unreproduced, and its external transaction writer is unknown.
An earlier stock 7.2.6 run also exposed a separate
`qgroup info item update error -2` during final rescans; source control flow
matches the branch's qgroup-teardown fix.
The later-kernel review found no change to the captured backref walk or
external-writer wait through upstream v7.3; v7.2.11 has a separate qgroup fix
for snapshot accounting during balance relocation. A 30.986-second host
commit was profiled in `btrfs_qgroup_account_extents()` and its expensive
backref walk. Our fast path keeps qgroups consistent, while the fallback's
`NO_ACCOUNTING` flag skips those walks, so our change is a likely indirect
contributor to the longer full-accounting commits. The walker itself is
unchanged. Replace or optimize the fast path so accurate qgroup counters do not
require expensive per-extent backref walks on the commit path. The exact 7.2.9
comparison is now complete; the custom module was built in a fresh external
output directory because the older output directory contained stale source
copies that had omitted the new sysfs toggles. Do not use that stale module
artifact as evidence. Establish how the target accounting workload scales
against realistic tree size and storage, and identify the external writer that
delayed the host transaction. Do not attribute the entire stall to our changes
until that writer and the host-scale path are captured. Full profile, matched
7.2.6 and 7.2.9 QEMU results, and later-version review are in `GOAL-done.md`.
Do not install the modified module on the host until the fast-path deletion
cost has been reduced or justified and its system-stall behavior is understood.
The reported stock-kernel hang makes live capture of blocked task stacks and
transaction progress the next diagnostic priority; do not attribute all
freezes to our patch.
Complete this investigation before resuming lower-priority deployment
validation. Detailed captures, source comparisons, and remaining diagnostic
gaps are in `GOAL-done.md`.

1. **Finish root-cause and live-accounting validation — 75% done.** The
   controlled QEMU matrix now includes exact 7.2.9 stock, modified-fast-path,
   and modified-fallback runs. The fast path avoids the tested automatic
   rescans but has a serious snapshot-deletion cost that must be investigated
   before deployment. Full evidence and limits are in `GOAL-done.md`. The
   shared-parent fast path remains provisional, not a claim of a general
   Btrfs correctness bug.

   Remaining: investigate the large root-snapshot deletion cost seen with the
   exact 7.2.9 fast path, optimize accurate accounting without a full rescan,
   and validate against larger and host-representative tree size and storage.
   Then capture the external writer and blocked-task stacks during a live stall.
   After review and safe activation of a signed module, verify sustained
   four-root snapshot and cleanup behavior on the host. Reconcile p8 qgroup
   values against an independent full-accounting report while filesystem
   updates are quiesced. Retained logs do not establish the first historical
   inconsistency; do not infer its cause from the oldest diagnostic scan.

2. **Deploy and maintain our latest-upstream Snapper build — 90% done.** The
   host runs our locally built Snapper 0.13.2 from commit `7d4db17085ce`, based
   on the current official upstream tip; the checkout and package evidence are
   in `GOAL-done.md`. APT upgraded both packages from the previous local build,
   and a later exact-version reinstall preserved the four configs and timeline
   service wiring. Snapper's D-Bus listing and read-only snapshot queries
   worked afterward. Keep this locally built runtime as the target.

   The host APT pin now rejects Debian-origin `snapper` and `libsnapper`
   packages so a distro update cannot silently replace this local runtime;
   its policy and full-upgrade simulation are recorded in `GOAL-done.md`.
   Remaining: complete host stale-quota, cleanup, and package rollback/runtime
   checks, and verify an upgrade to a subsequent local build. During
   investigation keep the timeline wrapper's explicit rescan block disabled
   and `SPACE_LIMIT="1.0"` so quota-aware cleanup remains disabled. This does
   not disable the current free-space or snapshot-count cleanup limits;
   validate their behavior separately. Recheck the shared window and hold
   path after future package configuration migrations. The build recipe is
   `scripts/build-local-debian-package.sh` on the Snapper fork's
   `codex/local-debian-package-builder` branch; generated files belong in its
   sibling build tree. This packaging work is separate from closed PR #1203.

3. **Make the fix durable across APT upgrades — 82% done.** Snapper-only
   alternatives tested on the exact 7.2.6 stock module do not preserve fresh
   counters with the required four snapshot-only QGROUPs; the bounded
   shared-parent kernel fast path avoids the fallback on that hierarchy. Keep
   the tested fast path and qgroup-teardown fix under APT-managed installation.
   The signed DKMS package currently has exact sources for installed 7.2.6 and
   7.2.9, and
   modules selected in both initramfs images. Before a kernel can be selected
   for boot, every installed release—including rollback kernels and the next
   APT candidate—must have a matching module built, signed, selected by
   `modprobe`, and present in its initramfs. Add and validate exact source
   support before each later kernel release.

   Current Snapper with both exact-release modules passed Secure Boot QEMU
   workloads. The host has since booted 7.2.9 with the stock Btrfs module via
   the explicit stock initramfs. Remaining: build and validate the modified
   7.2.9 module against the exact running configuration, then compare it with
   stock in QEMU before any host installation. Exercise supported and unsupported
   kernel transactions end to end: a failed or unmapped build must neither
   leave package configuration broken nor permit silent boot of stock Btrfs.
   The existing synthetic 7.3.0 APT fixture has no maintainer scripts, so it
   verifies candidate blocking but not Debian's DKMS-hook or dpkg failure
   behavior. Isolated tests found that a failed DKMS build in either Debian's
   kernel-image hook or our DKMS package's own `postinst` leaves a package
   half-configured. The kernel-image case also moves `/vmlinuz` before stopping
   later hooks. See `GOAL-done.md` for evidence. The source-controlled
   `scripts/local-btrfs-qgroup-dkms-preflight` builds and verifies modules in
   an alternate DKMS tree and emits a separate signed archive per release. It
   also has a preparation mode that stages an uncompressed signed build in an
   already registered DKMS tree and cleans newly created release state if a
   build fails. `scripts/local-btrfs-qgroup-apt-preflight` and its APT config
   snippet now parse protocol v3, identify exact incoming kernel releases,
   extract matching Debian headers and `linux-kbuild` packages, and invoke that
   preparation mode before dpkg. Real 7.2.9 headers and kbuild files produced
   a signed module in a disposable DKMS tree; a later DKMS install consumed it
   without rebuilding. Missing headers and non-kernel transactions were also
   checked. Full evidence and test limits are in `GOAL-done.md`.

   This is source-controlled but not yet installed or exercised as a complete
   APT kernel transaction. The local APT 3.0.3 manual identifies
   `DPkg::Pre-Install-Pkgs` as a hook that runs before dpkg and can receive the
   downloaded package files. A disposable transaction verified that a failing
   hook aborts before dpkg and that a successful hook runs before package
   `postinst`. In a separate DKMS-tree test, `autoinstall` installed a staged
   built module without compiling after its `.ko.xz` had been decompressed;
   it failed while only the compressed file was present. Remaining: run the
   source-controlled hook from a real disposable APT kernel transaction,
   verify Debian's kernel postinst installs the prebuilt module without
   rebuilding, and make changed DKMS source packages work safely when APT
   proposes them with a kernel. Install and enable the hook only after these
   checks. Gate boot/initramfs state on the verified result and preserve a
   usable rollback. The actual
   APT rejection check left package state and boot selection unchanged. Keep
   unrelated updates available and maintain the
   visible APT kernel allowlist before each candidate. Debian's
   tracker marks all 12 CVEs in DSA-6393 fixed by upstream
   7.2.9 or earlier. This supports keeping the selected 7.2.9 backport for
   those fixes. The backport's complete `debian/patches` tree was compared
   byte-for-byte with Debian's `7.2.9-1` unstable source and is identical.
   Recheck each later Debian kernel security advisory against the selected backports
   candidate; if a security fix is absent, prepare and test a matching signed
   module before allowing another kernel through the kernel guard. Verify the
   locally built Snapper fix also survives package reinstall/upgrade. The APT
   policy, DKMS design, exact-release tests, security comparison, and
   unsupported-release failure mode are documented in `GOAL-done.md`.

4. **Finish accounting and recovery coverage — 95% done.** Preserve four
   separately queryable snapshot collectives and verify their exclusive-space
   values against a full rescan. Exact-kernel QEMU snapshot, overflow, cleanup,
   stale-value, hold/window, Secure Boot, and recovery tests are documented in
   `GOAL-done.md`; run further QEMU coverage only for an uncovered Btrfs layout
   required by the patch.

   The retained p8 root snapshot 2176 is now included in `1/100` and a full
   rescan has completed. Remaining: complete the p8 independent accounting
   comparison, live cleanup and rollback checks under the paired host runtime,
   and verify the counters
   remain accurate through repeated snapshots and deletion. The installed
   21:41 helper now discovers mounted alternate-root configs, applies their
   enabled built-in cleanup algorithms, and skips duplicate p8 aliases by
   Btrfs root ID. Its dry-run includes Kingston root and home. The exact-kernel
   four-config QEMU run exercises alternate-root timeline cleanup. The
   exponential-retention tool remains unscheduled; its preview proposes
   deleting 60 Kingston snapshots, so keep it out of the service. Verify the
   first live Kingston cleanup and post-cleanup counters before claiming
   four-root cleanup coverage. Restore the normal quota-cleanup limit
   (`SPACE_LIMIT="0.5"`) only after accounting and cleanup pass.

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

The current locally built Snapper package (`7d4db17085ce`) has passed exact
7.2.6 QEMU stale-quota and hold tests using the exact installed DKMS module.
The direct-kernel run verified stale-value display, deferred cleanup, and
timeline-child snapshots while the hold kept the rescan idle. Separate OVMF
Secure Boot runs for exact 7.2.6 and 7.2.9 modules enforced signatures,
rejected unsigned Btrfs modules, and passed the same stale-quota and hold
checks. These QEMU runs do not replace host suspend/resume or live accounting
checks; see `GOAL-done.md` for evidence.

The bounded kernel fast path supplies accurate counters without a full scan
for the tested four-collective hierarchy; the stock fallback leaves the newest
snapshot counters stale until a full scan. Exact-7.2.6 QEMU alternatives using
untracked snapshots or post-creation qgroup assignment also fail the accounting
requirement. The kernel/module fix must be automatically reapplied and active
after every kernel APT upgrade/reinstall without blocking security updates; the
installed Snapper fix must also survive its APT upgrade/reinstall. Revisit the
kernel requirement only if a tested Snapper-only hierarchy preserves all four
snapshot-only totals, stale-value semantics, and cleanup behavior without
repeated scans. Verify the running kernel, loaded module, Snapper package, and
rescan rate.

## Completed evidence

See [`GOAL-done.md`](GOAL-done.md) for completed investigation, reproduction
results, kernel baseline, and temporary containment details. That file is
historical reference; the items above are the active work.
