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
# swiftDialog is pushed via Mosyle separately as a managed app, so it's
# already installed before first login (the onboarding script can
# self-install it if it's somehow still missing, but that adds a delay
# to the student's first login).
#
# TIMING GOTCHA: with Automated Device Enrollment, this script (triggered
# by "Enrollment Complete") often runs during or right after the Setup
# Assistant's own automatic first login — i.e. AFTER that login's launchd
# session has already started. RunAtLoad only fires when launchd loads a
# session's agents, which it doesn't redo retroactively just because a
# new plist appeared on disk. Relying on RunAtLoad alone risks the agent
# sitting there doing nothing until some hypothetical second login. So:
# if a real console user is already logged in by the time this runs,
# bootstrap the agent into their session immediately, right here, rather
# than only waiting for next time.
#
# ------------------------------------------------------------------------

set -u

INSTALL_DIR="/Library/Application Support/McKinnon"
REPO_RAW="https://raw.githubusercontent.com/McKinnonIT/onboardo/main"
PLIST_PATH="/Library/LaunchAgents/com.mckinnonsc.onboarding.plist"

mkdir -p "$INSTALL_DIR"

curl -sL --fail -o "${INSTALL_DIR}/mck-onboarding.sh" \
  "${REPO_RAW}/mck-onboarding.sh"
chmod +x "${INSTALL_DIR}/mck-onboarding.sh"

curl -sL --fail -o "$PLIST_PATH" \
  "${REPO_RAW}/mck-onboarding-launchagent.plist"
chown root:wheel "$PLIST_PATH"
chmod 644 "$PLIST_PATH"

CONSOLE_USER=$(stat -f "%Su" /dev/console)
if [[ -n "$CONSOLE_USER" && "$CONSOLE_USER" != "root" && "$CONSOLE_USER" != "loginwindow" ]]; then
  CONSOLE_UID=$(id -u "$CONSOLE_USER" 2>/dev/null)
  if [[ -n "$CONSOLE_UID" ]]; then
    launchctl bootstrap "gui/${CONSOLE_UID}" "$PLIST_PATH"
  fi
fi

exit 0
