#!/bin/zsh
#
# build-pkg.sh
#
# Builds a single signed .pkg containing mck-onboarding.sh (plain script
# copy) + mck-onboarding-daemon.sh + mck-onboarding-launchdaemon.plist,
# installed to /Library/Application Support/McKinnon and
# /Library/LaunchDaemons. The daemon runs as root from boot, polls for a
# real console user, then bridges the (unchanged) mck-onboarding.sh into
# that user's session via `launchctl asuser ... sudo -u ...` — see
# mck-onboarding-daemon.sh for the full reasoning.
#
# swiftDialog itself is NOT bundled in here — push its own official
# release .pkg (https://github.com/swiftDialog/swiftDialog/releases) to
# Mosyle separately, same as this one. An earlier version of this bundled
# both into one combined .pkg for a single upload; reverted 2026-09-14
# after that combined package repeatedly hit "Killed: 9" /
# corrupted-download failures pushing it through Mosyle (almost certainly
# because swiftDialog's own Dialog.app dominates the size — ~20MB of the
# combined pkg's ~21MB total) and swiftDialog's own self-linking
# postinstall step (which creates /usr/local/bin/dialog) failed silently
# on at least one real device as a result. Two small, independent
# packages are far less likely to hit either problem than one large one,
# and since this only gets set up in Mosyle occasionally rather than
# re-uploaded constantly, the two-upload inconvenience is a good trade
# for the reliability.
#
# An earlier version of this also shipped a LaunchAgent + app bundle as a
# second, parallel trigger mechanism. Removed 2026-09-11 after confirming
# the LaunchDaemon works on a real fresh enrollment — running both caused
# onboarding to fire twice (once via the Daemon bridging in early, once
# via the Agent's own RunAtLoad once the desktop finished loading), since
# the first run hadn't written its marker file yet by the time the second
# one started (the whole flow takes a while, waiting on Chrome/Drive).
#
# Deployment mechanism history:
#   1. Hand-rolled LaunchAgent + separate Mosyle bootstrap script — failed
#      with EX_CONFIG/exit-78 (StandardOutPath under /var/log, which a
#      standard user — what LaunchAgents always run as — can't write to).
#   2. Mosyle's "run app at login" feature — failed: its own delivery
#      channel for the login-item config was too slow, consistently
#      missing first login.
#   3. Mosyle's Background Task Management (zip upload + launchd config)
#      — hit an unexplained "Unknown error" in Mosyle's own console,
#      never resolved.
#   4. Current: LaunchDaemon bundled into this pkg, pushed through the
#      same plain-pkg-push channel already used for swiftDialog. Confirmed
#      working on a real fresh, supervised enrollment.
#
# IMPORTANT: this LaunchDaemon may still need Background Task Management
# approval (com.apple.servicemanagement payload) on some devices — the
# confirmation test wasn't run on an MDM-supervised Mac, so that gate was
# never actually exercised. If a real device silently blocks it:
#   RuleType: Label
#   RuleValue: com.mckinnonsc.onboarding.daemon
# (No TeamIdentifier — this launches a plain script via /bin/zsh, not a
# Team-signed binary.)
#
# Run this from anywhere; it resolves paths relative to the repo root.
#
# Requires a "Developer ID Installer" certificate in the login keychain
# to sign the final package (see SIGNING_IDENTITY below) — without one,
# pass --unsigned to produce an unsigned .pkg instead.
#
# ------------------------------------------------------------------------

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

DAEMON_LABEL="com.mckinnonsc.onboarding.daemon"
PKG_VERSION="2.1"
SIGNING_IDENTITY="Developer ID Installer: Alastair Ling (G8AMUBLDT2)"

BUILD_DIR="${SCRIPT_DIR}/build"
DIST_DIR="${SCRIPT_DIR}/dist"
APP_ROOT="${BUILD_DIR}/app-root"
SCRIPTS_DIR="${BUILD_DIR}/scripts"

MCKINNON_DIR="${APP_ROOT}/Library/Application Support/McKinnon"
ONBOARDING_SCRIPT_DEST="${MCKINNON_DIR}/mck-onboarding.sh"
DAEMON_SCRIPT_DEST="${MCKINNON_DIR}/mck-onboarding-daemon.sh"
LAUNCH_DAEMON_DEST="${APP_ROOT}/Library/LaunchDaemons/${DAEMON_LABEL}.plist"

UNSIGNED=false
for arg in "$@"; do
  case "$arg" in
    --unsigned) UNSIGNED=true ;;
  esac
done

# Fail fast with a clear message instead of hitting an opaque productbuild
# error at the very end of the build. `security find-identity` only lists
# an identity here if the cert AND its matching private key are both
# present in a keychain on the current login keychain search list — a
# cert imported by itself (e.g. downloading the .cer from the developer
# portal without ever generating/keeping the CSR's private key on this
# Mac) shows up in `security find-certificate` but NOT here, which is a
# common way this shows up.
if [[ "$UNSIGNED" == false ]]; then
  if ! security find-identity -v -p basic 2>/dev/null | grep -qF "$SIGNING_IDENTITY"; then
    echo "ERROR: Signing identity \"$SIGNING_IDENTITY\" not found (or has no matching private key) in any keychain on the search list." >&2
    echo "Run \`security find-identity -v -p basic\` to see what's actually usable, or pass --unsigned to build without signing." >&2
    exit 1
  fi
fi

rm -rf "$BUILD_DIR" "$DIST_DIR"
mkdir -p "$MCKINNON_DIR"
mkdir -p "$(dirname "$LAUNCH_DAEMON_DEST")"
mkdir -p "$SCRIPTS_DIR"
mkdir -p "$DIST_DIR"

### ---------------------------------------------------------------------
### 1. Add the onboarding scripts + LaunchDaemon
### ---------------------------------------------------------------------

echo "Adding onboarding scripts + LaunchDaemon..."

cp "${REPO_ROOT}/mck-onboarding.sh" "$ONBOARDING_SCRIPT_DEST"
chmod +x "$ONBOARDING_SCRIPT_DEST"

cp "${REPO_ROOT}/mck-onboarding-daemon.sh" "$DAEMON_SCRIPT_DEST"
chmod +x "$DAEMON_SCRIPT_DEST"

cp "${REPO_ROOT}/mck-onboarding-launchdaemon.plist" "$LAUNCH_DAEMON_DEST"
chmod 644 "$LAUNCH_DAEMON_DEST"

cat > "${SCRIPTS_DIR}/postinstall" <<POSTINSTALL_EOF
#!/bin/zsh
#
# Runs as root, immediately after this component installs. RunAtLoad
# only fires when launchd itself (re)starts, which doesn't happen on a
# plain pkg install — bootstrap it into the system domain explicitly so
# it starts polling for a console user right away rather than waiting
# for the next reboot.
#
# A reinstall/redeploy onto a device that's already had this pkg on it
# before can leave the label registered-but-disabled from an earlier
# attempt, which makes a plain "bootstrap" fail with "Bootstrap failed:
# 5: Input/output error" — confirmed hitting this in testing. enable +
# bootout first, ignoring failures (nothing to enable/bootout on a
# genuinely fresh device), then bootstrap.
#
# Every launchctl call here used to swallow its result entirely
# (2>/dev/null || true) — meaning a silent bootstrap failure (e.g. an
# MDM-supervised device not yet approving this via Background Task
# Management) looked identical to success, with zero evidence anywhere.
# Confirmed hitting exactly this on a real device: the daemon only
# started after a manual reboot, and there was nothing in any log to
# show why the immediate bootstrap hadn't worked. Logging the actual
# result of each step now, plus a final \`launchctl print\` check to
# confirm whether the daemon is actually loaded — if BTM is blocking it,
# this is the only place that'll show it.

POSTINSTALL_LOG="/var/log/mck-onboarding-postinstall.log"
DAEMON_PLIST_PATH="/Library/LaunchDaemons/${DAEMON_LABEL}.plist"

plog() {
  echo "\$(date '+%Y-%m-%d %H:%M:%S') | \$1" | tee -a "\$POSTINSTALL_LOG"
}

plog "postinstall starting for ${DAEMON_LABEL}"
plog "enable: \$(launchctl enable "system/${DAEMON_LABEL}" 2>&1; echo "exit=\$?")"
plog "bootout: \$(launchctl bootout "system/${DAEMON_LABEL}" 2>&1; echo "exit=\$?")"
plog "bootstrap: \$(launchctl bootstrap system "\$DAEMON_PLIST_PATH" 2>&1; echo "exit=\$?")"

if launchctl print "system/${DAEMON_LABEL}" >/dev/null 2>&1; then
  plog "Confirmed loaded immediately: system/${DAEMON_LABEL} is registered with launchd."
else
  plog "WARNING: system/${DAEMON_LABEL} is NOT registered with launchd after bootstrap — likely blocked (e.g. Background Task Management approval pending on a supervised device). It will only start at the next full boot via RunAtLoad."
fi

exit 0
POSTINSTALL_EOF

chmod +x "${SCRIPTS_DIR}/postinstall"

### ---------------------------------------------------------------------
### 2. Build the signed pkg
### ---------------------------------------------------------------------

echo "Building onboarding package..."

# Versioned filename (not just versioned pkg identifier/version) so a
# rebuild uploads as a genuinely new file to Mosyle's CDN, rather than
# replacing the bytes behind the same filename/reference — this mattered
# while tracking down a corrupted-download issue and is cheap to keep.
FINAL_PKG="${DIST_DIR}/McKinnonOnboarding-Installer-${PKG_VERSION}.pkg"

if [[ "$UNSIGNED" == true ]]; then
  pkgbuild \
    --root "$APP_ROOT" \
    --scripts "$SCRIPTS_DIR" \
    --identifier "${DAEMON_LABEL}.pkg" \
    --version "$PKG_VERSION" \
    --install-location "/" \
    "$FINAL_PKG"
  echo "Built UNSIGNED package: $FINAL_PKG"
else
  pkgbuild \
    --root "$APP_ROOT" \
    --scripts "$SCRIPTS_DIR" \
    --identifier "${DAEMON_LABEL}.pkg" \
    --version "$PKG_VERSION" \
    --install-location "/" \
    --sign "$SIGNING_IDENTITY" \
    "$FINAL_PKG"
  echo "Built and signed package: $FINAL_PKG"
fi

echo ""
echo "Verify with:"
echo "  pkgutil --check-signature \"$FINAL_PKG\""
echo "  installer -pkg \"$FINAL_PKG\" -target / -dumplog"
