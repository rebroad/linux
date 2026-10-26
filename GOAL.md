# Goal: establish whether accurate qgroup stats and low-latency snapshots can coexist

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
Snapper or a modified Btrfs module if one is selected. Local use instead
requires technical review, the exact-kernel acceptance workload, a valid
Secure Boot signature from an enrolled key, and a tested rollback and
kernel-upgrade path.
For any future PR, follow the target repository's template and keep the text to
the current implementation, validation, and limitations. Include historical
material only when the repository asks for it; make commit references clickable
and avoid duplicate URLs. See `GOAL-done.md` for the closed PR history.

The reproducible stock-kernel cycle is identified for the tested hierarchy:
the existing quick-inherit path does not handle the source and snapshot-only
QGROUP as siblings under their two-member tracker, so Btrfs takes its
conservative full-rescan fallback and marks accounting inconsistent. This may
be an intentional trade-off: Btrfs avoids expensive incremental accounting and
rebuilds the counters with a scan. The tests establish this fallback on our
hierarchy, but do not establish whether its scope is intended design or a bug
or overly conservative limitation. Do not assume that the inconsistent flag
means the counters are corrupted or that eliminating the fallback is
necessarily the right fix. Snapper's next quota-tracked operation sees that
flag and may start a full scan. Distinct root/home snapshot QGROUPs still
encounter this fallback, so sharing their ID is not the cause. Repeated
stock-kernel QEMU cycles showed the newest snapshot's counters short until a
full scan; the scan restored the values that the tested fast path maintained
directly. The Snapper-only alternatives were also tested on the exact 7.2.6
stock module.
Untracked snapshots still marked qgroups inconsistent and did not contribute
to the snapshot collectives; post-creation assignment left stale counters until
a full scan. The bounded kernel fast path is the only tested approach so far
that avoids rescans while maintaining four accurate, separate snapshot
collectives through Snapper's existing QGROUP interface. The staged exact-stock
7.2.9 reproduction now shows that Snapper already supplies the inheritance
target, yet this required source/tracker/snapshot-parent topology still takes
the stock fallback. Avoiding that fallback therefore requires either a
kernel-side accounting change or a different qgroup topology. Making live and
snapshot groups share one parent would mix live usage into the snapshot-only
collective, so it does not satisfy the stated accounting requirement. The
kernel change remains provisional until its host-scale latency and stall
behavior are validated.
QEMU workload, source, and scan-attribution evidence is in `GOAL-done.md`.

The host is currently booted with Debian `7.2.9+deb13-amd64` and the stock
Btrfs module, using the explicit stock initramfs entry. This was verified on
2026-10-26 by matching the live module build ID to the Btrfs module in both the
stock initramfs and the exact installed Debian `linux-modules` package; the
DKMS module has a different build ID. The stock GRUB entry worked, so no GRUB
change is needed. Some Btrfs qgroup symbols initially mistaken for custom are
present in upstream `v7.2.9`. A high-load event during this stock boot captured
the cleaner in qgroup subtree/backref reads and the transaction thread in
delayed-reference backref reads; no qgroup rescan was active. This proves our
custom module is not required to reproduce that particular stall pattern, but
does not determine whether earlier stalls were worsened by it. The exact
module and stack evidence is in `GOAL-done.md`.
The redundant `snapper-boot.timer` has since been disabled and is inactive;
the hourly `snapper-timeline.timer` remains enabled and active. The next clean
host observation must therefore begin after a completed rescan and use the
hourly path only.

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

A further stock-kernel event on 2026-10-26 overlapped the 19:00 Snapper timeline
run. The p8 qgroup rescan paused twice and was no longer running by 19:06;
accounting remained inconsistent. A live SysRq-w capture then found the stock
`btrfs-cleaner` blocked by block-layer writeback throttling while writing
transaction metadata, and `fstrim` blocked waiting for a synchronous discard on
the same p8 NVMe filesystem. I/O PSI `full` was about 19% over 10 seconds and
`fstrim` had been active for 19 minutes. It completed at 19:08, reporting
214.6 GiB trimmed on p8 and 508 GiB on Kingston. A later cleaner stack was in
`btrfs_qgroup_trace_subtree()` waiting for an extent-buffer read; by 19:09 it
was no longer blocked and I/O PSI `full` had fallen to 6.35%. These changing
wait sites and the pressure drop coincided with trim completion, but do not
prove trim caused the full stall. The rescan is not the active blocker in this
capture. Investigate discard/device latency and qgroup subtree read progress
before running another production rescan or testing the modified module. Also
determine which stock-kernel stop condition paused the rescan; the log message
does not identify it. Details are in `GOAL-done.md`.

The source branch is now based on upstream `v7.2.9`. The external build tree
has been reconfigured from `/boot/config-7.2.9+deb13-amd64`, and Kbuild reports
the exact running release `7.2.9+deb13-amd64`. Any kernel or module comparison
must use this baseline and distinguish the stock module from our modified
module. Independent quiescent counter validation and the onset of the
historical Kingston inconsistency remain open. See `GOAL-done.md` for the
earlier chronology and current boot evidence.
Once the cause and acceptable behavior are established, leave the host with a
persistent configuration or implementation that survives normal package
upgrades.
The required accounting has four independent snapshot collectives: p8-root,
p8-home, Kingston-root, and Kingston-home. Each Snapper config must keep its
own snapshot QGROUP so its exclusive-space total remains separately visible;
root and home do not need to share a snapshot QGROUP. Preserve accurate
accounting and expected cleanup behavior. Establish whether the full rescan is
an intended fallback or avoidable defect before deciding to eliminate it.
Never hide the inconsistent state or weaken accounting. Keep both rescan gates
configurable in Snapper: the optional hold-file gate and the rolling 24-hour
per-filesystem limit. Disable
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

The host's 20:00-versus-21:00 behavior is now explained by Snapper's
configured rescan window rather than by every snapshot intrinsically starting a
scan: `05:00-21:00` is local time with an exclusive end. A snapshot inside the
window may issue and wait for a rescan when qgroups are inconsistent; a
snapshot at or after 21:00 defers it. Preserve this distinction in further
latency diagnosis.

## Next steps

**First priority: reach a clear, evidence-backed verdict on whether our
required qgroup accuracy and low-latency snapshot workload can coexist on the
supported Btrfs stack and our four-group layout.** The goal is not merely to
explore possible designs: it is to either demonstrate a design that satisfies
both requirements in representative testing, or establish that they cannot
both be satisfied within the defined kernel, layout, workload, and latency
limits and document the unavoidable trade-off. Do not claim universal
impossibility for all Btrfs configurations; scope the verdict to those tested
conditions and state any remaining uncertainty. Do not assume the inconsistency
state is a bug or that
removing it is inherently better. Determine whether our Btrfs changes caused
or contributed to each observed stall; if not, identify the responsible kernel
path or dependency. For qgroup inconsistency, establish whether the conservative
fallback is expected design, a performance/accuracy trade-off, or a defect.
Test whether snapshot creation can preserve accurate counters without costly
accounting or repeated rescans, while allowing infrequent deletion to mark
values stale and recover later. If this works, make that policy optional and
document the stale interval and recovery behavior. If it does not, state which
requirements cannot be met together and quantify the least-cost trade-off; only
then decide whether a confirmed defect warrants a fix. For stalls, investigate
transaction waits, blocked writeback workers, discard latency, and long commits
with live kernel stacks and commit-progress evidence. The 2026-10-26 SysRq-w
capture on stock 7.2.9 found the cleaner in `wbt_wait()` while writing
transaction metadata, with `fstrim` waiting for NVMe discard; no rescan was
running. The stock worker reports “paused” for filesystem closing, remounting,
quota disable, or its cancel flag; current logs do not identify which condition
occurred. Establish the stop condition, whether storage requests make progress,
and whether weekly trim or queued snapshot cleanup contributes before another
production rescan or modified-module host trial. The 2026-10-20
captures found qgroup backref metadata reads during snapshot deletion and
unrelated tasks waiting at transaction start. A host CPU profile now confirms
the cleaner is spending substantial time in the unchanged qgroup subtree and
backref walk. A matched four-group QEMU workload on exact 7.2.9, with 32,768
metadata files per source and 32 Snapper snapshots per config, reproduced the
same stock/fallback inconsistency and automatic-rescan behavior. With the
custom fast path enabled, snapshots, timeline cleanup, and deletion stayed
consistent without automatic rescans.
The stock host's 12:50 blocked-task dump provides a separate result: `find`
was waiting in `read_extent_buffer_pages()`/`bit_wait_io` while opening a
Btrfs path, with no task in qgroup accounting or transaction-wait code. That
event is evidence of a metadata-read I/O wait, not evidence that qgroup
accounting caused every host stall. Full stack details are in
`GOAL-done.md`. The initial 114-second
`snapper delete --sync` measurement followed timeline cleanup that had queued
124 asynchronous snapshot drops, so it did not measure one snapshot in
isolation. In a follow-up with the same exact kernel, module, and workload,
explicitly draining that queue took 128 seconds; deleting the remaining root
snapshot afterward took 3 seconds. Matched drain-separated runs took 16
seconds with stock and 9 seconds with custom fallback accounting; their final
root deletions took 2 and 1 seconds, respectively. Together with the trace
capturing queued drop work, these results strongly indicate that the original
114-second phase was dominated by the cleanup backlog, not the final snapshot
alone. A function-graph trace during the undrained cleanup recorded
115 `btrfs_qgroup_trace_subtree()` return entries, with 105 of 106 parseable
durations over one second and a maximum of 5.84 seconds. It also recorded
thousands of qgroup extent/backref searches. This identifies qgroup subtree
and backref accounting during snapshot drops as the work to optimize, but does
not yet isolate its per-snapshot cost. Source control flow shows
`btrfs_qgroup_trace_subtree()` walking the dropped tree, then tracing newly
encountered extents through `btrfs_qgroup_trace_extent_post()` and
`btrfs_find_all_roots()`; the dirty-extent xarray deduplicates bytenrs within
a transaction. Sampled maximum commit times were also
higher with the fast path (2.8/3.7 seconds versus 0.5/0.6 seconds stock and
0.9/0.8 seconds fallback); the cause of those maxima remains to be isolated.
The fast-path code does not change the backref walker, but keeps full
accounting active during these drops. The earlier matched 7.2.6 function-graph
comparison also traced the custom path through
`btrfs_qgroup_trace_subtree()` and `btrfs_find_all_roots()`;
`NO_ACCOUNTING` short-circuits those searches after inconsistency. These guest
timings use TCG and small synthetic filesystems, so they do not establish
host-scale latency or prove that our patch caused every stall. The
30.986-second host commit remains unreproduced, and its external transaction
writer is unknown.
An earlier stock 7.2.6 run also exposed a separate
`qgroup info item update error -2` during final rescans; source control flow
matches the branch's qgroup-teardown fix.

A focused same-kernel control compared 128 four-group snapshots with the
snapshot fast path enabled and disabled. With it enabled, both qgroup tables
were byte-for-byte unchanged after full rescans; with it disabled, both tables
differed and the filesystem inconsistency flags were set. A test-only
`drop_subtree_threshold=0` made deletion mark both filesystems stale without
starting another scan. The TCG guest's full snapshot-cycle median was 1.31
seconds with accurate accounting versus 0.55 seconds with the fast path
disabled. A later 131,072-file workload showed that this test-only threshold
should not be confused with the default policy: `drop_subtree_threshold=3`
left both filesystems consistent through Snapper cleanup and deletion when
whole source-tree roots were level 2 or 3. Setting the threshold to 2 in the
same level-3 workload preserved accurate counters across snapshots, then made
both filesystems explicitly stale when the final retained snapshot was deleted;
no additional scan started. Snapshot-cycle medians were 585 ms at threshold 3
and 580 ms at threshold 2. TCG timings do not establish host-scale latency.

A matched 131,072-file run with the exact Debian stock 7.2.9 module had a
535 ms median snapshot cycle, compared with 580 ms for the modified module with
accurate counters and threshold 2 (12 cycles each). In the stock run both
qgroup tables differed from the later full-rescan tables; with the modified
fast path both matched. This is encouraging evidence that the requirements can
coexist in this controlled workload with about 45 ms additional median cycle
time, but the sample is small, QEMU uses TCG, and it does not prove host-scale
latency or rule out the separately observed system stalls.

The host-count workload was then scaled to 79 p8-root snapshots, 28 p8-home
snapshots, 82 Kingston-root snapshots, and 28 Kingston-home snapshots, matching
the live host counts observed before the run. The modified fast path with a
test-only deletion threshold of 2 kept all 217 snapshot cycles free of
inconsistency and both complete qgroup tables matched the full-rescan result
(the scans took 90.28 s and 108.83 s). Cleanup completed, but the first final
snapshot deletion did not complete within the one-hour TCG timeout. During the
stalled deletion, sampled transaction commits reached 110.16 s maximum and
43.79 s for the latest completed commit. This is a failed scalability result
for the tested design: accurate snapshot accounting and a deletion-only stale
policy are feasible for small populations, but that policy currently does not
meet the low-latency requirement at the host's snapshot population. It does
not prove that every possible accounting design is impossible; it identifies
the deletion/backref path as the next optimization target.

As a narrower control, the same host snapshot counts were tested with 32,768
metadata files per source and a test-only deletion threshold of 1. All 217
snapshot cycles remained accurate against the later full-rescan tables; the
scans took 13.29 s and 12.87 s. Timeline cleanup marked one filesystem stale,
and the remaining four final deletes completed in 9.59 s, 1.32 s, 1.37 s, and
1.29 s. This suggests threshold 1 can keep deletion work bounded enough for
the host snapshot population while allowing deletion to make counters stale,
but it is not yet a production conclusion: the metadata tree was smaller than
the threshold-2 run, the test used TCG, and the stale transition occurred
during routine cleanup rather than only the final explicit delete.

The decisive follow-up combined the host snapshot counts with 131,072-file,
level-3 trees and threshold 1. All 217 snapshot cycles again matched the
full-rescan qgroup tables; the scans took 75.73 s and 81.65 s. Cleanup finished
with both filesystems still consistent, then the four final deletes marked
both filesystems stale and completed in 15.46 s, 1.46 s, 6.45 s, and 1.31 s.
This is the strongest controlled evidence so far that accurate snapshot stats
and a deletion-triggered stale state can coexist at the current snapshot
population. It remains a TCG guest result, so it does not establish latency on
the host's NVMe and USB storage or prove that the threshold-1 setting is safe
to install permanently.

A matched stock-module control at the same 217 snapshot population and
32,768-file tree had an overall snapshot-cycle median of 320 ms (p95 400 ms,
maximum 770 ms), versus 1.34 s (p95 3.01 s, maximum 3.32 s) for the accurate
threshold-1 run. Stock's p8 and Kingston qgroup tables differed from their
full-rescan tables and its inconsistency warnings accumulated during cleanup
and deletion. This makes the measured trade-off explicit: stock is faster but
does not meet the accuracy requirement; the custom path meets accuracy at a
measurable accounting cost. Both runs used TCG and Kingston-backed guest
images.

**Immediate next step: validate and, if possible, optimize the threshold-1
deletion/backref policy before deciding whether it is an acceptable optional
policy.**
The new disposable stock-7.2.9 reproduction shows that the four-group
source/snapshot-parent transition itself can mark qgroups inconsistent before
any deletion. Therefore, treat snapshot creation and qgroup-parent assignment
as the first root-cause path to isolate; do not frame the investigation as a
deletion-only problem. Keep the deletion/backref measurements below because
they remain necessary for the latency verdict. The staged reproduction now
isolates the first stale transition to snapshot creation before assignment of
the new snapshot qgroup to its snapshot-only parent. The small 131,072-file runs
establish that the fast-path counters match full-rescan
qgroup tables before deletion, and that a test-only threshold of 2 can defer
the accounting fallback until deletion. The host-count run establishes that
this policy currently fails the latency requirement during its first final
deletion, despite accurate snapshot counters. Threshold 1 completed the same
snapshot-count population with the smaller tree, but its cleanup made one
filesystem stale. Threshold 3 did not make the
smaller test deletes stale. Source inspection shows the
threshold is checked against a shared child subtree's level during the drop
walk, not the whole source tree's root level. A separate privileged read-only
inspection found the live host's p8 root/home tree levels are 2/3 and
Kingston root/home are 2/3, so those root levels alone do not prove that the
default threshold will trigger. The host-shaped QEMU trace recorded 2,403
subtree calls at levels 0/1/2 and none at level 3; this explains the threshold
behavior in that workload but is not an actual host deletion capture. The
remaining host-side measurement requires a safe test of the modified module.
Next, identify
which extent/backref work dominates the timeout, and implement an optimization
that preserves exact counters or makes the fallback happen before the long
walk. Then compare threshold 1, threshold 2, threshold 3, and fast-path-off
for snapshot,
cleanup, deletion, commit, and recovery cost. Keep the modified module off the
host. QEMU remains TCG-only; use the live blocked-task and transaction evidence
to check stalls separately, and do not call either requirement satisfied until
representative host-scale measurements and independent accounting checks
support it. Continue investigating repeated extent-root discovery in
`btrfs_qgroup_trace_subtree()` ->
`btrfs_qgroup_trace_extent_post()` -> `btrfs_find_all_roots()` for a design
that keeps snapshot counters accurate without unacceptable commit-path cost.
The QEMU disk images used for the decisive runs were stored on the mounted
Kingston Btrfs filesystem, so they include that device's backing-file I/O path;
TCG still prevents treating the results as direct host workload timings, and
the p8 NVMe path remains untested.

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

1. **Finish root-cause and live-accounting validation — 82% done.** The
   controlled QEMU matrix now includes exact 7.2.9 stock, modified-fast-path,
   and modified-fallback runs. The fast path avoids the tested automatic
   rescans. Threshold-1 testing now preserves accurate counters through the
   host snapshot population and bounds deletion in the tested guest, while
   threshold 2 timed out at that population. Full evidence and limits are in
   `GOAL-done.md`. The shared-parent fast path remains provisional; no general
   Btrfs correctness bug has been established.

   Remaining: establish the intended semantics and production acceptability of
   the threshold-1 stale-on-delete policy, then choose whether to develop a
   faster design that preserves accurate four-group counters without automatic
   rescans. Validate the chosen approach against host p8 storage and capture
   the external writer and blocked-task stacks
   during a live stall as part of the same root-cause investigation.
   `tools/btrfs-stall-capture.sh` now provides the read-only bundle needed for
   that capture; it triggers SysRq-W only when the existing runtime mask allows
   it and does not change mount or qgroup state.
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

3. **Make any required kernel change durable across APT upgrades — 82% done.**
   Snapper-only
   alternatives tested on the exact 7.2.6 stock module do not preserve fresh
   counters with the required four snapshot-only QGROUPs; the bounded
   shared-parent kernel fast path avoids the fallback on that hierarchy. This
   does not establish that the kernel change should be deployed. If the
   performance/correctness review selects it, keep the tested fast path and
   qgroup-teardown fix under APT-managed installation.
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
extents, preserve the four separately queryable exclusive-space totals for
p8-root, p8-home, Kingston-root, and Kingston-home; root and home never share
one snapshot QGROUP. After accounting becomes consistent, totals match a full
rescan. Quota limits retain their existing snapshot-only scope.

The primary outcome is a decisive, reviewable verdict for the supported
kernel, four-group layout, representative host workload, and explicit latency
acceptance limits: **either** demonstrate that the required stats remain
accurate for routine snapshots without unacceptable filesystem latency while
infrequent deletion may make them explicitly stale until recovery, **or**
show which constraints cannot be met together and quantify the least-cost
trade-off. “Impossible” must mean impossible under this defined scope and
constraints, supported by source-level reasoning and repeatable tests; lack of
a working implementation or an incomplete test is not proof of impossibility.
Define accuracy by matching all four exclusive-space totals
against a completed full rescan whenever the status says consistent. Define
latency with measured snapshot and transaction-commit timings against the stock
baseline. Treat low latency as no user-visible filesystem stalls and no
material regression in repeated snapshot/commit timing distributions versus
stock; report sample counts, distributions, and worst observed stalls rather
than treating a single fast run as proof. If both requirements coexist in the
measured workload, demonstrate the selected policy end to end. If not, document
which requirement cannot be met together and the measured trade-off instead of
treating inconsistency elimination as mandatory. Fix and regression-test any
confirmed defect. Automatic scans must stay inside the configured
local-time window. During investigation, the per-day cap is disabled, while
`force-suspend` can hold new scans until its configured deadline. If a rescan
is deferred, users can still see the last-known quota numbers and their stale
status; quota-based deletion waits until the numbers are current. The host's
configured preference is 05:00-21:00 local time for every Snapper
configuration sharing the filesystem; the timeline wrapper's separate
explicit rescan commands remain disabled.

The current locally built Snapper package (`7d4db17085ce`) has passed exact
7.2.6 QEMU stale-quota and hold tests using the exact installed DKMS module.
The direct-kernel run verified stale-value display, deferred cleanup, and
timeline-child snapshots while the hold kept the rescan idle. Separate OVMF
Secure Boot runs for exact 7.2.6 and 7.2.9 modules enforced signatures,
rejected unsigned Btrfs modules, and passed the same stale-quota and hold
checks. These QEMU runs do not replace host suspend/resume or live accounting
checks; see `GOAL-done.md` for evidence.

In the tested four-collective hierarchy, the bounded kernel fast path supplies
accurate counters without a full scan, while the stock fallback leaves the
newest snapshot counters stale until a full scan. The exact-7.2.6 QEMU
alternatives using untracked snapshots or post-creation qgroup assignment also
left stale counters. These results describe tested behavior; they do not yet
show that the fallback is a bug or that the kernel change is necessary.
Reevaluate the kernel requirement after confirming the intended semantics and
choosing an acceptable cost/policy trade-off. If a kernel fix is selected, it
must be automatically reapplied and active after every kernel APT
upgrade/reinstall without blocking security updates. The installed Snapper
changes must also survive their APT upgrade/reinstall. Verify the running
kernel, loaded module, Snapper package, and rescan rate for the chosen design.

## Completed evidence

See [`GOAL-done.md`](GOAL-done.md) for completed investigation, reproduction
results, kernel baseline, and temporary containment details. That file is
historical reference; the items above are the active work.

The recurring hourly `qgroup scan paused` message is not itself proof of a
slow qgroup scan: in the exact 7.2.9 source it is emitted when the rescan
worker stops because the filesystem is closing/remounting, qgroups are
disabled, or cancellation is requested. Attribute that stop condition before
using the message as stall evidence.
