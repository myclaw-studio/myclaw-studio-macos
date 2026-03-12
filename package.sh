#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/build"
APP_NAME="MyClaw"
APP_DISPLAY_NAME="My Claw"
VERSION="3.0.0"
DMG_NAME="MyClaw-${VERSION}-Installer"
ENTITLEMENTS="$PROJECT_DIR/.github/entitlements.plist"

echo "========================================="
echo "  My Claw 打包脚本 (Pure Swift)"
echo "========================================="

# ── Step 1: 用 xcodebuild 编译 macOS App ────────────
echo ""
echo ">>> 编译 macOS App..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

xcodebuild \
    -project "$PROJECT_DIR/AIChat/AIChat.xcodeproj" \
    -scheme AIChat \
    -destination "platform=macOS" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR/DerivedData" \
    ARCHS="arm64 x86_64" \
    ONLY_ACTIVE_ARCH=NO \
    CODE_SIGN_IDENTITY="" \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGNING_ALLOWED=NO \
    build

# 找到编译出的 .app
APP_PATH=$(find "$BUILD_DIR/DerivedData" -name "$APP_NAME.app" -type d | head -1)
if [ -z "$APP_PATH" ]; then
    echo "找不到编译好的 $APP_NAME.app"
    exit 1
fi
echo "App 编译完成: $APP_PATH"

# ── Step 2: 签名 ─────────────────────────────────────
echo ""

# 检测是否有 Developer ID 证书
DEVID=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | awk -F'"' '{print $2}')

if [ -n "$DEVID" ]; then
    echo ">>> Developer ID 签名: $DEVID"
    SIGN_IDENTITY="$DEVID"

    # 签名嵌套 framework
    find "$APP_PATH" -name "*.framework" -type d | while read -r fw; do
        codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$fw"
    done

    # 签名所有 Mach-O 可执行文件
    find "$APP_PATH" -type f -perm +111 | while read -r bin; do
        if file "$bin" | grep -q "Mach-O"; then
            codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp \
                --entitlements "$ENTITLEMENTS" "$bin"
        fi
    done

    # 签名顶层 App bundle
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp \
        --entitlements "$ENTITLEMENTS" "$APP_PATH"
    echo "Developer ID 签名完成"
else
    echo ">>> Ad-hoc 签名 (未检测到 Developer ID 证书)"
    codesign --force --deep --sign - "$APP_PATH"
    echo "Ad-hoc 签名完成"
fi

# ── Step 3: 创建 DMG ─────────────────────────────────
echo ""
echo ">>> 创建 DMG..."
STAGING_DIR="$BUILD_DIR/dmg-staging"
rm -rf "$STAGING_DIR"
mkdir -p "$STAGING_DIR"
cp -R "$APP_PATH" "$STAGING_DIR/"
ln -s /Applications "$STAGING_DIR/Applications"

DMG_PATH="$PROJECT_DIR/$DMG_NAME.dmg"
rm -f "$DMG_PATH"
hdiutil create \
    -volname "$APP_DISPLAY_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"

# ── Step 4: 清理 Xcode 全局 DerivedData 中的旧副本 ────
XCODE_DD="$HOME/Library/Developer/Xcode/DerivedData"
if [ -d "$XCODE_DD" ]; then
    find "$XCODE_DD" -name "$APP_NAME.app" -type d -exec rm -rf {} + 2>/dev/null || true
    echo "已清理 Xcode DerivedData 旧副本"
fi

# ── Step 5: 自动安装到 /Applications ──────────────────
echo ""
echo ">>> 安装到 /Applications..."
pkill -f "$APP_NAME" 2>/dev/null || true
sleep 1
rm -rf "/Applications/$APP_NAME.app"
cp -R "$APP_PATH" "/Applications/$APP_NAME.app"
echo "已安装到 /Applications"

# ── Step 6: 启动 App ─────────────────────────────────
open "/Applications/$APP_NAME.app"

echo ""
echo "========================================="
echo "打包安装完成！"
echo "  DMG: $DMG_PATH"
echo "  App: /Applications/$APP_NAME.app (已启动)"
if [ -n "$DEVID" ]; then
    echo "  签名: Developer ID ($DEVID)"
    echo ""
    echo "下一步公证:"
    echo "  ./scripts/notarize-local.sh $DMG_PATH"
else
    echo "  签名: Ad-hoc (仅本机可用)"
    echo ""
    echo "如需分发，请先安装 Developer ID 证书再重新打包"
fi
echo "========================================="
