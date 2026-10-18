#!/bin/sh
set -eu

kernelver=${1:?usage: select-btrfs-source.sh KERNEL_RELEASE}
map_file=$(dirname "$0")/kernel-source-map
source_base=

while read -r mapped_kernel mapped_base; do
	case "$mapped_kernel" in
		''|\#*) continue ;;
	esac
	if [ "$mapped_kernel" = "$kernelver" ]; then
		if [ -n "$source_base" ]; then
			echo "Error: duplicate Btrfs source mapping for $kernelver" >&2
			exit 1
		fi
		source_base=$mapped_base
	fi
done < "$map_file"

if [ -z "$source_base" ]; then
	echo "Error: no matching Btrfs source is packaged for kernel $kernelver" >&2
	exit 1
fi

source_dir=$(dirname "$0")/kernel-sources/$source_base/fs/btrfs
if [ ! -f "$source_dir/Makefile" ]; then
	echo "Error: Btrfs source $source_base is missing for kernel $kernelver" >&2
	exit 1
fi

cp -a "$source_dir/." "$PWD/"
echo "Selected Btrfs $source_base source for kernel $kernelver"
