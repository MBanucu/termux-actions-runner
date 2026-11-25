#!/data/data/com.termux/files/usr/bin/bash
# Shared configuration and helpers. Sourced by the other scripts.
# shellcheck shell=bash

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

: "${RUNNER_DIR:=$HOME/actions-runner}"
: "${FAKE_ROOT:=$HOME/ghroot}"
: "${SHIM_DIR:=$HOME/glibc-shim}"
: "${GLIBC_DIR:=$PREFIX/glibc/lib}"
: "${GLIBC_LD:=$GLIBC_DIR/ld-linux-aarch64.so.1}"

: "${RUNNER_LABELS:=self-hosted,termux,android-arm64}"
: "${RUNNER_NAME:=$(getprop ro.product.model 2>/dev/null | tr ' ' '-')-termux}"
: "${RUNNER_WORK:=_work}"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
info() { printf '==> %s\n' "$*"; }

require_termux() {
	[ -n "${PREFIX:-}" ] && [ -d "${PREFIX:-}" ] || die "run this inside Termux"
	[ "$(uname -m)" = aarch64 ] || die "the runner binaries are arm64; this device reports $(uname -m)"
}

# The runner and its bundled node are glibc ELF; bionic has no glibc loader.
# node20/node24 matter as much as the listener: every JavaScript action runs on
# the bundled node, so actions/checkout breaks without them.
patch_glibc_binaries() {
	command -v patchelf >/dev/null 2>&1 || die "patchelf is missing: pkg install patchelf"
	[ -x "$GLIBC_LD" ] || die "glibc loader is missing: pkg install glibc glibc-runner"
	local rpath="$SHIM_DIR:$GLIBC_DIR:\$ORIGIN" f
	for f in bin/Runner.Listener bin/Runner.Worker bin/Runner.PluginHost \
		externals/node20/bin/node externals/node24/bin/node; do
		[ -f "$RUNNER_DIR/$f" ] || continue
		patchelf --set-interpreter "$GLIBC_LD" --set-rpath "$rpath" "$RUNNER_DIR/$f"
		info "patched $f"
	done
}

# One dependency asks for `libc.so`, which glibc ships as a text linker script.
# A shim directory with real symlinks satisfies it without touching the package.
make_shim_dir() {
	mkdir -p "$SHIM_DIR"
	local n
	for n in libc.so:libc.so.6 libm.so:libm.so.6 \
		libpthread.so:libpthread.so.0 libdl.so:libdl.so.2; do
		ln -sfn "$GLIBC_DIR/${n#*:}" "$SHIM_DIR/${n%%:*}"
	done
}

# .NET walks the parent chain of the runner directory and needs every entry to
# be listable; Android makes /data and / unlistable to an app uid. This fake
# root gives it a readable "/", and the bind mount in proot_exec keeps the real
# Termux tree at its usual absolute paths.
make_fake_root() {
	mkdir -p "$FAKE_ROOT"/{bin,usr/bin,data/data,tmp,proc,dev,sys,storage}
	chmod 1777 "$FAKE_ROOT/tmp"
	# Shebang support: the launch clears LD_PRELOAD, so termux-exec can no
	# longer rewrite "#!/bin/sh" and "#!/usr/bin/env bash" (gradlew relies on it).
	ln -sfn "$PREFIX/bin/sh" "$FAKE_ROOT/bin/sh"
	ln -sfn "$PREFIX/bin/bash" "$FAKE_ROOT/bin/bash"
	ln -sfn "$PREFIX/bin/env" "$FAKE_ROOT/usr/bin/env"
	ln -sfn "$PREFIX/bin/bash" "$FAKE_ROOT/usr/bin/bash"
}

# LD_PRELOAD carries termux-exec's bionic shim, which poisons every glibc
# binary, so both it and LD_LIBRARY_PATH are cleared before the listener starts.
proot_exec() {
	unset LD_PRELOAD LD_LIBRARY_PATH
	exec proot -r "$FAKE_ROOT" \
		-b /system:/system -b /apex:/apex -b /vendor:/vendor -b /product:/product \
		-b /proc:/proc -b /dev:/dev -b /sys:/sys -b /storage:/storage \
		-b /data/data/com.termux:/data/data/com.termux \
		-w "$RUNNER_DIR" "$@"
}
