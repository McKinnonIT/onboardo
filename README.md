# onboardo

A post-enrolment Mac onboarding walkthrough for McKinnon Secondary
College, built on [swiftDialog](https://github.com/swiftDialog/swiftDialog).
Fires at a new Mac's first login and walks the user through a branded
welcome screen, waits for their apps to install, sets up their Dock, and
leaves them on a "you're all set" screen — no admin interaction required.

## How it works

Three pieces, all in this repo:

1. **`mck-onboarding-launchdaemon.plist`** — a LaunchDaemon installed to
   `/Library/LaunchDaemons`, running as root from boot (`RunAtLoad`, not
   tied to any specific login).
2. **`mck-onboarding-daemon.sh`** — what that daemon runs. Polls
   `/dev/console` every 5s until a real human user is logged in (skips
   nobody, `loginwindow`, and system/service accounts), then bridges into
   *that user's* GUI session via `launchctl asuser <uid> sudo -u <user>`
   and runs `mck-onboarding.sh` there — the standard mechanism for
   getting a GUI window on screen from a root-context daemon.
3. **`mck-onboarding.sh`** — the actual walkthrough, now running as the
   logged-in user (not root). Runs once per Mac (marker file guards
   against re-running on every login) and shows:
   - **Welcome screen**
   - **Installing your apps** — a live-updating list gated on Google
     Chrome and Google Drive landing in `/Applications` (Mosyle pushes
     these as separate apps), plus a third row that configures the Dock
     via [`dockutil`](https://github.com/kcrawford/dockutil) once Chrome
     is confirmed installed
   - **Completion screen** — the moment it's on screen, it opens an info
     PDF (downloaded fresh from this repo) on the user's Desktop and
     restarts the Dock, so both land after everything else has had the
     whole process to roll out

This script is written to run correctly in two genuinely different
contexts — as root (ad hoc testing) or as the standard logged-in user
(real deployment) — see the `EXECUTION CONTEXT` comment block near the
top of `mck-onboarding.sh` before changing anything that writes to disk
or needs elevated privileges.

## Requirements

Pushed to devices as **three separate apps in Mosyle** (or whatever MDM
you're using) — deliberately not bundled together, see
`packaging/build-pkg.sh`'s header for why:

1. This repo's own installer pkg (see **Building & deploying** below).
2. [swiftDialog's official release .pkg](https://github.com/swiftDialog/swiftDialog/releases).
3. [dockutil's official release .pkg](https://github.com/kcrawford/dockutil/releases).

Google Chrome and Google Drive also need to be pushed as their own apps
for the "Installing your apps" gate to ever complete — if they're never
pushed, that page will sit there until `POLL_TIMEOUT` (default 20
minutes) and then continue anyway, flagging the completion screen as
needing IT attention.

## Testing locally, ad hoc

```
chmod +x mck-onboarding.sh
sudo ./mck-onboarding.sh --force
```

`--force` skips the "already run" marker check so you can re-run it as
many times as you like while iterating. Run as root like this, the
script self-installs swiftDialog if it isn't already present — in
production it expects swiftDialog to already be there (see
**Requirements**), and will wait up to `DIALOG_WAIT_TIMEOUT` (default 5
minutes) for it to appear before giving up, since Mosyle pushes it as an
independent app with no install-order guarantee.

## Building & deploying

```
packaging/build-pkg.sh            # signed
packaging/build-pkg.sh --unsigned # skip signing (no cert needed)
```

Produces `packaging/dist/McKinnonOnboarding-Installer-<version>.pkg`,
installing `mck-onboarding.sh` + `mck-onboarding-daemon.sh` to
`/Library/Application Support/McKinnon` and the LaunchDaemon plist to
`/Library/LaunchDaemons`, with a postinstall script that bootstraps the
daemon immediately (logged to
`/var/log/mck-onboarding-postinstall.log`) rather than waiting for a
reboot.

Signing needs a **"Developer ID Installer"** certificate *with its
matching private key* in your login keychain — check with
`security find-identity -v -p basic`. A certificate downloaded from the
Apple Developer portal without the original CSR's private key present on
the same Mac won't show up here even though `security find-certificate`
sees it; you'd need the matching `.p12` (cert + key together), or to
generate a fresh CSR/cert pair on this Mac. Use `--unsigned` to build
without one in the meantime.

Push the resulting `.pkg` to Mosyle alongside swiftDialog's and
dockutil's own release pkgs (see **Requirements**).

**Background Task Management**: on an MDM-supervised device, the
LaunchDaemon may need BTM approval before it's allowed to run — if a
device needs a manual reboot before onboarding ever fires, check
`/var/log/mck-onboarding-postinstall.log` for a `NOT registered with
launchd` warning, and consider pushing a BTM-approval profile
(`RuleType: Label`, `RuleValue: com.mckinnonsc.onboarding.daemon`) in
the same wave as this pkg.

## Configuration

Edit the `CONFIG` block near the top of `mck-onboarding.sh`:

| Variable | What it controls |
|---|---|
| `ORG_NAME`, `ACCENT_COLOR`, `LOGO_PATH`, `HELP_EMAIL` | Branding and the IT contact shown on the completion screen |
| `DESKTOP_PDF_NAME`, `PDF_SOURCE_URL` | The info PDF's filename and where it's fetched from at runtime (this repo, public, over `raw.githubusercontent.com`) |
| `DOCK_APPS` | Apps pinned to the Dock, in order — each path must actually exist by the time Dock configuration runs (Chrome is guaranteed; anything else needs checking) |
| `DOCK_MARKER_FILE` | Bump the year in this filename to reset every user's Dock for a relayout, without re-running the rest of onboarding |
| `POLL_TIMEOUT` / `POLL_INTERVAL` | How long to wait for Chrome/Drive before giving up and flagging the completion screen |
| `DIALOG_WAIT_TIMEOUT` / `DIALOG_WAIT_INTERVAL` | How long to wait for swiftDialog itself to appear, since it's pushed as a separate app |

`PKG_VERSION` and `SIGNING_IDENTITY` live at the top of
`packaging/build-pkg.sh`.

## Logs

Everything logs to both a plain-text file and the unified logging system
(`log stream`/`log show`/Console.app, tagged `com.mckinnonsc.onboarding`)
so you don't need filesystem access to the device to see what happened:

- Running as root (ad hoc test): `/var/log/mck-onboarding.log`
- Running as the real user (production): `~/Library/Logs/mck-onboarding.log`
- Daemon itself: `/var/log/mck-onboarding-daemon.log` and
  `/var/log/mck-onboarding-launchdaemon.log`
- Package postinstall: `/var/log/mck-onboarding-postinstall.log`

Errors/warnings are all logged at the same priority as routine output
(deliberately — see the `LOGGING` comment block in `mck-onboarding.sh`
for why) and are findable by searching for `ERROR:`/`WARNING:`/`FAILED`.

## Re-testing on a device that's already completed onboarding

Delete its marker file(s) and it'll run again next login:

- Onboarding itself: `~/Library/Application Support/McKinnon/.onboarding-complete`
- Dock configuration: `~/Library/Application Support/McKinnonIT/DockConfigured-<year>`
