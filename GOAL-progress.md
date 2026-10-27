# Current progress

Updated 2026-10-27. Percentages are rough estimates of each item's acceptance
work completed, not test pass rates or confidence levels. Items overlap, so do
not average them into a project-wide percentage. `GOAL.md` is the active
checklist; `GOAL-done.md` holds completed evidence and detailed history.

| Item in `GOAL.md` | Progress | Evidence completed | Main open gates |
| --- | ---: | --- | --- |
| First priority: diagnose stalls and establish the accounting trade-off | **50%** | Exact-version QEMU reproductions; stock/custom comparisons; source-path analysis; stock-host captures distinguish several wait paths. An overnight stock trace confirms a 10.7-hour `systemd-journal` D-state was the expected freezer wait across system suspend, not a Btrfs stall. | Determine the production rescan stop condition and external transaction writer; capture a complete live Btrfs stall; validate the modified path on representative host storage; decide the acceptable accuracy/latency policy. |
| Four-collective accounting and recovery | **70%** | QEMU workloads compare the four exclusive-space collectives to full-rescan tables and cover snapshots, deletion, cleanup, stale values, and recovery. | Complete independent p8 accounting, safe host cleanup/rollback checks, and repeated live snapshot/deletion validation before restoring quota-based cleanup. |
| Locally built Snapper | **85%** | Latest-upstream local build is installed; package pinning, retained configs, timeline wiring, and read-only operation have been checked. | Complete stale-quota and cleanup behavior, rollback/runtime checks, and an upgrade to a subsequent local build. |
| Conditional kernel-change durability | **65%** | Signed DKMS/preflight sources cover installed 7.2.6 and 7.2.9 releases; exact-release module/Secure Boot QEMU paths and much of the APT preflight behavior have been exercised. | Decide whether a kernel change is needed. If selected, finish exact 7.2.9 comparison, real disposable APT kernel-transaction and failure/rollback coverage, and support for every installed and next kernel. |
| Suspend-aware rescan containment | **80%** | Configurable hold, local-time window, disabled daily limit, timer handling, and resume hooks are installed or audited. A real overnight resume refreshed the shared hold to 04:00 the next day; the catch-up timeline run marked both filesystems inconsistent, while privileged status checks found no rescan in progress. Snapper source confirms quota-tracked snapshot creation calls the internal policy gate independently of `SPACE_LIMIT`. | In a controlled case, capture the qgroups already stale before suspend and an explicit hold-deferral result during resume catch-up; then verify a scan can start after expiry/window permission. |

## Current diagnostic context

- The host is running Debian `7.2.9+deb13-amd64` with the stock Btrfs module.
  The modified DKMS module remains off the host pending the safety and latency
  gates in `GOAL.md`.
- On 2026-10-26, a stock-kernel blocked-task dump found DRM/TTM waits on DMA
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
- The low-output trace remains active after resume and is set to cover the
  next hourly cycle. Raw output stays under `/var/tmp`, not in the source
  checkout.

Detailed captures, test limits, and completed work belong in `GOAL-done.md`.
