// BacklightBar —— Hackintosh 内屏亮度菜单栏控制（macOS 26 亮度栈不认内屏时的替代方案）
// 原理：绕过 corebrightnessd / DisplayServices，直接写 AppleBacklight 的整数参数 bklt（实测能真正改变背光）
import Cocoa
import IOKit
import IOKit.graphics
import Carbon.HIToolbox

// MARK: - 背光读写

final class Backlight {
    static let displayClass = "AppleBacklightDisplay"

    private static func service() -> io_service_t {
        IOServiceGetMatchingService(0, IOServiceMatching(displayClass))
    }

    struct Range {
        var value: Int32
        var minValue: Int32
        var maxValue: Int32
        var percent: Int {
            guard maxValue > minValue else { return 0 }
            return Int((Double(value) / Double(maxValue) * 100).rounded())
        }
    }

    static func read() -> Range? {
        let svc = service()
        guard svc != 0 else { return nil }
        defer { IOObjectRelease(svc) }
        var value: Int32 = -1, minv: Int32 = -1, maxv: Int32 = -1
        let kr = IODisplayGetIntegerRangeParameter(svc, 0, "bklt" as CFString, &value, &minv, &maxv)
        guard kr == KERN_SUCCESS, maxv > 0 else { return nil }
        return Range(value: value, minValue: minv, maxValue: maxv)
    }

    @discardableResult
    static func write(percent: Int) -> Bool {
        let svc = service()
        guard svc != 0 else { return false }
        defer { IOObjectRelease(svc) }
        var value: Int32 = -1, minv: Int32 = -1, maxv: Int32 = -1
        guard IODisplayGetIntegerRangeParameter(svc, 0, "bklt" as CFString, &value, &minv, &maxv) == KERN_SUCCESS,
              maxv > 0 else { return false }
        let pct = max(0, min(100, percent))
        let target = Int32((Double(pct) / 100.0 * Double(maxv)).rounded())
        let kr = IODisplaySetIntegerParameter(svc, 0, "bklt" as CFString, target)
        _ = IODisplaySetIntegerParameter(svc, 0, "commit" as CFString, 1)
        _ = IODisplayCommitParameters(svc, 0)
        return kr == KERN_SUCCESS
    }
}

// MARK: - 应用

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var slider: NSSlider!
    private var percentLabel: NSTextField!
    private var menu: NSMenu!
    private var lastPercent: Int = 100
    private var hotKeyRefs: [EventHotKeyRef] = []
    private var refreshTimer: Timer?
    private var mediaKeyTap: CFMachPort?
    private var logURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/BacklightBar.log")
    }
    private func log(_ msg: String) {
        let df = DateFormatter()
        df.dateFormat = "HH:mm:ss.SSS"
        let line = "\(df.string(from: Date())) \(msg)\n"
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile(); h.write(line.data(using: .utf8)!); try? h.close()
        } else {
            try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? line.write(to: logURL, atomically: true, encoding: .utf8)
        }
    }
    private var mediaKeyItem: NSMenuItem?

    private let launchAgentLabel = "com.hackintosh.BacklightBar"
    /// 长按 F5/F6 连调：按键是否仍被按住（轮询 CGEventSource）
    private var isHolding = false
    private var holdTimer: Timer?
    private var holdDirection = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: "亮度")
            button.image?.isTemplate = true
        }
        buildMenu()
        statusItem.menu = menu
        menu.delegate = self

        // 上次手动隐藏了图标 → 继续隐藏（Fn+F5/F6 与 blc 仍然有效）
        if UserDefaults.standard.bool(forKey: "hideIcon") {
            statusItem.isVisible = false
            log("statusItem hidden (restored from prefs)")
        }

        if let r = Backlight.read() { lastPercent = r.percent }
        // 开机/重新启动本 App 时恢复上次设定的亮度（系统 NVRAM 里存的仍是最大值，且普通用户无法写入）
        if let saved = UserDefaults.standard.object(forKey: "lastPercent") as? Int, saved != lastPercent {
            apply(percent: saved)
        }
        registerHotKeys()
        startMediaKeyTap()

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake),
            name: NSWorkspace.didWakeNotification, object: nil)
    }

    // MARK: URL scheme（供控制中心控件调用）：backlightbar://up / down / max / min

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard url.scheme == "backlightbar" else { continue }
            log("url open: \(url.absoluteString)")
            switch url.host {
            case "up": step(+10)
            case "down": step(-10)
            case "max": apply(percent: 100)
            case "min": apply(percent: 0)
            case "hide": hideIcon()
            case "show": showIcon()
            default: break
            }
        }
    }

    private func buildMenu() {
        menu = NSMenu()
        menu.autoenablesItems = false

        // 顶部：亮度滑块
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 240, height: 34))
        slider = NSSlider(frame: NSRect(x: 12, y: 6, width: 160, height: 22))
        slider.minValue = 0
        slider.maxValue = 100
        slider.doubleValue = Double(lastPercent)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(sliderChanged(_:))
        percentLabel = NSTextField(labelWithString: "\(lastPercent)%")
        percentLabel.frame = NSRect(x: 180, y: 9, width: 50, height: 18)
        percentLabel.alignment = .right
        container.addSubview(slider)
        container.addSubview(percentLabel)
        let sliderItem = NSMenuItem()
        sliderItem.view = container
        menu.addItem(sliderItem)

        menu.addItem(.separator())
        addItem("提高 10%", #selector(increase))
        addItem("降低 10%", #selector(decrease))
        addItem("最亮", #selector(setMax))
        addItem("最暗", #selector(setMin))
        menu.addItem(.separator())
        mediaKeyItem = addItem("键盘亮度键：检测中…", #selector(retryMediaKeyTap))
        menu.addItem(.separator())
        addItem("重新读取当前亮度", #selector(refresh))
        addItem("隐藏菜单栏图标（Fn+F5/F6 仍可用）", #selector(hideIconAction))
        let auto = addItem("开机自动启动", #selector(toggleLaunchAgent))
        auto.state = isLaunchAgentInstalled() ? .on : .off
        menu.addItem(.separator())
        addItem("退出", #selector(quit))
    }

    @discardableResult
    private func addItem(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return item
    }

    // MARK: 隐藏 / 恢复菜单栏图标

    @objc private func hideIconAction() { hideIcon() }

    private func hideIcon() {
        UserDefaults.standard.set(true, forKey: "hideIcon")
        statusItem.isVisible = false
        log("hide menu bar icon")
    }

    private func showIcon() {
        UserDefaults.standard.set(false, forKey: "hideIcon")
        statusItem.isVisible = true
        log("show menu bar icon")
    }

    /// 图标藏起来之后，再启动一次 App（open -a BacklightBar）就能让它回来
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if UserDefaults.standard.bool(forKey: "hideIcon") { showIcon() }
        return true
    }

    // MARK: 键盘上的亮度键（系统媒体键 NX_SYSDEFINED）

    /// 监听 NX_SYSDEFINED（type 14）里的亮度键：keyType 3 = 亮度+，2 = 亮度-。
    /// 这类键在 macOS 26 被 corebrightnessd 吃掉但无人处理，所以由本工具接管。
    /// 需要「系统设置 → 隐私与安全性 → 输入监控」里允许本 App。
    private func startMediaKeyTap() {
        if mediaKeyTap != nil { return }
        let mask = (CGEventMask(1) << 14) | (CGEventMask(1) << CGEventType.keyDown.rawValue)
        let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                    place: .headInsertEventTap,
                                    options: .listenOnly,
                                    eventsOfInterest: mask,
                                    callback: { _, type, event, _ in
            if type.rawValue == 14, let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 {
                let data1 = ns.data1
                let keyType = (data1 & 0xFFFF0000) >> 16
                let state = (data1 & 0x0000FF00) >> 8
                DispatchQueue.main.async {
                    (NSApplication.shared.delegate as? AppDelegate)?
                        .log("sysev keyType=\(keyType) state=0x\(String(state, radix: 16))")
                }
                if state == 0x0A { // key down
                    DispatchQueue.main.async {
                        guard let d = NSApplication.shared.delegate as? AppDelegate else { return }
                        if keyType == 3 { d.step(+10) } else if keyType == 2 { d.step(-10) }
                    }
                }
            } else if type == .keyDown {
                let code = event.getIntegerValueField(.keyboardEventKeycode)
                let f = event.flags
                var mods = ""
                if f.contains(.maskSecondaryFn) { mods += "fn+" }
                if f.contains(.maskAlternate) { mods += "opt+" }
                if f.contains(.maskShift) { mods += "shift+" }
                if f.contains(.maskControl) { mods += "ctrl+" }
                if f.contains(.maskCommand) { mods += "cmd+" }
                DispatchQueue.main.async {
                    (NSApplication.shared.delegate as? AppDelegate)?
                        .log("keyDown code=\(code) mods=\(mods.isEmpty ? "-" : mods)")
                }
            }
            return Unmanaged.passUnretained(event)
        }, userInfo: nil)

        guard let tap = tap else {
            mediaKeyItem?.title = "键盘亮度键：监听失败，点此授予「输入监控」权限后重试"
            log("mediaKeyTap: FAILED (nil) — 需要输入监控权限")
            return
        }
        log("mediaKeyTap: started")
        mediaKeyTap = tap
        if let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        mediaKeyItem?.title = "键盘亮度键：已接管（Fn 亮度键可用）"
    }

    @objc private func retryMediaKeyTap() {
        if mediaKeyTap != nil {
            CGEvent.tapEnable(tap: mediaKeyTap!, enable: true)
            mediaKeyItem?.title = "键盘亮度键：已接管（Fn 亮度键可用）"
            return
        }
        // 打开「输入监控」设置页，用户授权后本项会显示已接管
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
        startMediaKeyTap()
    }

    // MARK: 动作

    @objc private func sliderChanged(_ sender: NSSlider) {
        apply(percent: Int(sender.doubleValue.rounded()))
    }

    @objc private func increase() { apply(percent: lastPercent + 10) }
    @objc private func decrease() { apply(percent: lastPercent - 10) }
    @objc private func setMax() { apply(percent: 100) }
    @objc private func setMin() { apply(percent: 0) }

    @objc private func refresh() {
        if let r = Backlight.read() { updateUI(percent: r.percent) }
    }

    private func apply(percent: Int) {
        let pct = max(0, min(100, percent))
        let ok = Backlight.write(percent: pct)
        log("apply(\(pct)%) -> \(ok ? "ok" : "FAILED")")
        if ok { updateUI(percent: pct) }
    }

    private func updateUI(percent: Int) {
        lastPercent = percent
        UserDefaults.standard.set(percent, forKey: "lastPercent")
        slider?.doubleValue = Double(percent)
        percentLabel?.stringValue = "\(percent)%"
        statusItem.button?.image = NSImage(
            systemSymbolName: percent > 66 ? "sun.max.fill" : (percent > 33 ? "sun.max" : "sun.min"),
            accessibilityDescription: "亮度")
        statusItem.button?.image?.isTemplate = true
    }

    @objc private func didWake() {
        // 唤醒后 corebrightnessd 可能把背光拉回全亮，重新应用一次
        if let saved = UserDefaults.standard.object(forKey: "lastPercent") as? Int {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                self?.apply(percent: saved)
            }
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        refresh()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self = self, let r = Backlight.read() else { return }
            if r.percent != self.lastPercent { self.updateUI(percent: r.percent) }
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    // MARK: 快捷键（F5 降低 / F6 提高）

    private func registerHotKeys() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { (_, event, _) -> OSStatus in
            var hkID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            guard status == noErr else { return status }
            DispatchQueue.main.async {
                guard let delegate = NSApplication.shared.delegate as? AppDelegate else { return }
                delegate.log("hotkey id=\(hkID.id)")
                delegate.handleHotkey(id: hkID.id)
            }
            return noErr
        }, 1, &spec, nil, nil)

        let signature = OSType(0x424C4B31) // 'BLK1'
        // 只保留 F5（降低）/ F6（提高），F1/F2 已按要求移除
        let combos: [(UInt32, UInt32)] = [
            (UInt32(kVK_F5), 0),
            (UInt32(kVK_F6), 0),
        ]
        for (index, combo) in combos.enumerated() {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: signature, id: UInt32(index % 2 == 0 ? 1 : 2))
            let kr = RegisterEventHotKey(combo.0, combo.1, id, GetApplicationEventTarget(), 0, &ref)
            if kr == noErr, let ref = ref { hotKeyRefs.append(ref) }
        }
    }

    // MARK: 长按连调

    /// 热键按下：先走一步，然后开始轮询按键状态；按住则每 50ms 走 2%。
    fileprivate func handleHotkey(id: UInt32) {
        let dir = (id == 1) ? -1 : +1
        // 清掉上一次可能残留的连调状态（快速点按时 Timer 还没建起来）；
        // 连调中按下另一个键 = 换方向重新开始
        stopHolding()
        step(dir * 10)                       // 第一下照旧 ±10%
        holdDirection = dir
        isHolding = true
        let key: CGKeyCode = (id == 1) ? CGKeyCode(kVK_F5) : CGKeyCode(kVK_F6)
        // 0.35s 后开始连调，模拟系统按键重复的手感
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self = self, self.isHolding else { return }
            self.holdTimer?.invalidate()
            let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                let stillDown = CGEventSource.keyState(.combinedSessionState, key: key)
                if !stillDown {
                    self.stopHolding()
                    return
                }
                self.step(self.holdDirection * 2)   // 连调步长 2%
            }
            RunLoop.main.add(timer, forMode: .common)
            self.holdTimer = timer
        }
        log("hold start dir=\(dir) key=\(key)")
    }

    private func stopHolding() {
        holdTimer?.invalidate()
        holdTimer = nil
        isHolding = false
        log("hold stop")
    }

    fileprivate func step(_ delta: Int) {
        if let r = Backlight.read() { lastPercent = r.percent }
        apply(percent: lastPercent + delta)
    }

    // MARK: 开机自启（LaunchAgent）

    private var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(launchAgentLabel).plist")
    }

    private func isLaunchAgentInstalled() -> Bool {
        FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    @objc private func toggleLaunchAgent() {
        let fm = FileManager.default
        if isLaunchAgentInstalled() {
            _ = try? fm.removeItem(at: launchAgentURL)
            notify("已关闭开机自动启动")
        } else {
            let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
            let plist: [String: Any] = [
                "Label": launchAgentLabel,
                "ProgramArguments": [exe],
                "RunAtLoad": true,
                "KeepAlive": false,
                "ProcessType": "Interactive",
            ]
            guard let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) else { return }
            try? fm.createDirectory(at: launchAgentURL.deletingLastPathComponent(),
                                    withIntermediateDirectories: true)
            if (try? data.write(to: launchAgentURL)) != nil {
                notify("已设置开机自动启动")
            } else {
                notify("写入 LaunchAgent 失败")
            }
        }
        // 更新勾选状态
        menu.item(withTitle: "开机自动启动")?.state = isLaunchAgentInstalled() ? .on : .off
    }

    private func notify(_ text: String) {
        percentLabel?.stringValue = text
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
