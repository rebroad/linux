#!/bin/bash
set -euo pipefail

usage() {
	cat <<'EOF'
Usage: BTRFS_MOK_KEY=... BTRFS_MOK_CERT=... \
       scripts/build-btrfs-qgroup-dkms-package.sh

Build a local Debian DKMS package for the current patched Btrfs source. The
package and all generated files are written to the Linux sibling build tree.
The build requires the running 7.1.13+deb13-amd64 headers and a matching,
already enrolled Secure Boot key/certificate pair.
EOF
}

if [[ ${1:-} == -h || ${1:-} == --help ]]; then
	usage
	exit 0
fi
if (($#)); then
	usage >&2
	exit 2
fi

source_root=$(git rev-parse --show-toplevel)
source_root=$(realpath "$source_root")
target_kernel=$(uname -r)
expected_kernel=7.1.13+deb13-amd64
if [[ $target_kernel != "$expected_kernel" ]]; then
	echo "Error: refusing to package for $target_kernel; expected $expected_kernel" >&2
	exit 1
fi
if [[ $(make -s -C "$source_root" kernelversion) != 7.1.13 ]]; then
	echo "Error: source tree is not based on kernel 7.1.13" >&2
	exit 1
fi
if [[ ! -e /lib/modules/$target_kernel/build/Makefile ]]; then
	echo "Error: matching kernel headers are not installed" >&2
	exit 1
fi
if ! git -C "$source_root" diff --quiet -- fs/btrfs ||
   ! git -C "$source_root" diff --cached --quiet -- fs/btrfs; then
	echo "Error: commit or discard Btrfs source changes before packaging" >&2
	exit 1
fi
if [[ -n $(git -C "$source_root" status --porcelain --untracked-files=all) ]]; then
	echo "Error: commit or discard source-tree changes before packaging" >&2
	exit 1
fi

mok_key=${BTRFS_MOK_KEY:?set BTRFS_MOK_KEY to the enrolled module-signing private key}
mok_cert=${BTRFS_MOK_CERT:?set BTRFS_MOK_CERT to the matching DER X.509 certificate}
if [[ ! -r $mok_key || ! -r $mok_cert ]]; then
	echo "Error: cannot read the requested key/certificate pair" >&2
	exit 1
fi
if [[ $mok_key == *[!A-Za-z0-9_./+-]* ]]; then
	echo "Error: BTRFS_MOK_KEY must use only safe path characters" >&2
	exit 1
fi
openssl pkey -in "$mok_key" -check -noout >/dev/null
key_public=$(openssl pkey -in "$mok_key" -pubout -outform DER | sha256sum | cut -d' ' -f1)
cert_public=$(openssl x509 -inform DER -in "$mok_cert" -pubkey -noout |
	openssl pkey -pubin -outform DER | sha256sum | cut -d' ' -f1)
if [[ $key_public != "$cert_public" ]]; then
	echo "Error: BTRFS_MOK_KEY does not match BTRFS_MOK_CERT" >&2
	exit 1
fi
cert_fingerprint=$(openssl x509 -inform DER -in "$mok_cert" \
	-noout -fingerprint -sha1 | sed 's/^[^=]*=//' | tr -d ':' |
	tr '[:upper:]' '[:lower:]')
if ! mokutil --list-enrolled 2>/dev/null |
	sed -n 's/^SHA1 Fingerprint: //p' | tr -d ':' |
	tr '[:upper:]' '[:lower:]' |
	grep -Fxq "$cert_fingerprint"; then
	echo "Error: BTRFS_MOK_CERT is not enrolled" >&2
	exit 1
fi

storage_root=${source_root%%/@home/*}
source_relative=${source_root#*/@home/}
expected_build_root="$storage_root/builds/${source_relative%/*}/$(basename "$source_root").build"
expected_build_root_real=$(realpath -m "$expected_build_root")
build_root=$(realpath -m "${LINUX_BUILD_ROOT:-$expected_build_root}")
case "$build_root" in
	"$expected_build_root_real"|"$expected_build_root_real"/*) ;;
	*) echo "Error: build output must stay in $expected_build_root" >&2; exit 1 ;;
esac

source_commit=$(git -C "$source_root" rev-parse HEAD)
kernel_base=7.1.13
dkms_version="${kernel_base}+rebroad1.g${source_commit:0:12}"
package_version=$dkms_version
stamp=$(date -u +%Y%m%dT%H%M%SZ)
work_root="$build_root/local-btrfs-dkms/${target_kernel}-${source_commit:0:12}-${stamp}"
package_root="$work_root/package-root"
package_name="btrfs-qgroup-dkms_${package_version}_all.deb"
template_root="$source_root/packaging/btrfs-qgroup-dkms"
cpto_bin=${CPTO:-$(command -v cpto || true)}
if [[ ! -x $cpto_bin ]]; then
	echo "Error: cpto was not found or is not executable" >&2
	exit 1
fi

mkdir -p "$work_root" \
	"$package_root/DEBIAN" \
	"$package_root/etc/dkms/framework.conf.d" \
	"$package_root/usr/share/btrfs-qgroup-dkms" \
	"$package_root/usr/src/btrfs-qgroup-$dkms_version"
"$cpto_bin" --nogit --no-lngit "$source_root/fs/btrfs" \
	"$package_root/usr/src/btrfs-qgroup-$dkms_version"

sed "s|@DKMS_VERSION@|$dkms_version|g" \
	"$template_root/dkms.conf.in" \
	> "$package_root/usr/src/btrfs-qgroup-$dkms_version/dkms.conf"
sed "s|@PACKAGE_VERSION@|$package_version|g" \
	"$template_root/control.in" > "$package_root/DEBIAN/control"
for maintainer_script in postinst prerm postrm; do
	sed -e "s|@DKMS_VERSION@|$dkms_version|g" \
	    -e "s|@MOK_KEY@|$mok_key|g" \
	    "$template_root/$maintainer_script.in" \
	    > "$package_root/DEBIAN/$maintainer_script"
	chmod 0755 "$package_root/DEBIAN/$maintainer_script"
done
sed "s|@MOK_KEY@|$mok_key|g" \
	"$template_root/signing.conf.in" \
	> "$package_root/etc/dkms/framework.conf.d/50-btrfs-qgroup-signing.conf"
printf '%s\n' \
	/etc/dkms/framework.conf.d/50-btrfs-qgroup-signing.conf \
	> "$package_root/DEBIAN/conffiles"
openssl x509 -inform DER -in "$mok_cert" -out \
	"$package_root/usr/share/btrfs-qgroup-dkms/Rebroad-module-signing-key.pem"
install -m 0644 "$mok_cert" \
	"$package_root/usr/share/btrfs-qgroup-dkms/Rebroad-module-signing-key.der"

dpkg-deb --build --root-owner-group "$package_root" \
	"$work_root/$package_name" >/dev/null
sha256sum "$work_root/$package_name"
printf 'Built DKMS package: %s\n' "$work_root/$package_name"
printf 'Source commit: %s\n' "$source_commit"
printf 'DKMS version: %s\n' "$dkms_version"
