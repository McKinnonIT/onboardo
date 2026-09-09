#!/bin/zsh
#
# build-pkg.sh
#
# Builds a single signed .pkg containing:
#   - McKinnon Onboarding.app  (wraps mck-onboarding.sh — same script,
#     same RUNNING_AS_ROOT logic, just packaged as an app bundle so
#     Mosyle's "run at login" feature can target it directly, instead of
#     us hand-rolling a LaunchAgent plist)
#   - swiftDialog's own official release .pkg, bundled as a second
#     component so this is the only thing Mosyle needs to push
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

UNSIGNED=false
for arg in "$@"; do
  case "$arg" in
    --unsigned) UNSIGNED=true ;;
  esac
done

rm -rf "$BUILD_DIR" "$DIST_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
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
