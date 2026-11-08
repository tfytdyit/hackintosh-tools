# 安装包（HackintoshTools-1.3.pkg）

## 里面是什么

| App | 版本 | 作用 |
|---|---|---|
| SensorBar | 5.8 | 菜单栏状态监控：CPU 温度/各核/功耗/电压、GPU 占用、心率（华为手环 BLE）、电池健康、两块硬盘与分区、网络速率与测速、工具箱（清理/卸载/优化/磁盘） |
| VideoBar | 1.2 | 视频播放器，为 4K60 HEVC 130Mbps 素材优化（硬解直通、实时倍率显示、播放列表、续播） |
| BacklightBar | 1.3 | 内屏亮度控制（macOS 26 上黑苹果亮度条失效的替代方案），Fn+F5 / Fn+F6，长按连调 |

安装位置：`/Applications`。

## 安装

```bash
open HackintoshTools-1.3.pkg
```

或者 Finder 里双击。会要求输入一次管理员密码。

> 这个包是本地自签名（没有 Apple 开发者证书），系统可能提示「无法验证开发者」——**右键安装包 →「打开」**即可继续。

## 重新打包

```bash
bash installer/make-installer.sh
```

脚本会依次跑 `sensors/build.sh`、`videobar/build.sh`，然后 `pkgbuild` + `productbuild` 出新的 `HackintoshTools-1.3.pkg`（BacklightBar 用现成的 app 包）。

安装器里的欢迎文字在 `welcome.html`，完成页在 `conclusion.html`，窗口标题/选项在 `distribution.xml`，改完重跑脚本即可。

## 说明

- `.pkg` 用 `pkgbuild`/`productbuild` 生成，不需要 `hdiutil`，所以在我的沙箱里也能直接产出（DMG 需要磁盘设备权限，做不了）。
- 卸载：直接删掉 `/Applications` 里对应的三个 App 即可；SensorBar 若勾过开机自启，再删 `~/Library/LaunchAgents/com.hackintosh.SensorBar.plist`。
