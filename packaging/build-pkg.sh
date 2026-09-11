#!/bin/zsh
#
# build-pkg.sh
#
# Builds a single signed .pkg containing:
#   - mck-onboarding.sh (plain script copy) + mck-onboarding-daemon.sh +
#     mck-onboarding-launchdaemon.plist, installed to
#     /Library/Application Support/McKinnon and /Library/LaunchDaemons.
#     The daemon runs as root from boot, polls for a real console user,
#     then bridges the (unchanged) mck-onboarding.sh into that user's
#     session via `launchctl asuser ... sudo -u ...` — see
#     mck-onboarding-daemon.sh for the full reasoning.
#   - swiftDialog's own official release .pkg, bundled as a component so
#     this is the only thing Mosyle needs to push
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
PKG_VERSION="1.0"
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

DAEMON_PLIST_PATH="/Library/LaunchDaemons/${DAEMON_LABEL}.plist"

launchctl enable "system/${DAEMON_LABEL}" 2>/dev/null || true
launchctl bootout "system/${DAEMON_LABEL}" 2>/dev/null || true
launchctl bootstrap system "\$DAEMON_PLIST_PATH" 2>/dev/null || true

exit 0
POSTINSTALL_EOF

chmod +x "${SCRIPTS_DIR}/postinstall"

### ---------------------------------------------------------------------
### 2. Fetch swiftDialog's latest official release .pkg
### ---------------------------------------------------------------------
#
# swiftDialog ships its .pkg as a full "product archive" (built with
# productbuild, not pkgbuild) — that's not something productbuild can
# nest as a component inside another distribution package. It expands to
# a plain component package one level down, so pull that out and
# re-flatten it into a standalone component .pkg we CAN nest.

echo "Downloading latest swiftDialog release..."

SWIFTDIALOG_RAW_PKG="${BUILD_DIR}/swiftDialog-raw.pkg"
SWIFTDIALOG_PKG="${BUILD_DIR}/swiftDialog-component.pkg"
SWIFTDIALOG_URL=$(curl -sL "https://api.github.com/repos/swiftDialog/swiftDialog/releases/latest" \
  | grep "browser_download_url.*\.pkg" \
  | cut -d '"' -f 4)

if [[ -z "$SWIFTDIALOG_URL" ]]; then
  echo "ERROR: Could not resolve latest swiftDialog release URL." >&2
  exit 1
fi

curl -sL -o "$SWIFTDIALOG_RAW_PKG" "$SWIFTDIALOG_URL"

SWIFTDIALOG_EXPANDED="${BUILD_DIR}/swiftDialog-expanded"
pkgutil --expand "$SWIFTDIALOG_RAW_PKG" "$SWIFTDIALOG_EXPANDED"

INNER_COMPONENT=$(find "$SWIFTDIALOG_EXPANDED" -maxdepth 1 -name "*.pkg" | head -1)
if [[ -z "$INNER_COMPONENT" ]]; then
  echo "ERROR: Couldn't find an inner component package inside swiftDialog's release .pkg — its packaging format may have changed." >&2
  exit 1
fi

pkgutil --flatten "$INNER_COMPONENT" "$SWIFTDIALOG_PKG"

### ---------------------------------------------------------------------
### 3. pkgbuild the onboarding component
### ---------------------------------------------------------------------

echo "Building onboarding component package..."

APP_COMPONENT_PKG="${BUILD_DIR}/onboarding-app-component.pkg"

pkgbuild \
  --root "$APP_ROOT" \
  --scripts "$SCRIPTS_DIR" \
  --identifier "${DAEMON_LABEL}.pkg" \
  --version "$PKG_VERSION" \
  --install-location "/" \
  "$APP_COMPONENT_PKG"

### ---------------------------------------------------------------------
### 4. Combine both components into one distribution package
### ---------------------------------------------------------------------

echo "Combining into final distribution package..."

FINAL_PKG="${DIST_DIR}/McKinnonOnboarding-Installer.pkg"

if [[ "$UNSIGNED" == true ]]; then
  productbuild \
    --package "$APP_COMPONENT_PKG" \
    --package "$SWIFTDIALOG_PKG" \
    "$FINAL_PKG"
  echo "Built UNSIGNED package: $FINAL_PKG"
else
  productbuild \
    --package "$APP_COMPONENT_PKG" \
    --package "$SWIFTDIALOG_PKG" \
    --sign "$SIGNING_IDENTITY" \
    "$FINAL_PKG"
  echo "Built and signed package: $FINAL_PKG"
fi

echo ""
echo "Verify with:"
echo "  pkgutil --check-signature \"$FINAL_PKG\""
echo "  installer -pkg \"$FINAL_PKG\" -target / -dumplog"
