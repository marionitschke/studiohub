#!/bin/bash
# Builds and runs the checks (Tests/Checks.swift) against all sources except the app entry point.
# Works only in temporary folders; never touches the real Application Support folder.
set -euo pipefail
cd "$(dirname "$0")/.."

./build.sh >/dev/null
FLAGS=()
while IFS= read -r line; do FLAGS+=("$line"); done < <(./build.sh --print-flags)
LAME_LIB="${FLAGS[${#FLAGS[@]}-1]}"
unset "FLAGS[${#FLAGS[@]}-1]"

SOURCES=()
for file in Sources/VideoHub/*.swift; do
  [[ "$file" == */VideoHubApp.swift ]] || SOURCES+=("$file")
done
swiftc "${FLAGS[@]}" -parse-as-library -module-name VideoHub -o build/VideoHubChecks "${SOURCES[@]}" Tests/Checks.swift "$LAME_LIB"
build/VideoHubChecks
