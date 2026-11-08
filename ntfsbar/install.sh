#!/bin/bash
# 安装 NTFSBar：菜单栏 NTFS 读写工具（fuse-t + ntfs-3g）
# 用法：bash ntfsbar/install.sh      （会提示输入一次管理员密码）
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HERE/NTFSBar.app"
HELPER="$HERE/helper/ntfsbar-mount"
PLIST="$HERE/helper/com.hackintosh.ntfsbar.automount.plist"

bold() { printf "\033[1m%s\033[0m\n" "$*"; }
fail() { printf "\033[31m%s\033[0m\n" "$*" >&2; exit 1; }

[ -d "$APP" ] || fail "找不到 NTFSBar.app，先跑 ./build.sh"
[ -x "$HELPER" ] || fail "找不到 helper/ntfsbar-mount"

bold "== 1/4 检查依赖"
ok=1
if [ -x /usr/local/bin/ntfs-3g ]; then
  echo "  ✓ ntfs-3g: $(/usr/local/bin/ntfs-3g --version 2>&1 | head -1)"
else
  echo "  ✗ 缺少 ntfs-3g（/usr/local/bin/ntfs-3g）"; ok=0
fi
if [ -d /Library/Frameworks/fuse_t.framework ] || [ -x /usr/local/bin/go-nfsv4 ]; then
  echo "  ✓ fuse-t 已安装"
else
  echo "  ✗ 缺少 fuse-t（无内核扩展的 FUSE 实现）"; ok=0
fi
if [ "$ok" = "0" ]; then
  cat <<'TIP'

缺少依赖。两种办法：
  A. 仓库里已有现成脚本（推荐）：先跑
       bash ntfs-driver/install-ntfs3g.sh
     它会安装 fuse-t 并从源码编译 ntfs-3g（需要网络 + Xcode 命令行工具）。
  B. 自己装：
       fuse-t:  https://github.com/macos-fuse-t/fuse-t/releases
       ntfs-3g: 源码编译 ./configure --with-fuse=external && make && sudo make install
TIP
  exit 2
fi

bold "== 2/4 安装文件（需要管理员权限）"
sudo /bin/mkdir -p /usr/local/bin || fail "无法创建 /usr/local/bin"
sudo /bin/rm -rf /Applications/NTFSBar.app
sudo /usr/bin/ditto "$APP" /Applications/NTFSBar.app || fail "复制 App 失败"
sudo /bin/chmod 755 "$HELPER"
sudo /bin/cp "$HELPER" /usr/local/bin/ntfsbar-mount
sudo /usr/sbin/chown -R root:wheel /Applications/NTFSBar.app /usr/local/bin/ntfsbar-mount
echo "  ✓ /Applications/NTFSBar.app"
echo "  ✓ /usr/local/bin/ntfsbar-mount"

bold "== 3/4 注册开机自动挂载"
sudo /bin/cp "$PLIST" /Library/LaunchDaemons/com.hackintosh.ntfsbar.automount.plist
sudo /bin/chmod 644 /Library/LaunchDaemons/com.hackintosh.ntfsbar.automount.plist
sudo /usr/sbin/chown root:wheel /Library/LaunchDaemons/com.hackintosh.ntfsbar.automount.plist
sudo /bin/launchctl bootout system /Library/LaunchDaemons/com.hackintosh.ntfsbar.automount.plist >/dev/null 2>&1
sudo /bin/launchctl bootstrap system /Library/LaunchDaemons/com.hackintosh.ntfsbar.automount.plist 2>/dev/null \
  || echo "  ! launchd 注册返回非 0（下次开机仍会加载）"
echo "  ✓ /Library/LaunchDaemons/com.hackintosh.ntfsbar.automount.plist"

bold "== 3.5/4 注册登录时自启（菜单栏图标）"
AGENT="$HOME/Library/LaunchAgents/com.hackintosh.NTFSBar.plist"
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$AGENT" <<AGENTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key><string>com.hackintosh.NTFSBar</string>
	<key>ProgramArguments</key>
	<array><string>/Applications/NTFSBar.app/Contents/MacOS/NTFSBar</string></array>
	<key>RunAtLoad</key><true/>
	<key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
AGENTEOF
launchctl unload "$AGENT" >/dev/null 2>&1
launchctl load "$AGENT" 2>/dev/null || true
echo "  ✓ $AGENT"

bold "== 4/4 启动菜单栏程序"
/usr/bin/open /Applications/NTFSBar.app
sleep 1
if /usr/bin/pgrep -f "NTFSBar.app/Contents/MacOS/NTFSBar" >/dev/null; then
  echo "  ✓ NTFSBar 已在菜单栏运行（图标：硬盘）"
else
  echo "  ! 未能启动，可从 /Applications 手动打开"
fi

cat <<'NEXT'

安装完成。用法：
  · 点菜单栏硬盘图标 → 选卷 → 「挂载为可读写」（第一次会问管理员密码）
  · 已开启开机自动挂载：登录后 45 秒内，被系统只读挂载的 NTFS 卷会自动切成可读写
  · 想彻底替换 Tuxera：先确保卷都已卸载，再跑
      sudo bash ntfsbar/uninstall-tuxera.sh
NEXT
