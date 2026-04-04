#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: build-secureboot-debs.sh [--jobs N] [--localversion SUFFIX] [--check-only]
                                [--use-running-config|--no-use-running-config]
                                [--clean]

Build Debian kernel packages from the current linux tree, sign modules with
your MOK key, and produce Secure Boot-signed linux-image*.deb packages.

Defaults:
  MOK_PRIV=~/src/rebroad-mok.priv
  MOK_CERT=~/src/rebroad-mok.der
  LOCALVERSION=+rebroad
USAGE
}

jobs="${JOBS:-$(nproc)}"
localversion="${LOCALVERSION:-+rebroad}"
check_only=0
use_running_config=1
do_clean=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --jobs)
      jobs="$2"
      shift 2
      ;;
    --localversion)
      localversion="$2"
      shift 2
      ;;
    --check-only)
      check_only=1
      shift
      ;;
    --use-running-config)
      use_running_config=1
      shift
      ;;
    --no-use-running-config)
      use_running_config=0
      shift
      ;;
    --clean)
      do_clean=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown arg: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
if [[ -z "$repo_root" ]]; then
  echo "error: run inside linux git repo" >&2
  exit 1
fi
cd "$repo_root"

# Force large temporary artifacts into /var/tmp (not /tmp).
export TMPDIR="/var/tmp"

for cmd in make openssl sbsign dpkg-deb; do
  command -v "$cmd" >/dev/null 2>&1 || {
    echo "error: missing command: $cmd" >&2
    exit 1
  }
done

mok_priv="${MOK_PRIV:-$HOME/src/rebroad-mok.priv}"
mok_cert="${MOK_CERT:-$HOME/src/rebroad-mok.der}"

[[ -f "$mok_priv" ]] || { echo "error: missing MOK key: $mok_priv" >&2; exit 1; }
[[ -f "$mok_cert" ]] || { echo "error: missing MOK cert: $mok_cert" >&2; exit 1; }
[[ -x ./scripts/config ]] || { echo "error: scripts/config is required" >&2; exit 1; }

if head -n1 "$mok_priv" 2>/dev/null | grep -q '^version https://git-lfs.github.com/spec/v1$'; then
  echo "error: MOK key file looks like a Git LFS pointer, not real key material: $mok_priv" >&2
  echo "hint: fetch real LFS objects or point MOK_PRIV to an actual private key file" >&2
  exit 1
fi
if head -n1 "$mok_cert" 2>/dev/null | grep -q '^version https://git-lfs.github.com/spec/v1$'; then
  echo "error: MOK cert file looks like a Git LFS pointer, not real cert material: $mok_cert" >&2
  echo "hint: fetch real LFS objects or point MOK_CERT to an actual x509 cert file" >&2
  exit 1
fi

running_cfg="/boot/config-$(uname -r)"
if [[ "$use_running_config" -eq 1 ]]; then
  [[ -f "$running_cfg" ]] || {
    echo "error: running-kernel config not found: $running_cfg" >&2
    exit 1
  }
else
  [[ -f .config ]] || { echo "error: missing .config in repo root" >&2; exit 1; }
fi

if [[ "$check_only" -eq 1 ]]; then
  echo "Preflight OK:"
  echo "  repo: $repo_root"
  echo "  MOK key: $mok_priv"
  echo "  MOK cert: $mok_cert"
  echo "  jobs: $jobs"
  echo "  localversion: $localversion"
  echo "  use-running-config: $use_running_config"
  echo "  clean-before-build: $do_clean"
  if [[ "$use_running_config" -eq 1 ]]; then
    echo "  running config: $running_cfg"
  fi
  exit 0
fi

if [[ "$use_running_config" -eq 1 ]]; then
  echo "Using running kernel config: $running_cfg"
  cp "$running_cfg" .config
fi

if [[ "$do_clean" -eq 1 ]]; then
  echo "Cleaning tree before build..."
  make clean
fi

tmpdir="$(mktemp -d -p /var/tmp)"
trap 'rm -rf "$tmpdir"' EXIT

cert_pem="$tmpdir/mok-cert.pem"
case "$mok_cert" in
  *.der|*.DER) openssl x509 -inform DER -in "$mok_cert" -out "$cert_pem" ;;
  *) cp "$mok_cert" "$cert_pem" ;;
esac

# Kernel module signing expects a PEM containing key + cert.
module_sig_pem="$tmpdir/module-signing-key.pem"
cat "$mok_priv" "$cert_pem" > "$module_sig_pem"
chmod 600 "$module_sig_pem"

echo "Setting module signing config..."
./scripts/config --file .config --enable MODULE_SIG
./scripts/config --file .config --enable MODULE_SIG_ALL
./scripts/config --file .config --set-str MODULE_SIG_KEY "$module_sig_pem"
./scripts/config --file .config --set-str SYSTEM_TRUSTED_KEYS ""
./scripts/config --file .config --set-str SYSTEM_REVOCATION_KEYS "" || true
make olddefconfig >/dev/null

stamp="$tmpdir/build.stamp"
touch "$stamp"

print_space_context() {
  local tmp_base="/var/tmp"
  echo "Filesystem space context:"
  df -hP "$repo_root" "$pkg_dir" "$tmp_base" 2>/dev/null | awk '!seen[$0]++'
  echo
  echo "Filesystem inode context:"
  df -iP "$repo_root" "$pkg_dir" "$tmp_base" 2>/dev/null | awk '!seen[$0]++'
}

echo "Building bindeb-pkg (jobs=$jobs, LOCALVERSION=$localversion)..."
pkg_dir="$(dirname "$repo_root")"
build_log="$tmpdir/bindeb-pkg.log"
set +e
if command -v fakeroot >/dev/null 2>&1; then
  fakeroot make -j"$jobs" bindeb-pkg LOCALVERSION="$localversion" 2>&1 \
    | tee "$build_log" \
    | awk '
      /No space left on device/ {
        nospace++
        if (nospace == 1) {
          print "[ENOSPC] No space left on device detected; suppressing repeated lines..."
        }
        next
      }
      { print }
      END {
        if (nospace > 1) {
          printf "[ENOSPC] Suppressed %d repeated ENOSPC lines.\n", nospace
        }
      }'
  build_status=${PIPESTATUS[0]}
else
  make -j"$jobs" bindeb-pkg LOCALVERSION="$localversion" 2>&1 \
    | tee "$build_log" \
    | awk '
      /No space left on device/ {
        nospace++
        if (nospace == 1) {
          print "[ENOSPC] No space left on device detected; suppressing repeated lines..."
        }
        next
      }
      { print }
      END {
        if (nospace > 1) {
          printf "[ENOSPC] Suppressed %d repeated ENOSPC lines.\n", nospace
        }
      }'
  build_status=${PIPESTATUS[0]}
fi
set -e

if [[ "$build_status" -ne 0 ]]; then
  if grep -q "No space left on device" "$build_log"; then
    echo "error: build failed due to insufficient disk space."
    print_space_context
  fi
  exit "$build_status"
fi

mapfile -t image_pkgs < <(find "$pkg_dir" -maxdepth 1 -type f \
  \( -name 'linux-image-*.deb' -o -name 'linux-image-unsigned-*.deb' \) \
  -newer "$stamp" | sort)

if [[ ${#image_pkgs[@]} -eq 0 ]]; then
  echo "error: no new linux-image debs found under $pkg_dir" >&2
  exit 1
fi

sign_image_deb() {
  local deb="$1"
  local work out

  work="$(mktemp -d)"
  dpkg-deb -R "$deb" "$work/root"

  mapfile -t vmlinuz_files < <(find "$work/root/boot" -maxdepth 1 -type f -name 'vmlinuz-*' 2>/dev/null || true)
  for vmlinuz in "${vmlinuz_files[@]}"; do
    sbsign --key "$mok_priv" --cert "$cert_pem" --output "${vmlinuz}.signed" "$vmlinuz" >/dev/null
    mv -f "${vmlinuz}.signed" "$vmlinuz"
  done

  if [[ -f "$work/root/DEBIAN/md5sums" ]]; then
    (
      cd "$work/root"
      find . -type f ! -path './DEBIAN/*' -printf '%P\n' | sort | xargs -r md5sum
    ) > "$work/root/DEBIAN/md5sums"
  fi

  out="${deb%.deb}.secureboot-signed.deb"
  dpkg-deb -b "$work/root" "$out" >/dev/null
  rm -rf "$work"
  echo "$out"
}

echo "Signing kernel image debs for Secure Boot..."
for deb in "${image_pkgs[@]}"; do
  signed="$(sign_image_deb "$deb")"
  echo "  $deb -> $signed"
done

echo "Done."
