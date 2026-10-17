# Goal: fix Snapper-triggered Btrfs qgroup inconsistency

Find and fix the cause of hourly Snapper snapshots marking Btrfs qgroups
inconsistent and leading to disruptive full rescans. Preserve correct quota
accounting and Snapper cleanup behavior. Do not treat disabling rescans or
suppressing inconsistency warnings as the fix.

## Work remaining

- Design an accounting and cleanup model that preserves the intended measure
  of retained snapshot space without rescanning after each hourly snapshot.
  The current kernel path appears to request rescans correctly: aggregate
  qgroup counters do not reveal extent overlap between the source and a
  snapshot-only parent. Evaluate whether a different qgroup layout can retain
  useful cleanup semantics. Test any derived metric against shared extents
  held outside the snapshot set; a source-inclusive qgroup avoids rescans but
  its exclusive count includes live source data. If no exact layout/metric
  works, determine what principled Btrfs/Snapper accounting change is needed.
- Implement the smallest correct fix at the responsible layer (Btrfs
  accounting, Snapper integration, or host configuration). Preserve
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
- Keep the host timeline wrapper's explicit qgroup rescans disabled while the
  investigation continues. Snapper's own space-aware cleanup also requests and
  waits for rescans, so verify the effective host behavior and avoid claiming
  that the wrapper change disables every rescan source. This is temporary
  operational containment; Snapper snapshots remain enabled unless a safe
  reproduction shows otherwise.
- Restore the original `SPACE_LIMIT="0.5"` settings only after the accounting
  fix is verified and automated rescans are safe again. Until then, preserve
  the original values in the evidence log so quota-based cleanup can be
  reinstated deliberately.

## Reference

Verified completed investigation and reproduction evidence is recorded in
[`GOAL-done.md`](GOAL-done.md). It is background for the remaining work, not a
claim that the root cause has been fixed.
