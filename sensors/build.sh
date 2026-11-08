#!/bin/bash
# 一键重建 smc / sensmon / SensorBar.app
set -e
cd "$(dirname "$0")"
SDK=$(xcrun --show-sdk-path)
mkdir -p .build

echo "== 编译 smc / sensmon（命令行）"
clang -O2 -o smc smc.c -framework IOKit -framework CoreFoundation
clang -O2 -o sensmon sensmon.c -framework IOKit -framework CoreFoundation

echo "== 编译 SensorBar（C 桥接 + SwiftUI）"
clang -O2 -target x86_64-apple-macos26.0 -isysroot "$SDK" -I. -c bridge.c -o .build/bridge.o
swiftc -O -target x86_64-apple-macos26.0 -sdk "$SDK" -module-cache-path .build/mc \
    -import-objc-header bridge.h -o .build/SensorBar SensorBar.swift SettingsView.swift UninstallerView.swift DiskToolsView.swift WindowStyle.swift Tools.swift main.swift .build/bridge.o \
    -framework IOKit -framework CoreFoundation -framework Metal -framework AppKit -framework SwiftUI -framework CoreWLAN

echo "== 组装并签名 App"
rm -rf .build/SensorBar.app
mkdir -p .build/SensorBar.app/Contents/MacOS .build/SensorBar.app/Contents/Resources
cp .build/SensorBar .build/SensorBar.app/Contents/MacOS/
cp SensorBar.icns .build/SensorBar.app/Contents/Resources/
cp Info.plist .build/SensorBar.app/Contents/Info.plist
# 工作区是 file-provider 卷，会往 bundle 里塞 FinderInfo / fpfs 扩展属性，
# codesign 会因此报 "resource fork, Finder information, or similar detritus not allowed"。
# 解决：拷到 /tmp 里签名（普通卷），再 ditto 回来。
SIGN_DIR=$(mktemp -d /tmp/sbsign.XXXXXX)
rm -rf "$SIGN_DIR/SensorBar.app"
ditto --norsrc --noextattr --noacl .build/SensorBar.app "$SIGN_DIR/SensorBar.app"
/usr/bin/xattr -cr "$SIGN_DIR/SensorBar.app"
codesign -f -s - --force "$SIGN_DIR/SensorBar.app"
codesign --verify --strict "$SIGN_DIR/SensorBar.app"
rm -rf SensorBar.app
ditto --norsrc --noextattr --noacl "$SIGN_DIR/SensorBar.app" SensorBar.app
rm -rf "$SIGN_DIR"
/usr/bin/xattr -cr SensorBar.app 2>/dev/null || true

echo "== 完成: $(pwd)/SensorBar.app"
echo "   运行: open SensorBar.app"
echo "   装到 /Applications: cp -R SensorBar.app /Applications/"
