#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: rebase-master-to-running-kernel.sh [kernel-release]

Rebase the current repo's master branch onto upstream tag vX.Y.Z that matches:
- the provided kernel release, or
- `uname -r` when omitted.
USAGE
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$repo_root" ]]; then
  echo "error: run inside a git repo" >&2
  exit 1
fi
cd "$repo_root"

if ! git remote get-url upstream >/dev/null 2>&1; then
  echo "error: missing 'upstream' remote" >&2
  exit 1
fi

if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  echo "error: tracked changes present; commit/stash first" >&2
  exit 1
fi

release="${1:-$(uname -r)}"
base_ver="$(sed -E 's/^([0-9]+\.[0-9]+(\.[0-9]+)?).*/\1/' <<<"$release")"
if [[ -z "$base_ver" ]]; then
  echo "error: cannot parse kernel version from '$release'" >&2
  exit 1
fi
target_tag="v${base_ver}"

echo "Fetching upstream tags..."
git fetch upstream --tags

if ! git rev-parse -q --verify "refs/tags/${target_tag}^{commit}" >/dev/null; then
  echo "error: tag '${target_tag}' not found in upstream tags" >&2
  exit 1
fi

echo "Checking out master..."
git checkout master >/dev/null

fork_point="$(git merge-base --fork-point upstream/master master 2>/dev/null || true)"
if [[ -z "$fork_point" ]]; then
  fork_point="$(git merge-base upstream/master master)"
fi

echo "Rebasing commits after ${fork_point} onto ${target_tag}..."
git rebase --onto "$target_tag" "$fork_point" master
echo "Done."
