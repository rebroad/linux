#!/bin/sh
# Watch for uninterruptible tasks and capture their stacks immediately.

set -u

duration=300
interval=0.2
out=
while getopts 't:i:o:h' opt; do
	case "$opt" in
		t) duration=$OPTARG ;;
		i) interval=$OPTARG ;;
		o) out=$OPTARG ;;
		h)
			printf 'usage: %s [-t seconds] [-i seconds] [-o directory]\n' "$0"
			exit 0
			;;
		*) exit 2 ;;
	esac
done

if [ "$(id -u)" -ne 0 ]; then
	printf '%s\n' 'run this watcher as root' >&2
	exit 2
fi

stamp=$(date +%Y%m%dT%H%M%S%z)
[ -n "$out" ] || out=/var/tmp/btrfs-stall-watch-$stamp
umask 077
mkdir -p -- "$out" || exit 1
seen=$out/seen
: >"$seen"
printf 'started=%s\nduration=%s\ninterval=%s\n' \
	"$(date --iso-8601=seconds)" "$duration" "$interval" >"$out/metadata"
date +%s >"$out/start-epoch"
end=$(( $(cat "$out/start-epoch") + duration ))

capture_task()
{
	pid=$1
	tid=$2
	key=${pid}_${tid}
	taskdir=$out/task-$key
	if ! mkdir "$taskdir" 2>/dev/null; then
		return
	fi

	printf 'captured=%s\npid=%s\ntid=%s\n' \
		"$(date --iso-8601=seconds)" "$pid" "$tid" >"$taskdir/metadata"
	ps -eLo pid=,tid=,ppid=,stat=,wchan:32=,comm= >"$taskdir/tasks"
	cat "/proc/$pid/task/$tid/stack" >"$taskdir/stack" 2>&1 || true
	cat "/proc/$pid/task/$tid/status" >"$taskdir/status" 2>&1 || true
	cat /proc/loadavg >"$taskdir/loadavg"
	cat /proc/pressure/io >"$taskdir/pressure-io"
	cat /proc/pressure/memory >"$taskdir/pressure-memory"
	for stats in /sys/fs/btrfs/*/commit_stats; do
		[ -f "$stats" ] || continue
		fsid=$(basename "$(dirname "$stats")")
		cat "$stats" >"$taskdir/commit-stats-$fsid" 2>&1 || true
	done
	journalctl -k --since '30 seconds ago' --no-pager >"$taskdir/kernel-log" 2>&1 || true
}

while [ "$(date +%s)" -lt "$end" ]; do
	psfile=$out/tasks.current
	ps -eLo pid=,tid=,ppid=,stat=,wchan:32=,comm= >"$psfile"
	awk '$4 ~ /^D/ {print $1, $2}' "$psfile" |
	while read -r pid tid; do
		[ -n "${pid:-}" ] || continue
		key=$pid:$tid
		if grep -qxF "$key" "$seen"; then
			continue
		fi
		printf '%s\n' "$key" >>"$seen"
		capture_task "$pid" "$tid"
	done
	sleep "$interval"
done

printf 'finished=%s\n' "$(date --iso-8601=seconds)" >>"$out/metadata"
printf '%s\n' "$out"
