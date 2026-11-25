#!/data/data/com.termux/files/usr/bin/bash
# Register the runner against a repository.
#
#   bash scripts/register.sh owner/repo
#   RUNNER_LABELS=self-hosted,termux bash scripts/register.sh owner/repo
#   bash scripts/register.sh owner/repo --token <registration-token>
#
# Without --token, a registration token is requested with the authenticated gh
# CLI. Tokens are single use and expire after an hour.
#
# config.sh is deliberately not used: it greps ldd/ldconfig output first, and
# bionic has neither, so it exits before configuring anything. Its only other
# job is `./bin/Runner.Listener configure "$@"`.
set -euo pipefail

# shellcheck source=lib.sh
. "$(cd -- "$(dirname -- "$0")" && pwd)/lib.sh"

require_termux
[ -f "$RUNNER_DIR/bin/Runner.Listener" ] || die "run scripts/setup.sh first"

REPO="${1:-}"
[ -n "$REPO" ] || die "usage: $0 owner/repo [--token TOKEN]"
shift

TOKEN=""
while [ $# -gt 0 ]; do
	case "$1" in
	--token)
		TOKEN="${2:-}"
		[ -n "$TOKEN" ] || die "--token needs a value"
		shift 2
		;;
	*) die "unknown argument: $1" ;;
	esac
done

if [ -z "$TOKEN" ]; then
	command -v gh >/dev/null 2>&1 || die "gh is not installed; pass --token instead"
	TOKEN=$(gh api -X POST "repos/$REPO/actions/runners/registration-token" --jq .token)
fi
[ -n "$TOKEN" ] || die "could not obtain a registration token for $REPO"

info "registering '$RUNNER_NAME' as $RUNNER_LABELS"
proot_exec "$RUNNER_DIR/bin/Runner.Listener" configure \
	--unattended --replace \
	--url "https://github.com/$REPO" \
	--token "$TOKEN" \
	--labels "$RUNNER_LABELS" \
	--name "$RUNNER_NAME" \
	--work "$RUNNER_WORK"

info "registered; start it with: bash scripts/start.sh"
