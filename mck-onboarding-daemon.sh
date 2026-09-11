#!/bin/zsh
#
# mck-onboarding-daemon.sh
#
# Runs as root, via the companion LaunchDaemon
# (mck-onboarding-launchdaemon.plist), starting at boot — NOT tied to any
# specific login event, unlike a LaunchAgent. Its only job: wait for a
# real console user to actually appear, then bridge mck-onboarding.sh
# into THAT user's GUI session so swiftDialog gets a genuine WindowServer
# connection, using the same launchctl-asuser pattern real Mac admin
# tools (Jamf's "Setup Your Mac" family, etc) use to show GUI from a
# root-context script.
#
# mck-onboarding.sh itself needs NO changes for this — invoked via
# `sudo -u <user>`, `id -u` inside it correctly reports that user's UID,
# so its existing RUNNING_AS_ROOT branching already does the right thing.
#
# Why this exists: a plain LaunchAgent (RunAtLoad + LimitLoadToSessionType
# Aqua) should in theory fire correctly at login, but in testing it did
# not — the script executed (confirmed via logs) but swiftDialog never
# actually got a visible window, with no crash and no error. Never fully
# root-caused. This sidesteps the question entirely: launchctl asuser is
# the well-established mechanism specifically for bridging a root process
# into a real user's GUI session, rather than depending on launchd's own
# per-user agent-loading timing.
#
# ------------------------------------------------------------------------

set -u

ONBOARDING_SCRIPT="/Library/Application Support/McKinnon/mck-onboarding.sh"
LOG_FILE="/var/log/mck-onboarding-daemon.log"
POLL_INTERVAL=5

# The daemon can detect the console user right as the session starts,
# before Finder/Dock have finished drawing the desktop — this gives
# things a moment to settle so the dialog doesn't pop up mid-transition.
POST_DETECT_DELAY=10

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" | tee -a "$LOG_FILE"
  logger -t "com.mckinnonsc.onboarding.daemon" "$1"
}

log "Daemon started, waiting for a real console user to log in..."

while true; do
  CONSOLE_USER=$(stat -f "%Su" /dev/console 2>/dev/null)

  # Reject no-one-logged-in, the loginwindow itself, and system/service
  # accounts (Setup Assistant runs as one of these, e.g. _mbsetupuser,
  # before the actual primary user account exists) — Apple's convention
  # is a leading underscore for these.
  if [[ -n "$CONSOLE_USER" && "$CONSOLE_USER" != "root" && "$CONSOLE_USER" != "loginwindow" && "$CONSOLE_USER" != _* ]]; then
    break
  fi

  sleep "$POLL_INTERVAL"
done

log "Console user detected: ${CONSOLE_USER}. Waiting ${POST_DETECT_DELAY}s for the desktop to settle before bridging in."

sleep "$POST_DETECT_DELAY"

CONSOLE_UID=$(id -u "$CONSOLE_USER" 2>/dev/null)
if [[ -z "$CONSOLE_UID" ]]; then
  log "ERROR: Could not resolve a UID for ${CONSOLE_USER} — aborting."
  exit 1
fi

if [[ ! -f "$ONBOARDING_SCRIPT" ]]; then
  log "ERROR: ${ONBOARDING_SCRIPT} not found — aborting."
  exit 1
fi

launchctl asuser "$CONSOLE_UID" sudo -u "$CONSOLE_USER" /bin/zsh "$ONBOARDING_SCRIPT" >> "$LOG_FILE" 2>&1
EXIT_CODE=$?

log "Onboarding script finished with exit code ${EXIT_CODE}."
exit "$EXIT_CODE"
