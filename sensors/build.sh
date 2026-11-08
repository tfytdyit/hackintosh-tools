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
    -import-objc-header bridge.h -o .build/SensorBar SensorBar.swift HeartRate.swift SettingsView.swift UninstallerView.swift DiskToolsView.swift WindowStyle.swift Tools.swift main.swift .build/bridge.o \
    -framework IOKit -framework CoreFoundation -framework Metal -framework AppKit -framework SwiftUI -framework CoreWLAN -framework CoreBluetooth

echo "== 组装并签名 App"
rm -rf .build/SensorBar.app
mkdir -p .build/SensorBar.app/Contents/MacOS .build/SensorBar.app/Contents/Resources
cp .build/SensorBar .build/SensorBar.app/Contents/MacOS/
cp SensorBar.icns .build/SensorBar.app/Contents/Resources/
cp Info.plist .build/SensorBar.app/Contents/Info.plist
codesign -f -s - --force .build/SensorBar.app
codesign --verify --strict .build/SensorBar.app
rm -rf SensorBar.app
ditto .build/SensorBar.app SensorBar.app

echo "== 完成: $(pwd)/SensorBar.app"
echo "   运行: open SensorBar.app"
echo "   装到 /Applications: cp -R SensorBar.app /Applications/"
