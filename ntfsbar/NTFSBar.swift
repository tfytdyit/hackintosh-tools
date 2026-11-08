import AppKit
import Foundation

// MARK: - 数据

struct NTFSVolume: Identifiable {
    let id: String          // device, e.g. /dev/disk0s2
    let name: String        // VolumeName
    let sizeGB: Double
    let mountPoint: String?
    let fsType: String?     // ntfs / tuxera_ntfs / nfs(我们的)
    let readOnly: Bool

    var isMounted: Bool { mountPoint != nil }
    var isWritableNTFS: Bool {
        guard let fs = fsType else { return false }
        return (fs == "tuxera_ntfs" || fs == "nfs" || fs == "macfuse" || fs == "ntfs") && !readOnly
    }
}

func sh(_ path: String, _ args: [String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
}

enum Env {
    static func exists(_ p: String) -> Bool { FileManager.default.fileExists(atPath: p) }

    static var fuseTInstalled: Bool {
        exists("/Library/Frameworks/fuse_t.framework") || exists("/usr/local/bin/go-nfsv4")
    }
    static var ntfs3gInstalled: Bool { exists("/usr/local/bin/ntfs-3g") }
    static var helperInstalled: Bool { exists("/usr/local/bin/ntfsbar-mount") }
    static var tuxeraInstalled: Bool { exists("/Library/Filesystems/tuxera_ntfs.fs") }
    static var autoMountEnabled: Bool { exists("/Library/LaunchDaemons/com.hackintosh.ntfsbar.automount.plist") }
    static var ntfs3gVersion: String {
        let (_, out) = sh("/usr/local/bin/ntfs-3g", ["--version"])
        return out.split(separator: "\n").first.map(String.init) ?? "?"
    }
}

// MARK: - 枚举

enum Volumes {
    static func all() -> [NTFSVolume] {
        let (_, plistText) = sh("/usr/sbin/diskutil", ["list", "-plist"])
        guard let data = plistText.data(using: .utf8),
              let obj = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let disks = obj["AllDisksAndPartitions"] as? [[String: Any]] else { return [] }

        let mounts = mountTable()
        var result: [NTFSVolume] = []

        for d in disks {
            guard let parts = d["Partitions"] as? [[String: Any]] else { continue }
            for p in parts {
                let content = (p["Content"] as? String) ?? ""
                let ident = (p["DeviceIdentifier"] as? String) ?? ""
                guard !ident.isEmpty else { continue }

                // 候选：NTFS 的分区类型通常显示为 Microsoft Basic Data；exFAT/FAT 也是这个，
                // 所以再用 diskutil info 的 FilesystemType 过滤（tuxera_ntfs / ntfs / ufsd_NTFS / 空=未知）。
                let looksCandidate = content.uppercased().contains("NTFS")
                    || content == "Microsoft Basic Data"
                    || content == "Windows_NTFS"
                guard looksCandidate else { continue }

                let dev = "/dev/" + ident
                var fsFromInfo: String? = nil
                do {
                    let (_, infoText) = sh("/usr/sbin/diskutil", ["info", "-plist", dev])
                    if let d2 = infoText.data(using: .utf8),
                       let o2 = try? PropertyListSerialization.propertyList(from: d2, options: [], format: nil) as? [String: Any] {
                        fsFromInfo = o2["FilesystemType"] as? String
                    }
                }

                let name: String
                if let vn = p["VolumeName"] as? String, !vn.isEmpty { name = vn } else { name = ident }
                let size = (p["Size"] as? NSNumber)?.doubleValue ?? 0

                // 先找挂载点（ntfs-3g 走 fuse-t，设备名显示为 fuse-t:/卷名，只能按挂载点匹配）
                var mp: String? = nil
                var fst: String? = nil
                var ro = true
                if let m = mounts.first(where: { $0.device == dev }) {
                    mp = m.mountPoint; fst = m.fs; ro = m.readOnly
                } else if let m = mounts.first(where: { $0.mountPoint == "/Volumes/" + name }) {
                    mp = m.mountPoint; fst = m.fs; ro = m.readOnly
                }

                // 判定是不是 NTFS：
                // 已挂载 → 看挂载类型（ntfs / tuxera_ntfs / ufsd_NTFS / fuse-t 的 nfs）
                // 未挂载 → 看 diskutil 的 FilesystemType
                let fsUpper = (fsFromInfo ?? "").uppercased()
                let mountedFs = (fst ?? "").lowercased()
                let isNTFS: Bool
                if !mountedFs.isEmpty {
                    isNTFS = ["ntfs", "tuxera_ntfs", "ufsd_ntfs", "nfs", "macfuse"].contains(mountedFs)
                } else {
                    isNTFS = fsUpper.isEmpty || fsUpper.contains("NTFS") || fsUpper == "PERSONALITY_UNKNOWN"
                }
                guard isNTFS else { continue }

                if fst == nil { fst = fsFromInfo }
                result.append(NTFSVolume(id: dev, name: name, sizeGB: size / 1e9,
                                         mountPoint: mp, fsType: fst, readOnly: ro))
            }
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    struct MountEntry { let device: String; let mountPoint: String; let fs: String; let readOnly: Bool }

    static func mountTable() -> [MountEntry] {
        let (_, out) = sh("/sbin/mount", [])
        var list: [MountEntry] = []
        for line in out.split(separator: "\n") {
            let s = String(line)
            // 形如: /dev/disk0s2 on /Volumes/D (tuxera_ntfs, local, synchronous)
            guard let r1 = s.range(of: " on "), let r2 = s.range(of: " (", range: r1.upperBound..<s.endIndex) else { continue }
            let dev = String(s[s.startIndex..<r1.lowerBound])
            let mp = String(s[r1.upperBound..<r2.lowerBound])
            let opts = String(s[r2.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: "()"))
            let fs = opts.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? "?"
            list.append(MountEntry(device: dev, mountPoint: mp, fs: fs,
                                   readOnly: opts.contains("read-only")))
        }
        return list
    }
}

// MARK: - 提权

enum Admin {
    /// 用 osascript 弹一次管理员密码，返回 (成功, 输出)
    static func run(_ command: String) -> (Bool, String) {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with administrator privileges"
        let (rc, out) = sh("/usr/bin/osascript", ["-e", script])
        return (rc == 0, out.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var volumes: [NTFSVolume] = []
    private var lastMessage: String = ""

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--list") {
            for v in Volumes.all() {
                let state = v.mountPoint == nil ? "未挂载"
                    : (v.readOnly ? "只读(\(v.fsType ?? "?"))" : "可读写(\(v.fsType ?? "?"))")
                print("\(v.id)\t\(v.name)\t\(String(format: "%.1f", v.sizeGB))GB\t\(state)\t\(v.mountPoint ?? "-")")
            }
            exit(0)
        }
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "internaldrive", accessibilityDescription: "NTFSBar")
        statusItem.button?.imagePosition = .imageLeading

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        if UserDefaults.standard.bool(forKey: "hideIcon") { statusItem.isVisible = false }

        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer!, forMode: .common)
    }

    private func refresh() {
        let new = Volumes.all()
        let title = new.isEmpty ? "无 NTFS" : "\(new.count)"
        statusItem.button?.title = " " + title
        if new.map({ "\($0.id)\($0.mountPoint ?? "")\($0.readOnly)" }) != volumes.map({ "\($0.id)\($0.mountPoint ?? "")\($0.readOnly)" }) {
            volumes = new
            rebuildMenu()
        }
    }

    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        // 驱动状态
        let backendItem = NSMenuItem(title: backendSummary(), action: nil, keyEquivalent: "")
        backendItem.isEnabled = false
        menu.addItem(backendItem)
        let driverItem = NSMenuItem(title: driverSummary(), action: nil, keyEquivalent: "")
        driverItem.isEnabled = false
        menu.addItem(driverItem)
        menu.addItem(.separator())

        if volumes.isEmpty {
            let i = NSMenuItem(title: "没有检测到 NTFS 分区", action: nil, keyEquivalent: "")
            i.isEnabled = false
            menu.addItem(i)
        }

        for v in volumes {
            let state: String
            if v.mountPoint == nil { state = "未挂载" }
            else if v.readOnly { state = "只读" }
            else { state = "可读写" }
            let item = NSMenuItem(title: "\(v.name)  ·  \(fmtGB(v.sizeGB))  ·  \(state)",
                                  action: nil, keyEquivalent: "")
            let sub = NSMenu()
            if v.mountPoint == nil || v.readOnly {
                let m = NSMenuItem(title: "挂载为可读写", action: #selector(mountSelected(_:)), keyEquivalent: "")
                m.target = self; m.representedObject = v
                sub.addItem(m)
            }
            if let mp = v.mountPoint {
                let u = NSMenuItem(title: "卸载", action: #selector(unmountSelected(_:)), keyEquivalent: "")
                u.target = self; u.representedObject = v
                sub.addItem(u)
                let o = NSMenuItem(title: "在 Finder 中打开", action: #selector(openSelected(_:)), keyEquivalent: "")
                o.target = self; o.representedObject = v
                sub.addItem(o)
                let c = NSMenuItem(title: "拷贝挂载点路径", action: #selector(copyPath(_:)), keyEquivalent: "")
                c.target = self; c.representedObject = mp
                sub.addItem(c)
            }
            sub.addItem(.separator())
            let d = NSMenuItem(title: v.id, action: nil, keyEquivalent: "")
            d.isEnabled = false
            sub.addItem(d)
            item.submenu = sub
            menu.addItem(item)
        }

        menu.addItem(.separator())
        let allMount = NSMenuItem(title: "全部挂载为可读写", action: #selector(mountAll), keyEquivalent: "")
        allMount.target = self
        menu.addItem(allMount)
        let allUnmount = NSMenuItem(title: "全部卸载 NTFSBar 挂载", action: #selector(unmountAll), keyEquivalent: "")
        allUnmount.target = self
        menu.addItem(allUnmount)

        menu.addItem(.separator())
        let auto = NSMenuItem(title: "开机自动挂载为可读写", action: #selector(toggleAuto), keyEquivalent: "")
        auto.target = self
        auto.state = Env.autoMountEnabled ? .on : .off
        menu.addItem(auto)

        let openVol = NSMenuItem(title: "打开 /Volumes", action: #selector(openVolumes), keyEquivalent: "")
        openVol.target = self
        menu.addItem(openVol)

        let re = NSMenuItem(title: "刷新", action: #selector(doRefresh), keyEquivalent: "r")
        re.target = self
        menu.addItem(re)

        if !lastMessage.isEmpty {
            menu.addItem(.separator())
            let msg = NSMenuItem(title: lastMessage, action: nil, keyEquivalent: "")
            msg.isEnabled = false
            menu.addItem(msg)
        }

        menu.addItem(.separator())
        let hide = NSMenuItem(title: "隐藏菜单栏图标（再次打开 App 可恢复）",
                              action: #selector(hideIcon), keyEquivalent: "")
        hide.target = self
        menu.addItem(hide)

        let quit = NSMenuItem(title: "退出 NTFSBar", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    private func fmtGB(_ g: Double) -> String {
        if g >= 1000 { return String(format: "%.1f TB", g / 1000) }
        return String(format: "%.0f GB", g)
    }

    /// 当前挂载后端：macfuse（本地）/ nfs（fuse-t 回环）/ tuxera_ntfs
    private func backendSummary() -> String {
        let table = Volumes.mountTable()
        let fss = volumes.compactMap { $0.mountPoint }.compactMap { mp -> String? in
            table.first { $0.mountPoint == mp }?.fs
        }
        let macfuse = FileManager.default.isExecutableFile(atPath: "/usr/local/bin/ntfs-3g.macfuse")
        if fss.isEmpty { return macfuse ? "挂载后端：macFUSE（本地）" : "挂载后端：fuse-t（回环 nfs）" }
        let local = fss.filter { $0 == "macfuse" }.count
        let remote = fss.filter { $0 == "nfs" }.count
        let other = fss.count - local - remote
        var bits: [String] = []
        if local > 0 { bits.append("macFUSE 本地 ×\(local)") }
        if remote > 0 { bits.append("fuse-t nfs ×\(remote)") }
        if other > 0 { bits.append("其他 ×\(other)") }
        return "挂载后端：" + bits.joined(separator: " · ")
    }

    private func driverSummary() -> String {
        var bits: [String] = []
        bits.append(Env.ntfs3gInstalled ? "ntfs-3g ✓" : "ntfs-3g ✗")
        bits.append(Env.fuseTInstalled ? "fuse-t ✓" : "fuse-t ✗")
        bits.append(Env.helperInstalled ? "helper ✓" : "helper ✗")
        if Env.tuxeraInstalled { bits.append("Tuxera 已装") }
        return bits.joined(separator: " · ")
    }

    // MARK: 动作

    @objc private func mountSelected(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? NTFSVolume else { return }
        mount(v)
    }

    private func mount(_ v: NTFSVolume) {
        guard Env.helperInstalled && Env.ntfs3gInstalled && Env.fuseTInstalled else {
            lastMessage = "缺少依赖：先运行 ntfsbar/install.sh"
            rebuildMenu(); return
        }
        let cmd = "/usr/local/bin/ntfsbar-mount mount \(v.id) \"\(v.name)\""
        let (ok, out) = Admin.run(cmd)
        lastMessage = ok ? (out.isEmpty ? "已挂载 \(v.name)" : out) : "挂载失败"
        refresh(); rebuildMenu()
    }

    @objc private func unmountSelected(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? NTFSVolume, let mp = v.mountPoint else { return }
        let (ok, out) = Admin.run("/usr/local/bin/ntfsbar-mount unmount \"\(mp)\"")
        lastMessage = ok ? (out.isEmpty ? "已卸载 \(v.name)" : out) : "卸载失败"
        refresh(); rebuildMenu()
    }

    @objc private func openSelected(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? NTFSVolume, let mp = v.mountPoint else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: mp))
    }

    @objc private func copyPath(_ sender: NSMenuItem) {
        if let s = sender.representedObject as? String {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s, forType: .string)
            lastMessage = "已拷贝路径"
            rebuildMenu()
        }
    }

    @objc private func mountAll() {
        for v in volumes where v.mountPoint == nil || v.readOnly {
            let (ok, out) = Admin.run("/usr/local/bin/ntfsbar-mount mount \(v.id) \"\(v.name)\"")
            lastMessage = ok ? "已挂载 \(v.name)" : "\(v.name) 挂载失败：\(out)"
        }
        refresh(); rebuildMenu()
    }

    @objc private func unmountAll() {
        for v in volumes where v.mountPoint != nil && v.fsType == "nfs" {
            _ = Admin.run("/usr/local/bin/ntfsbar-mount unmount \"\(v.mountPoint!)\"")
        }
        lastMessage = "已卸载 NTFSBar 挂载的卷"
        refresh(); rebuildMenu()
    }

    @objc private func toggleAuto() {
        if Env.autoMountEnabled {
            let (ok, _) = Admin.run("/bin/launchctl bootout system /Library/LaunchDaemons/com.hackintosh.ntfsbar.automount.plist >/dev/null 2>&1; /bin/rm -f /Library/LaunchDaemons/com.hackintosh.ntfsbar.automount.plist")
            lastMessage = ok ? "已关闭开机自动挂载" : "关闭失败"
        } else {
            let src = Bundle.main.bundlePath + "/Contents/Resources/com.hackintosh.ntfsbar.automount.plist"
            let cmd = "/bin/cp \"\(src)\" /Library/LaunchDaemons/com.hackintosh.ntfsbar.automount.plist && /bin/chmod 644 /Library/LaunchDaemons/com.hackintosh.ntfsbar.automount.plist && /bin/launchctl bootstrap system /Library/LaunchDaemons/com.hackintosh.ntfsbar.automount.plist"
            let (ok, out) = Admin.run(cmd)
            lastMessage = ok ? "已开启开机自动挂载" : "开启失败：\(out)"
        }
        rebuildMenu()
    }

    @objc private func openVolumes() { NSWorkspace.shared.open(URL(fileURLWithPath: "/Volumes")) }
    @objc private func doRefresh() { refresh(); rebuildMenu() }
    @objc private func hideIcon() {
        UserDefaults.standard.set(true, forKey: "hideIcon")
        statusItem.isVisible = false
        lastMessage = "菜单栏图标已隐藏，再打开一次 NTFSBar 就会恢复"
    }

    /// 再次打开 App（⌘-Tab / 双击 /Applications/NTFSBar.app）时把图标恢复出来
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if UserDefaults.standard.bool(forKey: "hideIcon") {
            UserDefaults.standard.set(false, forKey: "hideIcon")
            statusItem.isVisible = true
            lastMessage = "菜单栏图标已恢复"
        }
        return true
    }

    @objc private func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
