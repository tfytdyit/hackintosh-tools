#!/bin/bash
# 构建 NTFSBar.app
set -u
cd "$(dirname "$0")" || exit 1
APP="NTFSBar.app"
rm -rf "$APP" .build
mkdir -p .build "$APP/Contents/MacOS" "$APP/Contents/Resources"

/usr/bin/swiftc -O -module-cache-path .build/mc -o .build/NTFSBar NTFSBar.swift 2>&1 | grep -E "error|warning: " | head -20
[ -x .build/NTFSBar ] || { echo "编译失败"; exit 1; }

cp .build/NTFSBar "$APP/Contents/MacOS/NTFSBar"
cp Info.plist "$APP/Contents/Info.plist"
cp helper/com.hackintosh.ntfsbar.automount.plist "$APP/Contents/Resources/"
chmod +x helper/ntfsbar-mount
/usr/bin/codesign -f -s - "$APP" 2>/dev/null

echo "完成：$(pwd)/$APP"
