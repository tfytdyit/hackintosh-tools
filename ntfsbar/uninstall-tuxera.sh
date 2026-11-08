#!/bin/bash
# 卸载 Tuxera NTFS（把 NTFS 读写交给 NTFSBar：fuse-t + ntfs-3g）
# 用法：sudo bash uninstall-tuxera.sh
set -u
[ "$(id -u)" -eq 0 ] || { echo "需要 root：sudo bash $0"; exit 1; }

echo "== 1/4 卸载所有 NTFS 卷（先卸载才能移除驱动）"
mount | awk '/tuxera_ntfs/ {print $3}' | while read -r mp; do
  [ -n "$mp" ] && /usr/sbin/diskutil unmount force "$mp" >/dev/null 2>&1 && echo "  已卸载 $mp"
done
sleep 1

echo "== 2/4 停止并移除 Tuxera 的文件系统驱动"
for f in /Library/Filesystems/tuxera_ntfs.fs /Library/Filesystems/ufsd_NTFS.fs; do
  [ -e "$f" ] && rm -rf "$f" && echo "  删除 $f"
done
for k in /Library/Extensions/tuxera*.kext /Library/Extensions/ufsd*.kext; do
  [ -e "$k" ] && rm -rf "$k" && echo "  删除 $k"
done

echo "== 3/4 移除 Tuxera 守护进程 / 启动项"
for d in \
  /Library/LaunchDaemons/com.tuxera*.plist \
  /Library/LaunchDaemons/com.paragon*.plist \
  /Library/LaunchAgents/com.tuxera*.plist \
  /Library/PrivilegedHelperTools/com.tuxera* ; do
  [ -e "$d" ] && rm -rf "$d" && echo "  删除 $d"
done
rm -rf "/Library/Application Support/Tuxera NTFS" 2>/dev/null
rm -f /Library/Preferences/com.tuxera.NTFS.plist 2>/dev/null
rm -rf "/Applications/Tuxera Disk Manager.app" "/Applications/Tuxera NTFS for Mac" 2>/dev/null

echo "== 4/4 重新挂载 NTFS 卷（用 ntfs-3g 接管）"
if [ -x /usr/local/bin/ntfsbar-mount ]; then
  /usr/local/bin/ntfsbar-mount auto || true
else
  echo "  NTFSBar 助手未安装，先跑 ntfsbar/install.sh；现在只做系统默认（只读）挂载："
  diskutil list -plist | /usr/bin/grep -o 'disk[0-9]s[0-9]*' | sort -u | while read -r d; do
    /usr/sbin/diskutil mount "$d" >/dev/null 2>&1 || true
  done
fi

cat <<'DONE'

完成。若「系统设置 → 隐私与安全性」里还留着 Tuxera 的扩展条目，可忽略
（重启后不再加载）。之后 NTFS 读写由 NTFSBar 负责。
DONE
