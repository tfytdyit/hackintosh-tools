#!/bin/bash
# 生成 Mac App Store 版本：无心率（-D NO_HEART）、开启 App Sandbox
# 说明：SensorBar 的传感器/磁盘/工具箱依赖 IOKit(AppleSMC)、libproc、diskutil 子进程，
#       App Sandbox 下会被系统拒绝——本脚本产出的是「带沙箱的构建样本」，用于验证上架可行性。
set -u
cd "$(dirname "$0")" || exit 1
SDK=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk
B="$(mktemp -d /tmp/sbmas.XXXXXX)"
APP="$B/SensorBar-MAS.app"
mkdir -p "$B/mc" "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 编译（无心率版本）"
clang -O2 -target x86_64-apple-macos26.0 -isysroot "$SDK" -I. -c bridge.c -o "$B/bridge.o" || exit 1
swiftc -O -target x86_64-apple-macos26.0 -sdk "$SDK" -module-cache-path "$B/mc" \
  -import-objc-header bridge.h \
  -o "$APP/Contents/MacOS/SensorBar" \
  SensorBar.swift SettingsView.swift UninstallerView.swift DiskToolsView.swift WindowStyle.swift Tools.swift main.swift "$B/bridge.o" \
  -framework IOKit -framework CoreFoundation -framework Metal -framework AppKit -framework SwiftUI || exit 1

echo "==> 写 Info.plist（去掉蓝牙用途描述、独立 bundle id）"
cp Info.plist "$APP/Contents/Info.plist"
for k in NSBluetoothAlwaysUsageDescription NSBluetoothPeripheralUsageDescription; do
    /usr/libexec/PlistBuddy -c "Delete :$k" "$APP/Contents/Info.plist" 2>/dev/null
done
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.hackintosh.SensorBar.mas" "$APP/Contents/Info.plist"
[ -f SensorBar.icns ] && cp SensorBar.icns "$APP/Contents/Resources/"

echo "==> 签名（本地 ad-hoc；上架时换成 Apple Distribution 证书 + provisioning profile）"
codesign -f -s - --entitlements mas/SensorBar.entitlements "$APP" || exit 1
codesign -dv "$APP" 2>&1 | head -4

echo "==> 输出到工作区"
rm -rf SensorBar-MAS.app
ditto "$APP" SensorBar-MAS.app
rm -rf "$B"
echo ""
echo "完成：$PWD/SensorBar-MAS.app"
echo "上架流程见 ../mas/README.md"
