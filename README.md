# termux-actions-runner

Run the official **arm64 GitHub Actions self-hosted runner** inside Termux on an
Android device, so an `aarch64` job runs on real phone hardware instead of an
emulated x86_64 VM.

This is not a wrapper around PRoot Ubuntu. The runner and every job step execute
with the **Termux** toolchain: Termux's `bash`, Termux's JDK, Termux's Android
SDK, Termux's `aapt2`. PRoot is used only to give the .NET listener a readable
`/`, which Android otherwise denies (see [Why this is not just `./run.sh`](#why-this-is-not-just-runsh)).

Verified on: Blackview XPLORE 2, Android 15, `arm64-v8a`, Termux, runner
`2.338.2`, GitHub-hosted-independent jobs building an Android app with Gradle
and installing/testing it over adb on the same device.

## Requirements

* Android device, `uname -m` → `aarch64` (arm64-v8a).
* Termux from F-Droid or GitHub releases (the Play Store build is outdated).
* ~2 GB free in Termux home and network access.
* A repository you administer, and `gh` authenticated in Termux
  (`pkg install gh && gh auth login`).

## Quick start

```bash
git clone https://github.com/MBanucu/termux-actions-runner
cd termux-actions-runner

# 1. Install the runner, its glibc dependencies and the fake root.
bash scripts/setup.sh

# 2. Register it against a repo. Labels default to self-hosted,termux,android-arm64.
bash scripts/register.sh owner/repo

# 3. Start it detached, holding a wake lock.
bash scripts/start.sh
```

Then check that GitHub sees it:

```bash
gh api repos/owner/repo/actions/runners \
  --jq '.runners[] | "\(.name) \(.status) \(.labels | map(.name) | join(","))"'
```

```
xplore2-termux online self-hosted,Linux,ARM64,termux,android-arm64
```

A workflow picks it up with:

```yaml
runs-on: [self-hosted, android-arm64]
```

## Why this is not just `./run.sh`

Two Android-specific problems, both solved by `scripts/setup.sh`:

**1. The runner is a glibc binary and Termux is bionic.**
`actions-runner-linux-arm64-*.tar.gz` needs `ld-linux-aarch64.so.1`, so it dies
with `cannot execute: required file not found`. Install Termux's `glibc` package
and repoint each executable at that loader:

```bash
patchelf --set-interpreter "$PREFIX/glibc/lib/ld-linux-aarch64.so.1" \
         --set-rpath "$SHIM_DIR:$PREFIX/glibc/lib:\$ORIGIN" \
         bin/Runner.Listener bin/Runner.Worker bin/Runner.PluginHost \
         externals/node20/bin/node externals/node24/bin/node
```

The bundled `node20`/`node24` must be patched too — every JavaScript action
(`actions/checkout`, `upload-artifact`, …) runs on them.

A shim directory is needed because one dependency asks for `libc.so`, which
glibc ships as a *text* linker script, not an ELF:

```bash
mkdir -p "$SHIM_DIR"
for n in libc.so:libc.so.6 libm.so:libm.so.6 libpthread.so:libpthread.so.0 libdl.so:libdl.so.2; do
  ln -sfn "$PREFIX/glibc/lib/${n#*:}" "$SHIM_DIR/${n%%:*}"
done
```

Also install `libicu-glibc`; the listener aborts with *"Couldn't find a valid ICU
package"* without it.

**2. .NET refuses to start when a parent directory is unreadable.**
The listener validates its own path:

```
An error occurred: Permission to read the directory contents is required for
'/data/data/com.termux/files/home/actions-runner' and each directory up the
hierarchy. Access to the path '/data/data' is denied.
```

Android makes `/data` and `/` unlistable to an app uid, and there is no Termux
path that avoids them (`/data/user/0` is `dr-x--x--x` too). The fix is a tiny
fake root for PRoot: its `/` is a normal readable directory we own, while a bind
mount keeps the real Termux tree at its usual absolute paths.

```
$FAKE_ROOT/
  bin/sh -> $PREFIX/bin/sh          # gradlew's "#!/bin/sh"
  usr/bin/env -> $PREFIX/bin/env    # "#!/usr/bin/env bash"
  data/data/com.termux              # bind: the real app data dir
```

and

```bash
proot -r "$FAKE_ROOT" \
  -b /system:/system -b /apex:/apex -b /vendor:/vendor -b /product:/product \
  -b /proc:/proc -b /dev:/dev -b /sys:/sys -b /storage:/storage \
  -b /data/data/com.termux:/data/data/com.termux \
  -w "$RUNNER_DIR" "$RUNNER_DIR/bin/Runner.Listener" run
```

The `/bin/sh` link matters because the launch clears `LD_PRELOAD`: Termux's
`termux-exec` normally rewrites `#!/bin/sh` to Termux's shell, and without it
Gradle fails with `gradlew: /bin/sh: bad interpreter`.

### `config.sh` is not used

`config.sh` greps `ldd`/`ldconfig` output to check .NET dependencies; bionic has
neither, so it exits with *"Can not find 'ldd'"* before doing anything. Its only
other action is `./bin/Runner.Listener configure "$@"`, so `scripts/register.sh`
calls that directly.

## Keeping it running

Android kills background processes aggressively. `scripts/start.sh`:

* takes a `termux-wake-lock` (the Termux notification must stay visible),
* starts the listener with `setsid nohup` so it survives the SSH/shell session,
* records a PID file for `scripts/stop.sh`.

To survive reboots, install the Termux:Boot add-on and drop a script in
`~/.termux/boot/` that runs `bash ~/termux-actions-runner/scripts/start.sh`.
Also exempt Termux from battery optimisation in Android settings.

## Job environment

`setup.sh` writes `$RUNNER_DIR/.env`, which the runner exports into every job:

```bash
ANDROID_HOME=$HOME/android-sdk
ANDROID_SDK_ROOT=$HOME/android-sdk
JAVA_HOME=$PREFIX/lib/jvm/java-17-openjdk
```

Edit it to match your SDK/JDK. Because jobs inherit Termux's `PATH`, `java`,
`gradle`, `adb`, `python` and friends resolve to the Termux packages.

## Device state for UI jobs

An instrumented UI test needs the device awake, unlocked and unobstructed — a
keyguard or an open notification shade sits above the activity and
`bringToFront`-style assertions fail with the app apparently running. Note that
`dumpsys user | grep State:` reporting `RUNNING_UNLOCKED` does *not* mean the
keyguard is dismissed; check `dumpsys window | grep mDreamingLockscreen`
instead. Over adb:

```bash
adb shell input keyevent KEYCODE_WAKEUP
adb shell input keyevent 82            # MENU raises the PIN bouncer; without it
                                       # `input text` has no focused field and is
                                       # silently discarded
adb shell input swipe 720 2600 720 900 200   # real resolution, not the 1080 default
adb shell input text "$PIN"            # PIN-only keyguard
adb shell input keyevent 66
adb shell settings put system screen_off_timeout 2147483647   # keep it awake
adb shell dumpsys window | grep mDreamingLockscreen          # want: false
```

Two traps while checking this remotely. `dumpsys window | grep mCurrentFocus`
keeps reporting `NotificationShade` on the keyguard, so it cannot tell you
whether the unlock worked — watch `mDreamingLockscreen` instead. And
`adb exec-out screencap -p` returns an all-black frame while a secure keyguard
is up (the surface is marked secure), so a black screenshot means "keyguard
still showing", not "screen off" unless `dumpsys power` also says `Asleep`.

A workflow can do all of this itself, which is what unattended runs need: the
consuming project's `e2e-arm64.yml` has a *Wake and unlock the device* step that
reads the PIN from a `DEVICE_PIN` secret, fails loudly if `mDreamingLockscreen`
is still `true`, and stops once the keyguard is down — so a `workflow_dispatch`
no longer depends on somebody having picked the phone up.

After unlocking, keep the screen from timing out again — a re-lock re-arms the
keyguard and fails the UI phase mid-run:

```bash
# on the phone, detached: poke the screen every 15s
while :; do adb shell input keyevent KEYCODE_WAKEUP >/dev/null 2>&1; sleep 15; done
```

## Android kills large process trees

Android 12+ kills the children an app spawns once the tree exceeds the phantom
process limit (32 by default). A Gradle build plus instrumentation plus adb goes
far past that, and the kill is silent: the listener and every child disappear,
the job dies minutes in, and GitHub only reports *"The self-hosted runner lost
communication with the server"*. Nothing is logged, because nothing got a chance
to log. Disable the monitor once per device, over adb:

```bash
adb shell settings put global settings_enable_monitor_phantom_procs false
adb shell settings get global settings_enable_monitor_phantom_procs   # false
```

If a job still vanishes, check `ps -A | grep -c proot` on the phone right after
the failure: zero means everything was killed, rather than a step failing.

## Limitations

* **PRoot overhead.** Every syscall in the runner's process tree is traced.
  Gradle builds pay a few percent; heavy I/O jobs pay more. Jobs still use the
  native aarch64 CPU and the real Android runtime.
* **Live with `WARNING: linker: ... /linkerconfig/ld.config.txt`.** `/linkerconfig`
  is SELinux-protected and cannot be bound into the fake root. It is noise; the
  linker falls back to its default configuration.
* **No Docker, no service containers.** Not available in Termux.
* **One job per device** at a time; a runner is single-slot.
* **`patchelf` is reapplied when the runner self-updates.** Disable automatic
  updates (`./config.sh --disableupdate`) or re-run `scripts/setup.sh` after an
  update, otherwise the listener reverts to the glibc interpreter path and stops
  with `required file not found`.

## Verified

Both gates of a real Android/Termux project were run through a runner set up
with exactly these steps, on a Blackview XPLORE 2 (aarch64, Android 15):

| gate | runner label | run | result |
|---|---|---|---|
| Termux smoke build | `termux` | [45603965036](https://github.com/MBanucu/opencode-termux-setup/actions/runs/45603965036) | success, `BUILD SUCCESSFUL in 1m 18s`, `termux-smoke-apks` artifact |
| full e2e on device | `android-arm64` | [45614207488](https://github.com/MBanucu/opencode-termux-setup/actions/runs/45614207488) | success in 3m 12s: instrumented UI suite, real install/uninstall (62 s / 34 s), pty and adb-endpoint tests all passed |

The e2e gate is the interesting one: it does not just compile. It boots the
app on the phone, drives it through instrumentation, and the device has to stay
awake and unlocked for the whole UI phase (see above).

## Security

A self-hosted runner executes whatever a workflow in that repository contains,
on your phone, with your Termux files. Only register it on repositories you
control, and never let a public repository run fork pull requests on it. Keep
the `termux`/`android-arm64` jobs opt-in behind a repository variable, as the
consuming workflows in this workspace do, so a missing runner leaves the job
queued rather than green.

## Troubleshooting

| symptom | cause / fix |
|---|---|
| `cannot execute: required file not found` | interpreter not patched: re-run `scripts/setup.sh`, or the runner updated itself — see Limitations |
| `Couldn't find a valid ICU package` | `pkg install libicu-glibc` |
| `invalid ELF header` for `.../libc.so` | missing shim directory |
| `Permission to read the directory contents ... Access to the path '/' is denied` | listener started without `proot -r "$FAKE_ROOT"` |
| `gradlew: /bin/sh: bad interpreter` | fake root lacks `bin/sh` |
| runner goes offline after a while | wake lock released / battery optimisation; see Keeping it running |
| job dies minutes in, runner vanishes, nothing in the log | Android phantom-process killer; see Android kills large process trees |
| UI tests fail in `bringToFront` while the app is visibly running | device locked or notification shade open; see Device state for UI jobs |
| `Can not find 'ldd'` | running `config.sh`; use `scripts/register.sh` |
