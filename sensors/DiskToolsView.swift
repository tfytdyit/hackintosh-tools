import SwiftUI
import AppKit

struct VolInfo: Identifiable {
    let id: String          // 挂载点
    let mountPath: String
    let device: String
    let fs: String
    let totalGB: Double
    let freeGB: Double
    var writable: Bool? = nil
    var name: String { (mountPath as NSString).lastPathComponent }
    var isNTFS: Bool { fs.lowercased().contains("ntfs") }
}

final class DiskTools: ObservableObject {
    @Published var vols: [VolInfo] = []
    @Published var scanning = false
    @Published var message = ""
    @Published var ntfs3g: String? = nil
    @Published var driverTitle = "检测中…"
    @Published var driverDetail = ""
    @Published var driverOK = false
    @Published var disks: [DiskInfo] = []

    func scan() {
        scanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let fm = FileManager.default
            var out: [VolInfo] = []
            if let names = try? fm.contentsOfDirectory(atPath: "/Volumes") {
                for n in names.sorted() {
                    let path = "/Volumes/" + n
                    var s = statfs()
                    guard statfs(path, &s) == 0 else { continue }
                    let fsName = withUnsafeBytes(of: &s.f_fstypename) { raw -> String in
                        String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
                    }
                    let devName = withUnsafeBytes(of: &s.f_mntfromname) { raw -> String in
                        String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
                    }
                    let bs = Double(s.f_bsize)
                    let total = Double(s.f_blocks) * bs / 1_073_741_824
                    let free = Double(s.f_bavail) * bs / 1_073_741_824
                    guard total > 0.5 else { continue }
                    // 可写性直接看挂载标志（MNT_RDONLY），不受当前进程沙箱影响
                    var w: Bool? = nil
                    if fsName.lowercased().contains("ntfs") || fsName.lowercased().contains("tuxera") {
                        w = (s.f_flags & UInt32(MNT_RDONLY)) == 0
                    }
                    out.append(VolInfo(id: path, mountPath: path, device: devName, fs: fsName,
                                       totalGB: total, freeGB: free, writable: w))
                }
            }
            let diskList = Metrics.readDisks()
            DispatchQueue.main.async {
                self.vols = out
                self.disks = diskList
                self.scanning = false
                self.detectDriver()
            }
        }
    }

    /// 判断当前 NTFS 读写能力来自哪里
    func detectDriver() {
        ntfs3g = FileManager.default.isExecutableFile(atPath: "/usr/local/bin/ntfs-3g") ? "/usr/local/bin/ntfs-3g" : nil
        let ntfs = vols.filter { $0.isNTFS }
        let tuxeraMounted = ntfs.contains { $0.fs.lowercased().contains("tuxera") }
        let paragonMounted = ntfs.contains { $0.fs.lowercased().contains("paragon") || $0.fs.lowercased().contains("ufsd") }
        let tuxeraInstalled = FileManager.default.fileExists(atPath: "/Library/Filesystems/tuxera_ntfs.fs")
        let paragonInstalled = FileManager.default.fileExists(atPath: "/Library/Filesystems/ufsd_NTFS.fs")

        if tuxeraMounted {
            driverOK = true
            driverTitle = "Tuxera NTFS 已启用 · 可读写"
            driverDetail = "\(ntfs.count) 个 NTFS 卷以 tuxera_ntfs 挂载。"
        } else if paragonMounted {
            driverOK = true
            driverTitle = "Paragon NTFS 已启用 · 可读写"
            driverDetail = "\(ntfs.count) 个 NTFS 卷以 ufsd 挂载。"
        } else if let ng = ntfs3g {
            driverOK = true
            driverTitle = "可用 ntfs-3g（fuse-t）· 卷仍只读"
            driverDetail = "已检测到 \(ng)。点卷上的「挂载为读写」用 ntfs-3g 重挂（需管理员密码），或者从命令行手动挂。"
        } else if tuxeraInstalled || paragonInstalled {
            driverOK = false
            driverTitle = "驱动已安装，但未加载 · 当前只读"
            driverDetail = "重启一次；若仍不行，去 系统设置 → 隐私与安全性 → 安全性 里允许 Tuxera/Paragon 的内核扩展，再重启。"
        } else {
            driverOK = false
            driverTitle = "未安装 NTFS 驱动 · 当前只读"
            driverDetail = "macOS 自带驱动只能读。工作区里已放好一键安装脚本：ntfs-driver/install-tuxera.sh（Tuxera，支持 macOS 26/27，试用 15 天；本机之前装过、授权文件还在）。"
        }
    }

    /// 用 ntfs-3g（fuse-t）把卷重新挂成读写；需要管理员密码
    func mountWithNtfs3g(_ v: VolInfo) {
        guard let ng = ntfs3g else { return }
        message = "正在用 ntfs-3g 挂载 \(v.name)…（会弹一次密码）"
        let mp = v.mountPath.replacingOccurrences(of: "'", with: "'\\''")
        let script = "/usr/sbin/diskutil unmount force '\(mp)' 2>/dev/null; " +
                     "/bin/mkdir -p '\(mp)'; " +
                     "'\(ng)' '\(v.device)' '\(mp)' -o local,allow_other,auto_xattr,noatime"
        DispatchQueue.global(qos: .userInitiated).async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "on run argv",
                           "-e", "do shell script (item 1 of argv) with administrator privileges",
                           "-e", "end run", "--", script]
            let pipe = Pipe(); p.standardError = pipe; p.standardOutput = pipe
            var err = ""
            do {
                try p.run(); p.waitUntilExit()
                err = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            } catch { err = error.localizedDescription }
            DispatchQueue.main.async {
                if p.terminationStatus == 0 {
                    self.message = "已用 ntfs-3g 挂载 \(v.name) · 现在应该可以写入"
                } else if err.contains("-128") || err.contains("User canceled") {
                    self.message = "已取消授权"
                } else {
                    self.message = "ntfs-3g 挂载失败：" + err.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160)
                }
                self.scan()
            }
        }
    }

    func unmount(_ v: VolInfo) {
        message = "已请求卸载 \(v.name)…"
        DispatchQueue.global().async {
            let (rc, out) = runUser("/usr/sbin/diskutil", ["unmount", v.device])
            DispatchQueue.main.async {
                self.message = rc == 0 ? "已卸载 \(v.name)" : "卸载失败：\(out.trimmingCharacters(in: .whitespacesAndNewlines))"
                self.scan()
            }
        }
    }

    /// 真实写一次，确认驱动层是否允许写
    func writeTest(_ v: VolInfo) {
        let probe = v.mountPath + "/.sensorbar-write-test"
        if FileManager.default.createFile(atPath: probe, contents: Data("ok".utf8)) {
            try? FileManager.default.removeItem(atPath: probe)
            message = "\(v.name)：写入测试成功，这个卷可以正常读写"
        } else {
            let e = NSError(domain: NSPOSIXErrorDomain, code: 0)
            message = "\(v.name)：写入失败（驱动只读、或需要给 SensorBar 授予「可移除宗卷」/「完全磁盘访问」权限）\(e.localizedDescription.isEmpty ? "" : "")"
        }
    }

    func remountRW(_ v: VolInfo) {
        guard driverOK else {
            message = "当前没有可用的 NTFS 读写驱动，重新挂载也只会是只读。先跑 ntfs-driver/install-tuxera.sh 装驱动并重启。"
            return
        }
        // 原生 ntfs.kext 只读；已装 Tuxera/ntfs-3g 时重新挂载即可读写
        message = "正在重新挂载（需要管理员密码）…"
        DispatchQueue.global().async {
            let script = "/usr/sbin/diskutil unmount force \(shQuotePath(v.device)) >/dev/null 2>&1; /usr/sbin/diskutil mount \(shQuotePath(v.device))"
            let err = runAdminScript(script)
            DispatchQueue.main.async {
                self.message = err == nil ? "已重新挂载 \(v.name)" : "重新挂载失败：\(err!)"
                self.scan()
            }
        }
    }
}

private func shQuotePath(_ p: String) -> String {
    "'" + p.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

struct DiskToolsView: View {
    @StateObject private var t = DiskTools()

    var body: some View {
        WindowShell(title: "磁盘 / NTFS", icon: "externaldrive.fill", tint: .blue,
                    subtitle: "卷列表 · 读写状态 · 卸载与重新挂载") {
            VStack(spacing: 0) {
                // 驱动状态卡
                HStack(alignment: .top, spacing: 8) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill((t.driverOK ? Color.green : Color.orange).opacity(0.15))
                        Image(systemName: t.driverOK ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                            .font(.system(size: 12)).foregroundStyle(t.driverOK ? Color.green : Color.orange)
                    }
                    .frame(width: 24, height: 24)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.driverTitle).font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(t.driverOK ? Color.green : Color.orange)
                        Text(t.driverDetail).font(.system(size: 9.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                    if !t.driverOK {
                        PillButton(title: "安装说明", icon: "questionmark.circle", tint: .orange) {
                            NSWorkspace.shared.selectFile(
                                NSHomeDirectory() + "/Documents/deepseek-harness/default-workspace/ntfs-driver/install-tuxera.sh",
                                inFileViewerRootedAtPath: "")
                        }
                    }
                }
                .padding(.horizontal, 12).padding(.top, 10)

                if !t.disks.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(t.disks) { d in
                            VStack(alignment: .leading, spacing: 1) {
                                Text(d.model)
                                    .font(.system(size: 9.5, weight: .medium))
                                    .lineLimit(1).truncationMode(.middle)
                                Text(String(format: "%.0f GB · %d 个分区", d.sizeGB, d.parts.count))
                                    .font(.system(size: 8.5))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(Color.primary.opacity(0.05)))
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12).padding(.top, 6)
                }

                HStack(spacing: 8) {
                    Text("\(t.vols.count) 个卷").font(.system(size: 10.5)).foregroundStyle(.secondary)
                    if t.scanning { ProgressView().controlSize(.small) }
                    Spacer()
                    PillButton(title: "重新扫描", icon: "arrow.clockwise") { t.scan() }
                    PillButton(title: "在 Finder 打开", icon: "folder", tint: .accentColor) {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/Volumes"))
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)

                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(t.vols) { v in volRow(v) }
                    }
                    .padding(.horizontal, 12)
                }

                Divider().opacity(0.5)
                VStack(alignment: .leading, spacing: 3) {
                    Text("NTFS 说明").font(.system(size: 10, weight: .semibold))
                    Text(t.driverOK
                         ? "已启用第三方 NTFS 驱动（Tuxera NTFS），上面的 NTFS 卷现在是可读写的。\n切到 Windows 之前建议先在这里点「卸载」或正常关机，避免 Windows 的快速启动把分区标记成脏盘。"
                         : "macOS 自带 NTFS 驱动只能读。要写入需要第三方驱动：Tuxera NTFS（推荐，脚本在工作区 ntfs-driver/install-tuxera.sh）或 Paragon NTFS；免费替代是 fuse-t + ntfs-3g（免内核扩展，但要自己编译）。驱动装好并允许系统扩展、重启后，这里会变成「已启用 · 可读写」。")
                        .font(.system(size: 9.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !t.message.isEmpty {
                        Text(t.message).font(.system(size: 9.5)).foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
            }
        }
        .frame(width: 560, height: 480)
        .onAppear { t.scan() }
    }

    @ViewBuilder
    private func volRow(_ v: VolInfo) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill((v.isNTFS ? Color.blue : Color.gray).opacity(0.15))
                    Image(systemName: v.isNTFS ? "externaldrive.fill.badge.windows" : "internaldrive.fill")
                        .font(.system(size: 11)).foregroundStyle(v.isNTFS ? Color.blue : Color.secondary)
                }
                .frame(width: 22, height: 22)

                Text(v.name).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                if v.isNTFS {
                    Text(v.fs)
                        .font(.system(size: 8.5, design: .monospaced))
                        .padding(.horizontal, 5).padding(.vertical, 1.5)
                        .background(Capsule().fill(Color.blue.opacity(0.14)))
                        .foregroundStyle(Color.blue)
                }
                if let w = v.writable {
                    Text(w ? "挂载为可读写" : "挂载为只读")
                        .font(.system(size: 9)).foregroundStyle(w ? Color.green : Color.orange)
                }
                Spacer()
                Text(String(format: "%.0f / %.0f GB", v.freeGB, v.totalGB))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text(v.device).font(.system(size: 9, design: .monospaced)).foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer()
                PillButton(title: "打开", icon: "folder", tint: .accentColor) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: v.mountPath))
                }
                PillButton(title: "卸载", icon: "eject") { t.unmount(v) }
                if v.isNTFS {
                    PillButton(title: "测写入", icon: "pencil") { t.writeTest(v) }
                    if t.ntfs3g != nil && !(v.writable ?? false) {
                        PillButton(title: "挂载为读写", icon: "pencil.and.outline", tint: .green) { t.mountWithNtfs3g(v) }
                    }
                    PillButton(title: "重新挂载", icon: "arrow.triangle.2.circlepath", tint: .blue) { t.remountRW(v) }
                }
            }
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
}
