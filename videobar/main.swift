import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var settingsWindow: NSWindow?
    let engine = PlayerEngine()
    private var appReady = false
    private var pendingURLs: [URL] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        VBSettings.registerDefaults()
        buildMenu()

        let d = UserDefaults.standard
        let w = d.object(forKey: VBSettings.windowWidth) as? Double ?? 1100
        let h = d.object(forKey: VBSettings.windowHeight) as? Double ?? 660
        let view = ContentView(engine: engine)
        let hosting = NSHostingView(rootView: view)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "VideoBar"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .black
        window.isMovableByWindowBackground = true
        window.isRestorable = false
        window.contentView = hosting
        window.minSize = NSSize(width: 720, height: 420)
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.delegate = self

        NotificationCenter.default.addObserver(forName: .init("VBShowSettings"), object: nil, queue: .main) { [weak self] _ in
            self?.showSettings()
        }
        if CommandLine.arguments.contains("--settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.showSettings() }
        }

        // 启动完成后再处理「开机就带文件」的 AppleEvent，避免 window 还没建好就解包
        appReady = true
        let queued = pendingURLs
        pendingURLs.removeAll()
        queued.forEach { openTarget($0) }

        // 启动参数：直接打开某个文件/文件夹
        for arg in CommandLine.arguments.dropFirst() where !arg.hasPrefix("-") {
            let url = URL(fileURLWithPath: (arg as NSString).expandingTildeInPath)
            if FileManager.default.fileExists(atPath: url.path) {
                openTarget(url)
                break
            }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let first = urls.first else { return }
        openTarget(first)
    }

    private func openTarget(_ url: URL) {
        guard appReady, window != nil else {
            pendingURLs.append(url)
            return
        }
        // 沙箱（App Store 版）下访问用户选择的文件需要显式开始访问；非沙箱时返回 false 无副作用
        _ = url.startAccessingSecurityScopedResource()
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            let files = VideoBar.filesInFolder(url)
            if let first = files.first { engine.open(first, playlist: files) }
        } else {
            let files = VideoBar.filesInFolder(url.deletingLastPathComponent())
            if files.contains(url) { engine.open(url, playlist: files) } else { engine.open(url) }
        }
        window.title = url.lastPathComponent
    }

    @objc func showSettings(_ sender: Any? = nil) {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 470, height: 520),
                             styleMask: [.titled, .closable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "VideoBar 设置"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .visible
            w.isReleasedWhenClosed = false
            w.backgroundColor = .windowBackgroundColor
            w.contentView = NSHostingView(rootView: VBSettingsView())
            w.center()
            settingsWindow = w
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openDocument(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        if panel.runModal() == .OK, let url = panel.url { openTarget(url) }
    }

    @objc func openFolder(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        if panel.runModal() == .OK, let url = panel.url { openTarget(url) }
    }

    @objc func togglePlay(_ sender: Any?) { engine.togglePlay() }
    @objc func nextItem(_ sender: Any?) { engine.next() }
    @objc func prevItem(_ sender: Any?) { engine.prev() }
    @objc func skipForward(_ sender: Any?) {
        engine.skip(UserDefaults.standard.object(forKey: VBSettings.seekStep) as? Double ?? 5)
    }
    @objc func skipBackward(_ sender: Any?) {
        engine.skip(-(UserDefaults.standard.object(forKey: VBSettings.seekStep) as? Double ?? 5))
    }
    @objc func toggleFullScreen(_ sender: Any?) { window.toggleFullScreen(nil) }

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于 VideoBar", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let prefs = NSMenuItem(title: "设置…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        prefs.target = self
        appMenu.addItem(prefs)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏 VideoBar", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "退出 VideoBar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem(); main.addItem(fileItem)
        let fileMenu = NSMenu(title: "文件")
        let open = NSMenuItem(title: "打开…", action: #selector(openDocument(_:)), keyEquivalent: "o")
        open.target = self
        fileMenu.addItem(open)
        let openDir = NSMenuItem(title: "打开文件夹…", action: #selector(openFolder(_:)), keyEquivalent: "O")
        openDir.keyEquivalentModifierMask = [.command, .shift]
        openDir.target = self
        fileMenu.addItem(openDir)
        fileItem.submenu = fileMenu

        let playItem = NSMenuItem(); main.addItem(playItem)
        let playMenu = NSMenu(title: "播放")
        let tp = NSMenuItem(title: "播放 / 暂停", action: #selector(togglePlay(_:)), keyEquivalent: " ")
        tp.keyEquivalentModifierMask = []
        tp.target = self
        playMenu.addItem(tp)
        let step = Int(UserDefaults.standard.object(forKey: VBSettings.seekStep) as? Double ?? 5)
        let fwd = NSMenuItem(title: "快进 \(step) 秒", action: #selector(skipForward(_:)), keyEquivalent: "")
        fwd.keyEquivalentModifierMask = [.command]
        fwd.target = self
        playMenu.addItem(fwd)
        let back = NSMenuItem(title: "后退 \(step) 秒", action: #selector(skipBackward(_:)), keyEquivalent: "")
        back.target = self
        playMenu.addItem(back)
        playMenu.addItem(.separator())
        let nxt = NSMenuItem(title: "下一个", action: #selector(nextItem(_:)), keyEquivalent: "\u{f703}")
        nxt.keyEquivalentModifierMask = [.command]
        nxt.target = self
        playMenu.addItem(nxt)
        let prv = NSMenuItem(title: "上一个", action: #selector(prevItem(_:)), keyEquivalent: "\u{f702}")
        prv.keyEquivalentModifierMask = [.command]
        prv.target = self
        playMenu.addItem(prv)
        playItem.submenu = playMenu

        let viewItem = NSMenuItem(); main.addItem(viewItem)
        let viewMenu = NSMenu(title: "显示")
        let fs = NSMenuItem(title: "全屏", action: #selector(toggleFullScreen(_:)), keyEquivalent: "f")
        fs.keyEquivalentModifierMask = [.command, .control]
        fs.target = self
        viewMenu.addItem(fs)
        viewItem.submenu = viewMenu

        let winItem = NSMenuItem(); main.addItem(winItem)
        let winMenu = NSMenu(title: "窗口")
        winMenu.addItem(withTitle: "最小化", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        winMenu.addItem(withTitle: "缩放", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        winItem.submenu = winMenu

        NSApp.mainMenu = main
    }
}

extension AppDelegate: NSWindowDelegate {
    func windowDidResize(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, w === window else { return }
        let d = UserDefaults.standard
        d.set(Double(w.frame.width), forKey: VBSettings.windowWidth)
        d.set(Double(w.frame.height), forKey: VBSettings.windowHeight)
    }
}

// MARK: - 探测模式（命令行自检）

func probe(_ path: String) {
    let engine = PlayerEngine()
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    engine.open(url)
    print("文件: \(url.lastPathComponent)")
    var samples: [Double] = []
    for i in 0..<10 {
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        if i == 2 {
            let m = engine.meta
            print("分辨率 \(m.resText)  帧率 \(m.fpsText)  码率 \(m.bitrateText)  编码 \(m.codec)  位深 \(m.bitDepth)  \(m.hwText)")
            print("时长 \(VideoBar.fmt(engine.duration))")
        }
        if i >= 3, engine.duration > 0 { samples.append(engine.effectiveSpeed) }
        print(String(format: "  t=%.2fs  位置=%.2fs  实时×%.3f  状态=%@", Double(i + 1), engine.position,
                     engine.effectiveSpeed, engine.stalls > 0 ? "卡顿\(engine.stalls)" : "正常"))
    }
    let avg = samples.isEmpty ? 0 : samples.reduce(0, +) / Double(samples.count)
    print(String(format: "== 平均实时倍率 ×%.3f （1.000 = 完全不掉帧）==", avg))
    engine.pause()
    exit(0)
}

let app = NSApplication.shared
if let idx = CommandLine.arguments.firstIndex(of: "--probe"), idx + 1 < CommandLine.arguments.count {
    app.setActivationPolicy(.prohibited)
    probe(CommandLine.arguments[idx + 1])
} else {
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    app.run()
}
