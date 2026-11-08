#!/bin/bash
# 重新构建三个 App 并打包成单个 .pkg 安装包
# 用法：bash $(cd "$(dirname "$0")/.." && pwd)/installer/make-installer.sh
set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

echo "==> 1/4 构建 SensorBar"
(cd sensors && ./build.sh > /tmp/build-sens.log 2>&1) || { echo "SensorBar 构建失败，见 /tmp/build-sens.log"; exit 1; }

echo "==> 2/4 构建 VideoBar"
(cd videobar && ./build.sh > /tmp/build-video.log 2>&1) || { echo "VideoBar 构建失败，见 /tmp/build-video.log"; exit 1; }

VER=1.3
echo "==> 3/4 组装暂存目录"
STAGE=$(mktemp -d /tmp/toolpack.XXXXXX)
mkdir -p "$STAGE/root/Applications" "$STAGE/res"
ditto --norsrc --noextattr --noacl sensors/SensorBar.app        "$STAGE/root/Applications/SensorBar.app"
ditto --norsrc --noextattr --noacl videobar/VideoBar.app        "$STAGE/root/Applications/VideoBar.app"
ditto --norsrc --noextattr --noacl backlight-tool/BacklightBar.app "$STAGE/root/Applications/BacklightBar.app"
find "$STAGE/root" -name "._*" -delete
cp installer/welcome.html installer/conclusion.html "$STAGE/res/"
cp installer/distribution.xml "$STAGE/"

echo "==> 4/4 打包 pkg"
(cd "$STAGE" && pkgbuild --root root --identifier com.hackintosh.toolpack --version "$VER" --install-location / ToolPack.pkg >/dev/null) || { echo "pkgbuild 失败"; exit 1; }
(cd "$STAGE" && productbuild --distribution distribution.xml --package-path . --resources res "$ROOT/HackintoshTools-$VER.pkg" >/dev/null) || { echo "productbuild 失败"; exit 1; }
rm -rf "$STAGE"

echo ""
echo "完成：$ROOT/HackintoshTools-$VER.pkg"
ls -lh "$ROOT/HackintoshTools-$VER.pkg"
echo "双击安装（或右键 →「打开」），会把三个 App 装到 /Applications。"
