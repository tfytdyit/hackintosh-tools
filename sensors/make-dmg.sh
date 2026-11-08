#!/bin/bash
# 打包 SensorBar → DMG 安装盘，并把 App 装进 /Applications
# 用法：bash $(cd "$(dirname "$0")/.." && pwd)/sensors/make-dmg.sh
set -u
WS="$(cd "$(dirname "$0")/.." && pwd)"
cd "$WS/sensors" || exit 1

bold() { printf "\033[1m%s\033[0m\n" "$*"; }

bold "==> 1/6 重新构建 App"
./build.sh || { echo "构建失败"; exit 1; }
VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" SensorBar.app/Contents/Info.plist)
NAME="SensorBar $VER"
OUT="$WS/SensorBar-$VER.dmg"
bold "   版本 $VER"

bold "==> 2/6 准备暂存目录"
STAGE=$(mktemp -d /tmp/sbdmg.XXXXXX)
cp -R SensorBar.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
mkdir -p "$STAGE/.background"
cp dmg/background.png "$STAGE/.background/background.png" 2>/dev/null
cp AppIcon.icns "$STAGE/.VolumeIcon.icns" 2>/dev/null
[ -f "$STAGE/.VolumeIcon.icns" ] && SetFile -c icnC "$STAGE/.VolumeIcon.icns" 2>/dev/null
SetFile -a V "$STAGE/.background" 2>/dev/null
echo "   暂存：$STAGE"

bold "==> 3/6 创建可写磁盘映像"
TMP="$(mktemp -u /tmp/sbdmg-img.XXXXXX).dmg"   # 必须放在 STAGE 外面，否则映像会把自己装进去
hdiutil create -srcfolder "$STAGE" -volname "$NAME" -fs HFS+ -format UDRW -ov "$TMP" >/dev/null || {
  echo "hdiutil create 失败"; exit 1; }

MNT=$(mktemp -d /tmp/sbmnt.XXXXXX)
hdiutil attach "$TMP" -nobrowse -mountpoint "$MNT" >/dev/null || { echo "挂载失败"; exit 1; }

bold "==> 4/6 设置窗口布局（可能要授权“Finder 控制”，点允许即可）"
osascript <<APPLESCRIPT >/dev/null 2>&1
tell application "Finder"
    tell disk "$NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {400, 180, 1040, 580}
        set opts to icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to 100
        set background picture of opts to file ".background:background.png"
        set position of item "SensorBar.app" of container window to {170, 200}
        set position of item "Applications" of container window to {470, 200}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT
sync
bold "==> 5/6 卸载并压缩为只读 DMG"
hdiutil detach "$MNT" >/dev/null 2>&1 || hdiutil detach "$MNT" -force >/dev/null 2>&1
rm -f "$OUT"
hdiutil convert "$TMP" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null || { echo "压缩失败"; exit 1; }
rm -rf "$STAGE" "$MNT" "$TMP"

bold "==> 6/6 安装到 /Applications"
rm -rf /Applications/SensorBar.app
if cp -R "$WS/sensors/SensorBar.app" /Applications/ 2>/dev/null; then
    echo "   已安装：/Applications/SensorBar.app"
else
    echo "   ⚠️ 无法直接写入 /Applications（权限），请手动把 DMG 里的 App 拖过去"
fi

echo
bold "完成 ✅"
echo "   DMG：$OUT  ($(du -h "$OUT" | cut -f1))"
echo "   打开：open \"$OUT\""
echo "   已装 App 可直接：open /Applications/SensorBar.app"
