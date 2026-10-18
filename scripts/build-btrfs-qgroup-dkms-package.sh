#!/bin/bash
set -euo pipefail

usage() {
	cat <<'EOF'
Usage: BTRFS_MOK_KEY=... BTRFS_MOK_CERT=... \
       [BTRFS_COMPAT_SOURCES=/path/to/kernel-sources.tsv] \
       scripts/build-btrfs-qgroup-dkms-package.sh

Build a local Debian DKMS package for the patched Btrfs source. The package
and all generated files are written to the Linux sibling build tree. The build
requires the running 7.1.13+deb13-amd64 headers and a matching, already
enrolled Secure Boot key/certificate pair. The optional tab-separated source
manifest maps exact additional kernel releases to extracted matching Linux
source trees; these trees are copied into the package and patched during build.
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
kernel_series=${kernel_base%.*}
kernel_source_version() {
	awk '
		/^VERSION = / { version = $3 }
		/^PATCHLEVEL = / { patchlevel = $3 }
		/^SUBLEVEL = / { sublevel = $3 }
		END {
			if (version == "" || patchlevel == "" || sublevel == "") exit 1
			printf "%s.%s.%s\n", version, patchlevel, sublevel
		}' "$1/Makefile"
}
stamp=$(date -u +%Y%m%dT%H%M%SZ)
work_root="$build_root/local-btrfs-dkms/${target_kernel}-${source_commit:0:12}-${stamp}"
mkdir -p "$work_root"
source_map="$work_root/kernel-source-map"

declare -A source_base_for_kernel=() source_root_for_base=()
source_root_for_base[$kernel_base]=$source_root
compat_manifest=${BTRFS_COMPAT_SOURCES:-}
if [[ -n $compat_manifest ]]; then
	if [[ ! -r $compat_manifest ]]; then
		echo "Error: cannot read BTRFS_COMPAT_SOURCES: $compat_manifest" >&2
		exit 1
	fi
	while IFS= read -r line || [[ -n $line ]]; do
		[[ -z $line || $line == \#* ]] && continue
		if [[ $line != *$'\t'* || ${line#*$'\t'} == *$'\t'* ]]; then
			echo "Error: compatibility source entries must be RELEASE<TAB>SOURCE_ROOT" >&2
			exit 1
		fi
		compat_release=${line%%$'\t'*}
		compat_root=${line#*$'\t'}
		if [[ ! $compat_release =~ ^[0-9]+\.[0-9]+\.[0-9]+\+deb13-amd64$ ||
		      ! -d $compat_root/fs/btrfs ]]; then
			echo "Error: invalid compatibility source entry for $compat_release" >&2
			exit 1
		fi
		compat_root=$(realpath "$compat_root")
		compat_base=$(kernel_source_version "$compat_root")
		if [[ ${compat_release%%+*} != "$compat_base" ]]; then
			echo "Error: source $compat_root is $compat_base, not ${compat_release%%+*}" >&2
			exit 1
		fi
		if [[ -n ${source_base_for_kernel[$compat_release]:-} ]]; then
			echo "Error: duplicate compatibility source for $compat_release" >&2
			exit 1
		fi
		if [[ -n ${source_root_for_base[$compat_base]:-} &&
		      ${source_root_for_base[$compat_base]} != "$compat_root" ]]; then
			echo "Error: conflicting source trees claim kernel $compat_base" >&2
			exit 1
		fi
		source_base_for_kernel[$compat_release]=$compat_base
		source_root_for_base[$compat_base]=$compat_root
	done < "$compat_manifest"
fi

installed_kernel_count=0
for module_dir in /lib/modules/*; do
	[[ -d $module_dir ]] || continue
	kernel_release=${module_dir##*/}
	kernel_version=${kernel_release%%+*}
	kernel_release_series=${kernel_version%.*}
	if [[ $kernel_release_series == "$kernel_series" ]]; then
		source_base_for_kernel[$kernel_release]=$kernel_base
	elif [[ -z ${source_base_for_kernel[$kernel_release]:-} ]]; then
		echo "Error: no matching Btrfs source supplied for installed kernel $kernel_release" >&2
		exit 1
	fi
	installed_kernel_count=$((installed_kernel_count + 1))
done
if ((installed_kernel_count == 0)); then
	echo "Error: no installed kernel module trees found under /lib/modules" >&2
	exit 1
fi

: > "$source_map"
for kernel_release in "${!source_base_for_kernel[@]}"; do
	printf '%s\t%s\n' "$kernel_release" "${source_base_for_kernel[$kernel_release]}" \
		>> "$source_map"
done
sort -o "$source_map" "$source_map"
mapping_hash=$(sha256sum "$source_map" | cut -c1-8)

source_fingerprints="$work_root/source-fingerprints"
: > "$source_fingerprints"
for compat_base in "${!source_root_for_base[@]}"; do
	compat_root=${source_root_for_base[$compat_base]}
	if find "$compat_root/fs/btrfs" -type f \
		\( -name '*.o' -o -name '*.ko' -o -name '.*.cmd' \) \
		-print -quit | grep -q .; then
		echo "Error: generated build files found in Btrfs source $compat_root" >&2
		exit 1
	fi
	fingerprint=$(tar -C "$compat_root" --sort=name --mtime='@0' \
		--owner=0 --group=0 --numeric-owner -cf - fs/btrfs |
		sha256sum | cut -c1-12)
	printf '%s\t%s\n' "$compat_base" "$fingerprint" >> "$source_fingerprints"
done
sort -o "$source_fingerprints" "$source_fingerprints"
source_hash=$(sha256sum "$source_fingerprints" | cut -c1-8)

package_release=$(date -u +%Y%m%d.%H%M%S)
dkms_version="${kernel_base}+rebroad1.${package_release}.g${source_commit:0:12}.m${mapping_hash}.s${source_hash}"
package_version=$dkms_version
installed_version=$(dpkg-query -W -f='${Version}' btrfs-qgroup-dkms 2>/dev/null || true)
if [[ -n $installed_version ]] &&
	! dpkg --compare-versions "$package_version" gt "$installed_version"; then
	echo "Error: package version $package_version is not newer than installed $installed_version" >&2
	exit 1
fi
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
	"$package_root/usr/src/btrfs-qgroup-$dkms_version/kernel-sources/$kernel_base/fs/btrfs"
package_source_root="$package_root/usr/src/btrfs-qgroup-$dkms_version"
"$cpto_bin" --nogit --no-lngit "$source_root/fs/btrfs" \
	"$package_source_root/kernel-sources/$kernel_base/fs/btrfs"

qgroup_patch="$work_root/qgroup.patch"
git -C "$source_root" diff "v$kernel_base" HEAD -- \
	fs/btrfs/qgroup.c fs/btrfs/qgroup.h fs/btrfs/tests/qgroup-tests.c \
	> "$qgroup_patch"
if [[ ! -s $qgroup_patch ]]; then
	echo "Error: no qgroup patch found between v$kernel_base and HEAD" >&2
	exit 1
fi

for compat_base in "${!source_root_for_base[@]}"; do
	[[ $compat_base == "$kernel_base" ]] && continue
	compat_root=${source_root_for_base[$compat_base]}
	variant_root="$package_source_root/kernel-sources/$compat_base"
	mkdir -p "$variant_root/fs"
	cp -a "$compat_root/fs/btrfs" "$variant_root/fs/"
	patch --dry-run -p1 -d "$variant_root" < "$qgroup_patch" >/dev/null
	patch -p1 -d "$variant_root" < "$qgroup_patch" >/dev/null
done

install -m 0644 "$source_map" "$package_source_root/kernel-source-map"
install -m 0755 "$template_root/select-btrfs-source.sh" \
	"$package_source_root/select-btrfs-source.sh"

sed "s|@DKMS_VERSION@|$dkms_version|g" \
	"$template_root/dkms.conf.in" \
	> "$package_source_root/dkms.conf"
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
