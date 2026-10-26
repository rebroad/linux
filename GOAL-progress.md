# Current progress

Updated 2026-10-26. Percentages are rough estimates of each item's acceptance
work completed, not test pass rates or confidence levels. Items overlap, so do
not average them into a project-wide percentage. `GOAL.md` is the active
checklist; `GOAL-done.md` holds completed evidence and detailed history.

| Item in `GOAL.md` | Progress | Evidence completed | Main open gates |
| --- | ---: | --- | --- |
| First priority: diagnose stalls and establish the accounting trade-off | **45%** | Exact-version QEMU reproductions; stock/custom comparisons; source-path analysis; stock-host captures show several distinct wait paths and that stalls can occur without an active rescan. | Determine the production rescan stop condition and external transaction writer; capture a complete live stall; validate the modified path on representative host storage; decide the acceptable accuracy/latency policy. A stock-host trace for the next hourly snapshot cycle is in progress. |
| Four-collective accounting and recovery | **70%** | QEMU workloads compare the four exclusive-space collectives to full-rescan tables and cover snapshots, deletion, cleanup, stale values, and recovery. | Complete independent p8 accounting, safe host cleanup/rollback checks, and repeated live snapshot/deletion validation before restoring quota-based cleanup. |
| Locally built Snapper | **85%** | Latest-upstream local build is installed; package pinning, retained configs, timeline wiring, and read-only operation have been checked. | Complete stale-quota and cleanup behavior, rollback/runtime checks, and an upgrade to a subsequent local build. |
| Conditional kernel-change durability | **65%** | Signed DKMS/preflight sources cover installed 7.2.6 and 7.2.9 releases; exact-release module/Secure Boot QEMU paths and much of the APT preflight behavior have been exercised. | Decide whether a kernel change is needed. If selected, finish exact 7.2.9 comparison, real disposable APT kernel-transaction and failure/rollback coverage, and support for every installed and next kernel. |
| Suspend-aware rescan containment | **75%** | Configurable hold, local-time window, disabled daily limit, timer handling, and resume hooks are installed or audited. | Prove through a real suspend/resume cycle that neither Snapper rescan path starts early, and that policy-permitted work can resume after hold expiry. |

## Current diagnostic context

- The host is running Debian `7.2.9+deb13-amd64` with the stock Btrfs module.
  The modified DKMS module remains off the host pending the safety and latency
  gates in `GOAL.md`.
- On 2026-10-26, a stock-kernel blocked-task dump found DRM/TTM waits on DMA
  fences while neither filesystem had an active qgroup rescan. A separate
  transaction-thread capture found a short block-layer `wbt_wait()` during
  metadata writeback; transaction commits continued. Neither capture alone
  explains the earlier multi-minute hangs.
- A low-output stock-kernel trace is running across the next hourly Snapper
  cycle. Its result should be summarized here after it ends; retain raw
  captures under `/var/tmp`, not in the source checkout.

Detailed captures, test limits, and completed work belong in `GOAL-done.md`.
