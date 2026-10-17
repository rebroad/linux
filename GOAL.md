# Goal: fix Snapper-triggered Btrfs qgroup inconsistency

Find and fix the cause of hourly Snapper snapshots marking Btrfs qgroups
inconsistent and leading to disruptive full rescans. Preserve correct quota
accounting and Snapper cleanup behavior. Do not treat disabling rescans or
suppressing inconsistency warnings as the fix.

## Work remaining

- Resolve why Snapper's configured snapshot qgroup inheritance (`1/100` for
  `root`, `1/101` for `home`) requests a rescan when the source subvolumes have
  no parent qgroup. Compare the no-inheritance behavior with the configured
  snapshot-space accounting and cleanup requirements.
- Select and implement the smallest correct fix at the responsible layer
  (Btrfs accounting, Snapper integration, or host configuration). Preserve
  meaningful referenced/exclusive counts and quota enforcement; do not assign
  live source data to a snapshot-only qgroup unless the resulting Snapper
  accounting is corrected and verified.
- Reproduce repeated snapshot creation and cleanup on a disposable Btrfs image,
  including shared extents and parent/child qgroups. Compare incremental counts
  with a full rescan and confirm the chosen fix avoids unnecessary rescans.
- Build and run checks appropriate to the changed layer. For kernel changes,
  use the source matching the currently running Debian kernel and build in the
  prescribed external build tree.
- Investigate the reported system stalls separately. Collect useful task
  stacks, transaction state, and storage/I/O evidence; do not infer causation
  from a qgroup warning or rescan correlation alone.
- Check for an existing upstream report if evidence points to a Btrfs bug. If
  none exists, prepare a focused report and patch for the correct venue; share
  the concrete draft for review before sending it.
- Keep the host's automated qgroup rescans disabled while the investigation
  continues. This is temporary operational containment; Snapper snapshots
  remain enabled unless a safe reproduction shows otherwise.

## Reference

Verified completed investigation and reproduction evidence is recorded in
[`GOAL-done.md`](GOAL-done.md). It is background for the remaining work, not a
claim that the root cause has been fixed.
