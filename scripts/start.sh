#!/data/data/com.termux/files/usr/bin/bash
# Start the runner detached, holding a Termux wake lock.
#
#   bash scripts/start.sh              # background it, write runner.pid
#   bash scripts/start.sh --foreground # what the backgrounded copy runs
set -euo pipefail

# shellcheck source=lib.sh
. "$(cd -- "$(dirname -- "$0")" && pwd)/lib.sh"

require_termux
[ -f "$RUNNER_DIR/.runner" ] || die "the runner is not registered: bash scripts/register.sh owner/repo"

PID_FILE="$RUNNER_DIR/runner.pid"

if [ "${1:-}" != "--foreground" ]; then
	if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
		die "already running (pid $(cat "$PID_FILE")); bash scripts/stop.sh first"
	fi
	make_fake_root
	# The listener stops the moment Android freezes Termux, so hold the lock.
	termux-wake-lock 2>/dev/null || true
	setsid nohup bash "$0" --foreground >>"$RUNNER_DIR/runner.log" 2>&1 </dev/null &
	echo $! >"$PID_FILE"
	info "started pid $(cat "$PID_FILE"); log: $RUNNER_DIR/runner.log"
	info "check it with: gh api repos/<owner>/<repo>/actions/runners"
	exit 0
fi

# proot_exec execs, so this PID is the one recorded above.
proot_exec "$RUNNER_DIR/bin/Runner.Listener" run
