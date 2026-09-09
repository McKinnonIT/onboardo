#!/bin/zsh
#
# build-pkg.sh
#
# Builds a single signed .pkg containing:
#   - McKinnon Onboarding.app  (wraps mck-onboarding.sh, unchanged)
#   - mck-onboarding-launchagent.plist, installed to /Library/LaunchAgents
#     — fires the app at first login via RunAtLoad. A postinstall script
#     also launchctl-bootstraps it immediately if a console user is
#     already logged in when the pkg installs, rather than only relying
#     on a future login.
#   - swiftDialog's own official release .pkg, bundled as a third
#     component so this is the only thing Mosyle needs to push
#
# IMPORTANT: this LaunchAgent needs a Background Task Management MDM
# profile (com.apple.servicemanagement payload) with a rule approving it,
# or macOS will silently block it pending manual user approval:
#   RuleType: Label
#   RuleValue: com.mckinnonsc.onboarding
# (No TeamIdentifier — the agent launches a plain script via /bin/zsh,
# not a Team-signed binary, so that constraint doesn't apply here.)
# Mosyle's own "run app at login" feature was tried first and dropped —
# its own delivery channel to the device was too slow to land before
# first login, which is exactly the failure mode this sidesteps by
# shipping the LaunchAgent in the same pkg as everything else instead of
# through a separate, slower Mosyle-side mechanism.
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

APP_NAME="McKinnon Onboarding"
APP_EXECUTABLE="McKinnonOnboarding"
BUNDLE_ID="com.mckinnonsc.onboarding"
PKG_VERSION="1.0"
SIGNING_IDENTITY="Developer ID Installer: Alastair Ling (G8AMUBLDT2)"

BUILD_DIR="${SCRIPT_DIR}/build"
DIST_DIR="${SCRIPT_DIR}/dist"
APP_ROOT="${BUILD_DIR}/app-root"
APP_BUNDLE="${APP_ROOT}/Applications/${APP_NAME}.app"
LAUNCH_AGENT_DEST="${APP_ROOT}/Library/LaunchAgents/${BUNDLE_ID}.plist"
SCRIPTS_DIR="${BUILD_DIR}/scripts"

UNSIGNED=false
for arg in "$@"; do
  case "$arg" in
    --unsigned) UNSIGNED=true ;;
  esac
done

rm -rf "$BUILD_DIR" "$DIST_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$(dirname "$LAUNCH_AGENT_DEST")"
mkdir -p "$SCRIPTS_DIR"
mkdir -p "$DIST_DIR"

### ---------------------------------------------------------------------
### 1. Build the .app bundle around mck-onboarding.sh
### ---------------------------------------------------------------------

echo "Building ${APP_NAME}.app..."

cp "${REPO_ROOT}/mck-onboarding.sh" "${APP_BUNDLE}/Contents/MacOS/${APP_EXECUTABLE}"
chmod +x "${APP_BUNDLE}/Contents/MacOS/${APP_EXECUTABLE}"

cat > "${APP_BUNDLE}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleIdentifier</key>
	<string>${BUNDLE_ID}</string>
	<key>CFBundleExecutable</key>
	<string>${APP_EXECUTABLE}</string>
	<key>CFBundleName</key>
	<string>${APP_NAME}</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>${PKG_VERSION}</string>
	<key>CFBundleVersion</key>
	<string>${PKG_VERSION}</string>
	<key>LSMinimumSystemVersion</key>
	<string>12.0</string>
	<!-- No Dock icon / app switcher entry — swiftDialog provides the
	     visible UI, this is just the driver. -->
	<key>LSUIElement</key>
	<true/>
</dict>
</plist>
EOF

# Ad-hoc signed (no Developer ID Application cert available at build time)
# — fine for MDM-pushed installs, which don't set the quarantine flag
# that triggers Gatekeeper's stricter "identified developer" check. Get
# a proper Developer ID Application cert and swap this for a real
# identity if this ever needs to be distributed outside MDM.
codesign --force --deep --sign - "$APP_BUNDLE"

### ---------------------------------------------------------------------
### 1b. Add the LaunchAgent + its postinstall (immediate-bootstrap) script
### ---------------------------------------------------------------------

echo "Adding LaunchAgent..."

cp "${REPO_ROOT}/mck-onboarding-launchagent.plist" "$LAUNCH_AGENT_DEST"
chmod 644 "$LAUNCH_AGENT_DEST"

cat > "${SCRIPTS_DIR}/postinstall" <<POSTINSTALL_EOF
#!/bin/zsh
#
# Runs as root, immediately after this component installs. The plist is
# now in place for RunAtLoad to pick up at the NEXT login, but if a
# console user is already logged in right now (installed after Setup
# Assistant handed off, not before), bootstrap it into their session
# immediately instead of waiting on a login that might not happen again
# for a long time on a single-user device. Errors here (already
# bootstrapped, no console user yet) are harmless — RunAtLoad still
# covers the normal case.

PLIST_PATH="/Library/LaunchAgents/${BUNDLE_ID}.plist"
CONSOLE_USER=\$(stat -f "%Su" /dev/console)

if [[ -n "\$CONSOLE_USER" && "\$CONSOLE_USER" != "root" && "\$CONSOLE_USER" != "loginwindow" ]]; then
  CONSOLE_UID=\$(id -u "\$CONSOLE_USER" 2>/dev/null)
  if [[ -n "\$CONSOLE_UID" ]]; then
    launchctl bootstrap "gui/\${CONSOLE_UID}" "\$PLIST_PATH" 2>/dev/null || true
  fi
fi

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
### 3. pkgbuild the app component
### ---------------------------------------------------------------------

echo "Building app component package..."

APP_COMPONENT_PKG="${BUILD_DIR}/onboarding-app-component.pkg"

pkgbuild \
  --root "$APP_ROOT" \
  --scripts "$SCRIPTS_DIR" \
  --identifier "${BUNDLE_ID}.pkg" \
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
