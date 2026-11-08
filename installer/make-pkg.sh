#!/bin/bash
# 用法: bash installer/make-pkg.sh sensorbar|videobar
# 单独为某个 App 打一个 .pkg（不再打合集包）
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

TARGET="${1:-}"
case "$TARGET" in
  sensorbar) APP="SensorBar";  DIR="sensors";  DESC="状态监控：温度/占用/功耗/电池/磁盘/网络/工具箱" ;;
  videobar)  APP="VideoBar";   DIR="videobar"; DESC="视频播放器：4K60 HEVC 硬解、变速、播放列表" ;;
  *) echo "用法: bash installer/make-pkg.sh sensorbar|videobar"; exit 1 ;;
esac

echo "==> 1/4 构建 $APP"
(cd "$DIR" && ./build.sh > "/tmp/build-$TARGET.log" 2>&1) || { echo "$APP 构建失败，见 /tmp/build-$TARGET.log"; exit 1; }

VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$DIR/$APP.app/Contents/Info.plist")
BID="com.hackintosh.$(echo "$APP" | tr '[:upper:]' '[:lower:]')"
OUT="$ROOT/$APP-$VER.pkg"
echo "   版本 $VER"

echo "==> 2/4 暂存"
STAGE=$(mktemp -d /tmp/pkg-$TARGET.XXXXXX)
mkdir -p "$STAGE/root/Applications" "$STAGE/res"
ditto --norsrc --noextattr --noacl "$DIR/$APP.app" "$STAGE/root/Applications/$APP.app"
find "$STAGE/root" -name "._*" -delete

sed -e "s|@TITLE@|$APP $VER|g" \
    -e "s|@APP@|$APP|g" \
    -e "s|@VER@|$VER|g" \
    -e "s|@DESC@|$DESC|g" \
    -e "s|@BID@|$BID|g" \
    installer/welcome.html > "$STAGE/res/welcome.html"
sed -e "s|@APP@|$APP|g" -e "s|@VER@|$VER|g" installer/conclusion.html > "$STAGE/res/conclusion.html"
sed -e "s|@APP@|$APP|g" -e "s|@VER@|$VER|g" -e "s|@BID@|$BID|g" installer/distribution.xml > "$STAGE/distribution.xml"

# 关键：必须关掉 bundle relocation，否则系统上任何同名 bundle（比如工作区里的
# .../sensors/SensorBar.app）会让 Installer 把内容"重定位"到那里，/Applications 里什么都不留
cat > "$STAGE/component.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<array>
  <dict>
    <key>BundleHasStrictIdentifier</key><true/>
    <key>BundleIsRelocatable</key><false/>
    <key>BundleIsVersionChecked</key><false/>
    <key>BundleOverwriteAction</key><string>upgrade</string>
    <key>RootRelativeBundlePath</key><string>Applications/$APP.app</string>
  </dict>
</array>
</plist>
PLIST

echo "==> 3/4 pkgbuild"
(cd "$STAGE" && pkgbuild --root root --identifier "$BID" --version "$VER" --install-location / --component-plist component.plist Payload.pkg >/dev/null) || { echo "pkgbuild 失败"; rm -rf "$STAGE"; exit 1; }

echo "==> 4/4 productbuild"
(cd "$STAGE" && productbuild --distribution distribution.xml --package-path . --resources res "$OUT" >/dev/null) || { echo "productbuild 失败"; rm -rf "$STAGE"; exit 1; }
rm -rf "$STAGE"

echo ""
echo "完成：$OUT"
ls -lh "$OUT"
