#!/bin/sh
# Capture evidence for a live Btrfs stall without changing filesystem state.

set -u

if [ "$(id -u)" -ne 0 ]; then
	printf '%s\n' 'run this collector as root' >&2
	exit 2
fi

stamp=$(date +%Y%m%dT%H%M%S%z)
out=${1:-/var/tmp/btrfs-stall-capture-$stamp}
umask 077
if ! mkdir -p -- "$out"; then
	printf 'cannot create output directory: %s\n' "$out" >&2
	exit 1
fi

run() {
	name=$1
	shift
	"$@" >"$out/$name" 2>&1 ||
		printf 'command failed (%s): %s\n' "$name" "$*" >>"$out/commands.failed"
}

run metadata sh -c '
	date --iso-8601=seconds
	uname -a
	cat /proc/loadavg
	cat /proc/pressure/io
	cat /proc/pressure/memory
	cat /proc/sys/kernel/sysrq
	findmnt -t btrfs -o TARGET,SOURCE,OPTIONS
'

run tasks ps -eLo pid=,tid=,ppid=,stat=,wchan:32=,comm=
run vmstat vmstat 1 5
run iostat sh -c 'command -v iostat >/dev/null 2>&1 && iostat -xz 1 3 || true'
run kernel-log-before journalctl -k --since '10 minutes ago' --no-pager

if command -v btrfs >/dev/null 2>&1; then
	for path in / /mnt/kingston; do
		name=$(printf '%s' "$path" | sed 's#^/##; s#[^A-Za-z0-9_.-]#_#g')
		[ -n "$name" ] || name=root
		run "${name}-rescan" btrfs quota rescan -s "$path"
		run "${name}-usage" btrfs filesystem usage -T "$path"
		run "${name}-device-stats" btrfs device stats "$path"
	done
fi

sysrq=$(cat /proc/sys/kernel/sysrq 2>/dev/null || printf 0)
printf 'sysrq_before=%s\n' "$sysrq" >"$out/sysrq"
case "$sysrq" in
	*[!0-9]*)
		printf 'sysrq_w=not-attempted-invalid-setting\n' >>"$out/sysrq" ;;
	*)
		if [ $((sysrq & 128)) -ne 0 ]; then
			if printf w >/proc/sysrq-trigger 2>/dev/null; then
				printf '%s\n' 'sysrq_w=triggered' >>"$out/sysrq"
			else
				printf '%s\n' 'sysrq_w=failed' >>"$out/sysrq"
			fi
		else
			printf '%s\n' 'sysrq_w=not-enabled' >>"$out/sysrq"
		fi
esac

run kernel-log-after journalctl -k --since '10 seconds ago' --no-pager

# Capture stacks for tasks which are currently uninterruptible.  SysRq-W has
# already printed a wider kernel-side view into the log; these files preserve
# the individual stacks when procfs permits reading them.
awk '$4 ~ /^D/ {print $1, $2}' "$out/tasks" |
while read -r pid tid; do
	[ -n "$pid" ] || continue
	safe=${pid}_${tid}
	if [ -r "/proc/$pid/task/$tid/stack" ]; then
		cat "/proc/$pid/task/$tid/stack" >"$out/stack-$safe" 2>&1 || true
	fi
done

printf '%s\n' "$out"
