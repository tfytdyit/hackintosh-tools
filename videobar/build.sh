#!/bin/bash
# 编译并打包 VideoBar.app
set -u
cd "$(dirname "$0")" || exit 1
SDK=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
ROOT="$PWD"
B="$ROOT/.build"
mkdir -p "$B/mc" "$B/App/VideoBar.app/Contents/MacOS" "$B/App/VideoBar.app/Contents/Resources"

echo "==> 编译 VideoBar"
swiftc -O -target x86_64-apple-macos13.0 -sdk "$SDK" -module-cache-path "$B/mc" \
  -o "$B/VideoBar" VideoBar.swift PlayerUI.swift Settings.swift main.swift \
  -framework AVFoundation -framework AppKit -framework SwiftUI -framework VideoToolbox -framework CoreMedia || exit 1

echo "==> 组装 App"
cp "$B/VideoBar" "$B/App/VideoBar.app/Contents/MacOS/VideoBar"
cp Info.plist "$B/App/VideoBar.app/Contents/Info.plist"
[ -f VideoBar.icns ] && cp VideoBar.icns "$B/App/VideoBar.app/Contents/Resources/VideoBar.icns"

echo "==> 签名"
codesign -f -s - --force "$B/App/VideoBar.app" 2>/dev/null
codesign --verify --strict "$B/App/VideoBar.app" 2>/dev/null || echo "（签名校验跳过）"

echo "==> 输出到工作区"
rm -rf "$ROOT/VideoBar.app"
ditto "$B/App/VideoBar.app" "$ROOT/VideoBar.app"
echo "完成: $ROOT/VideoBar.app"
