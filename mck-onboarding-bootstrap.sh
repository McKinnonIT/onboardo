#!/bin/zsh
#
# mck-onboarding-bootstrap.sh
#
# Paste this into Mosyle as a Custom Script, triggered once at
# "Enrollment Complete" (root context, no GUI — that's fine, this script
# only copies files into place).
#
# It does NOT run the onboarding flow itself. Its only job is to drop
# two files onto the Mac:
#   - mck-onboarding.sh                 -> /Library/Application Support/McKinnon/
#   - mck-onboarding-launchagent.plist  -> /Library/LaunchAgents/
#
# The LaunchAgent then fires the actual onboarding script at the user's
# first login, into a real GUI session — see mck-onboarding.sh's own
# header comment ("HOW TO WIRE INTO MOSYLE") for why that split exists.
#
# Also worth pushing the swiftDialog .pkg via Mosyle separately (as a
# managed app) so it's already installed before first login — the
# onboarding script can self-install it if missing, but that adds a
# delay to the student's first login.
#
# ------------------------------------------------------------------------

set -u

INSTALL_DIR="/Library/Application Support/McKinnon"
REPO_RAW="https://raw.githubusercontent.com/McKinnonIT/onboardo/main"

mkdir -p "$INSTALL_DIR"

curl -sL --fail -o "${INSTALL_DIR}/mck-onboarding.sh" \
  "${REPO_RAW}/mck-onboarding.sh"
chmod +x "${INSTALL_DIR}/mck-onboarding.sh"

curl -sL --fail -o "/Library/LaunchAgents/com.mckinnonsc.onboarding.plist" \
  "${REPO_RAW}/mck-onboarding-launchagent.plist"
chown root:wheel "/Library/LaunchAgents/com.mckinnonsc.onboarding.plist"
chmod 644 "/Library/LaunchAgents/com.mckinnonsc.onboarding.plist"

exit 0
