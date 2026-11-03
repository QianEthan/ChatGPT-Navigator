#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h}"
if [[ ! -x "$PROJECT_DIR/AppResources/Tools/pandoc" ]]; then
  print -u2 'Pandoc is missing. First run ./Scripts/setup_pandoc.sh /path/to/pandoc'
  exit 1
fi

BUILD_DIR="$PROJECT_DIR/.build-app"
APP_DIR="$PROJECT_DIR/ChatGPT Navigator.app"
SWIFT_CACHE_DIR="$BUILD_DIR/cache"
MODULE_CACHE_DIR="$BUILD_DIR/module-cache"

mkdir -p "$SWIFT_CACHE_DIR" "$MODULE_CACHE_DIR"
export CLANG_MODULE_CACHE_PATH="$MODULE_CACHE_DIR"
export SWIFTPM_MODULECACHE_OVERRIDE="$MODULE_CACHE_DIR"

swift build \
  --package-path "$PROJECT_DIR" \
  --configuration release \
  --disable-sandbox \
  --build-path "$BUILD_DIR/swift" \
  --cache-path "$SWIFT_CACHE_DIR" \
  --config-path "$BUILD_DIR/config" \
  --security-path "$BUILD_DIR/security"

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BUILD_DIR/swift/release/ChatGPTNavigator" "$APP_DIR/Contents/MacOS/ChatGPTNavigator"
cp "$PROJECT_DIR/AppResources/Info.plist" "$APP_DIR/Contents/Info.plist"


cp -R "$PROJECT_DIR/AppResources/Tools" "$APP_DIR/Contents/Resources/Tools"
codesign --force --sign - "$APP_DIR/Contents/Resources/Tools/pandoc"
codesign --force --deep --sign - "$APP_DIR"
echo "Built: $APP_DIR"
