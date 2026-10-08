#!/bin/bash
set -euo pipefail

# -----------------------------------------------------------------------------
# CCS Mobile Studio macOS 1-Click Installer / Updater
# Copies app to /Applications, removes quarantine, signs with local identity,
# and launches the application cleanly with zero Gatekeeper warnings.
# -----------------------------------------------------------------------------

TARGET="/Applications/ccs_mobile_studio.app"
SOURCE_APP=""

# Locate source application
if [ $# -ge 1 ] && [ -d "$1" ]; then
  SOURCE_APP="$1"
elif [ -d "build/macos/Build/Products/Release/ccs_mobile_studio.app" ]; then
  SOURCE_APP="build/macos/Build/Products/Release/ccs_mobile_studio.app"
elif [ -d "$HOME/Downloads/ccs_mobile_studio.app" ]; then
  SOURCE_APP="$HOME/Downloads/ccs_mobile_studio.app"
fi

if [ -z "$SOURCE_APP" ] || [ ! -d "$SOURCE_APP" ]; then
  echo "❌ Source ccs_mobile_studio.app not found."
  echo "Usage: ./tools/install_mac.sh [path/to/ccs_mobile_studio.app]"
  exit 1
fi

echo "📦 Installing from: $SOURCE_APP"
echo "🎯 Destination: $TARGET"

# Stop existing running instance if any
if pgrep -x "ccs_mobile_studio" >/dev/null 2>&1; then
  echo "🛑 Terminating running instance..."
  pkill -x "ccs_mobile_studio" || true
  sleep 1
fi

# Remove existing target
rm -rf "$TARGET"

# Copy new application
cp -R "$SOURCE_APP" "$TARGET"

# Strip quarantine attributes
echo "🛡️ Clearing macOS Gatekeeper quarantine flags..."
xattr -cr "$TARGET" 2>/dev/null || true

# Sign with local Apple Developer identity if available
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -E "Developer ID Application|Apple Development" | head -1 | awk -F '"' '{print $2}')
if [ -n "$IDENTITY" ]; then
  echo "✍️ Signing app with local identity: $IDENTITY"
  codesign --force --deep --sign "$IDENTITY" "$TARGET" 2>/dev/null || true
else
  echo "⚠️ No local Apple Developer certificate found; applying ad-hoc signature"
  codesign --force --deep --sign - "$TARGET" 2>/dev/null || true
fi

echo "✅ Verifying signature..."
codesign -vvv --deep --strict "$TARGET"

echo "🚀 Launching CCS Mobile Studio..."
open "$TARGET"

echo "🎉 Done! CCS Mobile Studio is installed and running from /Applications."
