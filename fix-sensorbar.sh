#!/bin/bash
# 修复 /Applications/SensorBar.app（该目录属 root，需要输入一次管理员密码）
set -u
cd "$(dirname "$0")" || exit 1
APP="$PWD/sensors/SensorBar.app"
[ -d "$APP" ] || { echo "找不到 $APP，请先运行 sensors/build.sh"; exit 1; }
echo "将用工作区的新构建替换 /Applications/SensorBar.app（需要管理员密码）"
sudo rm -rf /Applications/SensorBar.app
sudo ditto "$APP" /Applications/SensorBar.app
sudo chown -R root:wheel /Applications/SensorBar.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/SensorBar.app >/dev/null 2>&1
pkill -f "SensorBar.app/Contents/MacOS" 2>/dev/null
sleep 1
open /Applications/SensorBar.app
sleep 2
if pgrep -f "/Applications/SensorBar.app/Contents/MacOS" >/dev/null; then
  echo "✅ 已修复并启动，菜单栏应该能看到温度"
else
  echo "⚠️ 启动失败，请把终端输出发给我"
fi
