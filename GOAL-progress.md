# Current progress

Updated 2026-10-27. Percentages are rough estimates of each item's acceptance
work completed, not test pass rates or confidence levels. Items overlap, so do
not average them into a project-wide percentage. `GOAL.md` is the active
checklist; `GOAL-done.md` holds completed evidence and detailed history.

| Item in `GOAL.md` | Progress | Evidence completed | Main open gates |
| --- | ---: | --- | --- |
| First priority: diagnose stalls and establish the accounting trade-off | **50%** | Exact-version QEMU reproductions, source-path analysis, and stock/custom comparisons. The overnight 10.7-hour `systemd-journal` D-state was an expected freezer wait across system suspend, not a Btrfs stall. The loaded host module is confirmed to match the preserved stock 7.2.9 module. A 10:00 timeline run on 2026-10-27 logged two `qgroup scan paused` messages for `nvme0n1p5`; qgroups remained inconsistent. | Capture the next relevant scan start/stop with stacks and the triggering actor; determine whether pausing comes from Snapper, quota state, or another caller. Capture a complete live multi-minute Btrfs stall, compare stock/custom on representative host storage, and decide the accuracy/latency policy. |
| Four-collective accounting and recovery | **70%** | QEMU workloads compare the four exclusive-space collectives to full-rescan tables and cover snapshots, deletion, cleanup, stale values, and recovery. | Complete independent p8 accounting, safe host cleanup/rollback checks, and repeated live snapshot/deletion validation before restoring quota-based cleanup. |
| Locally built Snapper | **85%** | Latest-upstream local build is installed; package pinning, retained configs, timeline wiring, and read-only operation have been checked. | Complete stale-quota and cleanup behavior, rollback/runtime checks, and an upgrade to a subsequent local build. |
| Conditional kernel-change durability | **65%** | Signed DKMS/preflight sources cover installed 7.2.6 and 7.2.9 releases; exact-release module/Secure Boot QEMU paths and much of the APT preflight behavior have been exercised. | Decide whether a kernel change is needed. If selected, finish exact 7.2.9 comparison, real disposable APT kernel-transaction and failure/rollback coverage, and support for every installed and next kernel. |
| Suspend-aware rescan containment | **60%** | Configurable hold, local-time window, disabled daily limit, and timer handling are installed. The current marker is expired at 04:00 on 2026-10-27. Source changes removing resume-time refresh and limiting a new hold to the overnight window are committed and pushed on the home-repository branch `fix/snapper-rescan-hold-daytime`. | The installed `/usr/local/libexec/snapper-timeline-sleep` still refreshes expired holds; deployment was blocked because this shell cannot use sudo. A controlled stale-before-suspend case with explicit deferral logging is still needed. Verify both Snapper's internal quota gate and the timeline wrapper, and ensure stale values remain visibly stale. |

## Current diagnostic context

- The host is running Debian `7.2.9+deb13-amd64` with stock Btrfs loaded. The
  loaded module's sysfs build ID (`c2d998d4752632e0f5cf36eaab134a3e73b18940`)
  matches the preserved original 7.2.9 module in
  `/var/lib/dkms/btrfs-qgroup/original_module/7.2.9+deb13-amd64/x86_64/` and
  its recorded origin is the stock path
  `/lib/modules/7.2.9+deb13-amd64/kernel/fs/btrfs/btrfs.ko.xz`. The custom
  `btrfs-qgroup-dkms 7.2.6+rebroad1.z20261019.g89f68effaaf87` module is
  installed at `updates/dkms`, but its build ID differs and it is not the
  loaded binary. The `qgroup scan paused` string also exists in the preserved
  stock module, so that log message does not indicate custom code is running.
- On 2026-10-26, a blocked-task dump found DRM/TTM waits on DMA
  fences while neither filesystem had an active qgroup rescan. A separate
  transaction-thread capture found a short block-layer `wbt_wait()` during
  metadata writeback; transaction commits continued. Neither capture alone
  explains the earlier multi-minute hangs.
- On 2026-10-26 the laptop suspended at 22:43:56 and resumed at 09:25:15 on
  2026-10-27. The hourly timeline timer caught up immediately after resume.
  Snapper made four qgroup-inheritance calls that marked both filesystems
  inconsistent. The hold file was refreshed on resume and expires at 04:00
  on 2026-10-28; a privileged rescan-status query afterward reported no scan
  in progress on either filesystem. Snapper source confirms the snapshot
  path invokes the hold/window/daily-limit gate even with `SPACE_LIMIT="1.0"`.
  Earlier 20:00 logs show qgroup scans paused, making it likely qgroups were
  stale before resume, but that state was not captured then and no explicit
  hold-deferral message was retained. See `GOAL-done.md` for evidence and
  limits.
- The follow-up bpftrace process ended with timeout status 124 at 09:58 on
  2026-10-27, before the 10:00 timeline run. It recorded four earlier
  `qgroup_mark_inconsistent()` calls from snapshot inheritance. The longest
  recorded `psensor` D-state was 602 ms in Btrfs log-sync/fsync paths; the
  longest `btrfs-transacti` wait was 613 ms and `snapper` was 355 ms, not the
  reported multi-minute event. The `systemd-journal` D-state lasted
  38,478,836 ms across system suspend. The 10:00 timeline service ran
  10:00:03–10:01:06. Kernel logs recorded `qgroup scan paused` at 10:00:34 and
  10:01:06 on `nvme0n1p5`; qgroups remained inconsistent. Our source emits
  this pause message when `rescan_should_stop()` returns true, including after
  stock module. A pause message establishes that a scan stopped, but not who
  requested it or why; the trace ended before 10:00, so the exact trigger was
  not captured. Raw trace output remains under `/var/tmp`, not in the source
  checkout.

Detailed captures, test limits, and completed work belong in `GOAL-done.md`.
