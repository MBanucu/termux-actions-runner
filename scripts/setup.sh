#!/data/data/com.termux/files/usr/bin/bash
# Install the arm64 GitHub Actions runner into Termux and make it executable.
#
#   bash scripts/setup.sh                 # latest runner release
#   RUNNER_VERSION=2.338.2 bash scripts/setup.sh
set -euo pipefail

# shellcheck source=lib.sh
. "$(cd -- "$(dirname -- "$0")" && pwd)/lib.sh"

require_termux

info "installing Termux packages"
pkg install -y patchelf glibc glibc-runner libicu-glibc proot curl

if [ -z "${RUNNER_VERSION:-}" ]; then
	RUNNER_VERSION=$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest |
		sed -n 's/.*"tag_name":[[:space:]]*"v\([^"]*\)".*/\1/p' | head -1)
fi
[ -n "${RUNNER_VERSION:-}" ] || die "could not resolve the runner version; set RUNNER_VERSION"

info "runner version $RUNNER_VERSION in $RUNNER_DIR"
mkdir -p "$RUNNER_DIR"
cd "$RUNNER_DIR"
if [ ! -f bin/Runner.Listener ]; then
	curl -fsSL -o runner.tar.gz \
		"https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-arm64-${RUNNER_VERSION}.tar.gz"
	tar xzf runner.tar.gz
	rm -f runner.tar.gz
fi

make_shim_dir
patch_glibc_binaries
make_fake_root

if [ ! -f "$RUNNER_DIR/.env" ]; then
	cat >"$RUNNER_DIR/.env" <<-EOF
		ANDROID_HOME=${ANDROID_HOME:-$HOME/android-sdk}
		ANDROID_SDK_ROOT=${ANDROID_HOME:-$HOME/android-sdk}
		JAVA_HOME=${JAVA_HOME:-$PREFIX/lib/jvm/java-17-openjdk}
	EOF
	info "wrote $RUNNER_DIR/.env"
fi

info "verifying the listener"
unset LD_PRELOAD LD_LIBRARY_PATH
"$RUNNER_DIR/bin/Runner.Listener" --version

info "next: bash scripts/register.sh owner/repo"
