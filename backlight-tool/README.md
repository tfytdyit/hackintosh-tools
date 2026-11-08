# 黑苹果内屏亮度修复包（macOS 26.7.2）

本机：Lenovo i7-9750H / UHD 630 / SMBIOS MacBookPro16,1 / 无 T2，macOS 26.7.2 (25G332)。

## 一、结论（实测得出，不是猜的）

**硬件背光通路完全正常，坏的是 macOS 26 的用户态亮度栈。**

| 实测项 | 结果 | 说明 |
|---|---|---|
| 直接写 `AppleBacklight` 的整数参数 `bklt` | 成功，屏幕**肉眼可见变暗/变亮** | iGPU PWM / 背光寄存器写入没问题 |
| `DisplayServicesCanChangeBrightness()` | `false` | 这就是系统亮度条**变灰、拖不动**的直接原因 |
| `IODisplayGetFloatParameter("brightness")` | `0xe00002c7` = `kIOReturnUnsupported` | 浮点 `brightness` 参数**不存在**，只有整数 `bklt` 在 |
| `AGDCBacklightControl` 实例数 | `0`，内核日志 `AGDCBacklightControl: Didn't find DPMicro.` | macOS 26 新的背光控制通路没起来 |
| `corebrightnessd` 日志（20 分钟） | 无任何 `CBDisplayModule` 记录，仅 `BacklightControl: default new state: 1` | 系统压根没给这块内屏建立「可控亮度」的模块 |

即：26 把亮度控制交给了 `corebrightnessd` + `AGDC`/DPMicro 这条依赖真实 Mac（T2/苹果硬件）的通路；黑苹果拿不到 DPMicro → 判定「该内屏不可调亮度」→ 把滑块灰掉。底下的 `AppleBacklight` + framebuffer 链路其实一直能用，只是没人去调它。

排除项（都已验证过）：
- **不是 WEG 的 BLR/BLT/BLS 问题**。已实测 `enable-backlight-registers-alternative-fix`（BLT）无效；内核日志里 WEG 一行输出都没有（失败会走 SYSLOG，成功要走 `-wegdbg`）。
- **不是 SSDT-PNLF 问题**。`PNLF` 存在，`_STA=0x0B`、`_UID=19`（Coffee Lake profile）完全正确，且是现代版 SSDT-PNLF（不是废弃的 PNLFCFL）。
- **不是 SMBIOS 问题**。MacBookPro16,1 是 macOS 26 官方支持的机型（`PlatformSupport.plist` 的 SupportedBoardIds 含本机 board-id）。
- 复现环境一致：`AppleBacklightDisplay` → 帧缓冲 `AppleIntelFramebuffer@0`，`IOBacklightHandlerID` 指向 `AppleIntelPanelA`，链路齐全。

## 二、交付物

```
backlight-tool/
├── BacklightBar.app   菜单栏工具：☀ 图标 + 滑块 + F5/F6 快捷键 + 开机自启
├── BacklightBar.swift 源码（自己可改）
├── blc                命令行工具：get / set / up / down / max / min
└── blc.swift          源码
```

原理都是一件事：`IOServiceGetMatchingService("AppleBacklightDisplay")` → `IODisplaySetIntegerParameter("bklt", v)` + `commit`，绕过 `corebrightnessd`。

## 三、怎么用

### 1. 菜单栏工具（推荐）

```bash
# 拷到「应用程序」（需要你自己执行，我的沙箱写不了 /Applications）
cp -R backlight-tool/BacklightBar.app /Applications/
open /Applications/BacklightBar.app
```

菜单栏会出现 ☀ 图标，点开：

- 顶部**亮度滑块**：拖动即时生效（真实改变背光，不是滤镜变暗）
- 提高/降低 10%、最亮、最暗
- **开机自动启动**：勾上后会写 `~/Library/LaunchAgents/com.hackintosh.BacklightBar.plist`（也可再点一次取消）
- 全局快捷键：**F5 降低 / F6 提高**（Fn+F5/Fn+F6 同样有效；也可直接用滑块）

### 2. 命令行工具

```bash
cd backlight-tool
./blc get          # 打印当前亮度 0-100
./blc set 40       # 设为 40%
./blc up           # +10
./blc down 5       # -5
./blc max          # 最亮
./blc min          # 最暗（0，屏幕会几乎全黑，别在没外接屏时瞎试）
```

脚本里也能用，比如 `./blc set 30` 放进定时任务。

## 四、已验证 / 已知限制

- ✅ 写 `bklt` 能**真正**改变背光（用户目视确认；`bklt` 值随读随变）
- ✅ 写入不会被 `corebrightnessd` 立刻重置（连续 45 秒观测稳定）
- ✅ App 在系统唤醒（`NSWorkspace.didWake`）后会自动重设一次，防止被系统拉满
- ⚠️ **系统自己的亮度滑块仍然是灰的**，那是根因未解，不要指望它；请用菜单栏滑块
- ⚠️ 无法写 NVRAM 的 `backlight-level`（普通用户权限不足，实测报 `(iokit/common) general error`），所以**重启后亮度恢复靠 App 的开机自启**（App 启动时会把上次的值重新写回）
- ⚠️ 无 T2 的黑苹果在 26 上想恢复系统滑块，需要让 `corebrightnessd` 认为内屏可控，目前没有公开可行方案（acidanthera issue #2407 同类症状到 Sonoma 14.5 仍未解决）

## 五、根因实验（实验 1 已于 2026-11-07 做完，结果见第六节）

想再赌一把系统滑块，可以试下面两个，**每次只改一项**，都用 `oc-experiment.py`（自动备份、一条命令回滚、只改动目标键，其余字节保持不变——已用 config 副本逐字节验证过）：

```bash
cd backlight-tool

sudo python3 oc-experiment.py show                        # 看当前 ig-platform-id / boot-args
sudo python3 oc-experiment.py set-platform-id 0900a53e    # 实验 1
sudo python3 oc-experiment.py add-bootarg -wegnoegpu      # 实验 2
sudo python3 oc-experiment.py restore                     # 一键回滚到实验前
```

1. **换 ig-platform-id**：当前 `00009b3e`（0x3E9B0000，WEG 表里 `CamelliaDisabled`），UHD 630 的 Dortania 推荐值是 **`0900a53e`**（0x3EA50009，`CamelliaV3`）。WindowServer 日志里有大量 `Fallback GPU Display Pipe transaction submission failed`，若与 Camellia 显示管道有关，这一项可能让亮度模块重新挂上。
   低风险依据（已比对 WEG 的 framebuffer 表）：两个 ID 的 `[0]` 接口**完全相同**（`busId 0x00, pipe 8, type 0x2, flags 0x98 - ConnectorLVDS`），只有 Camellia 从 `Disabled` 变 `V3`、两个 DP 口 flags 从 `0x187` 变 `0x1C7`。内屏走的正是 LVDS connector，点不亮的概率不高。
2. **`-wegnoegpu`**（boot-args 追加）：彻底对 macOS 隐藏 GTX 1050，排除 dGPU 干扰 WindowServer 选显示管道。风险很低，只影响 dGPU。

### 实验前后怎么对比

```bash
bash snapshot.sh > ~/Desktop/snapshot-after.txt   # 重启后再跑，和 safety/snapshot-before-igpu-change.txt 对比
```

关注三行：`ig-platform-id`、`Camellia` 类实例数（`CamelliaBase` / `CamelliaTcon2` 从 0 变非 0 说明 Camellia 真启用了）、`DisplayServicesCanChangeBrightness`（`false` → `true` 就是滑块复活）。

### 黑屏时怎么救

自动备份在 `/Volumes/EFI/EFI/OC/config.plist.bak.<时间戳>`；工作区 `safety/config.plist.known-good-20261107-2045` 也存着当前这份**已知能开机**的 config（md5 `0ec0083c31996bf4d45aa4a17bcb40a1`）。

- 外接 HDMI 显示器还能用 → 在外屏上 `sudo python3 oc-experiment.py restore` 后重启；
- 内外屏都黑 → 强制关机，用 **FAT32 U 盘**里的 OpenCore（把 `/Volumes/EFI/EFI` 整个拷到 U 盘的 EFI 分区）启动，再把备份 config 覆盖回去。

两项都试完仍灰，就说明 26 对非 T2 平台把这条通路堵死了，菜单栏工具就是最终答案。

## 六、实验记录与最终定性（2026-11-07）

### 实验 1：`ig-platform-id` `00009b3e` → `0900a53e`（已完成）

改后实测（重启后 `safety/snapshot-after.txt` + `safety/quick-check-*.txt`）：

| 观测点 | 改前 | 改后 |
|---|---|---|
| `CamelliaBase` 类实例 | 0 | **1** |
| `BanksiaTcon` 类实例 | 0 | **1** |
| `CamelliaTcon2` | 0 | 0 |
| `AGDCBacklightControl` | 0 | 0 |
| `DisplayServicesCanChangeBrightness` | false | false |
| 浮点 `brightness` 参数 | `0xe00002c7` (unsupported) | 同 |
| WindowServer `Fallback GPU Display Pipe ... failed` | 1790 条 / 20 分钟 | **0 条 / 12 分钟** |
| 内屏显示、像素时钟 | 正常 | 正常（`IOFBCurrentPixelClock` 152600000 不变） |

**亮度滑块没救活，但显示管道报错归零**，所以这个平台 ID 值得保留（它也是 Dortania 对 UHD 630 的官方推荐值）。

### 最终根因（内核日志原文，`safety/quick-check-*.txt`）

```
kernel: (AppleIntelCFLGraphicsFramebuffer) [IGFB][ERROR  ]  [AGDC] AGDC not registered. Unmanaged display
kernel: (AGDCBacklightControl) AGDCBacklightControl: Didn't find DPMicro.
WindowServer: (CoreBrightness) [com.apple.CoreBrightness.BSCI:default] Connection interrupted!
WindowServer: (CoreBrightness) [com.apple.CoreBrightness.BSCI:default] Connection invalidated!
```

链路是这么断的：macOS 26 的亮度栈 = `corebrightnessd` → `AGDC`（AppleGraphicsDeviceControl）→ **DPMicro**（DCP 显示协处理器，只有真 Apple 硬件 / T2 才有）。
`AGDCBacklightControl` 找不到 DPMicro 就放弃 → 显示被判为 **Unmanaged display**（未纳管）→ `corebrightnessd` 拿不到亮度模块 → `DisplayServicesCanChangeBrightness()` 返回 false → 系统滑块变灰。
这套判定在用户态无法绕过（不是配置错、不是 kext 错、不是 SMBIOS 错；`SSDT-PNLF` `_SUID/UID=19`、BLR/BLT/BLS、`SecureBootModel`、`ig-platform-id` 全部已排除），继续折腾 EFI 只会增加黑屏风险。

### 结论

- **保留 `0900a53e`**（显示管道报错归零，收益实打实）；想回到旧值随时 `sudo python3 oc-experiment.py restore`。
- **亮度用 `BacklightBar.app` / `blc` 调**，那是这台机器上唯一可用的亮度通路（直接写 `bklt` 寄存器，实测有效、不被 `corebrightnessd` 重置）。
- 想要系统原生滑块 + 亮度键，只能换真 Apple 硬件或用 Apple Silicon 虚拟机方案，黑苹果这条路在 macOS 26 已经不通。

## 七、把亮度绑到键盘上

### 1. 键盘自带的亮度键（Fn+F11/F12 之类）

新版 `BacklightBar.app` 已内置：监听系统媒体键 `NX_SYSDEFINED`（type 14），
`keyType 3` = 亮度 +10%，`keyType 2` = 亮度 -10%。

需要授权（只需一次，重装新版本后可能再问一次）：

1. 菜单栏 ☀ → 退出
2. 系统设置 → 隐私与安全性 → **输入监控** → 勾选 `BacklightBar`
3. 还要在 **辅助功能** 里也勾上 `BacklightBar`
4. 重新打开 App，菜单第一行会显示「键盘亮度键：已接管（Fn 亮度键可用）」

若显示「监听失败」，点那一条会跳到设置页，授权后退出重开即可。

### 2. 先确认你的键到底发了什么

```bash
backlight-tool/blkeys
```

然后按一下那个键，终端会打印：

- `[系统键] NX_KEYTYPE_BRIGHTNESS_UP/DOWN` → 就是媒体亮度键，上面的 App 直接能接管；
- `[普通键] keyCode=xx 修饰键=Fn+...` → 是普通 F 键，需要按 keyCode 单独绑（把这一行发给我即可）；
- 什么都不打印 → 这个键压根没传到 macOS（多半是 Fn 组合在 EC 层被吞了），得先修键盘映射，App 无法接管。

### 3. 现有快捷键（不需要任何权限）

`F5` 降低 10% / `F6` 提高 10%（Carbon 全局热键，不依赖输入监控）。

> 2026-11-07 更新：已按用户要求移除 `F1`/`F2`/`⌥F1`/`⌥F2` 绑定，只保留 `F5`/`F6`。

### 4. 实测结果（2026-11-07 21:07，本机）

- **`Fn+F5` = 亮度 −10%，`Fn+F6` = 亮度 +10%** —— 已生效（`~/Library/Logs/BacklightBar.log` 里 34 条 `hotkey id=1/2` + `apply -> ok`，`bklt` 从 65535 降到 26214）。
- 原因：本机 `VoodooPS2Keyboard` 把 Fn+F5/F6 翻成**普通 F5/F6 键码**（不是媒体键事件），所以 Carbon 全局热键直接就能接住，**不需要「输入监控」权限**。
- 日志里 `keyDown` / `sysev` 计数为 0，说明 `CGEventTap`（媒体键路径）没拿到输入监控权限 —— 但本机用不上，纯当兜底。
- `F5/F6` 是全局热键（`F1/F2` 已移除）；改完亮度立即生效，无 OSD（系统亮度栈坏了，本来就没有 OSD）。
- 开机自启：`~/Library/LaunchAgents/com.hackintosh.BacklightBar.plist`（`RunAtLoad=true`，指向 `/Applications/BacklightBar.app/...`），下次登录自动起。

## 九、长按连调（1.3 起）

按住 **Fn+F5** 会一直降亮度、按住 **Fn+F6** 会一直升亮度：

- 按下瞬间先走一步 ±10%（手感和之前一样）；
- 0.35 秒后如果键还按着，每 50ms 再走 **2%**，直到松手；
- 连调过程中按另一个键会立刻换方向。

实现方式：Carbon 热键只给「按下」一次事件，拿不到「按住」的重复，所以按下后用 `Timer` 每 50ms
调用 `CGEventSource.keyState(.combinedSessionState, key:)` 检查 F5（keyCode 96）/ F6（keyCode 97）是否仍被按住，
松手即停。日志里能看到 `hold start dir=…` / 一连串 `apply(N%)` / `hold stop`。

## 八、隐藏菜单栏图标（1.2 起）

菜单里新增 **「隐藏菜单栏图标（Fn+F5/F6 仍可用）」**：点一下就藏起 ☀，但键盘 Fn+F5 / Fn+F6、`blc` 命令都照常工作。
选择会被记住，重启/重开 App 仍然隐藏。

恢复方法（任意一种）：

```bash
open -a BacklightBar      # 再启动一次，图标就回来了
```

或者手动清掉标记后重启 App：

```bash
defaults delete com.hackintosh.BacklightBar hideIcon; osascript -e 'quit app "BacklightBar"'; open -a BacklightBar
```

建议在隐藏之前先勾上菜单里的 **「开机自动启动」**，否则重启后没有东西在跑，Fn+F5/F6 就不会生效。

> 控制中心控件（ControlWidget）路线已放弃：扩展虽然能被 `pluginkit` 识别、`chronod` 也会去连它，
> 但即便按 App Extension 标准补上 `-Xlinker -e -Xlinker _NSExtensionMain` 入口，进程仍然连接失败
> （`NSCocoaErrorDomain 4099`）。1.2 版已移除 `Contents/PlugIns/BacklightBarControls.appex`。
