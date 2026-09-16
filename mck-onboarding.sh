#!/bin/zsh
#
# mck-onboarding.sh
#
# McKinnon Secondary College — post-enrolment Mac onboarding walkthrough.
# Built on swiftDialog. MDM-agnostic: designed for Mosyle, but doesn't call
# any Mosyle-specific APIs, so you can test it standalone on any test Mac
# before wiring it into a Custom Command / policy.
#
# IMPORTANT — this script runs as ROOT when you test it with `sudo`, but
# as the STANDARD, LOGGED-IN USER (never root) when the companion
# LaunchDaemon bridges it into that user's session at first login (see
# packaging/) — `launchctl asuser <uid> sudo -u <user>` runs it as that
# user, not as the root daemon invoking it. RUNNING_AS_ROOT below
# branches on this everywhere it matters (log/marker file locations,
# chown, sudo -u, swiftDialog self-install). If you add a new step that
# writes to disk or needs elevated privilege, it needs the same branch —
# a standard user has no write access to /Library or /var/log, and no
# sudo.
#
# (Two other deployment mechanisms were tried and dropped before this
# one — a LaunchAgent, and Mosyle's own "run app at login" feature — see
# packaging/build-pkg.sh's header for the full history. The LaunchAgent
# approach is why RUNNING_AS_ROOT existed in the first place; that
# reasoning didn't change when the trigger mechanism did.)
#
# WHAT IT DOES
#   1. Installs swiftDialog if it isn't already present (shouldn't be
#      needed in production — see packaging/ below).
#   2. Shows a branded welcome screen.
#   3. Runs a quick enrolment check silently, then shows a minimal
#      app-install page (plain status list, pulsing progress bar) gated
#      on both apps landing in /Applications, rechecked every 3s.
#   4. Downloads the info PDF from this repo straight to the user's
#      Desktop (no dedicated page for this — it just opens automatically
#      on the final screen below).
#   5. Shows a final page confirming the Mac is ready to go, with a help
#      contact if anything needs attention — the moment this page is on
#      screen, it opens the info PDF and restarts the Dock, so both
#      happen last, after everything else has had the whole process to
#      roll out.
#   6. Writes a marker file so it only runs once per Mac (delete it to
#      re-test).
#
# HOW TO TEST RIGHT NOW (ad hoc, as root)
#   chmod +x mck-onboarding.sh
#   sudo ./mck-onboarding.sh --force
#
#   --force skips the "already run" marker check so you can re-run it
#   as many times as you like while iterating.
#
# HOW TO WIRE INTO MOSYLE — fire at first login via a bundled LaunchDaemon
#   swiftDialog needs a real GUI session to draw its windows, and Mosyle's
#   "Enrollment Complete" trigger runs as root with no UI — so this has to
#   fire at the user's first *login* instead, into a real GUI session.
#
#   1. Build the installer: `packaging/build-pkg.sh`. It installs this
#      script + mck-onboarding-daemon.sh to
#      /Library/Application Support/McKinnon, and
#      mck-onboarding-launchdaemon.plist to /Library/LaunchDaemons (with
#      a postinstall script that bootstraps it immediately rather than
#      waiting for a reboot) — signed with a Developer ID Installer
#      certificate. swiftDialog is NOT bundled into this pkg — push its
#      own official release .pkg to Mosyle as a separate app (small,
#      independent packages proved far more reliable to deliver through
#      Mosyle than one large combined one — see build-pkg.sh's header).
#   2. Push both .pkgs to devices via Mosyle — confirmed working on a
#      real fresh enrollment (2026-09-11).
#   3. The LaunchDaemon runs as root from boot and polls for a real
#      console user (see mck-onboarding-daemon.sh), then bridges THIS
#      script into their session via `launchctl asuser ... sudo -u ...`
#      — that's why it runs as that user, not root, despite the daemon
#      itself being root.
#   4. The info PDF is NOT shipped this way — it's pulled from
#      PDF_SOURCE_URL (this repo, raw.githubusercontent.com) at runtime,
#      so first login needs working internet for that step to succeed.
#      It fails soft (logs a warning, carries on) if it can't reach it.
#   5. The marker file (guard above) stops a repeat login from re-running
#      onboarding.
#
# ------------------------------------------------------------------------

set -u

### ---------------------------------------------------------------------
### EXECUTION CONTEXT
###
### This script runs in one of two genuinely different contexts, and a
### lot of bugs have come from conflating them:
###   - As ROOT, via `sudo ./mck-onboarding.sh --force` — the only way
###     it's ever been tested ad hoc.
###   - As the logged-in CONSOLE USER (not root!), bridged in by
###     mck-onboarding-daemon.sh via `launchctl asuser <uid> sudo -u
###     <user>` — never as root, no matter that the daemon invoking it
###     is root. On a standard (non-admin) account this means: no
###     /Library writes, no /var/log writes, no chown, no sudo.
### RUNNING_AS_ROOT gates every action below that only makes sense in one
### context or the other, so the same script works correctly in both.
### ---------------------------------------------------------------------

RUNNING_AS_ROOT=false
[[ "$(id -u)" -eq 0 ]] && RUNNING_AS_ROOT=true

CONSOLE_USER=$(stat -f "%Su" /dev/console)
CONSOLE_USER_HOME=$(dscl . -read "/Users/${CONSOLE_USER}" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
if [[ -z "$CONSOLE_USER_HOME" ]]; then
  CONSOLE_USER_HOME="/Users/${CONSOLE_USER}"
fi

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

# Root-owned system paths when testing via sudo; user-writable paths under
# the console user's own home when running for real as a standard user
# (a standard user has no write access to /Library or /var/log — that
# mismatch was the actual cause of EX_CONFIG/exit-78 failures when this
# was hardcoded to /var/log and /Library under the old LaunchAgent
# deployment).
if [[ "$RUNNING_AS_ROOT" == true ]]; then
  MARKER_DIR="/Library/Application Support/McKinnon"
  LOG_FILE="/var/log/mck-onboarding.log"
else
  MARKER_DIR="${CONSOLE_USER_HOME}/Library/Application Support/McKinnon"
  LOG_FILE="${CONSOLE_USER_HOME}/Library/Logs/mck-onboarding.log"
fi
MARKER_FILE="${MARKER_DIR}/.onboarding-complete"

DIALOG_BIN="/usr/local/bin/dialog"
DIALOG_COMMAND_FILE="/var/tmp/mck-onboarding-command-$$.log"

# dockutil itself is deployed as its own separate Mosyle package (see
# https://github.com/kcrawford/dockutil/releases) — NOT bundled into this
# pkg — this script only calls it, once Chrome is confirmed installed.
# Own marker (separate from $MARKER_FILE above): bump the year in
# DOCK_MARKER_FILE to reset every user's Dock for a relayout without
# forcing the whole onboarding flow to re-run.
#
# Don't also deploy mck-dock-config.sh (the standalone Custom Script
# version) on the same fleet as this — that one has no marker at all and
# reconfigures the Dock on every login, which will fight this one-time
# step and undo any rearranging a student's done since their first login.
DOCKUTIL_BIN="/usr/local/bin/dockutil"
DOCK_MARKER_DIR="${CONSOLE_USER_HOME}/Library/Application Support/McKinnonIT"
DOCK_MARKER_FILE="${DOCK_MARKER_DIR}/DockConfigured-2026"
# Pinned in this order. Edit for your fleet — each path needs to actually
# exist by the time this runs (Chrome is guaranteed by this point; add
# anything else here only once you're sure it lands before it does too).
DOCK_APPS=(
  "/System/Applications/Apps.app"
  "/Applications/Manager.app"
  "/Applications/Google Chrome.app"
)

# How long (seconds) to wait for the app-install gate before giving up and
# flagging it as needing attention on the completion screen, instead of
# hanging forever. Set to 0 to wait indefinitely.
POLL_TIMEOUT=1200        # 20 minutes
POLL_INTERVAL=3          # how often to re-check, in seconds

# swiftDialog now ships as its own separate Mosyle package rather than
# bundled into this one (see packaging/build-pkg.sh's header) — there's
# no guarantee it lands before or at the same time as this script starts
# running, since Mosyle pushes/installs each app independently. Wait for
# it rather than failing immediately the first time it isn't there yet.
DIALOG_WAIT_TIMEOUT=300  # 5 minutes
DIALOG_WAIT_INTERVAL=5

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
#
# Every log() call goes to two places: the plain-text LOG_FILE (as
# before), and the unified logging system via `logger`, tagged
# "com.mckinnonsc.onboarding" — so runs, actions, and errors all show up
# live in Console.app or `log stream`/`log show`, without needing to know
# the log file's path (which differs depending on RUNNING_AS_ROOT) or
# have filesystem access to it at all.
#
# Deliberately NOT using `logger -p user.err` etc. for errors — tested
# directly against this system's unified log and confirmed err/warning/
# notice/crit all render as the same plain "Default" type as everything
# else, while "info" priority renders as a real "Info" type that
# Console.app and `log show` HIDE by default. Using it for errors would
# make them look identical to routine output; using it for routine
# output would make routine output invisible by default. Everything logs
# at the same (default/"notice") priority instead, and errors are found
# by searching for the existing "ERROR:"/"WARNING:"/"FAILED" message
# text, which is reliable and doesn't depend on log-type rendering.

LOGGER_TAG="com.mckinnonsc.onboarding"
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

# /usr/local/bin/dialog is only a convenience symlink — swiftDialog's own
# postinstall script creates it by self-invoking its freshly-installed
# CLI binary ("${dialogcli}" --link). That's one more thing that can fail
# independently of whether the actual app payload installed fine —
# confirmed hitting exactly that on a real device (Dialog.app present,
# symlink missing, no self-service way to inspect that device's own
# swiftDialog postinstall.log to confirm why). Don't depend on it: fall
# back to the real binary at its fixed install path if the symlink isn't
# there.
FALLBACK_DIALOG_BIN="/Library/Application Support/Dialog/Dialog.app/Contents/MacOS/dialogcli"

resolve_dialog_bin() {
  if [[ -x "$DIALOG_BIN" ]]; then
    return 0
  fi
  if [[ -x "$FALLBACK_DIALOG_BIN" ]]; then
    DIALOG_BIN="$FALLBACK_DIALOG_BIN"
    return 0
  fi
  return 1
}

if ! resolve_dialog_bin; then
  if [[ "$RUNNING_AS_ROOT" == true ]]; then
    install_swiftdialog
  else
    # `installer -pkg ... -target /` needs root, and there's no way to
    # self-heal without it — but swiftDialog is a separate Mosyle package
    # now (see packaging/build-pkg.sh's header), with no guarantee it's
    # landed by the time this fires, so wait for it rather than assuming
    # something's actually broken.
    log "swiftDialog not found yet (running as ${CONSOLE_USER}) — waiting up to ${DIALOG_WAIT_TIMEOUT}s for its separate Mosyle push to land..."
    waited=0
    while ! resolve_dialog_bin; do
      if [[ "$waited" -ge "$DIALOG_WAIT_TIMEOUT" ]]; then
        log "ERROR: swiftDialog still not found after waiting ${DIALOG_WAIT_TIMEOUT}s. Check its separate Mosyle push actually completed on this device."
        exit 1
      fi
      sleep "$DIALOG_WAIT_INTERVAL"
      waited=$(( waited + DIALOG_WAIT_INTERVAL ))
    done
    log "swiftDialog found after waiting ${waited}s."
  fi
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
### don't clutter the app-install page below.
### ---------------------------------------------------------------------

ANY_FAILED=false

log "Running step: Checking enrolment status"
if profiles status -type enrollment | grep -q 'MDM enrollment: Yes'; then
  log "Step succeeded: Checking enrolment status"
else
  log "Step FAILED: Checking enrolment status"
  ANY_FAILED=true
fi

### ---------------------------------------------------------------------
### WELCOME SCREEN
### ---------------------------------------------------------------------

"$DIALOG_BIN" \
  --title "none" \
  "${BANNER_ARGS[@]}" \
  --bannertitle "Welcome to your new Mac" \
  --message "Hi! This Mac has just been enrolled with **${ORG_NAME}**.\n\nWe'll spend the next minute or two setting a few things up and confirming your device is ready to go." \
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
  --message "Hang tight while these finish installing. You can click the Continue button when everything is installed." \
  --icon none \
  --progress \
  --progresstext "Installing..." \
  --listitem "Google Chrome,icon=SF=circle.dashed,status=wait,statustext=Installing..." \
  --listitem "Google Drive,icon=SF=circle.dashed,status=wait,statustext=Installing..." \
  --listitem "Setting up your Dock,icon=SF=circle.dashed,status=wait,statustext=Waiting..." \
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
else
  log "Continuing without every app installed (see timeout note above)."
fi

### ---------------------------------------------------------------------
### DOCK CONFIGURATION — third row on this same list, via dockutil
###
### Runs here rather than via a separate recurring Mosyle "Login" script
### because everything a standalone version of this would need to poll
### for is already true by this point: we're confirmed running as the
### real console user in a live GUI session (swiftDialog is already on
### screen), and Chrome's install state is already known from the loop
### above. Every dockutil call passes --no-restart — the completion
### screen's own Dock restart at the very end of this script picks up
### these changes along with everything else.
### ---------------------------------------------------------------------

run_as_console_user() {
  if [[ "$RUNNING_AS_ROOT" == true ]]; then
    sudo -u "$CONSOLE_USER" "$@"
  else
    "$@"
  fi
}

DOCK_DONE=false

if [[ -f "$DOCK_MARKER_FILE" ]]; then
  log "Dock already configured for ${CONSOLE_USER} (marker exists). Skipping."
  DOCK_DONE=true
  echo "listitem: index: 2, icon: SF=checkmark.circle.fill, status: success, statustext: Already configured" >> "$DIALOG_COMMAND_FILE"
elif [[ "$CHROME_DONE" == false ]]; then
  log "Skipping Dock configuration — Google Chrome never finished installing."
  echo "listitem: index: 2, icon: SF=xmark.circle.fill, status: fail, statustext: Skipped (Chrome missing)" >> "$DIALOG_COMMAND_FILE"
  ANY_FAILED=true
elif [[ ! -x "$DOCKUTIL_BIN" ]]; then
  log "WARNING: dockutil not found at ${DOCKUTIL_BIN} — deploy its package first. Skipping Dock configuration."
  echo "listitem: index: 2, icon: SF=xmark.circle.fill, status: fail, statustext: Not installed" >> "$DIALOG_COMMAND_FILE"
  ANY_FAILED=true
else
  log "Configuring Dock for ${CONSOLE_USER}..."
  echo "listitem: index: 2, icon: SF=circle.dashed, status: wait, statustext: Configuring..." >> "$DIALOG_COMMAND_FILE"

  run_as_console_user "$DOCKUTIL_BIN" --remove all --no-restart
  for dock_app in "${DOCK_APPS[@]}"; do
    run_as_console_user "$DOCKUTIL_BIN" --add "$dock_app" --no-restart
  done
  run_as_console_user "$DOCKUTIL_BIN" --add "$CONSOLE_USER_HOME" --view grid --display folder --no-restart

  mkdir -p "$DOCK_MARKER_DIR"
  date > "$DOCK_MARKER_FILE"
  if [[ "$RUNNING_AS_ROOT" == true ]]; then
    chown "$CONSOLE_USER" "$DOCK_MARKER_DIR" "$DOCK_MARKER_FILE" 2>> "$LOG_FILE"
  fi

  DOCK_DONE=true
  echo "listitem: index: 2, icon: SF=checkmark.circle.fill, status: success, statustext: Configured" >> "$DIALOG_COMMAND_FILE"
  log "Dock configured for ${CONSOLE_USER}. Marker written to ${DOCK_MARKER_FILE}."
fi

if [[ "$CHROME_DONE" == true && "$DRIVE_DONE" == true && "$DOCK_DONE" == true ]]; then
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
### PDF DOWNLOAD (no dedicated page — it just opens on the completion screen)
### ---------------------------------------------------------------------
#
# Downloads the info PDF from the (public) repo straight to the logged-in
# user's Desktop — no separate MDM push of the file needed, just the
# packaged app. CONSOLE_USER/CONSOLE_USER_HOME were already resolved up
# in EXECUTION CONTEXT.

DESKTOP_PDF_PATH="${CONSOLE_USER_HOME}/Desktop/${DESKTOP_PDF_NAME}"

log "Downloading info PDF from ${PDF_SOURCE_URL} to ${DESKTOP_PDF_PATH}"
if curl -sL --fail -o "$DESKTOP_PDF_PATH" "$PDF_SOURCE_URL" 2>> "$LOG_FILE"; then
  if [[ "$RUNNING_AS_ROOT" == true ]]; then
    chown "$CONSOLE_USER" "$DESKTOP_PDF_PATH" 2>> "$LOG_FILE"
  fi
  log "PDF downloaded successfully."
else
  log "WARNING: Failed to download info PDF (no network at first login? repo moved/renamed?) — opening it automatically on the final page won't find anything."
fi

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
    --message "Your Mac has been configured and is ready to use.\n\nIf you need assistance, please reach out to McKinnon IT via **${HELP_EMAIL}**" \
    --icon "SF=checkmark.circle.fill,colour=${ACCENT_COLOR}" \
    --button1text "Finish" \
    --width "$DIALOG_WIDTH" --height "$DIALOG_HEIGHT" \
    --moveable --ontop &
fi

COMPLETION_DIALOG_PID=$!
sleep 1   # give swiftDialog a moment to open before we restart the Dock / open the PDF

log "Opening info PDF for ${CONSOLE_USER}: ${DESKTOP_PDF_PATH}"
if [[ "$RUNNING_AS_ROOT" == true ]]; then
  # Dropping privileges to open it as the actual user, not root.
  sudo -u "$CONSOLE_USER" open "$DESKTOP_PDF_PATH" >> "$LOG_FILE" 2>&1
else
  # Already running as that user — no sudo needed (and a standard user
  # couldn't run it anyway).
  open "$DESKTOP_PDF_PATH" >> "$LOG_FILE" 2>&1
fi

log "Restarting Dock (final step, after all config has had time to roll out)"
killall Dock 2>> "$LOG_FILE" || log "NOTE: killall Dock returned non-zero — Dock may not have been running yet."

wait "$COMPLETION_DIALOG_PID"

### ---------------------------------------------------------------------
### MARK COMPLETE
### ---------------------------------------------------------------------

mkdir -p "$MARKER_DIR"
date > "$MARKER_FILE"
log "Onboarding complete. Marker written to $MARKER_FILE."

exit 0
