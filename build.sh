#!/bin/bash
# 编译 SpeedBar 并打包成 .app
#
# 构建过程不碰现有产物：
#   1. 在临时目录里编译、写 Info.plist、签名、校验；
#   2. 全部通过后才把旧产物移到 build/backups/ 保留；
#   3. 最后把新产物移入 build/SpeedBar.app。
# 因此任何一步失败，现有 build/SpeedBar.app 都保持原样。
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="SpeedBar"
BUILD_DIR="build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
BACKUP_DIR="$BUILD_DIR/backups"
STAGE_PARENT="${TMPDIR:-/tmp}"
STAGE_DIR="$(mktemp -d "$STAGE_PARENT/speedbar-build.XXXXXX")"

# 只清理本次自己创建的临时目录，避免误删其他路径
cleanup() {
  case "$STAGE_DIR" in
    "$STAGE_PARENT"/speedbar-build.*) rm -rf "$STAGE_DIR" ;;
  esac
}
trap cleanup EXIT

echo "==> 编译 Swift 源码..."
mkdir -p "$STAGE_DIR/$APP_NAME.app/Contents/MacOS"
swiftc -O \
  -target "$(uname -m)-apple-macosx11.0" \
  -o "$STAGE_DIR/$APP_NAME.app/Contents/MacOS/$APP_NAME" \
  Sources/SpeedBar.swift

echo "==> 写入 Info.plist..."
cp Info.plist "$STAGE_DIR/$APP_NAME.app/Contents/Info.plist"

echo "==> ad-hoc 签名..."
codesign --force --deep --sign - "$STAGE_DIR/$APP_NAME.app"

echo "==> 校验..."
codesign --verify --verbose=2 "$STAGE_DIR/$APP_NAME.app"
plutil -lint "$STAGE_DIR/$APP_NAME.app/Contents/Info.plist"

mkdir -p "$BUILD_DIR" "$BACKUP_DIR"
if [ -d "$APP_DIR" ]; then
  BACKUP="$BACKUP_DIR/$APP_NAME.app.$(date +%Y%m%d-%H%M%S)"
  mv "$APP_DIR" "$BACKUP"
  echo "==> 旧产物已备份：$BACKUP"
fi
mv "$STAGE_DIR/$APP_NAME.app" "$APP_DIR"

echo "==> 完成：$APP_DIR"
echo "    旧产物保留在 $BACKUP_DIR/，可自行清理"
