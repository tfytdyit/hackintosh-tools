// SensorBar.swift — 菜单栏系统监控（macOS 26 Tahoe 磨砂玻璃，折叠式布局）
// 构建见 build.sh；C 桥接接口在 bridge.h（SMC 传感器 / 系统信息 / 磁盘 IO / 进程 / 网络速率）
import AppKit
import SwiftUI
import Metal
import CoreWLAN

// MARK: - 模型

struct SpeedResult {
    var downloadMbps: Double?
    var uploadMbps: Double?
    var at: Date
}

struct DiskPart: Identifiable, Equatable {
    let id: String          // disk0s1
    let name: String        // 卷名或内容类型
    let content: String     // Microsoft Basic Data / APFS / EFI …
    let sizeGB: Double
}

struct DiskInfo: Identifiable, Equatable {
    let id: String          // disk0
    let model: String
    let sizeGB: Double
    let isInternal: Bool
    let solid: Bool
    let bus: String
    let parts: [DiskPart]
}

struct ProcRow: Identifiable {
    let id: Int32
    let cpu: Double
    let memMB: Double
    let name: String
}

final class Metrics: ObservableObject {
    @Published var disks: [DiskInfo] = []
    private var lastDiskScan: Double = -1000

    // 实时
    @Published var tempPkg: Double = 0
    @Published var cores: [Double] = []
    @Published var cpuUsage: Double = 0
    @Published var load1: Double = 0
    @Published var load5: Double = 0
    @Published var load15: Double = 0
    @Published var power: Double = 0
    @Published var powerPL: Double = 0
    @Published var vcore: Double = 0
    @Published var thermal: Double = 0

    @Published var memUsed: Double = 0
    @Published var memTotal: Double = 0
    @Published var memWired: Double = 0
    @Published var memCompressed: Double = 0
    @Published var memActive: Double = 0
    @Published var memPressure: Int32 = -1
    @Published var swapUsed: Double = 0

    @Published var battPct: Double = 0
    @Published var battVolt: Double = 0
    @Published var battCurrent: Double = 0
    @Published var battRemain: Double = 0
    @Published var battFull: Double = 0
    @Published var battCycle: Int32 = 0
    @Published var battDesign: Int32 = 0
    @Published var battMaxRaw: Int32 = 0
    @Published var battTimeMin: Int32 = 0
    @Published var acIn: Bool = false
    @Published var battPresent: Bool = false

    @Published var fans: [Double] = []

    // GPU（Intel 核显）
    @Published var gpuUtil: Int = -1
    @Published var gpuUtilPState: Int = -1

    @Published var downBps: Double = 0
    @Published var upBps: Double = 0
    @Published var rxTotal: Double = 0
    @Published var txTotal: Double = 0

    @Published var diskRead: Double = 0
    @Published var diskWrite: Double = 0
    @Published var diskReadTotal: Double = 0
    @Published var diskWriteTotal: Double = 0

    @Published var topCPU: [ProcRow] = []
    @Published var topMem: [ProcRow] = []
    @Published var wifiSSID: String = ""
    @Published var wifiRSSI: Int = 0
    @Published var wifiChannel: Int = 0
    @Published var wifiTxRate: Double = 0
    @Published var wifiPHY: String = "" 

    // 历史（60 秒）
    @Published var tempHistory: [Double] = []
    @Published var netHistory: [Double] = []
    @Published var cpuHistory: [Double] = []

    @Published var speed: SpeedResult? = nil
    @Published var testing = false
    @Published var showNetInMenuBar = UserDefaults.standard.bool(forKey: "showNetInMenuBar")
    @Published var autostartOn = FileManager.default.fileExists(atPath: Metrics.launchAgentPath())

    static func launchAgentPath() -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent("Library/LaunchAgents/com.hackintosh.SensorBar.plist")
    }

    func toggleAutostart() {
        let path = Metrics.launchAgentPath()
        if FileManager.default.fileExists(atPath: path) {
            try? FileManager.default.removeItem(atPath: path)
            autostartOn = false
        } else {
            let exe = Bundle.main.executablePath ?? "/Applications/SensorBar.app/Contents/MacOS/SensorBar"
            let plist: [String: Any] = [
                "Label": "com.hackintosh.SensorBar",
                "ProgramArguments": [exe],
                "RunAtLoad": true,
                "ProcessType": "Interactive"
            ]
            _ = (plist as NSDictionary).write(toFile: path, atomically: true)
            autostartOn = true
        }
    }

    // 静态系统信息
    let model = String(cString: sbi_model())
    let cpuBrand = String(cString: sbi_cpu_brand())
    let nvme = String(cString: sbi_nvme_model())
    let serial = String(cString: sbi_serial())
    let boardID = String(cString: sbi_board_id())
    let physCpus = Int(sbi_physical_cpus())
    let logCpus = Int(sbi_logical_cpus())
    let gpuName: String = {
        if let d = MTLCreateSystemDefaultDevice() { return d.name }
        return "—"
    }()
    let displayInfo: String = {
        let id = CGMainDisplayID()
        let w = CGDisplayPixelsWide(id), h = CGDisplayPixelsHigh(id)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        return "\(w)×\(h) @\(String(format: "%.0f", scale))x"
    }()
    let osVersion: String = {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion) (\(sysctlString("kern.osversion")))"
    }()
    var diskTotal: Double = 0
    var diskFree: Double = 0
    var uptime: Double = 0
    var smcKeys: Int = 0
    var netIface: String = ""
    var netIP: String = ""

    private var timer: Timer?
    private var tick = 0

    func start() {
        _ = sbi_open()
        smcKeys = Int(sbi_smc_key_count())
        diskTotal = sbi_disk_total_gb()
        diskFree = sbi_disk_free_gb()
        update()
        refreshProcesses()
        restartTimer()
        NotificationCenter.default.addObserver(forName: .init("SensorBarRefreshChanged"), object: nil, queue: .main) { [weak self] _ in
            self?.restartTimer()
        }
    }

    private var dataTimer: Timer?

    var refreshInterval: TimeInterval {
        let v = UserDefaults.standard.double(forKey: "refreshInterval")
        return v >= 1.0 ? v : 1.0
    }

    func restartTimer() {
        dataTimer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: refreshInterval, repeats: true) { [weak self] _ in
            self?.update()
        }
        RunLoop.main.add(t, forMode: .common)
        dataTimer = t
    }

    func update() {
        let nowTs = Date().timeIntervalSince1970
        if nowTs - lastDiskScan > 20 {
            lastDiskScan = nowTs
            DispatchQueue.global(qos: .utility).async {
                let list = Metrics.readDisks()
                DispatchQueue.main.async { self.disks = list }
            }
        }
        tempPkg = sbi_temp_pkg()
        let n = Int(sbi_core_count())
        cores = (0..<max(n, 0)).map { sbi_temp_core(Int32($0)) }
        cpuUsage = sbi_cpu_usage()
        load1 = sbi_load1(); load5 = sbi_load5(); load15 = sbi_load15()
        let pNow = sbi_power_cpu()
        if pNow > 0 { power = pNow }
        powerPL = sbi_power_pl(); vcore = sbi_vcore()
        thermal = sbi_thermal_level()
        let g = Int(sbi_gpu_util())
        if g >= 0 { gpuUtil = g }
        let gp = Int(sbi_gpu_util_at_pstate())
        gpuUtilPState = gp

        memUsed = sbi_mem_used_gb(); memTotal = sbi_mem_total_gb(); swapUsed = sbi_swap_used_gb()
        memWired = sbi_mem_wired_gb(); memCompressed = sbi_mem_compressed_gb()
        memActive = sbi_mem_active_gb(); memPressure = sbi_mem_pressure()

        battPct = sbi_batt_pct(); battVolt = sbi_batt_volt(); battCurrent = sbi_batt_current()
        battRemain = sbi_batt_remain(); battFull = sbi_batt_full()
        battCycle = sbi_batt_cycle(); battDesign = sbi_batt_design_mah()
        battMaxRaw = sbi_batt_maxraw_mah(); battTimeMin = sbi_batt_time_remaining()
        acIn = sbi_ac_in() != 0
        battPresent = sbi_batt_present() != 0

        let fn = Int(sbi_fan_count())
        fans = (0..<max(fn, 0)).map { sbi_fan_rpm(Int32($0)) }

        var dn = 0.0, up = 0.0
        sbi_net_rates(&dn, &up)
        downBps = dn; upBps = up
        var rx = 0.0, tx = 0.0
        sbi_net_totals(&rx, &tx)
        rxTotal = rx; txTotal = tx
        netIface = String(cString: sbi_net_interface())
        netIP = String(cString: sbi_net_ipv4())

        refreshWiFi()

        var dr = 0.0, dw = 0.0, drt = 0.0, dwt = 0.0
        sbi_disk_io(&dr, &dw, &drt, &dwt)
        diskRead = dr; diskWrite = dw; diskReadTotal = drt; diskWriteTotal = dwt

        diskFree = sbi_disk_free_gb(); diskTotal = sbi_disk_total_gb()
        uptime = sbi_uptime()

        tick += 1
        tempHistory.append(tempPkg); if tempHistory.count > 60 { tempHistory.removeFirst() }
        cpuHistory.append(cpuUsage); if cpuHistory.count > 60 { cpuHistory.removeFirst() }
        netHistory.append(downBps + upBps); if netHistory.count > 60 { netHistory.removeFirst() }

        if tick % 3 == 0 { refreshProcesses() }
    }

    func refreshWiFi() {
        guard let i = CWWiFiClient.shared().interface() else { return }
        if let s = i.ssid(), !s.isEmpty { wifiSSID = s } else { wifiSSID = i.interfaceName == "en0" ? (wifiSSID.isEmpty ? "未连接" : wifiSSID) : wifiSSID }
        wifiRSSI = i.rssiValue()
        wifiChannel = i.wlanChannel()?.channelNumber ?? wifiChannel
        wifiTxRate = i.transmitRate()
    }

    // MARK: 进程（libproc 快照，CPU% 为单核百分比）
    func refreshProcesses() {
        var buf = [CChar](repeating: 0, count: 8192)
        _ = sbi_top_procs(&buf, Int32(buf.count), 0)
        topCPU = Metrics.parseProcRows(String(cString: buf))
        _ = sbi_top_procs(&buf, Int32(buf.count), 1)
        topMem = Metrics.parseProcRows(String(cString: buf))
    }

    static func parseProcRows(_ text: String) -> [ProcRow] {
        var rows: [ProcRow] = []
        for line in text.split(separator: "\n") {
            let p = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
            guard p.count == 4, let pid = Int32(p[0]), let cpu = Double(p[1]), let rss = Double(p[2]) else { continue }
            rows.append(ProcRow(id: pid, cpu: cpu, memMB: rss, name: String(p[3])))
        }
        return rows
    }

    // MARK: 磁盘枚举（diskutil -plist，物理盘 + 分区）

    private static func runDiskutil(_ args: [String]) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? data : nil
    }

    private static func plistDict(_ data: Data?) -> [String: Any]? {
        guard let data, !data.isEmpty else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
    }

    static func readDisks() -> [DiskInfo] {
        guard let root = plistDict(runDiskutil(["list", "-plist"])),
              let all = root["AllDisksAndPartitions"] as? [[String: Any]] else { return [] }
        var out: [DiskInfo] = []
        for d in all {
            guard let ident = d["DeviceIdentifier"] as? String,
                  ident.range(of: "^disk[0-9]+$", options: .regularExpression) != nil else { continue }
            let content = (d["Content"] as? String) ?? ""
            if content.contains("Apple_APFS") { continue }        // 跳过合成的 APFS 容器
            let size = (d["Size"] as? NSNumber)?.doubleValue ?? 0
            guard size > 0 else { continue }
            var model = ident, isInternal = false, solid = false, bus = ""
            if let info = plistDict(runDiskutil(["info", "-plist", ident])) {
                model = (info["MediaName"] as? String) ?? (info["DeviceBlockSize"] != nil ? ident : model)
                isInternal = (info["Internal"] as? Bool) ?? false
                solid = (info["SolidState"] as? Bool) ?? false
                bus = (info["BusProtocol"] as? String) ?? ""
                if (info["VirtualOrPhysical"] as? String) == "Virtual" { continue }
            }
            var parts: [DiskPart] = []
            for p in (d["Partitions"] as? [[String: Any]] ?? []) {
                guard let pid = p["DeviceIdentifier"] as? String else { continue }
                let ps = (p["Size"] as? NSNumber)?.doubleValue ?? 0
                let nm = (p["VolumeName"] as? String) ?? ""
                let ct = (p["Content"] as? String) ?? ""
                parts.append(DiskPart(id: pid, name: nm.isEmpty ? ct : nm, content: ct, sizeGB: ps / 1_000_000_000))
            }
            out.append(DiskInfo(id: ident, model: model, sizeGB: size / 1_000_000_000,
                                isInternal: isInternal, solid: solid, bus: bus, parts: parts))
        }
        return out.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    // MARK: 网络测速（Cloudflare 公共端点）
    func runSpeedTest() {
        guard !testing else { return }
        testing = true
        speed = nil
        Task {
            let down = await Metrics.measureDownload()
            let up = await Metrics.measureUpload()
            await MainActor.run {
                self.speed = SpeedResult(downloadMbps: down, uploadMbps: up, at: Date())
                self.testing = false
            }
        }
    }

    static func measureDownload() async -> Double? {
        let url = URL(string: "https://speed.cloudflare.com/__down?bytes=25000000")!
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        let t0 = Date()
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            let elapsed = max(0.05, Date().timeIntervalSince(t0))
            return Double(data.count) * 8 / elapsed / 1_000_000
        } catch { return nil }
    }

    static func measureUpload() async -> Double? {
        let url = URL(string: "https://speed.cloudflare.com/__up")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 30
        let body = Data(count: 8_000_000)
        req.httpBody = body
        let t0 = Date()
        do {
            _ = try await URLSession.shared.data(for: req)
            let elapsed = max(0.05, Date().timeIntervalSince(t0))
            return Double(body.count) * 8 / elapsed / 1_000_000
        } catch { return nil }
    }
}

func sysctlString(_ name: String) -> String {
    var size = 0
    if sysctlbyname(name, nil, &size, nil, 0) != 0 || size <= 0 { return "?" }
    var buf = [CChar](repeating: 0, count: size + 1)
    if sysctlbyname(name, &buf, &size, nil, 0) != 0 { return "?" }
    return String(cString: buf)
}

// MARK: - 格式化

func fmtBytes(_ b: Double) -> String {
    if b < 1024 { return String(format: "%.0f B/s", b) }
    if b < 1048576 { return String(format: "%.1f KB/s", b / 1024) }
    if b < 1073741824 { return String(format: "%.1f MB/s", b / 1048576) }
    return String(format: "%.2f GB/s", b / 1073741824)
}

func fmtTotal(_ b: Double) -> String {
    if b < 1073741824 { return String(format: "%.0f MB", b / 1048576) }
    return String(format: "%.2f GB", b / 1073741824)
}

func fmtUptime(_ s: Double) -> String {
    let t = Int(s)
    let d = t / 86400, h = (t % 86400) / 3600, m = (t % 3600) / 60
    if d > 0 { return "\(d)天 \(h)小时" }
    if h > 0 { return "\(h)小时 \(m)分" }
    return "\(m)分钟"
}

func tempColor(_ t: Double) -> Color {
    if t >= 85 { return .red }
    if t >= 70 { return .orange }
    if t >= 55 { return .yellow }
    return .green
}

// MARK: - 小组件

struct Bar: View {
    var value: Double        // 0...1
    var tint: Color
    var height: CGFloat = 5
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.10))
                Capsule().fill(tint)
                    .frame(width: max(0, min(1, value)) * geo.size.width)
            }
        }
        .frame(height: height)
    }
}

struct Sparkline: View {
    var values: [Double]
    var tint: Color
    var body: some View {
        Canvas { ctx, size in
            guard values.count > 1 else { return }
            let mx = max(values.max() ?? 1, 0.001)
            var path = Path()
            for (i, v) in values.enumerated() {
                let x = size.width * CGFloat(i) / CGFloat(values.count - 1)
                let y = size.height * (1 - CGFloat(v / mx) * 0.92)
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            ctx.stroke(path, with: .color(tint), lineWidth: 1.4)
        }
        .frame(height: 26)
    }
}

struct ProcLine: View {
    var name: String
    var right: String
    var highlight: Bool = false
    var body: some View {
        HStack(spacing: 6) {
            Text(name)
                .font(.system(size: 10.5))
                .foregroundStyle(Color.primary.opacity(0.72))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            Text(right)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(highlight ? Color.orange : Color.primary)
                .fixedSize()
        }
    }
}

struct LabelValue: View {
    var label: String
    var value: String
    var color: Color = .primary
    var mono = true
    var body: some View {
        HStack(spacing: 8) {
            Text(label).font(.system(size: 10.5)).foregroundStyle(Color.primary.opacity(0.72))
            Spacer(minLength: 6)
            Text(value)
                .font(.system(size: 11, weight: .medium, design: mono ? .monospaced : .default))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

/// 折叠区块：标题栏一行，展开后显示内容
struct FoldSection<Content: View>: View {
    let title: String
    let icon: String
    var summary: String = ""
    @Binding var expanded: Bool
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: icon)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.72))
                        .frame(width: 15, alignment: .leading)
                    Text(title).font(.system(size: 11.5, weight: .semibold))
                    Spacer(minLength: 6)
                    if !summary.isEmpty {
                        Text(summary)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.primary.opacity(0.72))
                            .lineLimit(1)
                    }
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7.5, weight: .bold))
                        .foregroundStyle(.secondary.opacity(0.8))
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                content
                    .padding(.horizontal, 10)
                    .padding(.bottom, 9)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Color.white.opacity(0.045))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 0.5)
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}

// MARK: - 主界面

// MARK: - 控制中心风格磁贴

struct PressableTileStyle: ButtonStyle {
    static let demoPressed = CommandLine.arguments.contains("--pressdemo")
    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed || Self.demoPressed
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.primary.opacity(pressed ? 0.34 : 0.09))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(Color.primary.opacity(pressed ? 0.30 : 0.14), lineWidth: 0.6)
            )
            .scaleEffect(pressed ? 0.90 : 1.0)
            .animation(.easeOut(duration: 0.11), value: pressed)
    }
}

struct ActionTile: View {
    let icon: String
    let title: String
    var tint: Color = .primary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(tint)
                Text(title)
                    .font(.system(size: 9))
                    .foregroundStyle(Color.primary.opacity(0.8))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
            .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(PressableTileStyle())
    }
}

struct ContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct RootView: View {
    @ObservedObject var m: Metrics
    @State private var open: Set<String> = RootView.initialOpen
    @AppStorage("glassOpacity") private var glassOpacity: Double = 0.0
    @StateObject private var tools = Toolbox()
    @StateObject private var pm = PowerMode()
    @State private var pendingClean: CleanItem? = nil

    static var initialOpen: Set<String> {
        if let a = CommandLine.arguments.first(where: { $0.hasPrefix("--open=") }) {
            let list = a.dropFirst("--open=".count).split(separator: ",").map(String.init)
            if !list.isEmpty { return Set(list) }
        }
        return ["overview"]
    }

    private func bind(_ key: String) -> Binding<Bool> {
        Binding(
            get: { open.contains(key) },
            set: { v in
                if v { open.insert(key) } else { open.remove(key) }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 9)
            quickActions
            powerModeRow
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            Divider().overlay(Color.white.opacity(0.07))
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 6) {
                    overviewSection
                    cpuSection
                    gpuSection
                    memSection
                    battSection
                    diskSection
                    netSection
                    procSection
                    toolsSection
                    sysSection
                }
                .padding(11)
                .background(GeometryReader { g in
                    Color.clear.preference(key: ContentHeightKey.self, value: g.size.height)
                })
            }
            Divider().overlay(Color.white.opacity(0.07))
            footer
                .padding(.horizontal, 12).padding(.vertical, 9)
        }
        .onAppear { pm.refresh() }
        .frame(width: 400)
        .onReceive(NotificationCenter.default.publisher(for: .init("SensorBarOpenTools"))) { _ in
            withAnimation(.easeInOut(duration: 0.16)) { _ = open.insert("tools") }
        }
        .onPreferenceChange(ContentHeightKey.self) { h in
            NotificationCenter.default.post(name: .init("SensorBarContentHeight"), object: h)
        }
        .background(Color.clear)
        .glassEffect(glassOpacity > 0.001
                     ? .regular.tint(Color.black.opacity(glassOpacity))
                     : .clear.tint(Color.white.opacity(0.16)),
                     in: .rect(cornerRadius: 26))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(Color.white.opacity(0.11), lineWidth: 0.8)
        )
    }

    private var quickActions: some View {
        HStack(spacing: 6) {
            ActionTile(icon: "sparkles", title: "一键清理", tint: .cyan) {
                pendingClean = CleanItem(id: "__all__", title: "全部可清理项", icon: "sparkles",
                                         url: URL(fileURLWithPath: NSHomeDirectory()))
            }
            ActionTile(icon: "wand.and.stars", title: "优化", tint: .purple) {
                tools.optimize { msg in tools.lastMessage = msg }
            }
            ActionTile(icon: "trash.slash", title: "卸载", tint: .orange) {
                NotificationCenter.default.post(name: .init("SensorBarOpenUninstaller"), object: nil)
            }
            ActionTile(icon: "gearshape", title: "设置") {
                NotificationCenter.default.post(name: .init("SensorBarOpenSettings"), object: nil)
            }
            ActionTile(icon: "arrow.clockwise", title: "刷新") {
                tools.rescan()
                m.update()
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .padding(.bottom, 10)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(m.model).font(.system(size: 14.5, weight: .semibold))
                Text(m.osVersion).font(.system(size: 10)).foregroundStyle(Color.primary.opacity(0.72))
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("已运行 " + fmtUptime(m.uptime))
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.primary.opacity(0.72))
                Text(m.thermal <= 0 ? "热压力正常" : "热压力 \(Int(m.thermal))")
                    .font(.system(size: 9.5)).foregroundStyle(m.thermal <= 0 ? .green : .orange)
            }
        }
    }

    // MARK: 概览
    private var overviewSection: some View {
        FoldSection(title: "概览", icon: "gauge.with.needle",
                    summary: String(format: "%.0f° · %.0f%%", m.tempPkg, m.cpuUsage),
                    expanded: bind("overview")) {
            HStack(spacing: 8) {
                metricTile(title: "温度", value: String(format: "%.1f°", m.tempPkg),
                           sub: "TC0P", tint: tempColor(m.tempPkg))
                metricTile(title: "CPU", value: String(format: "%.0f%%", m.cpuUsage),
                           sub: String(format: "%.2f 负载", m.load1), tint: .accentColor)
                metricTile(title: "内存", value: String(format: "%.1f", m.memUsed),
                           sub: String(format: "/ %.0f GB", m.memTotal), tint: .purple)
                metricTile(title: "电池", value: String(format: "%.0f%%", m.battPct),
                           sub: m.acIn ? (m.battCurrent > 50 ? "充电中" : "已接电源") : "放电中",
                           tint: m.battPct < 20 ? .red : .green)
            }
            Divider().overlay(Color.white.opacity(0.06)).padding(.vertical, 1)
            LabelValue(label: "网络", value: "↓ \(fmtBytes(m.downBps))   ↑ \(fmtBytes(m.upBps))", color: .cyan)
            LabelValue(label: "磁盘读写", value: "读 \(fmtBytes(m.diskRead))   写 \(fmtBytes(m.diskWrite))")
        }
    }

    private func metricTile(title: String, value: String, sub: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.system(size: 9)).foregroundStyle(Color.primary.opacity(0.72))
            Text(value).font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.7)
            Text(sub).font(.system(size: 8.5, design: .monospaced)).foregroundStyle(Color.primary.opacity(0.72)).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 6).padding(.horizontal, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.05)))
    }

    // MARK: CPU
    private var cpuSection: some View {
        FoldSection(title: "CPU", icon: "cpu",
                    summary: String(format: "%.0f° · %.0f%%", m.tempPkg, m.cpuUsage),
                    expanded: bind("cpu")) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(String(format: "%.1f°", m.tempPkg))
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .foregroundStyle(tempColor(m.tempPkg))
                    Text("封装温度 TC0P").font(.system(size: 9)).foregroundStyle(Color.primary.opacity(0.72))
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(String(format: "%.0f%%", m.cpuUsage))
                        .font(.system(size: 19, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.primary.opacity(0.72))
                    Text("CPU 使用率").font(.system(size: 9)).foregroundStyle(Color.primary.opacity(0.72))
                }
            }
            HStack(spacing: 5) {
                ForEach(Array(m.cores.enumerated()), id: \.offset) { _, t in
                    VStack(spacing: 2) {
                        Text(String(format: "%.0f", t))
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(tempColor(t))
                        Capsule().fill(tempColor(t).opacity(0.75))
                            .frame(height: max(3, CGFloat(min(1, t / 100)) * 20))
                            .animation(.easeOut(duration: 0.25), value: t)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 33, alignment: .bottom)
            Bar(value: m.cpuUsage / 100, tint: .accentColor, height: 4)
            LabelValue(label: "负载 1/5/15", value: String(format: "%.2f  %.2f  %.2f", m.load1, m.load5, m.load15))
            LabelValue(label: "功耗 / 上限", value: String(format: "%.2f W / %.1f W", m.power, m.powerPL))
            LabelValue(label: "核心电压", value: String(format: "%.3f V", m.vcore))
            Divider().overlay(Color.white.opacity(0.06))
            Text("占用最高的进程").font(.system(size: 9)).foregroundStyle(Color.primary.opacity(0.72))
            ForEach(m.topCPU.prefix(4)) { p in
                ProcLine(name: p.name, right: String(format: "%.1f%%   %.0f MB", p.cpu, p.memMB), highlight: p.cpu > 30)
            }
        }
    }

    private func modeColor(_ mode: PerfMode) -> Color {
        switch mode {
        case .quiet: return .teal
        case .balanced: return .blue
        case .performance: return .orange
        }
    }


    // MARK: 性能模式行（快捷键图标下方常驻）
    private var powerModeRow: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                ForEach(PerfMode.allCases) { mode in
                    Button {
                        pm.apply(mode) { msg in tools.lastMessage = msg }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: mode.icon).font(.system(size: 11, weight: .medium))
                            Text(mode.rawValue).font(.system(size: 10, weight: .medium))
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 26)
                        .foregroundStyle(pm.current == mode ? Color.white : Color.primary.opacity(0.85))
                        .background(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .fill(pm.current == mode ? modeColor(mode).opacity(0.78) : Color.primary.opacity(0.07))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 9, style: .continuous)
                                .strokeBorder(Color.primary.opacity(pm.current == mode ? 0.25 : 0.12), lineWidth: 0.6)
                        )
                    }
                    .buttonStyle(.plain)
                    .disabled(pm.busy)
                }
            }
            if !pm.message.isEmpty {
                Text(pm.message).font(.system(size: 8.5))
                    .foregroundStyle(Color.primary.opacity(0.6))
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: 显卡
    private var gpuSection: some View {
        FoldSection(title: "显卡", icon: "cpu.fill",
                    summary: m.gpuUtil >= 0 ? "\(m.gpuUtil)% · 核显" : "无数据",
                    expanded: bind("gpu")) {
            HStack(alignment: .center, spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(m.gpuUtil >= 0 ? "\(m.gpuUtil)%" : "—")
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .foregroundStyle(Color.cyan)
                    Text("GPU 占用（Device Utilization）").font(.system(size: 9))
                        .foregroundStyle(Color.primary.opacity(0.72))
                }
                Spacer(minLength: 0)
            }
            Bar(value: Double(max(0, m.gpuUtil)) / 100, tint: .cyan, height: 4)
            LabelValue(label: "当前 P-State 占用", value: m.gpuUtilPState >= 0 ? "\(m.gpuUtilPState)%" : "—")
            LabelValue(label: "设备", value: "Intel UHD Graphics 630")
            LabelValue(label: "显存（动态共享）", value: "1536 MB")
            Text("说明：核显占用来自 IOAccelerator 的 PerformanceStatistics，NVIDIA GTX 1050 在 macOS 26 无驱动、不提供任何指标。")
                .font(.system(size: 9)).foregroundStyle(Color.primary.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
        }
    }


    private var memSection: some View {
        FoldSection(title: "内存", icon: "memorychip",
                    summary: String(format: "%.1f / %.0f GB", m.memUsed, m.memTotal),
                    expanded: bind("mem")) {
            Bar(value: m.memTotal > 0 ? m.memUsed / m.memTotal : 0, tint: .purple, height: 5)
            LabelValue(label: "已用", value: String(format: "%.2f / %.1f GB", m.memUsed, m.memTotal))
            LabelValue(label: "活跃 / 联动", value: String(format: "%.2f / %.2f GB", m.memActive, m.memWired))
            LabelValue(label: "压缩内存", value: String(format: "%.2f GB", m.memCompressed))
            LabelValue(label: "交换分区", value: String(format: "%.2f GB", m.swapUsed))
            LabelValue(label: "内存压力", value: pressureText(m.memPressure),
                       color: m.memPressure >= 4 ? .red : (m.memPressure == 2 ? .orange : .green))
            Divider().overlay(Color.white.opacity(0.06))
            Text("占用内存最多的进程").font(.system(size: 9)).foregroundStyle(Color.primary.opacity(0.72))
            ForEach(m.topMem.prefix(4)) { p in
                ProcLine(name: p.name, right: String(format: "%.0f MB", p.memMB))
            }
        }
    }

    private func pressureText(_ v: Int32) -> String {
        switch v {
        case 1: return "正常"
        case 2: return "警告"
        case 4: return "严重"
        default: return "—"
        }
    }

    // MARK: 电池
    private var battSection: some View {
        FoldSection(title: "电池", icon: "battery.75",
                    summary: String(format: "%.0f%% · %@", m.battPct, battStateText()),
                    expanded: bind("batt")) {
            Bar(value: m.battPct / 100, tint: m.battPct < 20 ? .red : .green, height: 5)
            LabelValue(label: "状态", value: battStateText(),
                       color: m.acIn ? .green : .secondary)
            LabelValue(label: "电压 / 电流", value: String(format: "%.2f V / %.0f mA", m.battVolt, m.battCurrent))
            LabelValue(label: "剩余 / 满容量", value: String(format: "%.0f / %.0f mAh", m.battRemain, m.battFull))
            LabelValue(label: "设计容量", value: String(format: "%d mAh", m.battDesign))
            LabelValue(label: "循环次数", value: "\(m.battCycle) 次")
            LabelValue(label: "健康度", value: healthText(), color: healthColor())
            LabelValue(label: "剩余时间", value: timeRemainingText())
            LabelValue(label: "外接电源", value: m.acIn ? "已连接" : "未连接")
        }
    }

    private func battStateText() -> String {
        if !m.battPresent { return "无电池" }
        if m.acIn { return m.battCurrent > 50 ? "充电中" : "已接电源" }
        return "放电中"
    }

    private func healthText() -> String {
        guard m.battDesign > 0, m.battMaxRaw > 0 else { return "—" }
        return String(format: "%.0f%%", Double(m.battMaxRaw) / Double(m.battDesign) * 100)
    }

    private func healthColor() -> Color {
        guard m.battDesign > 0, m.battMaxRaw > 0 else { return .secondary }
        let h = Double(m.battMaxRaw) / Double(m.battDesign)
        return h > 0.85 ? .green : (h > 0.7 ? .orange : .red)
    }

    private func timeRemainingText() -> String {
        // 插着电源时不显示「剩余时间」（旧版本用哨兵值算出了荒谬的数字）
        if m.acIn {
            return m.battCurrent > 50 ? "充电中（接通电源）" : "接通电源，不耗电池"
        }
        // 用容量/电流自己算更可靠（SMC/Registry 的 TimeRemaining 常是哨兵值）
        let cur = abs(m.battCurrent)
        guard cur > 20, m.battRemain > 0 else { return m.acIn ? "已接电源" : "计算中" }
        let minutes = Int(m.battRemain / cur * 60)
        if minutes <= 0 || minutes > 24 * 60 { return m.acIn ? "已接电源" : "计算中" }
        return "\(minutes / 60) 小时 \(minutes % 60) 分"
    }

    // MARK: 磁盘
    private var diskSection: some View {
        FoldSection(title: "磁盘", icon: "internaldrive",
                    summary: diskSummaryText,
                    expanded: bind("disk")) {
            // 物理磁盘（这台机器有两块 1TB）
            if !m.disks.isEmpty {
                ForEach(m.disks) { d in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Image(systemName: d.solid ? "internaldrive.fill" : "externaldrive.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(Color.primary.opacity(0.6))
                            Text(d.model)
                                .font(.system(size: 10.5, weight: .medium))
                                .lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 4)
                            Text(String(format: "%.0f GB", d.sizeGB))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Color.primary.opacity(0.72))
                        }
                        Text(diskPartsLine(d))
                            .font(.system(size: 9))
                            .foregroundStyle(Color.primary.opacity(0.55))
                            .lineLimit(2)
                    }
                    .padding(.vertical, 3)
                    .padding(.horizontal, 6)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.045)))
                }
            }
            LabelValue(label: "系统卷可用 / 总量", value: String(format: "%.1f / %.1f GB", m.diskFree, m.diskTotal))
            Bar(value: m.diskTotal > 0 ? (m.diskTotal - m.diskFree) / m.diskTotal : 0, tint: .orange, height: 5)
            LabelValue(label: "读 / 写", value: "\(fmtBytes(m.diskRead)) / \(fmtBytes(m.diskWrite))", color: .cyan)
            LabelValue(label: "启动后累计", value: "\(fmtTotal(m.diskReadTotal)) / \(fmtTotal(m.diskWriteTotal))")
        }
    }

    private var diskSummaryText: String {
        if m.disks.isEmpty { return String(format: "%.0f / %.0f GB", m.diskFree, m.diskTotal) }
        let total = m.disks.reduce(0) { $0 + $1.sizeGB }
        return String(format: "%d 块 · %.1f TB", m.disks.count, total / 1000)
    }

    private func diskPartsLine(_ d: DiskInfo) -> String {
        d.parts.map { p in
            let name = p.name.isEmpty ? p.content : p.name
            return "\(name) \(fmtPartGB(p.sizeGB))"
        }.joined(separator: "  ·  ")
    }

    private func fmtPartGB(_ gb: Double) -> String {
        if gb >= 100 { return String(format: "%.0fG", gb) }
        if gb >= 10 { return String(format: "%.0fG", gb) }
        if gb >= 1 { return String(format: "%.1fG", gb) }
        return String(format: "%.0fM", gb * 1000)
    }

    // MARK: 网络
    private var netSection: some View {
        FoldSection(title: "网络", icon: "wifi",
                    summary: "↓ \(fmtBytes(m.downBps)) ↑ \(fmtBytes(m.upBps))",
                    expanded: bind("net")) {
            HStack(alignment: .bottom, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("↓ " + fmtBytes(m.downBps))
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.cyan)
                    Text("↑ " + fmtBytes(m.upBps))
                        .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Color.primary.opacity(0.72))
                }
                Spacer(minLength: 0)
                Sparkline(values: m.netHistory, tint: .cyan)
                    .frame(width: 110, height: 30).clipped()
            }
            LabelValue(label: "本次流量", value: "↓ \(fmtTotal(m.rxTotal))   ↑ \(fmtTotal(m.txTotal))")
            LabelValue(label: "接口 / IP", value: "\(m.netIface)   \(m.netIP)")
            if !m.wifiSSID.isEmpty {
                LabelValue(label: "Wi-Fi", value: "\(m.wifiSSID)  \(m.wifiChannel) 信道", color: .primary)
                LabelValue(label: "信号 / 速率", value: "\(m.wifiRSSI) dBm   \(String(format: "%.0f", m.wifiTxRate)) Mbps")
            }
            HStack(spacing: 8) {
                Button { m.runSpeedTest() } label: {
                    HStack(spacing: 5) {
                        if m.testing { ProgressView().controlSize(.mini) }
                        Text(m.testing ? "测速中…" : "测速")
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .padding(.horizontal, 9).padding(.vertical, 3.5)
                    .background(Capsule().fill(Color.white.opacity(0.10)))
                }
                .buttonStyle(.plain)
                .disabled(m.testing)

                if let s = m.speed {
                    Text(String(format: "↓%.1f / ↑%.1f Mbps", s.downloadMbps ?? 0, s.uploadMbps ?? 0))
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.primary.opacity(0.72))
                } else {
                    Text("Cloudflare 测速").font(.system(size: 9.5)).foregroundStyle(Color.primary.opacity(0.72))
                }
            }
        }
    }

    // MARK: 进程
    private var procSection: some View {
        FoldSection(title: "进程", icon: "list.bullet.rectangle",
                    summary: m.topCPU.first.map { String(format: "%@ %.0f%%", $0.name, $0.cpu) } ?? "",
                    expanded: bind("proc")) {
            Text("CPU").font(.system(size: 9)).foregroundStyle(Color.primary.opacity(0.72))
            ForEach(m.topCPU.prefix(5)) { p in
                ProcLine(name: p.name, right: String(format: "%.1f%%   %.0f MB", p.cpu, p.memMB), highlight: p.cpu > 30)
            }
            Divider().overlay(Color.white.opacity(0.06))
            Text("内存").font(.system(size: 9)).foregroundStyle(Color.primary.opacity(0.72))
            ForEach(m.topMem.prefix(5)) { p in
                ProcLine(name: p.name, right: String(format: "%.0f MB", p.memMB))
            }
        }
    }

    // MARK: 系统
    private var sysSection: some View {
        FoldSection(title: "系统", icon: "desktopcomputer",
                    summary: m.model,
                    expanded: bind("sys")) {
            LabelValue(label: "型号", value: m.model)
            LabelValue(label: "序列号", value: maskedSerial(m.serial))
            LabelValue(label: "Board ID", value: m.boardID)
            LabelValue(label: "处理器", value: m.cpuBrand)
            LabelValue(label: "核心", value: "\(m.physCpus) 物理 / \(m.logCpus) 逻辑")
            LabelValue(label: "显卡", value: m.gpuName)
            LabelValue(label: "显示器", value: m.displayInfo)
            LabelValue(label: "内存", value: String(format: "%.0f GB", m.memTotal))
            LabelValue(label: "磁盘", value: sysDiskText)
            LabelValue(label: "SMC", value: "\(m.smcKeys) 键 · 风扇 \(m.fans.isEmpty ? "无" : "\(m.fans.count) 个")")
            LabelValue(label: "系统", value: m.osVersion)
            LabelValue(label: "开机时长", value: fmtUptime(m.uptime))
        }
    }

    private var sysDiskText: String {
        guard !m.disks.isEmpty else { return m.nvme }
        let total = m.disks.reduce(0) { $0 + $1.sizeGB }
        return String(format: "%d 块（%.1f TB）· %@", m.disks.count, total / 1000, m.nvme)
    }

    private func maskedSerial(_ s: String) -> String {
        guard s.count > 6 else { return s }
        return String(s.prefix(4)) + "••••" + String(s.suffix(3))
    }

    // MARK: 工具箱
    private var toolsSection: some View {
        FoldSection(title: "工具箱", icon: "wrench.and.screwdriver",
                    summary: toolboxSummary(), expanded: bind("tools")) {
            if tools.scanning {
                Text("正在统计…").font(.system(size: 9.5)).foregroundStyle(Color.primary.opacity(0.72))
            }
            ForEach(tools.items) { item in
                HStack(spacing: 6) {
                    Image(systemName: item.icon)
                        .font(.system(size: 9))
                        .foregroundStyle(Color.primary.opacity(0.72))
                        .frame(width: 13)
                    Text(item.title).font(.system(size: 10.5))
                    Spacer(minLength: 4)
                    Text(item.exists ? Toolbox.human(item.size) : "不存在")
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(Color.primary.opacity(0.72))
                    Button(item.needsRoot ? "需 sudo" : "清理") { pendingClean = item }
                        .font(.system(size: 9.5))
                        .buttonStyle(.plain)
                        .foregroundStyle(item.size > 0 && !item.needsRoot ? Color.accentColor : Color.secondary.opacity(0.5))
                        .disabled(!item.exists || item.size == 0 || item.needsRoot)
                }
                .frame(height: 17)
            }
            HStack(spacing: 10) {
                Button {
                    pendingClean = CleanItem(id: "__all__", title: "全部可清理项", icon: "sparkles", url: URL(fileURLWithPath: NSHomeDirectory()))
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "sparkles").font(.system(size: 9))
                        Text("全部清理").font(.system(size: 9.5))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.orange)
                Button {
                    tools.rescan()
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.clockwise").font(.system(size: 8.5))
                        Text("重新扫描").font(.system(size: 9.5))
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.primary.opacity(0.72))
                Spacer()
                Text("磁盘可用 \(String(format: "%.0f", m.diskFree)) GB")
                    .font(.system(size: 9)).foregroundStyle(Color.primary.opacity(0.72))
            }
            .padding(.top, 2)
            HStack(spacing: 8) {
                Text("工具").font(.system(size: 9)).foregroundStyle(Color.primary.opacity(0.55))
                Button("卸载程序…") {
                    NotificationCenter.default.post(name: .init("SensorBarOpenUninstaller"), object: nil)
                }
                Button("一键优化") {
                    tools.optimize { msg in tools.lastMessage = msg }
                }
                Button("磁盘 / NTFS") {
                    NotificationCenter.default.post(name: .init("SensorBarOpenDisks"), object: nil)
                }
                Spacer()
            }
            .font(.system(size: 9.5))
            .buttonStyle(.plain)
            .foregroundStyle(Color.primary.opacity(0.85))

            HStack(spacing: 8) {
                Text("维护").font(.system(size: 9)).foregroundStyle(Color.primary.opacity(0.55))
                Button("清空剪贴板") { tools.runMaintenance("clipboard") }
                Button("重启 Dock") { tools.runMaintenance("dock") }
                Button("重启 Finder") { tools.runMaintenance("finder") }
                Button("刷新 DNS") { tools.runMaintenance("dns") }
                Spacer()
            }
            .font(.system(size: 9.5))
            .buttonStyle(.plain)
            .foregroundStyle(Color.primary.opacity(0.8))
            if !tools.lastMessage.isEmpty {
                Text(tools.lastMessage)
                    .font(.system(size: 9.5))
                    .foregroundStyle(Color.primary.opacity(0.72))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .alert("确认清理？", isPresented: Binding(
            get: { pendingClean != nil },
            set: { if !$0 { pendingClean = nil } })) {
            Button("清理", role: .destructive) {
                if let it = pendingClean {
                    if it.id == "__all__" { tools.cleanAll() } else { tools.clean(it) }
                }
                pendingClean = nil
            }
            Button("取消", role: .cancel) { pendingClean = nil }
        } message: {
            Text(cleanPrompt())
        }
    }

    private func cleanPrompt() -> String {
        guard let it = pendingClean else { return "" }
        if it.id == "__all__" {
            return "将清空用户缓存、应用日志、崩溃报告、Xcode 派生数据、模拟器缓存与废纸篓，共 \(Toolbox.human(tools.items.filter { !$0.needsRoot }.reduce(0) { $0 + $1.size }))。"
        }
        return "将清空「\(it.title)」下的全部内容（\(Toolbox.human(it.size))），不会删除目录。"
    }

    private func toolboxSummary() -> String {
        let total = tools.items.filter { !$0.needsRoot }.reduce(Int64(0)) { $0 + $1.size }
        if tools.scanning { return "统计中…" }
        return "可清理 " + Toolbox.human(total)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("v" + ((Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "")).font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(Color.primary.opacity(0.55))

            Spacer()

            Text(String(format: "%.0f°", m.tempPkg))
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.primary.opacity(0.72))

            Button("退出") { NSApp.terminate(nil) }
                .font(.system(size: 10))
                .buttonStyle(.plain)
                .foregroundStyle(Color.primary.opacity(0.72))
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let metrics = Metrics()
    var statusItem: NSStatusItem!
    var panel: NSPanel!
    var hosting: NSHostingView<RootView>!
    var refreshTimer: Timer?
    var settingsWindow: NSWindow?
    var uninstallerWindow: NSWindow?
    var diskWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let bid = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
                .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            for o in others { o.terminate() }
        }
        NSApp.setActivationPolicy(.accessory)
        metrics.start()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "52°"
            button.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
            button.target = self
            button.action = #selector(togglePanel)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        hosting = NSHostingView(rootView: RootView(m: metrics))
        hosting.frame = NSRect(x: 0, y: 0, width: 400, height: 560)

        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 560),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.contentView = hosting

        startTitleTimer()

        NotificationCenter.default.addObserver(forName: .init("SensorBarMenuBarPrefsChanged"), object: nil, queue: .main) { [weak self] _ in
            self?.refreshStatusTitle()
        }

        NotificationCenter.default.addObserver(forName: .init("SensorBarRefreshChanged"), object: nil, queue: .main) { [weak self] _ in
            self?.startTitleTimer()
        }

        NotificationCenter.default.addObserver(forName: .init("SensorBarOpenSettings"), object: nil, queue: .main) { [weak self] _ in
            self?.showSettings()
        }

        NotificationCenter.default.addObserver(forName: .init("SensorBarOpenUninstaller"), object: nil, queue: .main) { [weak self] _ in
            self?.showUninstaller()
        }

        NotificationCenter.default.addObserver(forName: .init("SensorBarOpenDisks"), object: nil, queue: .main) { [weak self] _ in
            self?.showDisks()
        }

        NotificationCenter.default.addObserver(forName: .init("SensorBarContentHeight"), object: nil, queue: .main) { [weak self] note in
            guard let self = self, let h = note.object as? CGFloat else { return }
            self.applyContentHeight(h)
        }

        NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.hidePanel()
        }
        refreshStatusTitle()

        if CommandLine.arguments.contains("--show") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.showPanel() }
        }
        if CommandLine.arguments.contains("--settings") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.showSettings() }
        }
        if CommandLine.arguments.contains("--uninstall") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.showUninstaller() }
        }
        if CommandLine.arguments.contains("--disks") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.showDisks() }
        }
    }

    private var lastHeight: CGFloat = 0

    func applyContentHeight(_ content: CGFloat) {
        let target = min(860, max(340, content + 146))
        if abs(target - lastHeight) < 1 { return }
        lastHeight = target
        panel.setContentSize(NSSize(width: 400, height: target))
        hosting.frame = NSRect(x: 0, y: 0, width: 400, height: target)
        if panel.isVisible { positionPanel() }
    }

    func positionPanel() {
        guard let button = statusItem.button, let win = button.window else { return }
        let rectInWindow = button.convert(button.bounds, to: nil)
        let screenRect = win.convertToScreen(rectInWindow)
        let x = min(max(8, screenRect.midX - 192), (NSScreen.main?.visibleFrame.maxX ?? 1440) - 392)
        let y = screenRect.minY - panel.frame.height - 6
        panel.setFrameOrigin(NSPoint(x: x, y: max(8, y)))
    }

    func startTitleTimer() {
        refreshTimer?.invalidate()
        let interval = metrics.refreshInterval
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refreshStatusTitle()
        }
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
        refreshStatusTitle()
    }

    func refreshStatusTitle() {
        guard let button = statusItem.button else { return }
        let mode = UserDefaults.standard.integer(forKey: "menuBarMode")
        let netPart = String(format: "↓%.1f ↑%.1f", metrics.downBps / 1048576, metrics.upBps / 1048576)
        var s: String
        switch mode {
        case 1: s = String(format: "%.0f°  ", metrics.tempPkg) + netPart
        case 2: s = netPart
        case 3: s = String(format: "%.0f%%", metrics.cpuUsage)
        default:
            s = String(format: "%.0f°", metrics.tempPkg)
            if metrics.showNetInMenuBar { s += "  " + netPart }
        }
        if button.title != s { button.title = s }
    }


    private func styleWindow(_ w: NSWindow, title: String, size: NSSize) {
        w.title = title
        w.isReleasedWhenClosed = false
        w.titlebarAppearsTransparent = false
        w.titleVisibility = .visible
        w.styleMask.remove(.fullSizeContentView)
        w.isMovableByWindowBackground = false
        w.backgroundColor = .windowBackgroundColor
        w.isOpaque = true
        w.hasShadow = true
        w.setContentSize(size)
        w.center()
    }

    func showUninstaller() {
        if uninstallerWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 500),
                             styleMask: [.titled, .closable, .resizable],
                             backing: .buffered, defer: false)
            styleWindow(w, title: "卸载程序", size: NSSize(width: 540, height: 500))
            w.contentView = NSHostingView(rootView: UninstallerView())
            uninstallerWindow = w
        }
        hidePanel()
        NSApp.activate(ignoringOtherApps: true)
        uninstallerWindow?.makeKeyAndOrderFront(nil)
    }

    func showDisks() {
        if diskWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 480),
                             styleMask: [.titled, .closable, .resizable],
                             backing: .buffered, defer: false)
            styleWindow(w, title: "磁盘 / NTFS", size: NSSize(width: 560, height: 480))
            w.contentView = NSHostingView(rootView: DiskToolsView())
            diskWindow = w
        }
        hidePanel()
        NSApp.activate(ignoringOtherApps: true)
        diskWindow?.makeKeyAndOrderFront(nil)
    }

    func showSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 540),
                             styleMask: [.titled, .closable, .resizable],
                             backing: .buffered, defer: false)
            styleWindow(w, title: "SensorBar 设置", size: NSSize(width: 430, height: 540))
            w.contentView = NSHostingView(rootView: SettingsView())
            settingsWindow = w
        }
        hidePanel()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func togglePanel() {
        if panel.isVisible { hidePanel() } else { showPanel() }
    }

    func showPanel() {
        positionPanel()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    func hidePanel() {
        if panel.isVisible { panel.orderOut(nil) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
