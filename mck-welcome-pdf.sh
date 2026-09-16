#!/bin/zsh
#
# mck-welcome-pdf.sh
#
# McKinnon Secondary College — standalone "welcome PDF" delivery, with NO
# dialog/UI dependency at all (no swiftDialog, no LaunchDaemon bridge).
# For devices/fleets that don't need the full mck-onboarding.sh walkthrough
# but should still get the info PDF on first login.
#
# Runs as the logged-in user via a plain LaunchAgent (see
# mck-welcome-pdf-launchagent.plist) — safe here specifically because all
# this does is call `open` on a file, which doesn't draw anything itself;
# it just asks Finder/Preview to open it in the user's own session. That's
# different from mck-onboarding.sh's swiftDialog windows, which is why
# THAT needs the heavier LaunchDaemon+bridge mechanism (see
# mck-onboarding-daemon.sh) instead of a plain LaunchAgent — a LaunchAgent
# never reliably got swiftDialog a real WindowServer connection in
# testing. `open` has no such issue.
#
# HOW TO TEST RIGHT NOW (ad hoc, as the logged-in user — NOT root; unlike
# mck-onboarding.sh, this never runs as root in production, so testing as
# root would exercise a path this script never actually takes)
#   chmod +x mck-welcome-pdf.sh
#   ./mck-welcome-pdf.sh --force
#
#   --force skips the "already run" marker check so you can re-run it as
#   many times as you like while iterating.
#
# HOW TO WIRE INTO MOSYLE
#   1. Build the installer: `packaging/build-pdf-pkg.sh`. It installs this
#      script to /Library/Application Support/McKinnon and
#      mck-welcome-pdf-launchagent.plist to /Library/LaunchAgents, with a
#      postinstall script that bootstraps it immediately into the current
#      console user's GUI session (if one is logged in already), rather
#      than waiting for their next login.
#   2. Push that .pkg to devices via Mosyle.
#   3. RunAtLoad fires this at every login for every user on the Mac
#      (LaunchAgents in /Library/LaunchAgents run per-user, for whoever's
#      logging in) — the marker file (per-user, under their own home)
#      guards against it re-running past the first time for each of them.
#
# ------------------------------------------------------------------------

set -u

CONSOLE_USER=$(stat -f "%Su" /dev/console)
CONSOLE_USER_HOME=$(dscl . -read "/Users/${CONSOLE_USER}" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
if [[ -z "$CONSOLE_USER_HOME" ]]; then
  CONSOLE_USER_HOME="/Users/${CONSOLE_USER}"
fi

### ---------------------------------------------------------------------
### CONFIG — edit these (kept in sync with mck-onboarding.sh's own PDF
### settings — same file, same source)
### ---------------------------------------------------------------------

DESKTOP_PDF_NAME="Welcome to your MacBook.pdf"
PDF_SOURCE_URL="https://raw.githubusercontent.com/McKinnonIT/onboardo/main/Welcome%20to%20your%20MacBook.pdf"

MARKER_DIR="${CONSOLE_USER_HOME}/Library/Application Support/McKinnon"
MARKER_FILE="${MARKER_DIR}/.welcome-pdf-complete"
LOG_FILE="${CONSOLE_USER_HOME}/Library/Logs/mck-welcome-pdf.log"
LOGGER_TAG="com.mckinnonsc.welcomepdf"

### ---------------------------------------------------------------------
### ARGS
### ---------------------------------------------------------------------

FORCE_RUN=false
for arg in "$@"; do
  case "$arg" in
    --force) FORCE_RUN=true ;;
  esac
done

### ---------------------------------------------------------------------
### LOGGING — same approach as mck-onboarding.sh: plain file + unified log
### ---------------------------------------------------------------------

mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null

log() {
  local message="$1"
  echo "$(date '+%Y-%m-%d %H:%M:%S') | $message" | tee -a "$LOG_FILE"
  logger -t "$LOGGER_TAG" "$message"
}

### ---------------------------------------------------------------------
### GUARD: already run?
### ---------------------------------------------------------------------

if [[ -f "$MARKER_FILE" && "$FORCE_RUN" == false ]]; then
  log "Welcome PDF already delivered to ${CONSOLE_USER} ($MARKER_FILE exists). Use --force to re-run."
  exit 0
fi

### ---------------------------------------------------------------------
### DOWNLOAD + OPEN
### ---------------------------------------------------------------------

DESKTOP_PDF_PATH="${CONSOLE_USER_HOME}/Desktop/${DESKTOP_PDF_NAME}"

log "Downloading info PDF from ${PDF_SOURCE_URL} to ${DESKTOP_PDF_PATH}"
if curl -sL --fail -o "$DESKTOP_PDF_PATH" "$PDF_SOURCE_URL" 2>> "$LOG_FILE"; then
  log "PDF downloaded successfully."
else
  log "ERROR: Failed to download info PDF (no network at login? repo moved/renamed?). Nothing to open — exiting."
  exit 1
fi

log "Opening info PDF for ${CONSOLE_USER}: ${DESKTOP_PDF_PATH}"
open "$DESKTOP_PDF_PATH" >> "$LOG_FILE" 2>&1

### ---------------------------------------------------------------------
### MARK COMPLETE
### ---------------------------------------------------------------------

mkdir -p "$MARKER_DIR"
date > "$MARKER_FILE"
log "Welcome PDF delivery complete. Marker written to $MARKER_FILE."

exit 0
