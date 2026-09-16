#!/bin/zsh
#
# mck-dock-config.sh
#
# McKinnon Secondary College — Dock first-login setup, as a genuinely
# independent script. Not a pkg, no LaunchAgent/LaunchDaemon of its own —
# deploy it directly as a Mosyle Custom Script instead (see below).
# Unlike the Dock steps built into mck-onboarding.sh and
# mck-welcome-pdf.sh, this doesn't get to assume anything about GUI
# readiness or Chrome's install state by the time it runs, since nothing
# upstream of it has already confirmed those — it checks for itself.
#
# Same DOCK_APPS list as mck-onboarding.sh's and mck-welcome-pdf.sh's own
# Dock steps, kept in sync by hand. Unlike those two, this one has NO
# "already run" guard — it reconfigures the Dock on every single login,
# continuously enforcing the layout rather than setting it up once and
# leaving it alone. Don't deploy this alongside mck-onboarding.sh's or
# mck-welcome-pdf.sh's own Dock steps on the same fleet — those are
# one-time, this one actively fights any rearranging a student does, so
# running both is at best redundant and at worst confusing about which
# one "wins."
#
# WHAT IT DOES
#   Configures the Dock at every login — students can rearrange it in a
#   session, but it resets back to this layout the next time they log in.
#
# HOW TO TEST RIGHT NOW (ad hoc, as root — this always runs as root in
# production too, via Mosyle's Custom Script mechanism, so this is the
# one script in this repo where testing via sudo matches production
# exactly)
#   chmod +x mck-dock-config.sh
#   sudo ./mck-dock-config.sh
#
# HOW TO WIRE INTO MOSYLE
#   1. Deploy dockutil itself first, as its own separate app/package:
#        https://github.com/kcrawford/dockutil/releases
#      (installs the binary to /usr/local/bin/dockutil)
#   2. Upload this script as a Custom Script in Mosyle.
#      Trigger: "Login" (recurring), Execution context: root.
#      Recurring here means what it says — this runs and reconfigures
#      the Dock at every login, not just until some marker's written. If
#      Chrome or Dock/Finder aren't ready yet on one pass, it exits
#      non-zero and just tries again next login same as always.
#
# ------------------------------------------------------------------------

set -u

### ---------------------------------------------------------------------
### CONFIG — edit these (kept in sync with mck-onboarding.sh's and
### mck-welcome-pdf.sh's own Dock settings — same values, three files)
### ---------------------------------------------------------------------

DOCKUTIL_BIN="/usr/local/bin/dockutil"
DOCK_APPS=(
  "/System/Applications/Apps.app"
  "/Applications/Manager.app"
  "/Applications/Google Chrome.app"
)

LOG_FILE="/var/log/mck-dock-config.log"
LOGGER_TAG="com.mckinnonsc.dockconfig"

# How long (seconds) to wait for Chrome, then separately for Dock/Finder,
# before giving up on this pass and letting the recurring Login trigger
# catch it next time — not indefinite, since a Custom Script firing at
# every login shouldn't hang around forever if something's genuinely
# wrong on a given device.
CHROME_WAIT_TIMEOUT=30
CHROME_WAIT_INTERVAL=2
DOCK_READY_TIMEOUT=60
DOCK_READY_INTERVAL=2

### ---------------------------------------------------------------------
### LOGGING — same approach as the other two scripts: plain file + unified log
### ---------------------------------------------------------------------

log() {
  local message="$1"
  echo "$(date '+%Y-%m-%d %H:%M:%S') | $message" | tee -a "$LOG_FILE"
  logger -t "$LOGGER_TAG" "$message"
}

### ---------------------------------------------------------------------
### IDENTIFY THE ACTUAL CONSOLE USER (this script runs as root via Mosyle)
### ---------------------------------------------------------------------

CONSOLE_USER=$(stat -f "%Su" /dev/console 2>/dev/null)

if [[ -z "$CONSOLE_USER" || "$CONSOLE_USER" == "root" || "$CONSOLE_USER" == "loginwindow" || "$CONSOLE_USER" == _* ]]; then
  log "No real console user logged in yet. Exiting quietly — will retry next login."
  exit 0
fi

CONSOLE_UID=$(id -u "$CONSOLE_USER" 2>/dev/null)
CONSOLE_USER_HOME=$(dscl . -read "/Users/${CONSOLE_USER}" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
if [[ -z "$CONSOLE_UID" || -z "$CONSOLE_USER_HOME" || ! -d "$CONSOLE_USER_HOME" ]]; then
  log "ERROR: Could not resolve UID/home directory for ${CONSOLE_USER}. Exiting."
  exit 1
fi

### ---------------------------------------------------------------------
### SANITY CHECK: dockutil actually installed?
### ---------------------------------------------------------------------

if [[ ! -x "$DOCKUTIL_BIN" ]]; then
  log "dockutil not found at ${DOCKUTIL_BIN} — deploy its package first. Exiting — will retry next login."
  exit 1
fi

### ---------------------------------------------------------------------
### WAIT FOR GOOGLE CHROME (deploys via its own Mosyle package and may
### land after this script first fires)
### ---------------------------------------------------------------------

CHROME_APP="/Applications/Google Chrome.app"
CHROME_READY=false
waited=0
log "Checking for Google Chrome..."
while [[ "$waited" -lt "$CHROME_WAIT_TIMEOUT" ]]; do
  if [[ -d "$CHROME_APP" ]]; then
    CHROME_READY=true
    break
  fi
  sleep "$CHROME_WAIT_INTERVAL"
  waited=$(( waited + CHROME_WAIT_INTERVAL ))
done

if [[ "$CHROME_READY" == false ]]; then
  log "Google Chrome not found at ${CHROME_APP} yet. Exiting — will retry next login."
  exit 1
fi

### ---------------------------------------------------------------------
### HELPER: run a command as the logged-in user, in their GUI session
### ---------------------------------------------------------------------

run_as_console_user() {
  launchctl asuser "$CONSOLE_UID" sudo -u "$CONSOLE_USER" "$@"
}

### ---------------------------------------------------------------------
### WAIT FOR DOCK + FINDER TO ACTUALLY BE ALIVE FOR THIS USER
### ---------------------------------------------------------------------

DOCK_READY=false
waited=0
log "Waiting for Dock and Finder to start for ${CONSOLE_USER}..."
while [[ "$waited" -lt "$DOCK_READY_TIMEOUT" ]]; do
  if run_as_console_user pgrep -x Dock >/dev/null 2>&1 && run_as_console_user pgrep -x Finder >/dev/null 2>&1; then
    DOCK_READY=true
    break
  fi
  sleep "$DOCK_READY_INTERVAL"
  waited=$(( waited + DOCK_READY_INTERVAL ))
done

if [[ "$DOCK_READY" == false ]]; then
  log "Dock/Finder never came up for ${CONSOLE_USER} within timeout. Exiting — will retry next login."
  exit 1
fi

### ---------------------------------------------------------------------
### CONFIGURE THE DOCK
### ---------------------------------------------------------------------

log "Configuring Dock for ${CONSOLE_USER}..."

run_as_console_user "$DOCKUTIL_BIN" --remove all --no-restart
for dock_app in "${DOCK_APPS[@]}"; do
  run_as_console_user "$DOCKUTIL_BIN" --add "$dock_app" --no-restart
done
run_as_console_user "$DOCKUTIL_BIN" --add "$CONSOLE_USER_HOME" --view grid --display folder --no-restart

run_as_console_user killall Dock

log "Dock configured for ${CONSOLE_USER}."
exit 0
