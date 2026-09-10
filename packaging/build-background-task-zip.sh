#!/bin/zsh
#
# build-background-task-zip.sh
#
# Builds the "Background Task Reference file (.zip)" for Mosyle's
# Background Task Management profile. Upload the resulting zip to the
# "Background Task Reference file" field, and
# mck-onboarding-launchagent.plist to the "Launchd Configurations" table
# with Launchd Context = Agent, with Task Identifier set to
# com.mckinnonsc.onboarding.
#
# The directory inside the zip is named after the Task Identifier — this
# matches the documented convention for this macOS 15+ feature (verified
# against Apple's own docs + a working Jamf Pro equivalent write-up, NOT
# against Mosyle's implementation directly). If Mosyle places the script
# somewhere other than
#   /private/var/db/ManagedConfigurationFiles/BackgroundTaskServices/Services/com.mckinnonsc.onboarding/mck-onboarding.sh
# on a real test device, update mck-onboarding-launchagent.plist's
# ProgramArguments to match the real path and rebuild.
#
# ------------------------------------------------------------------------

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

TASK_IDENTIFIER="com.mckinnonsc.onboarding"
BUILD_DIR="${SCRIPT_DIR}/build/background-task"
DIST_DIR="${SCRIPT_DIR}/dist"
ZIP_PATH="${DIST_DIR}/${TASK_IDENTIFIER}.zip"

rm -rf "$BUILD_DIR"
mkdir -p "${BUILD_DIR}/${TASK_IDENTIFIER}"
mkdir -p "$DIST_DIR"

cp "${REPO_ROOT}/mck-onboarding.sh" "${BUILD_DIR}/${TASK_IDENTIFIER}/mck-onboarding.sh"
chmod +x "${BUILD_DIR}/${TASK_IDENTIFIER}/mck-onboarding.sh"

rm -f "$ZIP_PATH"
(cd "$BUILD_DIR" && zip -r "$ZIP_PATH" "$TASK_IDENTIFIER")

echo ""
echo "Built: $ZIP_PATH"
echo ""
echo "Upload to Mosyle's Background Task Management profile:"
echo "  Task Identifier:              $TASK_IDENTIFIER"
echo "  Background Task Reference file: $ZIP_PATH"
echo "  Launchd Configurations:       ${REPO_ROOT}/mck-onboarding-launchagent.plist  (Launchd Context: Agent)"
