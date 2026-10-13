#!/usr/bin/env bash
# 构建 OWABridge.app(菜单栏应用,LSUIElement)。
#   CONFIG=debug|release(默认 release)
#   UNIVERSAL=1 同时构建 arm64 + x86_64(需要完整 Xcode)
#   SIGN_IDENTITY="Developer ID Application: ..." 默认 ad-hoc 签名("-")
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
ARCH_ARGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCH_ARGS=(--arch arm64 --arch x86_64)
fi

swift build -c "$CONFIG" ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"}
BIN_DIR="$(swift build -c "$CONFIG" ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} --show-bin-path)"

APP="build/OWABridge.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/OWABridge" "$APP/Contents/MacOS/OWABridge"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/extractor.js "$APP/Contents/Resources/extractor.js"

codesign --force --deep --sign "$SIGN_IDENTITY" "$APP"
echo "Built $APP"
