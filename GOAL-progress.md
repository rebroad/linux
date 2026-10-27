# Current progress

Updated 2026-10-27. Percentages are rough estimates of each item's acceptance
work completed, not test pass rates or confidence levels. Items overlap, so do
not average them into a project-wide percentage. `GOAL.md` is the active
checklist; `GOAL-done.md` holds completed evidence and detailed history.

| Item in `GOAL.md` | Progress | Evidence completed | Main open gates |
| --- | ---: | --- | --- |
| First priority: diagnose stalls and establish the accounting trade-off | **65%** | Exact 7.2.9 QEMU runs show stock and feature-off reproduce inconsistency/rescans, while quick-inherit on keeps all four counters accurate in verified root-home and home-root creation orders. In retained two-snapshot-per-config logs, fast-on had 16 snapshot cycles at 250-560 ms (median 295 ms) versus stock's 8 at 230-800 ms (median 255 ms); deletion medians were similar at about 1.77 s. The recorded 217-snapshot TCG workload exposed a scale trade-off: threshold 2 exceeded a one-hour deletion timeout; threshold 1 kept counters accurate through snapshots, then made deletion stale (15.46 s maximum) with explicit rescans taking 75-82 s. The matched stock median snapshot cycle was 320 ms versus 1.34 s for custom threshold 1. This supports accuracy-through-snapshots/stale-on-deletion as feasible in QEMU, but not as a host-latency verdict. The old high-count raw logs are missing from their recorded build path and must be recreated. Host snapshots on stock 7.2.9 found no active rescan and, at 11:59, only TTM GPU-fence D-state tasks; earlier stock-host captures show Btrfs metadata/drop waits. The custom fast path adds in-memory qgroup graph work under a spinlock, so indirect contention is not ruled out. | Re-run the high-count comparison with current source and retained logs under `/var/tmp/builds`; capture per-task stacks, transaction/device progress, and the exact qgroup pause caller during a live Btrfs event. Measure latency on representative host storage, then set the acceptable snapshot/deletion/rescan limits. |
| Four-collective accounting and recovery | **80%** | Two shared-parent quick-inherit QEMU runs, in root/home and home/root order, matched all four-group accounting against completed full rescans; both remained consistent after cleanup and default-threshold deletion. The feature-off path and actual stock module reproduced stale values/scans. | Complete independent p8 accounting, safe host cleanup/rollback checks, and repeated live snapshot/deletion validation before restoring quota-based cleanup. |
| Locally built Snapper | **85%** | Latest-upstream local build is installed; package pinning, retained configs, timeline wiring, and read-only operation have been checked. | Complete stale-quota and cleanup behavior, rollback/runtime checks, and an upgrade to a subsequent local build. |
| Conditional kernel-change durability | **65%** | Signed DKMS/preflight sources cover installed 7.2.6 and 7.2.9 releases; exact-release module/Secure Boot QEMU paths and much of the APT preflight behavior have been exercised. | Decide whether a kernel change is needed. If selected, finish exact 7.2.9 comparison, real disposable APT kernel-transaction and failure/rollback coverage, and support for every installed and next kernel. |
| Suspend-aware rescan containment | **70%** | Configurable hold, local-time scan window, and disabled daily limit are installed. The source and installed `/usr/local/libexec/snapper-rescan-hold` now enforce an overnight-only hold (21:00 to 04:00); daytime refresh writes an expired deadline, so no wake-up cleanup is required. Simulated 03:00, daytime-with-stale-future-marker, and 22:00 cases passed. The live marker is expired. | Capture a controlled stale-before-suspend case with explicit deferral logging. Verify the internal Snapper gate and any wrapper path that may start rescans, and ensure stale values remain visibly stale. |

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
- At 10:11 on 2026-10-27, both production filesystems still reported
  `qgroups/inconsistent=1`, with no rescan in progress and no sampled D-state
  Btrfs/Snapper tasks. The host remains on the stock 7.2.9 module. The 10:00
  timeline service ran from 10:00:03 to 10:01:06; its journal contains only
  duplicate-target notices plus two p8 `qgroup scan paused` messages. The
  exact rescan caller and stop reason were not logged. The short-lived
  system-wide probe trace started at 10:11 but produced only its attachment
  line and is no longer running. An on-demand QEMU run has since exercised the
  same Snapper snapshot path without the hold file; see `GOAL-done.md`. Keep a
  host trace as supplemental evidence for host-specific pause/stall causes,
  not as a prerequisite for controlled QEMU work.
- A privileged read-only sample at 11:59:35 on 2026-10-27 again confirmed
  stock Btrfs build ID `c2d998d4752632e0f5cf36eaab134a3e73b18940`, both
  filesystems `inconsistent=1`, and no active rescans. The 15 sampled D-state
  tasks were all TTM workers waiting in `dma_fence_default_wait`; none was a
  Btrfs task. I/O PSI `some avg10` was 1.26% and memory PSI `some avg10` was
  0.30%. This sample identifies the current blocked-task family but does not
  explain the earlier multi-minute Btrfs transaction stalls. The follow-up
  stack read was not completed because sudo authentication was not provided.
- An initial source audit against upstream `v7.2.9` found the custom delta
  confined to qgroup code, qgroup sysfs toggles, and tests. Shared-parent
  quick-inherit adds in-memory qgroup-graph traversal under `qgroup_lock`, but
  no transaction start, metadata read, commit, or explicit blocking wait. The
  stale-accounting optimization skips a subtree read walk. This lowers the
  likelihood of a direct blocking-I/O regression in those paths, but does not
  rule out longer spinlock holds, deletion-path effects, or indirect
  transaction contention. A full modified-kernel comparison and stall trace
  remain open.
- A second on-demand QEMU run used the actual Debian stock 7.2.9 Btrfs module
  and Snapper 0.13.2/libsnapper 8.2.0 with the hold absent. The loaded guest
  module build ID matched the host's preserved stock module. It reproduced
  the same sequence: root snapshot inheritance marked both filesystems
  inconsistent, later root snapshot calls each completed a rescan, and
  deletion made the qgroups inconsistent again. The QEMU fixture's explicit
  pre/post full-rescan table comparison changed values, as expected when
  replacing stale accounting; it did not pass the unchanged-counter check.
  The fixture also repeats both inconsistency sysfs paths under each printed
  filesystem label, so those particular label/value lines are not per-FS
  evidence. Snapshot timings were 220-770 ms in this small virtual-disk test;
  they are not a host-latency estimate. Full details and the serial-log hash
  are in `GOAL-done.md`.
- A privileged host snapshot at 10:54 on 2026-10-27 confirmed the same loaded
  stock module build ID, no rescan on `/` or `/mnt/kingston`, and
  `qgroups/inconsistent=1` on both filesystems. No D-state tasks were present
  in the sample. The 09:00-to-10:54 kernel journal contained no Btrfs stall
  message, and the Snapper journal showed the known 09:25 resume catch-up and
  10:00 timer run only. This quiet snapshot does not explain the earlier scan
  pause or reproduce a multi-minute stall.

Detailed captures, test limits, and completed work belong in `GOAL-done.md`.
