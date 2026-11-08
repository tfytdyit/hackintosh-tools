import Foundation
import SwiftUI
import AppKit

// MARK: - 清理工具（缓存 / 日志 / 废纸篓 …）

struct CleanItem: Identifiable {
    let id: String
    let title: String
    let icon: String
    let url: URL
    var needsRoot: Bool = false
    var size: Int64 = 0
    var exists: Bool = true
}

final class Toolbox: ObservableObject {
    @Published var items: [CleanItem] = []
    @Published var lastMessage: String = ""
    @Published var scanning = false

    init() { rescan() }

    static func defs() -> [CleanItem] {
        let home = NSHomeDirectory()
        func mk(_ id: String, _ title: String, _ icon: String, _ path: String, root: Bool = false) -> CleanItem {
            CleanItem(id: id, title: title, icon: icon,
                      url: URL(fileURLWithPath: path.hasPrefix("/") ? path : home + "/" + path),
                      needsRoot: root)
        }
        return [
            mk("caches", "用户缓存", "shippingbox", "Library/Caches"),
            mk("logs", "应用日志", "doc.text", "Library/Logs"),
            mk("crash", "崩溃报告", "exclamationmark.triangle", "Library/Logs/DiagnosticReports"),
            mk("xcode", "Xcode 派生数据", "hammer", "Library/Developer/Xcode/DerivedData"),
            mk("sim", "模拟器缓存", "iphone", "Library/Developer/CoreSimulator/Caches"),
            mk("trash", "废纸篓", "trash", ".Trash"),
            mk("syscache", "系统缓存", "gear", "/Library/Caches", root: true),
        ]
    }

    func rescan() {
        let list = Toolbox.defs()
        scanning = true
        DispatchQueue.global(qos: .utility).async {
            var out: [CleanItem] = []
            for var it in list {
                it.exists = FileManager.default.fileExists(atPath: it.url.path)
                it.size = it.exists ? Toolbox.size(of: it.url) : 0
                out.append(it)
            }
            DispatchQueue.main.async {
                self.items = out
                self.scanning = false
            }
        }
    }

    static func size(of url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            let n = (try? fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber) ?? nil
            return n?.int64Value ?? 0
        }
        guard let e = fm.enumerator(at: url,
                                    includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey],
                                    options: [.skipsPackageDescendants],
                                    errorHandler: nil) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            guard let v = try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]) else { continue }
            total += Int64(v.totalFileAllocatedSize ?? v.fileAllocatedSize ?? 0)
        }
        return total
    }

    /// 清理某个目录里的内容（保留目录本身）
    func clean(_ item: CleanItem) {
        guard !item.needsRoot else {
            lastMessage = "「\(item.title)」需要管理员权限，请在终端执行：sudo rm -rf /Library/Caches/*"
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            var freed: Int64 = 0
            var failed = 0
            let kids = (try? fm.contentsOfDirectory(at: item.url, includingPropertiesForKeys: nil, options: [])) ?? []
            for k in kids {
                let s = Toolbox.size(of: k)
                do {
                    try fm.removeItem(at: k)
                    freed += s
                } catch {
                    failed += 1
                }
            }
            DispatchQueue.main.async {
                let status = failed == 0 ? "已清理" : "部分清理（\(failed) 项被占用）"
                self.lastMessage = "\(status)「\(item.title)」，释放 \(Toolbox.human(freed))"
                self.rescan()
            }
        }
    }

    func cleanAll() {
        let targets = items.filter { $0.exists && $0.size > 0 && !$0.needsRoot }
        guard !targets.isEmpty else {
            lastMessage = "没有可清理的项目"
            return
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            var freed: Int64 = 0
            var failed = 0
            for item in targets {
                let kids = (try? fm.contentsOfDirectory(at: item.url, includingPropertiesForKeys: nil, options: [])) ?? []
                for k in kids {
                    let s = Toolbox.size(of: k)
                    do { try fm.removeItem(at: k); freed += s } catch { failed += 1 }
                }
            }
            DispatchQueue.main.async {
                self.lastMessage = "已清理 \(targets.count) 个位置，释放 \(Toolbox.human(freed))" + (failed > 0 ? "（\(failed) 项被占用）" : "")
                self.rescan()
            }
        }
    }

    // MARK: 维护动作（不需要管理员权限的）
    func runMaintenance(_ kind: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            func sh(_ cmd: String) {
                let q = Process()
                q.executableURL = URL(fileURLWithPath: "/bin/sh")
                q.arguments = ["-c", cmd]
                try? q.run()
                q.waitUntilExit()
            }
            var msg = ""
            switch kind {
            case "clipboard":
                sh("/usr/bin/pbcopy < /dev/null"); msg = "剪贴板已清空"
            case "dock":
                sh("/usr/bin/killall Dock 2>/dev/null"); msg = "Dock 已重启"
            case "finder":
                sh("/usr/bin/killall Finder 2>/dev/null"); msg = "Finder 已重启"
            case "dns":
                sh("/usr/bin/dscacheutil -flushcache 2>&1"); msg = "已刷新本地 DNS 缓存（mDNSResponder 需 sudo）"
            case "purge":
                msg = "释放内存需要在终端执行：sudo purge"
            default:
                msg = "未知操作"
            }
            DispatchQueue.main.async { self.lastMessage = msg }
        }
    }

    static func human(_ b: Int64) -> String {
        if b <= 0 { return "0 B" }
        let kb = Double(b) / 1024
        if kb < 1024 { return String(format: "%.0f KB", kb) }
        let mb = kb / 1024
        if mb < 1024 { return String(format: "%.1f MB", mb) }
        return String(format: "%.2f GB", mb / 1024)
    }
}

// MARK: - 卸载程序

// MARK: - 卸载程序

struct AppItem: Identifiable {
    let id: String          // 路径
    let name: String
    let url: URL
    let bundleID: String
    var size: Int64
    var icon: NSImage?
}

final class Uninstaller: ObservableObject {
    @Published var apps: [AppItem] = []
    @Published var scanning = false
    @Published var message = ""

    func scan() {
        scanning = true
        DispatchQueue.global(qos: .userInteractive).async {
            let fm = FileManager.default
            let dir = URL(fileURLWithPath: "/Applications")
            var out: [AppItem] = []
            if let kids = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) {
                for u in kids where u.pathExtension == "app" {
                    let info = Bundle(url: u)?.infoDictionary
                    let bid = (info?["CFBundleIdentifier"] as? String) ?? ""
                    let nm = (info?["CFBundleDisplayName"] as? String)
                        ?? (info?["CFBundleName"] as? String)
                        ?? u.deletingPathExtension().lastPathComponent
                    let icon = NSWorkspace.shared.icon(forFile: u.path)
                    icon.size = NSSize(width: 32, height: 32)
                    out.append(AppItem(id: u.path, name: nm, url: u, bundleID: bid, size: 0, icon: icon))
                }
            }
            out.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            DispatchQueue.main.async {
                self.apps = out
                self.scanning = false
                self.computeSizes()
            }
        }
    }

    /// 体积在后台逐个补上（Adobe 这类几个 GB 的程序很慢）
    func computeSizes() {
        let snapshot = apps
        DispatchQueue.global(qos: .utility).async {
            for app in snapshot {
                let sz = Toolbox.size(of: app.url)
                DispatchQueue.main.async {
                    if let i = self.apps.firstIndex(where: { $0.id == app.id }) {
                        self.apps[i].size = sz
                    }
                }
            }
        }
    }

    /// 需要 root 权限的系统级残留（/Library 下）
    func systemLeftovers(for app: AppItem) -> [URL] {
        let fm = FileManager.default
        var out: [URL] = []
        var names = [app.bundleID, app.name]
        if let vendor = vendorFolder(for: app.bundleID) {
            names.append(vendor)
        }
        names = names.filter { !$0.isEmpty }
        for n in names {
            out.append(URL(fileURLWithPath: "/Library/Application Support/\(n)"))
            out.append(URL(fileURLWithPath: "/Library/Preferences/\(n).plist"))
            out.append(URL(fileURLWithPath: "/Library/Caches/\(n)"))
            out.append(URL(fileURLWithPath: "/Library/Logs/\(n)"))
        }
        for dir in ["/Library/LaunchDaemons", "/Library/LaunchAgents"] {
            if let kids = try? fm.contentsOfDirectory(atPath: dir) {
                for k in kids where !app.bundleID.isEmpty && k.contains(app.bundleID) {
                    out.append(URL(fileURLWithPath: dir + "/" + k))
                }
            }
        }
        return out.filter { fm.fileExists(atPath: $0.path) }
    }

    /// 从 bundle id 猜厂商目录名（com.better365.menubar → Better365）
    func vendorFolder(for bundleID: String) -> String? {
        let parts = bundleID.split(separator: ".")
        guard parts.count >= 3 else { return nil }
        let key = parts[1].lowercased()
        for root in ["/Library/Application Support", NSHomeDirectory() + "/Library/Application Support"] {
            if let kids = try? FileManager.default.contentsOfDirectory(atPath: root) {
                for k in kids where k.lowercased() == key { return k }
            }
        }
        return nil
    }

    /// 应用可能留下的支持文件
    func leftovers(for app: AppItem) -> [URL] {
        let home = NSHomeDirectory()
        var paths: [String] = []
        let bid = app.bundleID
        if !bid.isEmpty {
            paths += [
                "\(home)/Library/Application Support/\(bid)",
                "\(home)/Library/Caches/\(bid)",
                "\(home)/Library/Preferences/\(bid).plist",
                "\(home)/Library/Logs/\(bid)",
                "\(home)/Library/Containers/\(bid)",
                "\(home)/Library/Saved Application State/\(bid).savedState",
                "\(home)/Library/HTTPStorages/\(bid)",
                "\(home)/Library/WebKit/\(bid)",
            ]
        }
        paths.append("\(home)/Library/Application Support/\(app.name)")
        return paths.map { URL(fileURLWithPath: $0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func leftoversSize(for app: AppItem) -> Int64 {
        leftovers(for: app).reduce(Int64(0)) { $0 + Toolbox.size(of: $1) }
    }

    /// 移到废纸篓（可恢复），返回提示文本
    /// 说明：macOS 13+ 有「App 管理」TCC 权限，未授权时 trashItem 会报
    /// "you don't have permission to access it"；此时自动降级为管理员权限移动（弹密码）。
    func uninstall(_ items: [AppItem], removeLeftovers: Bool, done: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            var freed: Int64 = 0
            var names: [String] = []
            var blocked: [String] = []
            var needAdmin: [AppItem] = []
            var appFail = 0
            var leftoverFail = 0
            var firstError = ""

            for app in items {
                var isRunning = false
                if !app.bundleID.isEmpty {
                    isRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty
                }
                if !isRunning {
                    // bundle id 为空 / 不匹配时，按可执行文件路径判断
                    isRunning = !NSWorkspace.shared.runningApplications.contains {
                        ($0.executableURL?.path ?? "").hasPrefix(app.url.path + "/")
                    }
                }
                if isRunning {
                    // 先尝试优雅退出（和 Finder 删 App 的行为一致），退不掉就跳过
                    for r in NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID) { r.terminate() }
                    if app.bundleID.isEmpty {
                        for r in NSWorkspace.shared.runningApplications
                        where (r.executableURL?.path ?? "").hasPrefix(app.url.path + "/") { r.terminate() }
                    }
                    usleep(1_500_000)
                    var stillRunning = false
                    if !app.bundleID.isEmpty {
                        stillRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty
                    }
                    if !stillRunning {
                        stillRunning = NSWorkspace.shared.runningApplications.contains {
                            ($0.executableURL?.path ?? "").hasPrefix(app.url.path + "/")
                        }
                    }
                    if stillRunning { blocked.append(app.name); continue }
                }
                do {
                    try fm.trashItem(at: app.url, resultingItemURL: nil)
                    names.append(app.name)
                    freed += app.size
                    if removeLeftovers {
                        for u in self.leftovers(for: app) {
                            let s = Toolbox.size(of: u)
                            do { try fm.trashItem(at: u, resultingItemURL: nil); freed += s }
                            catch { leftoverFail += 1; if firstError.isEmpty { firstError = error.localizedDescription } }
                        }
                    }
                } catch {
                    // 权限不足 → 走管理员兜底
                    let ns = error as NSError
                    if ns.code == 513 || ns.code == 257 || ns.code == 1 ||
                        ns.localizedDescription.localizedCaseInsensitiveContains("permission") {
                        needAdmin.append(app)
                    } else {
                        appFail += 1
                        if firstError.isEmpty { firstError = ns.localizedDescription }
                    }
                }
            }

            // 一次管理员密码搞定：需要权限的 App 本体 + /Library 下的系统级残留
            var sysLeftoverFail = 0
            var adminOK: [AppItem] = []
            if !needAdmin.isEmpty || removeLeftovers {
                var adminPaths: [URL] = needAdmin.map { $0.url }
                var sysSizes: [Int64] = []
                if removeLeftovers {
                    var sysPaths: [URL] = []
                    for a in items { sysPaths.append(contentsOf: self.systemLeftovers(for: a)) }
                    sysSizes = sysPaths.map { Toolbox.size(of: $0) }
                    adminPaths.append(contentsOf: sysPaths)
                }
                if !adminPaths.isEmpty {
                    if let err = self.moveWithAdmin(adminPaths) {
                        if firstError.isEmpty { firstError = err }
                        if !needAdmin.isEmpty { appFail += needAdmin.count }
                        sysLeftoverFail = sysSizes.count
                    } else {
                        adminOK = needAdmin
                        for a in adminOK {
                            names.append(a.name)
                            freed += a.size
                            if removeLeftovers {
                                for u in self.leftovers(for: a) {
                                    let s = Toolbox.size(of: u)
                                    try? fm.trashItem(at: u, resultingItemURL: nil)
                                    freed += s
                                }
                            }
                        }
                        for s in sysSizes { freed += s }
                    }
                }
            }

            DispatchQueue.main.async {
                var msg: String
                if names.isEmpty {
                    msg = firstError.isEmpty ? "没有可卸载的项目" : "卸载失败：\(firstError)"
                    if !blocked.isEmpty { msg += "（\(blocked.joined(separator: "、")) 正在运行，请先退出）" }
                    msg += "。可在「系统设置 → 隐私与安全性 → App 管理」里允许 SensorBar 直接删除，否则请用管理员密码重试" 
                } else {
                    msg = "已把 \(names.joined(separator: "、")) 移到废纸篓，释放 \(Toolbox.human(freed))"
                    if removeLeftovers { msg += "（含残留文件）" }
                    if !adminOK.isEmpty { msg += "；其中含管理员权限删除" }
                    if leftoverFail > 0 { msg += "，\(leftoverFail) 个残留项失败" }
                    if sysLeftoverFail > 0 { msg += "，\(sysLeftoverFail) 个系统残留未清理" }
                    if !blocked.isEmpty { msg += "；已跳过正在运行的 \(blocked.joined(separator: "、"))" }
                }
                self.message = msg
                self.scan()
                done(msg)
            }
        }
    }

    /// 用管理员权限把 App 移到废纸篓（返回 nil 表示成功，否则返回错误说明）
    /// 注意：脚本通过 argv 传给 osascript，避免三层引号嵌套。
    func moveWithAdmin(_ urls: [URL]) -> String? {
        guard !urls.isEmpty else { return nil }
        let trash = NSHomeDirectory() + "/.Trash"
        let list = urls.map { shQuote($0.path) }.joined(separator: " ")
        let script = "/bin/mkdir -p \(shQuote(trash)) && /bin/mv -f \(list) \(shQuote(trash))/"
        return runAdmin(script)
    }

    /// 以管理员权限执行一段 shell 脚本（返回 nil 表示成功）
    func runAdmin(_ script: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = [
            "-e", "on run argv",
            "-e", "do shell script (item 1 of argv) with administrator privileges",
            "-e", "end run",
            "--", script
        ]
        let errPipe = Pipe(); p.standardError = errPipe
        p.standardOutput = Pipe()
        do { try p.run() } catch { return error.localizedDescription }
        p.waitUntilExit()
        if p.terminationStatus == 0 { return nil }
        let d = errPipe.fileHandleForReading.readDataToEndOfFile()
        let s = String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if s.contains("-128") || s.localizedCaseInsensitiveContains("User canceled") { return "已取消授权" }
        return s.isEmpty ? "管理员权限操作被取消或失败" : s
    }

    private func shQuote(_ s: String) -> String {
        return "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

}

// MARK: - 维护 / 优化 / TRIM

extension Toolbox {
    /// 一键优化（全部是用户级操作，不需要 sudo）
    func optimize(done: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let ls = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
            let tasks: [(String, String)] = [
                ("重建 LaunchServices 数据库", "\(ls) -kill -r -domain local -domain system -domain user"),
                ("清理 QuickLook 缩略图缓存", "/usr/bin/qlmanage -r cache"),
                ("刷新 DNS 缓存", "/usr/bin/dscacheutil -flushcache"),
                ("重启 Dock", "/usr/bin/killall Dock"),
                ("重启 Finder", "/usr/bin/killall Finder"),
            ]
            var ok: [String] = []
            for (title, cmd) in tasks {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = ["-c", cmd + " >/dev/null 2>&1"]
                do {
                    try p.run()
                    p.waitUntilExit()
                    if p.terminationStatus == 0 { ok.append(title) }
                } catch { }
            }
            // 清空废纸篓
            let trash = URL(fileURLWithPath: NSHomeDirectory() + "/.Trash")
            var freed: Int64 = 0
            if let kids = try? FileManager.default.contentsOfDirectory(at: trash, includingPropertiesForKeys: nil, options: []) {
                for k in kids {
                    let s = Toolbox.size(of: k)
                    if (try? FileManager.default.removeItem(at: k)) != nil { freed += s }
                }
            }
            DispatchQueue.main.async {
                var msg = "优化完成：\(ok.joined(separator: "、"))"
                if freed > 0 { msg += "；废纸篓释放 \(Toolbox.human(freed))" }
                self.lastMessage = msg
                self.rescan()
                done(msg)
            }
        }
    }

    /// 读 NVMe / SATA 的 TRIM 状态
    static func trimStatus() -> String {
        func run(_ path: String, _ args: [String]) -> String {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            do { try p.run(); p.waitUntilExit() } catch { return "" }
            let d = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: d, encoding: .utf8) ?? ""
        }
        let nvme = run("/usr/sbin/system_profiler", ["SPNVMeDataType"])
        var model = ""
        var trim = ""
        for line in nvme.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("Model:") && model.isEmpty { model = t.replacingOccurrences(of: "Model:", with: "").trimmingCharacters(in: .whitespaces) }
            if t.hasPrefix("TRIM Support:") { trim = t.replacingOccurrences(of: "TRIM Support:", with: "").trimmingCharacters(in: .whitespaces) }
        }
        if !trim.isEmpty {
            return "磁盘：\(model.isEmpty ? "NVMe SSD" : model)\nTRIM：\(trim)（NVMe 由系统自动下发 TRIM，无需手动处理）"
        }
        let sata = run("/usr/sbin/system_profiler", ["SPSerialATADataType"])
        for line in sata.split(separator: "\n") where line.contains("TRIM Support:") {
            trim = line.replacingOccurrences(of: "TRIM Support:", with: "").trimmingCharacters(in: .whitespaces)
        }
        if trim.isEmpty { return "没有找到支持 TRIM 的 SSD（或用磁盘工具 → 宗卷 → 信息查看）" }
        return "SATA SSD TRIM：\(trim)"
    }

    /// 用管理员权限跑 trimforce（需要输入密码）
    func enableTRIM(done: @escaping (String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "do shell script \"/usr/sbin/trimforce enable\" with administrator privileges"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = pipe
            var msg = ""
            do {
                try p.run()
                p.waitUntilExit()
                let d = pipe.fileHandleForReading.readDataToEndOfFile()
                let out = String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                msg = p.terminationStatus == 0 ? "已启用 TRIM，重启后生效。\(out.isEmpty ? "" : "\n" + out)" : "未能启用：\(out)"
            } catch {
                msg = "无法执行 trimforce：\(error.localizedDescription)"
            }
            DispatchQueue.main.async { done(msg) }
        }
    }
}

// MARK: - 性能模式（CPU 功耗 / 睿频策略）

/// 以管理员权限执行脚本（返回 nil 表示成功，否则返回错误说明）
func runAdminScript(_ script: String) -> String? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
    p.arguments = [
        "-e", "on run argv",
        "-e", "do shell script (item 1 of argv) with administrator privileges",
        "-e", "end run",
        "--", script
    ]
    let errPipe = Pipe(); p.standardError = errPipe
    p.standardOutput = Pipe()
    do { try p.run() } catch { return error.localizedDescription }
    p.waitUntilExit()
    if p.terminationStatus == 0 { return nil }
    let d = errPipe.fileHandleForReading.readDataToEndOfFile()
    let s = String(data: d, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if s.contains("-128") || s.localizedCaseInsensitiveContains("User canceled") { return "已取消授权" }
    return s.isEmpty ? "管理员权限操作失败" : s
}

/// 用户级执行（不需要密码）
@discardableResult
func runUser(_ path: String, _ args: [String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (-1, error.localizedDescription) }
    p.waitUntilExit()
    let d = pipe.fileHandleForReading.readDataToEndOfFile()
    return (p.terminationStatus, String(data: d, encoding: .utf8) ?? "")
}

enum PerfMode: String, CaseIterable, Identifiable {
    case quiet = "安静"
    case balanced = "均衡"
    case performance = "性能"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .quiet: return "leaf"
        case .balanced: return "scale.3d"
        case .performance: return "bolt.fill"
        }
    }
    var detail: String {
        switch self {
        case .quiet: return "低电量模式：抑制睿频、尽量省电，机器最安静"
        case .balanced: return "系统默认调度：轻载省电、重载给性能"
        case .performance: return "关闭低电量模式与后台节流，CPU 尽量跑满"
        }
    }
}

final class PowerMode: ObservableObject {
    @Published var current: PerfMode = .balanced
    @Published var busy = false
    @Published var message = ""

    /// 读取当前状态：低电量模式 + 后台节流开关
    func refresh() {
        let (_, out) = runUser("/usr/bin/pmset", ["-g"])
        let lowPower = out.contains("lowpowermode         1") || out.contains("lowpowermode 1")
        let (_, d) = runUser("/usr/bin/defaults", ["read", "NSGlobalDomain", "NSAppSleepDisabled"])
        let napDisabled = d.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
        if lowPower { current = .quiet }
        else if napDisabled { current = .performance }
        else { current = .balanced }
    }

    func apply(_ mode: PerfMode, done: @escaping (String) -> Void) {
        busy = true
        DispatchQueue.global(qos: .userInitiated).async {
            var script = ""
            switch mode {
            case .quiet:
                script = "/usr/bin/pmset -a lowpowermode 1 && /usr/bin/pmset -a powernap 0"
            case .balanced:
                script = "/usr/bin/pmset -a lowpowermode 0 && /usr/bin/pmset -a powernap 1"
            case .performance:
                script = "/usr/bin/pmset -a lowpowermode 0 && /usr/bin/pmset -a powernap 0 && /usr/sbin/sysctl -w debug.lowpri_throttle_enabled=0"
            }
            let err = runAdminScript(script)
            // 用户级：App Nap（只有性能模式才关掉）
            let home = NSHomeDirectory()
            _ = runUser("/usr/bin/defaults", ["write", home + "/Library/Preferences/.GlobalPreferences", "NSAppSleepDisabled", "-bool", mode == .performance ? "YES" : "NO"])
            DispatchQueue.main.async {
                self.busy = false
                if let e = err {
                    self.message = "切换失败：\(e)"
                } else {
                    self.current = mode
                    self.message = "已切到\(mode.rawValue)模式：\(mode.detail)"
                }
                done(self.message)
            }
        }
    }
}
