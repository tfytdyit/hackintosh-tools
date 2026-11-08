#!/bin/bash
set -e
cd "$(cd "$(dirname "$0")/.." && pwd)"
APPPATH="${1:?usage: make-portable.sh <path/to/App.app>}"
APP=$(basename "$APPPATH" .app)
VER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APPPATH/Contents/Info.plist")
STAGE=$(mktemp -d /tmp/port-$APP.XXXXXX)
ditto --norsrc --noextattr --noacl "$APPPATH" "$STAGE/$APP.app"
cat > "$STAGE/install.command" <<CMD
#!/bin/bash
cd "\$(dirname "\$0")"
sudo rm -rf "/Applications/$APP.app"
sudo ditto --norsrc --noextattr --noacl "$APP.app" "/Applications/$APP.app"
sudo chown -R root:wheel "/Applications/$APP.app"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/$APP.app"
open "/Applications/$APP.app"
echo "已安装 $APP $VER 到 /Applications"
CMD
chmod +x "$STAGE/install.command"
OUT="$APP-$VER-portable.zip"
rm -f "$OUT"
(cd "$STAGE" && zip -qry "$OLDPWD/$OUT" .)
rm -rf "$STAGE"
echo "$OUT ($(du -h "$OUT" | cut -f1))"
