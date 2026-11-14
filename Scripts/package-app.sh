#!/usr/bin/env bash
# Build the Wisp menu-bar app as .build/Wisp.app and install it as /Applications/Wisp.app.
#
# macOS remembers Screen Recording and Microphone permission per app, by bundle id and code
# signature. Installing to one fixed path and signing with the same certificate every time keeps
# those permissions across rebuilds.
#
#   ./Scripts/package-app.sh                                   build, sign, install
#   WISP_SKIP_APPLICATIONS_INSTALL=1 ./Scripts/package-app.sh  build and sign .build/Wisp.app only
#   WISP_CODESIGN_IDENTITY="<certificate name>" ./Scripts/package-app.sh
#                                                              sign with that certificate ("-" = ad-hoc)
#
# The script never replaces an app that is not Wisp, and never quits a running Wisp for you:
# quitting it mid-recording would leave unplayable files.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

PLIST="$ROOT/Apps/Wisp/Info.plist"
BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw -o - "$PLIST")"
DISPLAY_NAME="$(plutil -extract CFBundleDisplayName raw -o - "$PLIST")"
INSTALLED="/Applications/Wisp.app"
DEV_BUILD="$ROOT/.build/Wisp.app"

INSTALL=1
if [[ "${WISP_SKIP_APPLICATIONS_INSTALL:-}" == "1" ]]; then
  INSTALL=0
fi

fail() {
  echo "error: $*" >&2
  exit 1
}

# Refuses to go on when /Applications/Wisp.app exists but is some other app.
check_installed_is_wisp() {
  [[ -e "$INSTALLED" || -L "$INSTALLED" ]] || return 0
  local existing
  existing="$(plutil -extract CFBundleIdentifier raw -o - "$INSTALLED/Contents/Info.plist" 2>/dev/null || true)"
  # app.wisp.macos is the id earlier builds used; replacing one of those is an upgrade.
  if [[ "$existing" != "$BUNDLE_ID" && "$existing" != "app.wisp.macos" ]]; then
    fail "$INSTALLED is a different app (bundle id: ${existing:-unknown}; Wisp is $BUNDLE_ID).
Nothing was replaced. Move that app out of /Applications, or build without installing:
  WISP_SKIP_APPLICATIONS_INSTALL=1 ./Scripts/package-app.sh"
  fi
}

wisp_is_running() {
  [[ -n "$(lsappinfo find "bundleid=$BUNDLE_ID" 2>/dev/null)" || -n "$(lsappinfo find "bundleid=app.wisp.macos" 2>/dev/null)" ]]
}

# Waits for the user to quit Wisp. Never kills it: a recording in progress would be lost.
wait_until_wisp_quits() {
  wisp_is_running || return 0
  echo ""
  echo "Wisp is running. Stop any recording, then quit it from the menu bar (⋯ → Quit Wisp)."
  echo "This script does not quit Wisp for you, because that would ruin a recording in progress."
  if [[ ! -t 0 ]]; then
    fail "Wisp is still running. Quit it and run this script again."
  fi
  while wisp_is_running; do
    read -r -p "Press Return once Wisp has quit (Ctrl-C to cancel): " _
  done
}

if [[ "$INSTALL" == "1" ]]; then
  check_installed_is_wisp
fi

# App icon and menu-bar images (regenerated only when missing).
if [[ ! -f "$ROOT/Resources/AppIcon.icns" ]]; then
  "$ROOT/Scripts/make-icon.sh"
fi

# Release build: same behaviour, ~30% less CPU in Wisp's own code (measured with capture-smoke).
swift build -c release --product Wisp
BIN="$(swift build -c release --show-bin-path)/Wisp"
APP="$DEV_BUILD"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Wisp"
# Local symbols only matter to a debugger: keep them in a dSYM next to the build, ship without.
dsymutil "$BIN" -o "$ROOT/.build/Wisp.dSYM" >/dev/null 2>&1 || true
strip -x "$APP/Contents/MacOS/Wisp"
cp "$PLIST" "$APP/Contents/Info.plist"

# App icon (Finder / Dock / permission dialogs) + menu-bar template images.
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
cp "$ROOT/Resources/tray/wispTemplate.png" "$APP/Contents/Resources/wispTemplate.png"
cp "$ROOT/Resources/tray/wispTemplate@2x.png" "$APP/Contents/Resources/wispTemplate@2x.png"

# Signing. An Apple Development certificate keeps permissions across rebuilds; an ad-hoc
# signature changes with every build, so macOS forgets the permissions each time.
if [[ -n "${WISP_CODESIGN_IDENTITY:-}" ]]; then
  CODESIGN_ID="$WISP_CODESIGN_IDENTITY"
  SIGN_LABEL="WISP_CODESIGN_IDENTITY"
  if [[ "$CODESIGN_ID" == "-" ]]; then
    SIGN_LABEL="ad-hoc (WISP_CODESIGN_IDENTITY=-)"
  fi
else
  CODESIGN_ID="-"
  SIGN_LABEL="ad-hoc (permissions reset on every rebuild)"
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ {print $2; exit}' || true)"
  if [[ -n "$IDENTITY" ]]; then
    CODESIGN_ID="$IDENTITY"
    SIGN_LABEL="Apple Development (first one in the keychain)"
  fi
fi

codesign --force --deep --sign "$CODESIGN_ID" \
  --entitlements "$ROOT/Apps/Wisp/Wisp.entitlements" \
  "$APP"

if [[ "$INSTALL" == "1" ]]; then
  check_installed_is_wisp
  wait_until_wisp_quits
  rm -rf "$INSTALLED"
  ditto "$APP" "$INSTALLED"
  codesign --force --deep --sign "$CODESIGN_ID" \
    --entitlements "$ROOT/Apps/Wisp/Wisp.entitlements" \
    "$INSTALLED"
fi

echo ""
echo "=== $DISPLAY_NAME ==="
echo "  Bundle ID : $BUNDLE_ID"
echo "  Signature : $SIGN_LABEL"
if [[ "$INSTALL" == "1" ]]; then
  echo "  Installed : $INSTALLED"
  echo ""
  echo "Run: open $INSTALLED"
else
  echo "  Built     : $DEV_BUILD (not installed)"
  echo ""
  echo "Run: open \"$DEV_BUILD\""
fi
echo "Allow Screen & System Audio Recording and Microphone for $DISPLAY_NAME, then reopen it."
echo "Guide: docs/permissions-howto.md"
