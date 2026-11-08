# Hackintosh Tools · macOS 26 小工具集

三个原生 macOS 菜单栏/桌面工具，用 Swift + SwiftUI（部分 C + IOKit）写成，主打**零依赖、单文件构建脚本、本地自签名即可运行**。为 macOS 26 (Tahoe) 的 Liquid Glass 设计，在 Intel Hackintosh 上实测通过（也适用于白苹果）。

| App | 版本 | 说明 |
|---|---|---|
| **SensorBar** | 5.9.3 | 菜单栏状态监控：CPU 温度/各核温度/功耗/电压（直读 AppleSMC）、GPU 占用、内存细分、电池健康、磁盘读写、实时网速 + Cloudflare 测速、进程 TOP、工具箱（清理缓存/卸载 App/一键优化） |
| **VideoBar** | 1.4.0 | 视频播放器：4K60 HEVC 硬解直通（实时 ×1.000）、2× 以上自动按机器性能挑代理档位（1080p / 720p / 540p，够快则直放 4K）、悬浮毛玻璃控制条、播放列表、续播、全屏、独立设置窗口 |
| **NTFSBar** | 1.2 | 免 Tuxera 的 NTFS 读写：macFUSE 本地挂载（`mount` 显示 `macfuse`）优先、fuse-t 回环兜底；菜单栏一键挂载/卸载/全部挂载、开机自动接管、菜单顶部显示当前挂载后端 |

## 下载 / 安装

- **Releases 页面** ：`SensorBar-<版本>.pkg`、`VideoBar-<版本>.pkg`、`NTFSBar-<版本>.zip`（前两个各自装到 `/Applications`，NTFSBar 用 `install.command` 安装）
- 或自行构建（见下），产物直接 `open` 即可

> 双击 pkg（提示「Apple无法验证」时打开设置→隐私与安全性→安全性→仍要打开）。已装旧版会原地覆盖。

## 构建（无需 Xcode 工程，脚本直接调 swiftc/clang）

要求：macOS 26 + Xcode（命令行工具即可），Intel 或 Apple Silicon。

```bash
# SensorBar（菜单栏监控）
cd sensors && ./build.sh            # → sensors/SensorBar.app

# VideoBar（播放器）
cd videobar && ./build.sh           # → videobar/VideoBar.app

# NTFSBar（NTFS 读写，需先装 macFUSE / fuse-t + ntfs-3g）
cd ntfsbar && ./build.sh            # → ntfsbar/NTFSBar.app
sudo bash ntfsbar/install.sh        # 装 App + helper + 开机自动挂载

一键打 pkg（两个 App 一起）：

```bash
bash installer/make-installer.sh    # → HackintoshTools-<ver>.pkg
```

## 目录结构

```
sensors/         SensorBar：SwiftUI 界面 + bridge.c（AppleSMC / IOKit / libproc）+ smc/sensmon 命令行
videobar/        VideoBar：AVFoundation + SwiftUI
ntfsbar/         NTFSBar：菜单栏 NTFS 读写（macFUSE 本地挂载 / fuse-t 兜底）+ helper + LaunchDaemon
installer/       pkgbuild/productbuild 打包脚本（带安装器欢迎页/完成页）
mas/             可选：App Store 可行性分析与沙箱版构建脚本
```
## 已知限制

- SensorBar 的传感器数据来自 SMC，不同机型键名不同（本项目在 i7-9750H + UHD 630 上验证）；风扇转速依赖 SMCSuperIO，部分机型 SMC 不暴露（本机 `FNum=0`）。

## License

MIT，见 [LICENSE](LICENSE)。
