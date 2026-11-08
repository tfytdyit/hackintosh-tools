import SwiftUI
import AppKit

// MARK: - 播放器设置（独立窗口）

enum VBSettings {
    static let autoPlay = "vb.autoPlay"
    static let loopByDefault = "vb.loopByDefault"
    static let autoAdvance = "vb.autoAdvance"
    static let rememberPosition = "vb.rememberPosition"
    static let hideDelay = "vb.hideDelay"
    static let seekStep = "vb.seekStep"
    static let playlistOnOpen = "vb.playlistOnOpen"
    static let defaultVolume = "vb.defaultVolume"
    static let windowWidth = "vb.windowWidth"
    static let windowHeight = "vb.windowHeight"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            autoPlay: true,
            loopByDefault: false,
            autoAdvance: true,
            rememberPosition: true,
            hideDelay: 2.6,
            seekStep: 5.0,
            playlistOnOpen: false,
            defaultVolume: 1.0,
            windowWidth: 1100.0,
            windowHeight: 660.0,
        ])
    }
}

struct VBSettingsView: View {
    @AppStorage(VBSettings.autoPlay) private var autoPlay = true
    @AppStorage(VBSettings.loopByDefault) private var loopByDefault = false
    @AppStorage(VBSettings.autoAdvance) private var autoAdvance = true
    @AppStorage(VBSettings.rememberPosition) private var rememberPosition = true
    @AppStorage(VBSettings.hideDelay) private var hideDelay = 2.6
    @AppStorage(VBSettings.seekStep) private var seekStep = 5.0
    @AppStorage(VBSettings.playlistOnOpen) private var playlistOnOpen = false
    @AppStorage(VBSettings.defaultVolume) private var defaultVolume = 1.0

    @State private var cleared = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(LinearGradient(colors: [Color(red: 0.35, green: 0.75, blue: 1.0),
                                                      Color(red: 0.62, green: 0.60, blue: 1.0)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                    Image(systemName: "play.fill")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                }
                .frame(width: 29, height: 29)
                VStack(alignment: .leading, spacing: 1) {
                    Text("播放").font(.system(size: 12.5, weight: .semibold))
                    Text("默认行为与播放位置").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)

            Divider().opacity(0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    card("播放") {
                        toggleRow("打开后自动播放", $autoPlay)
                        toggleRow("记住播放位置（下次接着看）", $rememberPosition)
                        toggleRow("播完自动下一个", $autoAdvance)
                        toggleRow("默认单曲循环", $loopByDefault)
                        toggleRow("打开文件时展开播放列表", $playlistOnOpen)
                    }
                    card("控制条") {
                        HStack {
                            Text("自动隐藏延迟").font(.system(size: 11))
                            Spacer()
                            Text(String(format: "%.1f 秒", hideDelay))
                                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        Slider(value: $hideDelay, in: 1.0...8.0, step: 0.2).controlSize(.small)
                        HStack {
                            Text("快进 / 后退步长").font(.system(size: 11))
                            Spacer()
                            Picker("", selection: $seekStep) {
                                Text("5 秒").tag(5.0)
                                Text("10 秒").tag(10.0)
                                Text("15 秒").tag(15.0)
                                Text("30 秒").tag(30.0)
                            }
                            .labelsHidden().pickerStyle(.segmented).frame(width: 220)
                        }
                        HStack {
                            Text("默认音量").font(.system(size: 11))
                            Spacer()
                            Slider(value: $defaultVolume, in: 0...1).frame(width: 150).controlSize(.small)
                            Text(String(format: "%.0f%%", defaultVolume * 100))
                                .font(.system(size: 10.5, design: .monospaced)).foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .trailing)
                        }
                    }
                    card("数据") {
                        HStack {
                            Text("已记住 \(rememberedCount()) 个文件的播放位置").font(.system(size: 10.5)).foregroundStyle(.secondary)
                            Spacer()
                            Button("清除全部") { clearPositions() }
                                .font(.system(size: 10.5))
                        }
                        if !cleared.isEmpty {
                            Text(cleared).font(.system(size: 10)).foregroundStyle(.orange)
                        }
                    }
                    Text("修改立即生效；V 键可显示/隐藏播放列表，F 键全屏，⌘, 打开这个设置。")
                        .font(.system(size: 9.5)).foregroundStyle(.secondary)
                        .padding(.horizontal, 2)
                }
                .padding(14)
                .frame(width: 442, alignment: .leading)
            }
        }
        .frame(width: 470, height: 520, alignment: .topLeading)
    }

    private func card<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 8) { content() }
                .padding(11)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(0.05)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.07), lineWidth: 0.5))
        }
    }

    private func toggleRow(_ title: String, _ binding: Binding<Bool>) -> some View {
        Toggle(title, isOn: binding)
            .toggleStyle(.switch)
            .font(.system(size: 11))
            .controlSize(.small)
    }

    private func rememberedCount() -> Int {
        UserDefaults.standard.dictionaryRepresentation().keys.filter { $0.hasPrefix("pos:") }.count
    }

    private func clearPositions() {
        let d = UserDefaults.standard
        var n = 0
        for k in d.dictionaryRepresentation().keys where k.hasPrefix("pos:") {
            d.removeObject(forKey: k)
            n += 1
        }
        cleared = "已清除 \(n) 条记录"
    }
}
