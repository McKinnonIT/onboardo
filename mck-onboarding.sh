#!/bin/zsh
#
# mck-onboarding.sh
#
# McKinnon Secondary College — post-enrolment Mac onboarding walkthrough.
# Built on swiftDialog. MDM-agnostic: designed for Mosyle, but doesn't call
# any Mosyle-specific APIs, so you can test it standalone on any test Mac
# before wiring it into a Custom Command / policy.
#
# WHAT IT DOES
#   1. Installs swiftDialog if it isn't already present.
#   2. Shows a branded welcome screen.
#   3. Runs quick enrolment/Dock checks silently, then shows a minimal
#      app-install page (plain status list, pulsing progress bar) gated
#      on both apps landing in /Applications, rechecked every 3s.
#   4. Downloads the info PDF from this repo straight to the user's
#      Desktop, then shows a page pointing at it with more details about
#      their new MacBook.
#   5. Shows a final page confirming the Mac is ready to go, with a help
#      contact if anything needs attention — the moment this page is on
#      screen, it opens the info PDF and restarts the Dock, so both
#      happen last, after everything else has had the whole process to
#      roll out.
#   6. Writes a marker file so it only runs once per Mac (delete it to re-test).
#   7. If it was launched via the companion LaunchAgent, self-unloads and
#      deletes that LaunchAgent so it doesn't linger as a permanent
#      background item once its one job is done.
#
# HOW TO TEST RIGHT NOW (ad hoc, no LaunchAgent involved)
#   chmod +x mck-onboarding.sh
#   sudo ./mck-onboarding.sh --force
#
#   --force skips the "already run" marker check so you can re-run it
#   as many times as you like while iterating.
#
# HOW TO WIRE INTO MOSYLE — fire at first login via LaunchAgent
#   swiftDialog needs a real GUI session to draw its windows, and Mosyle's
#   "Enrollment Complete" trigger runs as root with no UI — so this has to
#   fire at the user's first *login*, via a LaunchAgent, not at enrolment
#   itself.
#
#   1. Ship two files to every enrolled Mac (Mosyle Custom Script/Command,
#      or a profile that drops files):
#        - this script       -> /Library/Application Support/McKinnon/mck-onboarding.sh
#        - the companion plist -> /Library/LaunchAgents/com.mckinnonsc.onboarding.plist
#      (see mck-onboarding-launchagent.plist in this repo — update the
#      ProgramArguments path in it if you install the script somewhere else.)
#      The info PDF itself is NOT shipped this way — it's pulled from
#      PDF_SOURCE_URL (this repo, raw.githubusercontent.com) at runtime,
#      so first login needs working internet for that step to succeed.
#      It fails soft (logs a warning, carries on) if it can't reach it.
#   2. Also ship the swiftDialog pkg, or let the script self-install it
#      (it will, the first time it runs, but that adds a delay to first
#      login — pre-installing it separately is smoother).
#   3. launchd loads the LaunchAgent at the user's next login and runs the
#      script in their session. RunAtLoad + LimitLoadToSessionType=Aqua
#      means it only fires once per login, and only into a real GUI
#      session (not e.g. the loginwindow itself).
#   4. The marker file (guard above) and the LaunchAgent self-cleanup
#      (step 7 above) both exist so a stray reload or repeat login never
#      re-runs onboarding — belt and braces.
#   - Swap the placeholder STEP commands below for your real fleet scripts
#     (dockutil config, profilecleaner, admin cleanup, etc).
#
# ------------------------------------------------------------------------

set -u

### ---------------------------------------------------------------------
### CONFIG — edit these
### ---------------------------------------------------------------------

ORG_NAME="McKinnon Secondary College"
ACCENT_COLOR="#0F216D"          # McKinnon Blue
LOGO_PATH="/Library/McKinnon/branding/logo.png"   # swap for a real path/URL; swiftDialog also accepts URLs and SF Symbols
HELP_EMAIL="help@mckinnonsc.vic.edu.au"          # placeholder — set your real helpdesk address
DESKTOP_PDF_NAME="Welcome to your MacBook.pdf"     # filename of the info PDF placed on the user's Desktop
# Downloaded fresh from this repo (public) each run and placed on the
# user's Desktop as $DESKTOP_PDF_NAME — the two filenames need to match.
PDF_SOURCE_URL="https://raw.githubusercontent.com/McKinnonIT/onboardo/main/Welcome%20to%20your%20MacBook.pdf"

MARKER_DIR="/Library/Application Support/McKinnon"
MARKER_FILE="${MARKER_DIR}/.onboarding-complete"
LOG_FILE="/var/log/mck-onboarding.log"

# Only relevant when this script is deployed via the companion LaunchAgent
# (see mck-onboarding-launchagent.plist) — used to self-unload and delete
# that agent after a successful run, so it never lingers as a permanent
# background item once its one job (firing at first login) is done.
LAUNCH_AGENT_LABEL="com.mckinnonsc.onboarding"
LAUNCH_AGENT_PLIST_PATH="/Library/LaunchAgents/${LAUNCH_AGENT_LABEL}.plist"

DIALOG_BIN="/usr/local/bin/dialog"
DIALOG_COMMAND_FILE="/var/tmp/mck-onboarding-command-$$.log"

# How long (seconds) to wait for the app-install gate before giving up and
# flagging it as needing attention on the completion screen, instead of
# hanging forever. Set to 0 to wait indefinitely.
POLL_TIMEOUT=1200        # 20 minutes
POLL_INTERVAL=3          # how often to re-check, in seconds

# Shared so every dialog page is the same size — swapping between
# differently-sized windows read as visually inconsistent.
DIALOG_WIDTH=640
DIALOG_HEIGHT=420

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
### LOGGING
### ---------------------------------------------------------------------

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" | tee -a "$LOG_FILE"
}

### ---------------------------------------------------------------------
### GUARD: already run?
### ---------------------------------------------------------------------

if [[ -f "$MARKER_FILE" && "$FORCE_RUN" == false ]]; then
  log "Onboarding already completed on this Mac ($MARKER_FILE exists). Use --force to re-run."
  exit 0
fi

### ---------------------------------------------------------------------
### ENSURE swiftDialog IS INSTALLED
### ---------------------------------------------------------------------

install_swiftdialog() {
  log "swiftDialog not found — installing latest release..."

  local pkg_url
  pkg_url=$(curl -sL "https://api.github.com/repos/swiftDialog/swiftDialog/releases/latest" \
    | grep "browser_download_url.*\.pkg" \
    | cut -d '"' -f 4)

  if [[ -z "$pkg_url" ]]; then
    log "ERROR: Could not resolve latest swiftDialog release URL. Aborting."
    exit 1
  fi

  local tmp_pkg="/tmp/swiftDialog.pkg"
  curl -sL -o "$tmp_pkg" "$pkg_url"
  installer -pkg "$tmp_pkg" -target / >> "$LOG_FILE" 2>&1
  rm -f "$tmp_pkg"

  if [[ ! -x "$DIALOG_BIN" ]]; then
    log "ERROR: swiftDialog install appears to have failed."
    exit 1
  fi

  log "swiftDialog installed successfully."
}

if [[ ! -x "$DIALOG_BIN" ]]; then
  install_swiftdialog
fi

### ---------------------------------------------------------------------
### BANNER / ICON — guaranteed-legible text
### ---------------------------------------------------------------------
#
# swiftDialog's --bannertitle overlay text is white, on the assumption
# there's a dark banner image behind it. Until a real (dark) logo asset
# exists at $LOGO_PATH, that leaves white-on-nothing — invisible. So:
#   - only pass --bannerimage if the file actually exists
#   - always force --bannertitlefont to a dark, on-brand colour so the
#     title stays readable regardless of what ends up behind it
# Once you drop a real logo in, double-check contrast — if it's a dark
# logo, this navy text will still read fine; if it's a light logo, bump
# --bannertitlefont colour to something light again.

typeset -a BANNER_ARGS
if [[ -f "$LOGO_PATH" ]]; then
  BANNER_ARGS=(--bannerimage "$LOGO_PATH")
else
  BANNER_ARGS=()
fi
BANNER_ARGS+=(--bannertitlefont "colour=${ACCENT_COLOR},weight=bold,size=26")

if [[ -f "$LOGO_PATH" ]]; then
  ICON_PATH="$LOGO_PATH"
else
  ICON_PATH="SF=laptopcomputer"
fi

### ---------------------------------------------------------------------
### SILENT PRE-CHECKS
###
### Quick, non-gating steps — logged only, not shown on screen, so they
### don't clutter the app-install page below. Swap the placeholder Dock
### command for your real dockutil script.
### ---------------------------------------------------------------------

ANY_FAILED=false

log "Running step: Checking enrolment status"
if profiles status -type enrollment | grep -q 'MDM enrollment: Yes'; then
  log "Step succeeded: Checking enrolment status"
else
  log "Step FAILED: Checking enrolment status"
  ANY_FAILED=true
fi

log "Running step: Applying Dock layout"
if sleep 2 && true; then   # placeholder for your dockutil script
  log "Step succeeded: Applying Dock layout"
else
  log "Step FAILED: Applying Dock layout"
  ANY_FAILED=true
fi

### ---------------------------------------------------------------------
### WELCOME SCREEN
### ---------------------------------------------------------------------

"$DIALOG_BIN" \
  --title "none" \
  "${BANNER_ARGS[@]}" \
  --bannertitle "Welcome to your new Mac" \
  --message "Hi! This Mac has just been enrolled with **${ORG_NAME}**.\n\nWe'll spend the next minute or two setting a few things up and confirming your device is ready to go. You don't need to do anything — just leave this window open." \
  --icon "$ICON_PATH" \
  --button1text "Let's Go" \
  --width "$DIALOG_WIDTH" --height "$DIALOG_HEIGHT" \
  --moveable \
  --ontop

### ---------------------------------------------------------------------
### APP-INSTALL PROGRESS DIALOG (backgrounded, driven via command file)
###
### A plain list of apps with their install status over a pulsing
### (indeterminate) progress bar. Gated on Mosyle actually pushing both
### apps down; this page won't move on until they're both present in
### /Applications. Re-checked every $POLL_INTERVAL seconds.
###
### Each row needs an "icon" key or swiftDialog's listitem row collapses
### to just the statustext with no title. Rather than a static placeholder,
### the icon itself starts as an empty circle and is flipped to a filled
### checkmark below the moment that specific app is actually found in
### /Applications — so the row visibly shows install state, not just text.
###
### One "--listitem" flag per row, each a "Title,key=value,..." string —
### confirmed against a live debug run to be the format swiftDialog's CLI
### actually supports. Passing a whole JSON array as one --listitem value
### (what an earlier version of this script did) isn't a supported CLI
### form — it silently mis-parses into a single garbled row with raw
### JSON text leaking into the title. The rich {"listitem": [...]} JSON
### schema documented on the wiki is only for --jsonstring/--jsonfile,
### which use a different, more restrictive top-level key set than the
### plain CLI flags used here, so it wasn't a drop-in fix either.
### ---------------------------------------------------------------------

: > "$DIALOG_COMMAND_FILE"

"$DIALOG_BIN" \
  --title "none" \
  "${BANNER_ARGS[@]}" \
  --bannertitle "Installing your apps" \
  --message "Hang tight while these finish installing. This page will move on automatically once both are ready." \
  --icon none \
  --progress \
  --progresstext "Installing..." \
  --listitem "Google Chrome,icon=SF=circle.dashed,status=wait,statustext=Installing..." \
  --listitem "Google Drive,icon=SF=circle.dashed,status=wait,statustext=Installing..." \
  --button1text "Please Wait" --button1disabled \
  --width "$DIALOG_WIDTH" --height "$DIALOG_HEIGHT" \
  --moveable \
  --ontop \
  --commandfile "$DIALOG_COMMAND_FILE" &

DIALOG_PID=$!
sleep 1   # give swiftDialog a moment to open before we start sending commands

log "Waiting for Google Chrome and Google Drive to install..."

CHROME_DONE=false
DRIVE_DONE=false
elapsed=0

while true; do
  if [[ "$CHROME_DONE" == false ]] && [[ -d "/Applications/Google Chrome.app" ]]; then
    CHROME_DONE=true
    echo "listitem: index: 0, icon: SF=checkmark.circle.fill, status: success, statustext: Installed" >> "$DIALOG_COMMAND_FILE"
  fi
  if [[ "$DRIVE_DONE" == false ]] && [[ -d "/Applications/Google Drive.app" ]]; then
    DRIVE_DONE=true
    echo "listitem: index: 1, icon: SF=checkmark.circle.fill, status: success, statustext: Installed" >> "$DIALOG_COMMAND_FILE"
  fi

  if [[ "$CHROME_DONE" == true && "$DRIVE_DONE" == true ]]; then
    break
  fi
  if [[ "$POLL_TIMEOUT" -gt 0 && "$elapsed" -ge "$POLL_TIMEOUT" ]]; then
    log "Timed out after ${POLL_TIMEOUT}s waiting for app install(s)."
    [[ "$CHROME_DONE" == false ]] && echo "listitem: index: 0, icon: SF=xmark.circle.fill, status: fail, statustext: Timed out" >> "$DIALOG_COMMAND_FILE"
    [[ "$DRIVE_DONE" == false ]] && echo "listitem: index: 1, icon: SF=xmark.circle.fill, status: fail, statustext: Timed out" >> "$DIALOG_COMMAND_FILE"
    ANY_FAILED=true
    break
  fi

  mins=$(( elapsed / 60 ))
  secs=$(( elapsed % 60 ))
  echo "progresstext: Installing... (${mins}m${secs}s)" >> "$DIALOG_COMMAND_FILE"

  sleep "$POLL_INTERVAL"
  elapsed=$(( elapsed + POLL_INTERVAL ))
done

if [[ "$CHROME_DONE" == true && "$DRIVE_DONE" == true ]]; then
  log "Google Chrome and Google Drive are both installed."
  echo "progresstext: All done!" >> "$DIALOG_COMMAND_FILE"
else
  echo "progresstext: Still finishing up — continuing anyway." >> "$DIALOG_COMMAND_FILE"
fi

echo "progress: complete" >> "$DIALOG_COMMAND_FILE"
sleep 1
echo "button1text: Continue" >> "$DIALOG_COMMAND_FILE"
echo "button1: enable" >> "$DIALOG_COMMAND_FILE"

wait "$DIALOG_PID"
rm -f "$DIALOG_COMMAND_FILE"

### ---------------------------------------------------------------------
### PDF INFO PAGE
### ---------------------------------------------------------------------
#
# Downloads the info PDF from the (public) repo straight to the logged-in
# user's Desktop — no separate MDM push of the file needed, just this
# script + the LaunchAgent. Resolves the console user's home directory
# rather than assuming $HOME, since this script may run as root (testing
# via sudo, or an enrolment-time policy) rather than in the user's own
# session (the LaunchAgent path described in the README).

CONSOLE_USER=$(stat -f "%Su" /dev/console)
CONSOLE_USER_HOME=$(dscl . -read "/Users/${CONSOLE_USER}" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
if [[ -z "$CONSOLE_USER_HOME" ]]; then
  CONSOLE_USER_HOME="/Users/${CONSOLE_USER}"
fi
DESKTOP_PDF_PATH="${CONSOLE_USER_HOME}/Desktop/${DESKTOP_PDF_NAME}"

log "Downloading info PDF from ${PDF_SOURCE_URL} to ${DESKTOP_PDF_PATH}"
if curl -sL --fail -o "$DESKTOP_PDF_PATH" "$PDF_SOURCE_URL" 2>> "$LOG_FILE"; then
  chown "$CONSOLE_USER" "$DESKTOP_PDF_PATH" 2>> "$LOG_FILE"
  log "PDF downloaded successfully."
else
  log "WARNING: Failed to download info PDF (no network at first login? repo moved/renamed?) — the info page still shows, but opening it automatically on the final page won't find anything."
fi

"$DIALOG_BIN" \
  --title "none" \
  "${BANNER_ARGS[@]}" \
  --bannertitle "One more thing" \
  --message "We've left a short PDF on your Desktop called **${DESKTOP_PDF_NAME}** with more information about your new MacBook Neo.\n\nIt'll open automatically when the setup process is complete." \
  --icon "SF=doc.text.fill,colour=${ACCENT_COLOR}" \
  --button1text "Got it" \
  --width "$DIALOG_WIDTH" --height "$DIALOG_HEIGHT" \
  --moveable --ontop

### ---------------------------------------------------------------------
### COMPLETION SCREEN (+ FINAL DOCK RESTART, + PDF AUTO-OPEN)
### ---------------------------------------------------------------------
#
# The Dock restart and the PDF auto-open both happen once this last page
# is actually on screen, rather than before — so they kick in while the
# user is reading the final message instead of adding a silent pause
# beforehand. The Dock restart is still the last thing that touches the
# Dock, after everything else has had a chance to land (app installs,
# Dock layout, etc), so it picks up config that's had the whole process
# to roll out.

if [[ "$ANY_FAILED" == true ]]; then
  "$DIALOG_BIN" \
    --title "none" \
    "${BANNER_ARGS[@]}" \
    --bannertitle "Almost there" \
    --message "Your Mac is mostly set up, but one or more checks need attention.\n\nThis is nothing to worry about — please contact IT and mention this device's name so we can take a look:\n\n**${HELP_EMAIL}**" \
    --icon "SF=exclamationmark.triangle.fill,colour=#DDA004" \
    --button1text "Close" \
    --width "$DIALOG_WIDTH" --height "$DIALOG_HEIGHT" \
    --moveable --ontop &
else
  "$DIALOG_BIN" \
    --title "none" \
    "${BANNER_ARGS[@]}" \
    --bannertitle "You're all set!" \
    --message "Your Mac has been configured and is ready to use.\n\nIf you need assistance, please reach out to McKinnon IT at **${HELP_EMAIL}**" \
    --icon "SF=checkmark.circle.fill,colour=${ACCENT_COLOR}" \
    --button1text "Finish" \
    --width "$DIALOG_WIDTH" --height "$DIALOG_HEIGHT" \
    --moveable --ontop &
fi

COMPLETION_DIALOG_PID=$!
sleep 1   # give swiftDialog a moment to open before we restart the Dock / open the PDF

log "Opening info PDF for ${CONSOLE_USER}: ${DESKTOP_PDF_PATH}"
sudo -u "$CONSOLE_USER" open "$DESKTOP_PDF_PATH" >> "$LOG_FILE" 2>&1

log "Restarting Dock (final step, after all config has had time to roll out)"
killall Dock 2>> "$LOG_FILE" || log "NOTE: killall Dock returned non-zero — Dock may not have been running yet."

wait "$COMPLETION_DIALOG_PID"

### ---------------------------------------------------------------------
### MARK COMPLETE
### ---------------------------------------------------------------------

mkdir -p "$MARKER_DIR"
date > "$MARKER_FILE"
log "Onboarding complete. Marker written to $MARKER_FILE."

### ---------------------------------------------------------------------
### SELF-CLEANUP: unload + delete the LaunchAgent, if that's how we got here
### ---------------------------------------------------------------------
#
# Only relevant when deployed via the companion LaunchAgent — a plain
# `sudo ./mck-onboarding.sh --force` test run won't have it installed, so
# this is a no-op there. Backgrounded with a short delay and disowned so
# it survives this script's own exit — we're unloading the very launchd
# job that's running us, which would otherwise race the parent process.

if [[ -f "$LAUNCH_AGENT_PLIST_PATH" ]]; then
  log "Onboarding LaunchAgent found at ${LAUNCH_AGENT_PLIST_PATH} — scheduling self-unload so it doesn't linger."
  (
    sleep 2
    CONSOLE_UID=$(id -u "$CONSOLE_USER" 2>/dev/null)
    if [[ -n "$CONSOLE_UID" ]]; then
      launchctl bootout "gui/${CONSOLE_UID}/${LAUNCH_AGENT_LABEL}" >> "$LOG_FILE" 2>&1
    fi
    rm -f "$LAUNCH_AGENT_PLIST_PATH"
    echo "$(date '+%Y-%m-%d %H:%M:%S') | Onboarding LaunchAgent unloaded and removed." >> "$LOG_FILE"
  ) &
  disown
fi

exit 0
