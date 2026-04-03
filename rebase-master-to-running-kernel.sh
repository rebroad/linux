#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: rebase-master-to-running-kernel.sh [--from REF] [kernel-release]

Rebase the current repo's master branch onto upstream tag vX.Y.Z that matches:
- the provided kernel release, or
- `uname -r` when omitted.

By default, rebases commits in `<base-tag>..master`, where `<base-tag>` is the
nearest stable tag (vX.Y.Z) on master's first-parent chain.
Use `--from REF` to override the base explicitly.
USAGE
}

from_ref=""
release=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --from)
      from_ref="${2:-}"
      if [[ -z "$from_ref" ]]; then
        echo "error: --from requires a ref" >&2
        exit 1
      fi
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      if [[ -n "$release" ]]; then
        echo "error: unexpected extra argument: $1" >&2
        usage >&2
        exit 1
      fi
      release="$1"
      shift
      ;;
  esac
done

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

release="${release:-$(uname -r)}"
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

if [[ -z "$from_ref" ]]; then
  from_ref="$(git describe --first-parent --tags --match 'v[0-9]*.[0-9]*.[0-9]*' --abbrev=0 master 2>/dev/null || true)"
  if [[ -z "$from_ref" ]]; then
    echo "error: could not auto-detect base stable tag on master; use --from REF" >&2
    exit 1
  fi
fi

if ! git rev-parse -q --verify "$from_ref^{commit}" >/dev/null; then
  echo "error: ref '$from_ref' does not resolve to a commit" >&2
  exit 1
fi

if ! git merge-base --is-ancestor "$from_ref" master; then
  echo "error: '$from_ref' is not an ancestor of master" >&2
  echo "hint: choose an ancestor ref for --from" >&2
  exit 1
fi

if [[ "$(git rev-list --count "${from_ref}..master")" -eq 0 ]]; then
  echo "No commits to rebase in ${from_ref}..master. Nothing to do."
  exit 0
fi

echo "Rebasing commits in ${from_ref}..master onto ${target_tag}..."
git rebase --onto "$target_tag" "$from_ref" master
echo "Done."
