#!/bin/bash
set -e

# Navigate to the project root directory
cd "$(dirname "$0")/.."

# Extract current version from pubspec.yaml
VERSION=$(grep '^version:' pubspec.yaml | awk '{print $2}')

# Default release notes if none provided
NOTES="${1:-"CCS Mobile Studio beta release $VERSION. Unified EEG research platform updates."}"

echo "=================================================="
echo "🚀 Starting CCS Mobile Studio Release: Version $VERSION"
echo "Notes: $NOTES"
echo "=================================================="

# Check for firebase-cli (check locally or in NeuroYukti)
FIREBASE_CLI="./firebase-cli"
if [ ! -f "$FIREBASE_CLI" ]; then
  if [ -f "../NeuroYukti/firebase-cli" ]; then
    echo "ℹ️ firebase-cli found in NeuroYukti, using that."
    FIREBASE_CLI="../NeuroYukti/firebase-cli"
  else
    echo "⚠️ Warning: firebase-cli not found. Please install Firebase CLI or place it in the project root."
  fi
fi

echo "📦 [1/2] Building Android APK..."
flutter build apk --release

# Firebase Android App ID for CCS Mobile Studio
FIREBASE_APP_ID="1:267674249051:android:5965f25894b9c90cbc1c7e"

echo "🚀 [2/2] Uploading Android APK to Firebase App Distribution..."
$FIREBASE_CLI appdistribution:distribute build/app/outputs/flutter-apk/app-release.apk \
  --app "$FIREBASE_APP_ID" \
  --testers arunsasi84@gmail.com \
  --release-notes "$NOTES"

echo "=================================================="
echo "🎉 Process complete!"
echo "=================================================="
