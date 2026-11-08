import SwiftUI
import AppKit

// MARK: - 开机自启

enum AutoStart {
    static var path: String {
        NSHomeDirectory() + "/Library/LaunchAgents/com.hackintosh.SensorBar.plist"
    }
    static var isOn: Bool { FileManager.default.fileExists(atPath: path) }

    @discardableResult
    static func toggle() -> Bool {
        if isOn {
            try? FileManager.default.removeItem(atPath: path)
            return false
        }
        let exe = Bundle.main.executablePath ?? "/Applications/SensorBar.app/Contents/MacOS/SensorBar"
        let plist: [String: Any] = [
            "Label": "com.hackintosh.SensorBar",
            "ProgramArguments": [exe],
            "RunAtLoad": true,
            "ProcessType": "Interactive",
        ]
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        return (plist as NSDictionary).write(toFile: path, atomically: true)
    }
}

// MARK: - 设置窗口

struct SettingsView: View {
    @AppStorage("glassOpacity") private var glass: Double = 0.0
    @AppStorage("menuBarMode") private var menuMode: Int = 0
    @AppStorage("refreshInterval") private var interval: Double = 1.0
    @AppStorage("showNetInMenuBar") private var showNet: Bool = false
    @State private var autostart: Bool = AutoStart.isOn
    @State private var savedHint = false

#if NO_HEART
    private let modes = ["温度", "温度+网速", "仅网速", "CPU"]
#else
    private let modes = ["温度", "温度+网速", "仅网速", "CPU", "心率"]
#endif

    var body: some View {
        WindowShell(title: "SensorBar 设置", icon: "gearshape.fill", tint: .gray,
                    subtitle: "外观、菜单栏与刷新频率") {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    WSectionTitle(text: "外观")
                    WCard {
                        HStack {
                            Text("磨砂强度").font(.system(size: 11.5))
                            Spacer()
                            Text(String(format: "%.0f%%", min(100, glass / 0.25 * 100)))
                                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $glass, in: 0.0...0.25)
                            .controlSize(.small)
                            .onChange(of: glass) { _, _ in flashSaved() }
                        Text("0% = 完全透明（只有模糊感），100% = 深色磨砂")
                            .font(.system(size: 9.5)).foregroundStyle(.secondary)
                    }

                    WSectionTitle(text: "菜单栏")
                    WCard {
                        HStack {
                            Text("显示内容").font(.system(size: 11.5))
                            Spacer()
                        }
                        Picker("", selection: $menuMode) {
                            ForEach(Array(modes.enumerated()), id: \.offset) { i, t in
                                Text(t).tag(i)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .onChange(of: menuMode) { _, _ in
                            NotificationCenter.default.post(name: .init("SensorBarMenuBarPrefsChanged"), object: nil)
                            flashSaved()
                        }
                        Toggle("菜单栏同时显示网速", isOn: $showNet)
                            .font(.system(size: 11.5))
                            .toggleStyle(.switch).controlSize(.mini)
                            .onChange(of: showNet) { _, _ in
                                NotificationCenter.default.post(name: .init("SensorBarMenuBarPrefsChanged"), object: nil)
                                flashSaved()
                            }
                    }

                    WSectionTitle(text: "数据")
                    WCard {
                        Text("刷新间隔").font(.system(size: 11.5))
                        Picker("", selection: $interval) {
                            Text("1 秒").tag(1.0)
                            Text("2 秒").tag(2.0)
                            Text("3 秒").tag(3.0)
                            Text("5 秒").tag(5.0)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .onChange(of: interval) { _, _ in
                            NotificationCenter.default.post(name: .init("SensorBarRefreshChanged"), object: nil)
                            flashSaved()
                        }
                    }

                    WSectionTitle(text: "通用")
                    WCard {
                        Toggle("开机自动启动", isOn: $autostart)
                            .font(.system(size: 11.5))
                            .toggleStyle(.switch).controlSize(.mini)
                            .onChange(of: autostart) { _, v in
                                let on = AutoStart.isOn
                                if v != on { AutoStart.toggle() }
                                flashSaved()
                            }
                    }

                    HStack(spacing: 8) {
                        PillButton(title: "打开工具箱", icon: "wrench.and.screwdriver", tint: .accentColor, filled: true) {
                            NotificationCenter.default.post(name: .init("SensorBarOpenTools"), object: nil)
                        }
                        PillButton(title: "恢复默认", icon: "arrow.counterclockwise") {
                            glass = 0.0
                            menuMode = 0
                            interval = 1.0
                            flashSaved()
                            NotificationCenter.default.post(name: .init("SensorBarMenuBarPrefsChanged"), object: nil)
                            NotificationCenter.default.post(name: .init("SensorBarRefreshChanged"), object: nil)
                        }
                        Spacer()
                        if savedHint {
                            Text("已保存").font(.system(size: 10.5)).foregroundStyle(.green)
                                .transition(.opacity)
                        }
                    }
                    .padding(.top, 2)

                    Text("配置：~/Library/Preferences/com.hackintosh.SensorBar.plist")
                        .font(.system(size: 9)).foregroundStyle(.tertiary)
                        .padding(.bottom, 8)
                }
                .padding(14)
                .frame(width: 402, alignment: .leading)
            }
        }
        .frame(width: 430, height: 540)
    }

    @ViewBuilder
    private func group<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.secondary)
            content()
            Divider().padding(.vertical, 4)
        }
    }

    private func flashSaved() {
        savedHint = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { savedHint = false }
    }
}
