#!/bin/bash
set -e

# Navigate to the project root directory
cd "$(dirname "$0")/.."

# Extract current version from pubspec.yaml
VERSION=$(grep '^version:' pubspec.yaml | awk '{print $2}')

# Default release notes if none provided
DEFAULT_NOTES="CCS Mobile Studio release $VERSION:
- Heartbeat Evoked Potential (HEP) module with synchronized EEG/ECG, live artifact rejection, SEM, pseudotrial comparison, and JSON export.
- Heart Rate Detection (HRD) module with ECG/PPG input, Bayesian marginal-Psi Rust core, and auditory/visual feedback.
- NeuroKit2 ECG branch in Rust with R-peak detection, iterative artifact correction, and heart-rate interpolation."

NOTES="${1:-"$DEFAULT_NOTES"}"

echo "=================================================="
echo "🚀 Starting CCS Mobile Studio Release: Version $VERSION"
echo "=================================================="
echo "Release Notes:"
echo "$NOTES"
echo "=================================================="

# Detect available Firebase CLI
if command -v firebase >/dev/null 2>&1; then
  FIREBASE_CMD="firebase"
elif command -v npx >/dev/null 2>&1; then
  FIREBASE_CMD="npx --yes firebase-tools"
elif [ -f "./firebase-cli" ] && ./firebase-cli --version >/dev/null 2>&1; then
  FIREBASE_CMD="./firebase-cli"
elif [ -f "../NeuroYukti/firebase-cli" ] && ../NeuroYukti/firebase-cli --version >/dev/null 2>&1; then
  FIREBASE_CMD="../NeuroYukti/firebase-cli"
else
  echo "❌ Error: Neither firebase CLI nor npx is available."
  exit 1
fi

echo "📦 [1/2] Building Android APK..."
flutter build apk --release

# Firebase Android App ID for CCS Mobile Studio
FIREBASE_APP_ID="1:267674249051:android:5965f25894b9c90cbc1c7e"

echo "🚀 [2/2] Uploading Android APK to Firebase App Distribution..."
$FIREBASE_CMD appdistribution:distribute build/app/outputs/flutter-apk/app-release.apk \
  --app "$FIREBASE_APP_ID" \
  --testers arunsasi84@gmail.com \
  --release-notes "$NOTES"

echo "=================================================="
echo "🎉 Firebase Release $VERSION complete!"
echo "=================================================="
