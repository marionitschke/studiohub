#!/bin/bash
# Builds MusicHub.app (shared steps in ../shared/build-common.sh).
#
#   ./build.sh               → build/MusicHub.app
#   ./build.sh --install     → also installs it into /Applications/StudioHub
#   ./build.sh --icon        → redraws the app icon (Resources/AppIcon.icns)
#   ./build.sh --print-flags → compiler flags and shared sources for scripts/check.sh, the LAME library last
#
# MP3 encoding uses LAME (`brew install lame`), linked statically, so the finished app runs without Homebrew.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME=MusicHub
DEPLOYMENT_TARGET=15.0 # Homebrew's LAME is built for macOS 15
MODE="${1:-}"
source ../shared/build-common.sh

if [[ "$MODE" == "--icon" ]]; then
  draw_icon
  exit 0
fi
if [[ "$MODE" == "--install" ]]; then
  ensure_not_running
fi

use_lame
SHARED_SOURCES=("$SHARED/MP3Encoder.swift" "$SHARED/StudioApps.swift" "$SHARED/StudioCommands.swift" "$SHARED/Darcula.swift" "$SHARED/DarculaSwiftUI.swift")

if [[ "$MODE" == "--print-flags" ]]; then
  printf '%s\n' "${FLAGS[@]}" "${SHARED_SOURCES[@]}" "$LAME_LIB"
  exit 0
fi

echo "Compiling …"
swiftc "${FLAGS[@]}" -parse-as-library -module-name MusicHub -o build/MusicHub Sources/MusicHub/*.swift "${SHARED_SOURCES[@]}" "$LAME_LIB"
bundle_app
if [[ "$MODE" == "--install" ]]; then
  install_app
fi
echo "Done: $APP"
