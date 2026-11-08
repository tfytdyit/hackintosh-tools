#!/bin/bash
# 生成 Mac App Store（沙箱）版本：VideoBar-MAS.app
# 需要：Apple Developer Program 账号 + 「Apple Distribution」证书（本地先用 ad-hoc 占位）
set -u
cd "$(dirname "$0")" || exit 1
SDK=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
B="$(mktemp -d /tmp/vbmas.XXXXXX)"
APP="$B/VideoBar-MAS.app"
mkdir -p "$B/mc" "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 编译"
swiftc -O -target x86_64-apple-macos13.0 -sdk "$SDK" -module-cache-path "$B/mc" \
  -o "$APP/Contents/MacOS/VideoBar" \
  VideoBar.swift PlayerUI.swift Settings.swift main.swift \
  -framework AVFoundation -framework AppKit -framework SwiftUI -framework VideoToolbox -framework CoreMedia || exit 1

echo "==> Info.plist"
cp Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.hackintosh.VideoBar.mas" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString 1.2" "$APP/Contents/Info.plist" 2>/dev/null
[ -f VideoBar.icns ] && cp VideoBar.icns "$APP/Contents/Resources/"

echo "==> 沙箱签名"
codesign -f -s - --entitlements mas/VideoBar.entitlements "$APP" || exit 1
codesign -d --entitlements - "$APP" 2>/dev/null | head -14
codesign --verify --strict "$APP" && echo "签名校验通过"

echo "==> 输出到工作区"
rm -rf VideoBar-MAS.app
ditto "$APP" VideoBar-MAS.app
rm -rf "$B"
echo "完成：$PWD/VideoBar-MAS.app"
