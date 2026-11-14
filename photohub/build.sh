#!/bin/bash
# Builds PhotoHub.app (shared steps in ../shared/build-common.sh).
#
#   ./build.sh            → build/PhotoHub.app
#   ./build.sh --install  → also installs it into /Applications/StudioHub
#   ./build.sh --icon     → redraws the app icon (Resources/AppIcon.icns)
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME=PhotoHub
DEPLOYMENT_TARGET=13.0
MODE="${1:-}"
source ../shared/build-common.sh

if [[ "$MODE" == "--icon" ]]; then
  draw_icon
  exit 0
fi
if [[ "$MODE" == "--install" ]]; then
  ensure_not_running
fi

SHARED_SOURCES=("$SHARED/StudioApps.swift" "$SHARED/Darcula.swift")

echo "Compiling …"
swiftc "${FLAGS[@]}" -module-name PhotoHub -o build/PhotoHub Sources/PhotoHub/*.swift "${SHARED_SOURCES[@]}"
bundle_app
if [[ "$MODE" == "--install" ]]; then
  install_app
fi
echo "Done: $APP"
