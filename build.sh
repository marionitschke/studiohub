#!/bin/bash
# Builds the StudioHub apps; each one also builds on its own with <app>/build.sh.
#
#   ./build.sh                    → all apps, each into <app>/build/
#   ./build.sh video music        → only these (photo, video, music)
#   ./build.sh --install          → also installs them into /Applications/StudioHub
#   ./build.sh --icon             → redraws the app icons
#   ./build.sh --check            → builds and runs the checks of the apps that have them
#
# An app that is running is not installed; the others still are.
set -euo pipefail
cd "$(dirname "$0")"

APPS=()
OPTION=""
for arg in "$@"; do
  case "$arg" in
    photo|video|music) APPS+=("${arg}hub") ;;
    --install|--icon|--check) OPTION="$arg" ;;
    *) echo "Unknown argument: $arg (apps: photo, video, music; options: --install, --icon, --check)" >&2; exit 1 ;;
  esac
done
if [[ ${#APPS[@]} -eq 0 ]]; then
  APPS=(photohub videohub musichub)
fi

FAILED=""
for app in "${APPS[@]}"; do
  echo "== $app"
  if [[ "$OPTION" == "--check" ]]; then
    if [[ -x "$app/scripts/check.sh" ]]; then
      "$app/scripts/check.sh" || FAILED="$FAILED $app"
    else
      echo "No checks."
    fi
  elif [[ -n "$OPTION" ]]; then
    "$app/build.sh" "$OPTION" || FAILED="$FAILED $app"
  else
    "$app/build.sh" || FAILED="$FAILED $app"
  fi
done

if [[ -n "$FAILED" ]]; then
  echo "Failed:$FAILED" >&2
  exit 1
fi
