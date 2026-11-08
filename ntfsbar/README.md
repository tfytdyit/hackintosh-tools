# NTFSBar — 用 fuse-t + ntfs-3g 读写 NTFS（不依赖 Tuxera）

菜单栏小工具：点硬盘图标 → 选卷 → 挂载为可读写 / 卸载 / 在 Finder 打开。

## 依赖（本机已装好）

- `fuse-t` 1.2.9：`/Library/Frameworks/fuse_t.framework`、`/usr/local/bin/go-nfsv4`
- `ntfs-3g` 2022.10.3：`/usr/local/bin/ntfs-3g`（external FUSE 29）
- 若换机器，先跑仓库里的 `ntfs-driver/install-ntfs3g.sh`（装 fuse-t + 编译 ntfs-3g）

## 安装

```bash
cd ntfsbar
./build.sh            # 生成 NTFSBar.app
bash install.sh       # 需要一次管理员密码
```

安装内容：

| 路径 | 作用 |
|---|---|
| `/Applications/NTFSBar.app` | 菜单栏程序 |
| `/usr/local/bin/ntfsbar-mount` | 提权助手（挂载/卸载/自动挂载） |
| `/Library/LaunchDaemons/com.hackintosh.ntfsbar.automount.plist` | 开机 45 秒内把「系统只读挂载」的 NTFS 卷自动换成可读写 |

## 用法

```bash
ntfsbar-mount status                        # 看 ntfs-3g 版本、console 用户、当前 NTFS 挂载
ntfsbar-mount mount /dev/disk0s5 Software   # 挂载为可读写（需要 sudo 或 App 里的输入密码）
ntfsbar-mount unmount /Volumes/Software     # 卸载
ntfsbar-mount auto                          # 把只读挂载的 NTFS 卷切成可读写
```

菜单栏里还有「全部挂载 / 全部卸载 / 开机自动挂载 / 打开 /Volumes」。

## 和 Tuxera 共存 / 替换

- 共存：NTFSBar 只动**只读挂载**的卷，Tuxera 挂好的卷不会被抢。
- 替换：先确保所有 NTFS 卷都已卸载，再
  ```bash
  sudo bash uninstall-tuxera.sh
  sudo ntfsbar-mount auto
  ```
  脚本会卸载 Tuxera 卷、删掉 `/Library/Filesystems/tuxera_ntfs.fs`、扩展、LaunchDaemons 和 Tuxera Disk Manager，然后用 ntfs-3g 接管。
  ⚠️ 卸载 Tuxera 后想换回去要重新下载官方 dmg 安装。
  ⚠️ 卸载后 Tuxera 的内核扩展可能仍处于已加载状态（`kextstat | grep tuxera` 还能看到），
     文件已删除，**重启一次**就彻底不加载了；重启后 macOS 会先把 NTFS 卷只读挂上，
     NTFSBar 的自动挂载守护进程在 45 秒内把它们换成 ntfs-3g 可读写。

## 已在本机切换完成（2026-11-08）

Tuxera 已卸载，4 个 NTFS 卷全部由 ntfs-3g 接管：

```
/dev/disk0s2  D              677.1GB  可读写(nfs)  /Volumes/D
/dev/disk1s2  F              623.9GB  可读写(nfs)  /Volumes/F
/dev/disk0s5  Software        54.1GB  可读写(nfs)  /Volumes/Software
/dev/disk0s1  Win11 Pro X64  215.0GB  可读写(nfs)  /Volumes/Win11 Pro X64
```

`--list` 输出中的 `nfs` 就是 fuse-t 的挂载方式（不是网络盘）。检测 NTFS 时不能只看
`diskutil` 的 `FilesystemType`（ntfs-3g 挂上后它会误报 `msdos`），要按挂载表里的文件系统
（`ntfs` / `tuxera_ntfs` / `ufsd_NTFS` / `nfs`）判断。

## 注意

- 切到 Windows 前建议先卸载卷（或在 Windows 里正常关机），避免快速启动把分区标记成脏盘。
- `/tmp` 在 macOS 上是 `/private/tmp` 的软链接：卸载时要 `umount /private/tmp/xxx` 或 `diskutil unmount`，否则会报 `not currently mounted`。
- fuse-t 的挂载在 `mount` 里显示为 `fuse-t:/<卷名> ... (nfs)`，这是正常的（走本地 NFS 回环）。

## 排障：同一卷出现两条 fuse-t 挂载

ntfs-3g 有时会把 `mount -t nfs` 卡在半路，导致同一挂载点堆叠两层。清理：

```bash
for i in $(seq 1 8); do
  sudo /sbin/umount -f /Volumes/D 2>/dev/null
  n=$(/sbin/mount | grep -c "on /Volumes/D (nfs)")
  [ "$n" -eq 0 ] && break; sleep 0.4
done
sudo pkill -f "go-nfsv4 --volname D"
sudo diskutil mount /dev/disk0s2      # 先让系统挂一次
sudo ntfsbar-mount auto               # 再由 NTFSBar 换成可读写
```

## 重启之后的自动挂载

重启后 macOS 会先把 NTFS 卷以只读挂上（`(ntfs, ... read-only)`），
`/Library/LaunchDaemons/com.hackintosh.ntfsbar.automount.plist` 每 45 秒扫一次，
把只读的卷换成 ntfs-3g 可读写，日志在 `/var/log/ntfsbar.log`。

如果某个卷（例如 `/Volumes/Win11 Pro X64`，名字里带空格）一直没被换掉，
说明 helper 解析挂载点时按空格截断了 —— 1.1 已修（`auto_mount` 改用 sed 抽挂载点）。
手动补一次：

```bash
sudo /usr/local/bin/ntfsbar-mount auto
```
