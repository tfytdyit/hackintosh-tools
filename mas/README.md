# 上架 Mac App Store：可行性与操作手册（2026-11-08）

> 相关目录：`videobar/`（视频播放器 VideoBar 1.2）、`sensors/`（监控 SensorBar 5.8）
> 本文档 = 结论 + 我改好的代码 + 你还需要买/做什么

---

## 0. 一句话结论

| App | 能否上 Mac App Store | 原因 |
|---|---|---|
| **VideoBar**（视频播放器） | ✅ **能**，改动不大 | 只用 AVFoundation / SwiftUI / AppKit，全部在沙箱允许范围内 |
| **SensorBar**（监控数据） | ❌ **基本不能** | 核心功能（AppleSMC 温度/电压、libproc 进程、`diskutil` 子进程、卸载 App、`pmset` 改电源）在 App Sandbox 下被系统拒绝，且**没有 entitlement 能放开** |
| BacklightBar（亮度） | ❌ 不能 | 直接写 IOKit `bklt` 参数，沙箱禁止 |

Mac App Store 强制要求 **App Sandbox 打开**（[Apple 审核指南 2.4.5 / 构建要求](https://developer.apple.com/app-store/review/guidelines/)），而沙箱明确不允许访问 IOKit 设备（社区结论见 [IOKit not permitted in Sandbox](https://stackoverflow.com/questions/23244349/iokit-not-permitted-in-sandbox)、[sandboxed app 读 AppleSMC](https://stackoverflow.com/questions/27386340/os-x-cocoa-access-applesmc-from-sandboxed-app)）。这不是签名/权限问题，是能力被拿掉。

**心率已按你的要求从商店版里砍掉**（`-D NO_HEART` 编译开关，蓝牙相关代码与文案完全不进二进制）。

---

## 1. 我这次改好的东西

### 1.1 心率移除（SensorBar）

| 改动 | 位置 |
|---|---|
| 全部心率代码用 `#if !NO_HEART` 包起来 | `sensors/SensorBar.swift`（`hr` 属性、`heartSection`、列表引用、菜单栏 `case 4`） |
| 设置里的「心率」菜单栏模式同步隐藏 | `sensors/SettingsView.swift` |
| `HeartRate.swift` 不参与商店版编译 | `sensors/build-mas.sh` 的 swiftc 文件列表里没有它 |
| Info.plist 移除 `NSBluetoothAlwaysUsageDescription` / `NSBluetoothPeripheralUsageDescription` | `build-mas.sh` 里用 PlistBuddy 删 |
| bundle id 改成 `com.hackintosh.SensorBar.mas`（上架前换成你自己的） | 同上 |

验证（已跑）：`nm -u` 里 **0 个 CoreBluetooth 符号**、二进制里 **0 处「心率 / HUAWEI / 手环电量」字符串**。

### 1.2 商店版构建脚本

```bash
# 监控（无心率 + 沙箱）
bash sensors/build-mas.sh
#   → sensors/SensorBar-MAS.app（已用 sandbox entitlement 签名，可跑起来看哪些功能会失效）

# 播放器（沙箱 + 用户选择文件只读 + 书签）
bash videobar/build-mas.sh
#   → videobar/VideoBar-MAS.app
```

Entitlements 文件：
- `sensors/mas/SensorBar.entitlements`：`app-sandbox=true`（里面还试填了 `temporary-exception.iokit-user-client-class: [AppleSMC]`，**商店审核不会批这个临时例外**，只是用来看沙箱下的表现）
- `videobar/mas/VideoBar.entitlements`：
  - `com.apple.security.app-sandbox` = true
  - `com.apple.security.files.user-selected.read-only` = true
  - `com.apple.security.files.bookmarks.app-scope` = true
- 播放器另外加了一行沙箱适配：打开文件前 `url.startAccessingSecurityScopedResource()`（非沙箱环境返回 false，无副作用）。

### 1.3 沙箱下会失效的功能（实测清单）

| 功能 | 依赖 | 沙箱下 |
|---|---|---|
| CPU 温度/电压/风扇 | IOKit `AppleSMC` | ❌ 直接打不开用户客户端 |
| CPU 占用 ≈ 可用 `host_statistics` | Mach | ✅ 但需要重写，目前走的是 `/bin/ps` 思路的 libproc |
| 进程列表（CPU/内存榜） | libproc 读别的进程 | ❌ 只能看到自己 |
| 磁盘可用/总量、分区表 | `diskutil` 子进程 | ❌ 子进程继承沙箱，拿不到 IOKit 磁盘信息 |
| 卸载程序（扫描 `/Applications`） | 文件系统 | ❌ 只能操作用户手选的文件 |
| 一键优化（lsregister/killall/pmset） | 子进程 + 隐私权限 | ❌ 全部不可用 |
| 心率 | CoreBluetooth | ✅（沙箱允许）但已按你要求删除 |
| GPU 占用 | IOKit `IntelAccelerator` | ❌ |

**所以 SensorBar 想上商店 = 只能剩下「温度以外」的一小部分，等于把产品砍掉了。** 建议走另一条路（见第 4 节）。

---

## 2. 你需要买的/准备的东西

| 项目 | 费用 | 说明 |
|---|---|---|
| Apple Developer Program | **$99/年**（个人/公司） | 没有它无法创建 App ID、无法上传 |
| Apple Distribution 证书 | 免费（账号内生成） | 用 Xcode → Settings → Accounts → Manage Certificates |
| App Store Connect 记录 | 免费 | 建 App、填元数据、传截图 |
| 隐私政策网址 | 0 | 审核必填（可用 GitHub Pages） |
| 应用截图 | 0 | 1280×800 / 1440×900 / 2560×1600 / 2880×1800 至少一组 |
| 1024×1024 图标（直角、不透明） | 0 | 商店自动裁圆角，我们的 `AppIcon-1024.png` 需要去掉透明边 |

本机现状（我查过）：`security find-identity -v -p codesigning` → **0 valid identities**，也就是**还没有开发者证书**，Xcode 26.5 已装。所以现在只能出「本地 ad-hoc 签名的样本包」，真上架必须先买账号。

---

## 3. 上架操作步骤（官方路径）

### 3.1 账号与证书
1. https://developer.apple.com/programs/ 注册（个人 $99/年，审核 1–3 天）。
2. Xcode → Settings → Accounts → 登录 → Manage Certificates → `+` → **Apple Distribution**。
3. https://appstoreconnect.apple.com → 我的 App → `+` 新建 macOS App，记下 **Bundle ID**（如 `com.yourname.videobar`）。

### 3.2 工程化（关键：目前没有 .xcodeproj）
现在的构建是 `swiftc` 脚本，App Store 上传要求 `xcodebuild archive` 产出的 `.xcarchive`。两条路：

- **推荐**：Xcode 里新建 *macOS App*（SwiftUI，名字 VideoBar），把 `videobar/VideoBar.swift / PlayerUI.swift / Settings.swift / main.swift` 拖进去，Target 设置：
  - Signing & Capabilities → Team = 你的团队，**App Sandbox** 勾上，User Selected File = Read Only
  - Deployment Target 13.0，Architecture = x86_64（本机 Intel；Apple Silicon 需要用户自己选 Universal）
  - Info 里填 Bundle ID、版本、`LSApplicationCategoryType = public.app-category.video`
  - 加 `PrivacyInfo.xcprivacy`（见 3.4）
- 或者用 `xcodebuild -project … -scheme VideoBar archive` 命令行打包（我可以帮你生成工程文件）。

### 3.3 签名 + 打包 + 上传
```bash
# 在 Xcode 里
xcodebuild -project VideoBar.xcodeproj -scheme VideoBar -configuration Release \
           -archivePath build/VideoBar.xcarchive archive
xcodebuild -exportArchive -archivePath build/VideoBar.xcarchive \
           -exportPath build/upload -exportOptionsPlist ExportOptions.plist
```
导出后（`.pkg`）用 **Xcode Organizer** 或 **Transporter.app** 上传到 App Store Connect；
命令行也可以用 `xcrun altool --upload-app -f build/upload/VideoBar.pkg -t macos --apiKey … --apiIssuer …`（API Key 在 App Store Connect → 用户和访问 → 密钥 里建）。

### 3.4 隐私清单（必需）
新建 `PrivacyInfo.xcprivacy`，至少声明：
- `NSPrivacyAccessedAPICategoryUserDefaults` → 原因 `CA92.1`（存设置/播放位置）
- `NSPrivacyAccessedAPICategoryFileTimestamp`（如用文件时间）→ `C617.1`
- `NSPrivacyCollectedDataTypes` 空数组（不收集数据）

### 3.5 提交审核
App Store Connect → 版本信息（描述、关键词、截图、隐私政策 URL）→ 选择构建 → 提交。
VideoBar 审核关注点：
- **4.2 最低功能**：功能要完整（播放器没问题）
- **2.5.1 私有 API**：我们只用公开 API，OK
- **2.4.5 (v) 沙箱**：必须在沙箱里能跑通主要流程 —— 注意：单文件打开时同目录播放列表会被沙箱挡住（只能拿到用户选中的那个文件），所以商店版要引导用户**「打开文件夹」**或拖文件夹进来；已做降级（扫不到就单文件播放）
- 不能写 `/Applications`、不能 `killall`、不能读 SMC —— 这些在商店版都没有

---

## 4. SensorBar 的现实选择

| 方案 | 说明 | 费用/难度 |
|---|---|---|
| **Developer ID + 公证（推荐）** | 不上商店，但用户双击可直接装、Gatekeeper 不拦；保留全部功能（SMC/进程/清理/卸载） | $99/年，`codesign + notarytool`，10 分钟一条命令 |
| 不上架、直接分发 | 就是你现在的 ad-hoc 包，用户右键「打开」 | 免费 |
| 砍成商店版 | 只剩 CPU/内存/网络/电池等 Mach API 能读的部分 + 心率（你已要求砍），产品价值大幅下降 | $99/年 + 审核 |
| Setapp / 独立站 | 第三方订阅商店，允许非沙箱 App（需审核） | 分成 15% |

我的建议：**VideoBar 上商店**（流量入口），**SensorBar / BacklightBar 走 Developer ID 公证**（功能完整），两者共用同一个 $99 账号。

---

## 5. 我还能继续做的（你说一声就动手）

1. 生成 `VideoBar.xcodeproj`（可直接 `xcodebuild archive`），并把 entitlements / PrivacyInfo / 图标按商店要求配好；
2. 生成 1024×1024 直角无透明图标 + 1280×800 起的商店截图（从现有截图裁）；
3. 写 Developer ID 公证脚本（`codesign --deep --options runtime` + `xcrun notarytool submit` + `stapler staple`），给你现在这三个 App 用；
4. SensorBar 商店版若真要试：把 SMC/libproc/diskutil 功能用 `#if NO_SMC` 再剥一层，做成「CPU/内存/网络/电池」轻量版（但定位就变成另一个产品了）。
