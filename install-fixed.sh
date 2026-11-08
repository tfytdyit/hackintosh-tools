#!/bin/bash
# 一次性把两个 App 的修复版装进 /Applications（需要输入一次管理员密码）
set -u
cd "$(dirname "$0")" || exit 1

SB="./sensors/SensorBar.app"
VB="./videobar/VideoBar.app"
[ -d "$SB" ] || { echo "缺少 $SB，先运行 sensors/build.sh"; exit 1; }
[ -d "$VB" ] || { echo "缺少 $VB，先运行 videobar/build.sh"; exit 1; }

echo "将安装："
echo "  SensorBar $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SB/Contents/Info.plist")"
echo "  VideoBar  $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$VB/Contents/Info.plist")"
echo "需要一次管理员密码。"
sudo rm -rf /Applications/SensorBar.app /Applications/VideoBar.app
sudo ditto "$SB" /Applications/SensorBar.app
sudo ditto "$VB" /Applications/VideoBar.app
sudo chown -R root:wheel /Applications/SensorBar.app /Applications/VideoBar.app
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSR" -f /Applications/SensorBar.app >/dev/null 2>&1
"$LSR" -f /Applications/VideoBar.app >/dev/null 2>&1

pkill -f "SensorBar.app/Contents/MacOS" 2>/dev/null
pkill -f "VideoBar.app/Contents/MacOS" 2>/dev/null
sleep 1
open /Applications/SensorBar.app
sleep 2
if pgrep -f "/Applications/SensorBar.app/Contents/MacOS" >/dev/null; then echo "✅ SensorBar 已启动"; else echo "⚠️ SensorBar 启动失败"; fi
echo "✅ VideoBar 已更新，双击视频文件即可打开"
