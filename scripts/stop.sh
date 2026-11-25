#!/data/data/com.termux/files/usr/bin/bash
# Stop the runner started by scripts/start.sh.
set -euo pipefail

# shellcheck source=lib.sh
. "$(cd -- "$(dirname -- "$0")" && pwd)/lib.sh"

PID_FILE="$RUNNER_DIR/runner.pid"
[ -f "$PID_FILE" ] || die "no $PID_FILE; is the runner running?"

PID=$(cat "$PID_FILE")
if kill -0 "$PID" 2>/dev/null; then
	kill -TERM "$PID" 2>/dev/null || true
	for _ in $(seq 1 20); do
		kill -0 "$PID" 2>/dev/null || break
		sleep 0.5
	done
	kill -0 "$PID" 2>/dev/null && kill -KILL "$PID" 2>/dev/null || true
	info "stopped pid $PID"
else
	info "pid $PID was not running"
fi

rm -f "$PID_FILE"
termux-wake-unlock 2>/dev/null || true
