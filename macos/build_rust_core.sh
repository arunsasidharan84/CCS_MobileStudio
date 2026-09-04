#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$PROJECT_DIR/.." && pwd)"
if [[ "$CONFIGURATION" == "Debug" ]]; then
  BUILD_MODE="debug"
else
  BUILD_MODE="release"
fi

"$ROOT_DIR/rust/build_macos.sh" "$BUILD_MODE"

SOURCE_LIBRARY="$ROOT_DIR/rust/target/macos-universal/$BUILD_MODE/libtrain_nidra_core.dylib"
FRAMEWORKS_DIR="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
mkdir -p "$FRAMEWORKS_DIR"
cp "$SOURCE_LIBRARY" "$FRAMEWORKS_DIR/libtrain_nidra_core.dylib"
install_name_tool \
  -id "@rpath/libtrain_nidra_core.dylib" \
  "$FRAMEWORKS_DIR/libtrain_nidra_core.dylib"
codesign --force --sign - "$FRAMEWORKS_DIR/libtrain_nidra_core.dylib"
