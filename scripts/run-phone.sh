#!/bin/zsh
set -euo pipefail

PHONE_UDID="${PHONE_UDID:-00008150-001E1C49347A401C}"

BUILD_DIR="$(xcodebuild -showBuildSettings -scheme Carry | awk -F' = ' '/TARGET_BUILD_DIR/ {print $2; exit}')"
WRAPPER_NAME="$(xcodebuild -showBuildSettings -scheme Carry | awk -F' = ' '/WRAPPER_NAME/ {print $2; exit}')"
APP_PATH="${BUILD_DIR}/${WRAPPER_NAME}"

if [[ ! -d "$APP_PATH" ]]; then
  xcodebuild \
    -scheme Carry \
    -destination "generic/platform=iOS" \
    -configuration Debug \
    CODE_SIGNING_ALLOWED=NO \
    build

  BUILD_DIR="$(xcodebuild -showBuildSettings -scheme Carry | awk -F' = ' '/TARGET_BUILD_DIR/ {print $2; exit}')"
  WRAPPER_NAME="$(xcodebuild -showBuildSettings -scheme Carry | awk -F' = ' '/WRAPPER_NAME/ {print $2; exit}')"
  APP_PATH="${BUILD_DIR}/${WRAPPER_NAME}"
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "Could not locate Carry.app at $APP_PATH" >&2
  exit 1
fi

devicectl device install app --device "$PHONE_UDID" "$APP_PATH"
devicectl device process launch --device "$PHONE_UDID" --terminate-existing com.lumastudio.carry
