# Build steps shared by the apps' build.sh, which sources this file from its own folder after setting
# APP_NAME and DEPLOYMENT_TARGET. Only the Command Line Tools are needed – no Xcode, no certificate.

SHARED="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="/Applications/StudioHub"
APP="build/$APP_NAME.app"
mkdir -p build

FLAGS=(-O -swift-version 5 -target "$(uname -m)-apple-macos$DEPLOYMENT_TARGET")

# Some Command Line Tools installs ship an outdated module.modulemap that clashes with
# bridging.modulemap ("redefinition of module 'SwiftBridging'"). A VFS overlay hides it while
# compiling; the system itself stays unchanged.
SWIFT_INCLUDE="$(dirname "$(dirname "$(xcrun -f swiftc)")")/include/swift"
if [[ -f "$SWIFT_INCLUDE/module.modulemap" && -f "$SWIFT_INCLUDE/bridging.modulemap" ]]; then
  : > build/empty.modulemap
  cat > build/clt-overlay.yaml <<EOF
{ "version": 0, "case-sensitive": "false", "roots": [ { "name": "$SWIFT_INCLUDE", "type": "directory",
  "contents": [ { "name": "module.modulemap", "type": "file", "external-contents": "$PWD/build/empty.modulemap" } ] } ] }
EOF
  FLAGS+=(-vfsoverlay build/clt-overlay.yaml -Xcc -ivfsoverlay -Xcc build/clt-overlay.yaml)
fi

# LAME from Homebrew (`brew install lame`), always the static library: the finished app must not
# need Homebrew. Homebrew's bottle is built for macOS 15, so apps using it target macOS 15.
use_lame() {
  LAME_PREFIX="${LAME_PREFIX:-$(brew --prefix lame 2>/dev/null || true)}"
  local candidate
  for candidate in "$LAME_PREFIX" /opt/homebrew /usr/local; do
    if [[ -n "$candidate" && -f "$candidate/lib/libmp3lame.a" && -f "$candidate/include/lame/lame.h" ]]; then
      LAME_PREFIX="$candidate"
      break
    fi
  done
  if [[ ! -f "$LAME_PREFIX/lib/libmp3lame.a" ]]; then
    echo "LAME not found. Install it with: brew install lame" >&2
    exit 1
  fi
  FLAGS+=(-I "$SHARED/CLame" -Xcc -I"$LAME_PREFIX/include")
  LAME_LIB="$LAME_PREFIX/lib/libmp3lame.a"
}

# Redraws Resources/AppIcon.icns from scripts/make-icon.swift.
draw_icon() {
  swiftc "${FLAGS[@]}" -o build/make-icon scripts/make-icon.swift
  rm -rf build/AppIcon.iconset
  build/make-icon build/AppIcon.iconset
  mkdir -p Resources
  iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns
  echo "Icon updated: Resources/AppIcon.icns"
}

# Installing replaces the app, so it must not be running.
ensure_not_running() {
  if pgrep -f "$APP_NAME.app/Contents/MacOS/$APP_NAME" >/dev/null; then
    echo "$APP_NAME is running. Quit it, then install again." >&2
    exit 1
  fi
}

# Wraps build/$APP_NAME into the app bundle and signs it ad hoc ("-": no certificate, no Apple account)
# with Hardened Runtime, which prevents injecting foreign libraries into the running app.
bundle_app() {
  echo "Creating $APP …"
  rm -rf "$APP"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp "build/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
  cp Resources/Info.plist "$APP/Contents/Info.plist"
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
  codesign --force --options runtime --sign - "$APP"
  # No install without a valid signature and Hardened Runtime.
  codesign --verify --strict "$APP"
  [[ "$(codesign -dv "$APP" 2>&1)" == *"flags="*"runtime"* ]] || { echo "Hardened Runtime missing from the signature." >&2; exit 1; }
}

install_app() {
  mkdir -p "$INSTALL_DIR"
  rm -rf "$INSTALL_DIR/$APP_NAME.app"
  cp -R "$APP" "$INSTALL_DIR/"
  echo "Installed: $INSTALL_DIR/$APP_NAME.app"
}
