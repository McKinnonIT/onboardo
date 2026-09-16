#!/bin/zsh
#
# build-pdf-pkg.sh
#
# Builds a single signed .pkg for the standalone "welcome PDF" flow
# (mck-welcome-pdf.sh) — no swiftDialog, no LaunchDaemon/bridge, just a
# LaunchAgent that downloads the info PDF and opens it on first login.
# Separate from build-pkg.sh (the full onboarding walkthrough) entirely
# on purpose — see mck-welcome-pdf.sh's own header for why a plain
# LaunchAgent is safe to use here when it wasn't for the swiftDialog flow.
#
# Run this from anywhere; it resolves paths relative to the repo root.
#
# Requires a "Developer ID Installer" certificate (with its matching
# private key) in the login keychain to sign the final package — check
# with `security find-identity -v -p basic`. Pass --unsigned to produce
# an unsigned .pkg instead.
#
# ------------------------------------------------------------------------

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

AGENT_LABEL="com.mckinnonsc.welcomepdf"
PKG_VERSION="1.0"
SIGNING_IDENTITY="Developer ID Installer: Alastair Ling (G8AMUBLDT2)"

BUILD_DIR="${SCRIPT_DIR}/build-pdf"
DIST_DIR="${SCRIPT_DIR}/dist"
APP_ROOT="${BUILD_DIR}/app-root"
SCRIPTS_DIR="${BUILD_DIR}/scripts"

MCKINNON_DIR="${APP_ROOT}/Library/Application Support/McKinnon"
PDF_SCRIPT_DEST="${MCKINNON_DIR}/mck-welcome-pdf.sh"
LAUNCH_AGENT_DEST="${APP_ROOT}/Library/LaunchAgents/${AGENT_LABEL}.plist"

UNSIGNED=false
for arg in "$@"; do
  case "$arg" in
    --unsigned) UNSIGNED=true ;;
  esac
done

# Fail fast with a clear message instead of an opaque pkgbuild error at
# the very end of the build — see build-pkg.sh's own check for the full
# reasoning (a cert imported without its matching private key shows up in
# `security find-certificate` but not here).
if [[ "$UNSIGNED" == false ]]; then
  if ! security find-identity -v -p basic 2>/dev/null | grep -qF "$SIGNING_IDENTITY"; then
    echo "ERROR: Signing identity \"$SIGNING_IDENTITY\" not found (or has no matching private key) in any keychain on the search list." >&2
    echo "Run \`security find-identity -v -p basic\` to see what's actually usable, or pass --unsigned to build without signing." >&2
    exit 1
  fi
fi

rm -rf "$BUILD_DIR"
mkdir -p "$MCKINNON_DIR"
mkdir -p "$(dirname "$LAUNCH_AGENT_DEST")"
mkdir -p "$SCRIPTS_DIR"
mkdir -p "$DIST_DIR"

### ---------------------------------------------------------------------
### 1. Add the script + LaunchAgent
### ---------------------------------------------------------------------

echo "Adding mck-welcome-pdf.sh + LaunchAgent..."

cp "${REPO_ROOT}/mck-welcome-pdf.sh" "$PDF_SCRIPT_DEST"
chmod +x "$PDF_SCRIPT_DEST"

cp "${REPO_ROOT}/mck-welcome-pdf-launchagent.plist" "$LAUNCH_AGENT_DEST"
chmod 644 "$LAUNCH_AGENT_DEST"

cat > "${SCRIPTS_DIR}/postinstall" <<POSTINSTALL_EOF
#!/bin/zsh
#
# Runs as root, immediately after this component installs. RunAtLoad
# alone only fires the NEXT time this LaunchAgent's session type
# reloads (i.e. the console user's next login) — if a user is already
# logged in when this pkg installs, bootstrap it into their GUI session
# right now too, the same immediate-bootstrap approach build-pkg.sh
# uses for the onboarding LaunchDaemon (see its postinstall for the full
# reasoning on enable+bootout-first / logging every result rather than
# swallowing failures).

POSTINSTALL_LOG="/var/log/mck-welcome-pdf-postinstall.log"
AGENT_PLIST_PATH="/Library/LaunchAgents/${AGENT_LABEL}.plist"

plog() {
  echo "\$(date '+%Y-%m-%d %H:%M:%S') | \$1" | tee -a "\$POSTINSTALL_LOG"
}

CONSOLE_USER=\$(stat -f "%Su" /dev/console 2>/dev/null)

if [[ -z "\$CONSOLE_USER" || "\$CONSOLE_USER" == "root" || "\$CONSOLE_USER" == "loginwindow" || "\$CONSOLE_USER" == _* ]]; then
  plog "No real console user logged in yet — ${AGENT_LABEL} will load naturally at next login via RunAtLoad. Nothing to bootstrap now."
  exit 0
fi

CONSOLE_UID=\$(id -u "\$CONSOLE_USER" 2>/dev/null)
if [[ -z "\$CONSOLE_UID" ]]; then
  plog "WARNING: Could not resolve a UID for \$CONSOLE_USER — skipping immediate bootstrap. Will still load at next login."
  exit 0
fi

plog "postinstall starting for ${AGENT_LABEL}, console user \${CONSOLE_USER} (uid \${CONSOLE_UID})"
plog "enable: \$(launchctl enable "gui/\${CONSOLE_UID}/${AGENT_LABEL}" 2>&1; echo "exit=\$?")"
plog "bootout: \$(launchctl bootout "gui/\${CONSOLE_UID}/${AGENT_LABEL}" 2>&1; echo "exit=\$?")"
plog "bootstrap: \$(launchctl bootstrap "gui/\${CONSOLE_UID}" "\$AGENT_PLIST_PATH" 2>&1; echo "exit=\$?")"

if launchctl print "gui/\${CONSOLE_UID}/${AGENT_LABEL}" >/dev/null 2>&1; then
  plog "Confirmed loaded immediately: gui/\${CONSOLE_UID}/${AGENT_LABEL} is registered with launchd."
else
  plog "WARNING: gui/\${CONSOLE_UID}/${AGENT_LABEL} is NOT registered with launchd after bootstrap. It will only start at \${CONSOLE_USER}'s next login via RunAtLoad."
fi

exit 0
POSTINSTALL_EOF

chmod +x "${SCRIPTS_DIR}/postinstall"

### ---------------------------------------------------------------------
### 2. Build the signed pkg
### ---------------------------------------------------------------------

echo "Building welcome-PDF package..."

# Versioned filename, not just the pkg's internal version — see
# build-pkg.sh's own comment for why (uploads as a genuinely new file to
# Mosyle's CDN on every rebuild).
FINAL_PKG="${DIST_DIR}/McKinnonWelcomePDF-Installer-${PKG_VERSION}.pkg"

if [[ "$UNSIGNED" == true ]]; then
  pkgbuild \
    --root "$APP_ROOT" \
    --scripts "$SCRIPTS_DIR" \
    --identifier "${AGENT_LABEL}.pkg" \
    --version "$PKG_VERSION" \
    --install-location "/" \
    "$FINAL_PKG"
  echo "Built UNSIGNED package: $FINAL_PKG"
else
  pkgbuild \
    --root "$APP_ROOT" \
    --scripts "$SCRIPTS_DIR" \
    --identifier "${AGENT_LABEL}.pkg" \
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
