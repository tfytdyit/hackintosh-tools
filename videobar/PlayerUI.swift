import SwiftUI
import AppKit

// MARK: - 悬停高亮按钮

struct HoverIcon: View {
    let symbol: String
    var size: CGFloat = 14
    var active: Bool = false
    var help: String = ""
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(active ? Color.accentColor : .white.opacity(hover ? 1.0 : 0.86))
                .frame(width: size + 16, height: size + 10)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.white.opacity(hover ? 0.14 : 0.0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .help(help)
    }
}

// MARK: - 播放器界面

struct ContentView: View {
    @ObservedObject var engine: PlayerEngine

    @AppStorage(VBSettings.hideDelay) private var hideDelay = 2.6
    @AppStorage(VBSettings.seekStep) private var seekStep = 5.0
    @AppStorage(VBSettings.playlistOnOpen) private var playlistOnOpen = false

    @State private var controlsVisible = true
    @State private var hideWorkItem: DispatchWorkItem?
    @State private var showPlaylist = false
    @State private var scrubbing = false
    @State private var scrubValue: Double = 0
    @State private var isFullScreen = false
    @State private var dragOver = false

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.width < 820
            ZStack {
                Color.black.ignoresSafeArea()

                PlayerSurface(player: engine.player)
                    .ignoresSafeArea()
                    .onTapGesture(count: 2) { toggleFullScreen() }
                    .onTapGesture { engine.togglePlay(); flashControls() }
                    .onDrop(of: [.fileURL], isTargeted: $dragOver) { providers in
                        handleDrop(providers)
                    }

                if engine.currentURL == nil { emptyState }
                if dragOver { dropOverlay }

                if controlsVisible {
                    VStack(spacing: 0) {
                        topBar(compact: compact)
                        Spacer(minLength: 0)
                        if !engine.isPlaying && engine.currentURL != nil { centerPlay }
                        Spacer(minLength: 0)
                        bottomBar(compact: compact)
                    }
                    .transition(.opacity)
                }

                if showPlaylist {
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)
                        playlistPanel
                    }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.18), value: showPlaylist)
            .animation(.easeInOut(duration: 0.16), value: controlsVisible)
        }
        .frame(minWidth: 640, minHeight: 380)
        .onContinuousHover { phase in
            if case .active = phase { flashControls() }
        }
        .background(KeyboardCatcher { key in handleKey(key) })
        .onReceive(NotificationCenter.default.publisher(for: .init("VBOpenSettings"))) { _ in
            // 由 AppDelegate 处理，界面无需动作
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didEnterFullScreenNotification)) { _ in
            isFullScreen = true; flashControls()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didExitFullScreenNotification)) { _ in
            isFullScreen = false; flashControls()
        }
        .onAppear {
            if (playlistOnOpen || CommandLine.arguments.contains("--playlist")) && engine.playlist.count > 1 {
                showPlaylist = true
            }
            flashControls()
        }
    }

    // MARK: 空状态

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "play.rectangle.on.rectangle")
                .font(.system(size: 62, weight: .thin))
                .foregroundStyle(.white.opacity(0.55))
            Text("把视频文件或文件夹拖到这里")
                .font(.system(size: 19, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
            HStack(spacing: 18) {
                shortcutHint("⌘O", "打开文件")
                shortcutHint("⇧⌘O", "打开文件夹")
                shortcutHint("⌘,", "设置")
            }
            .padding(.top, 2)
        }
    }

    private func shortcutHint(_ key: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Text(key)
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.12)))
            Text(text).font(.system(size: 11)).foregroundStyle(.white.opacity(0.55))
        }
    }

    private var dropOverlay: some View {
        ZStack {
            Color.black.opacity(0.55)
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(0.9), style: StrokeStyle(lineWidth: 2.5, dash: [9, 6]))
                .padding(22)
            VStack(spacing: 8) {
                Image(systemName: "arrow.down.doc.fill").font(.system(size: 34)).foregroundStyle(.white.opacity(0.9))
                Text("松手即播放").font(.system(size: 15, weight: .medium)).foregroundStyle(.white.opacity(0.9))
            }
        }
        .ignoresSafeArea()
    }

    // MARK: 顶栏

    private func badgeText(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(color.opacity(0.95))
            .padding(.horizontal, 6).padding(.vertical, 2.5)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.black.opacity(0.35)))
    }

    private func topBar(compact: Bool) -> some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            if engine.usingProxy {
                badgeText("\(ProxyTier.currentTitle) 代理", color: .green)
            } else if engine.proxyPreparing {
                badgeText("代理 \(Int(ProxyManager.shared.progress * 100))%", color: .orange)
            }
            HStack(spacing: 4) {
                HoverIcon(symbol: "list.bullet", size: 13, active: showPlaylist, help: "播放列表（V）") {
                    withAnimation(.easeInOut(duration: 0.18)) { showPlaylist.toggle() }
                }
                HoverIcon(symbol: "gearshape", size: 13, help: "设置（⌘,）") {
                    NotificationCenter.default.post(name: .init("VBShowSettings"), object: nil)
                }
            }
            .padding(4)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.black.opacity(0.34))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
            )
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
    }

    private func chip(_ text: String, tint: Color = .white) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(tint.opacity(0.95))
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(.white.opacity(0.12))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
            )
    }

    // MARK: 中央播放按钮

    private var centerPlay: some View {
        Button { engine.play(); flashControls() } label: {
            ZStack {
                Circle().fill(.black.opacity(0.42))
                    .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1))
                Image(systemName: "play.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                    .offset(x: 2)
            }
            .frame(width: 84, height: 84)
        }
        .buttonStyle(.plain)
        .transition(.scale(scale: 0.9).combined(with: .opacity))
    }

    // MARK: 底栏

    private func bottomBar(compact: Bool) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 9) {
                Text(VideoBar.fmt(scrubbing ? scrubValue : engine.position))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.9))
                    .frame(width: 56, alignment: .leading)
                scrubber
                Text(VideoBar.fmt(engine.duration))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                    .frame(width: 56, alignment: .trailing)
            }

            HStack(spacing: 6) {
                HoverIcon(symbol: engine.isPlaying ? "pause.fill" : "play.fill", size: compact ? 16 : 18,
                          help: "播放 / 暂停（空格）") { engine.togglePlay(); flashControls() }
                HoverIcon(symbol: "backward.fill", size: 12, help: "后退 \(Int(seekStep)) 秒（←）") {
                    engine.skip(-seekStep); flashControls()
                }
                HoverIcon(symbol: "forward.fill", size: 12, help: "前进 \(Int(seekStep)) 秒（→）") {
                    engine.skip(seekStep); flashControls()
                }
                HoverIcon(symbol: "backward.end.fill", size: 11, help: "上一个（⌘←）") { engine.prev(); flashControls() }
                HoverIcon(symbol: "forward.end.fill", size: 11, help: "下一个（⌘→）") { engine.next(); flashControls() }

                Spacer(minLength: 8)

                HStack(spacing: 2) {
                    HoverIcon(symbol: (engine.muted || engine.volume == 0) ? "speaker.slash.fill" : "speaker.wave.2.fill",
                              size: 12, help: "静音（M）") { engine.toggleMute() }
                    Slider(value: Binding(get: { engine.muted ? 0 : engine.volume },
                                          set: { engine.setVolume($0) }), in: 0...1)
                        .frame(width: compact ? 62 : 84)
                        .controlSize(.mini)
                }

                if !compact {
                    speedMenu
                }
                HoverIcon(symbol: "repeat", size: 12, active: engine.loop, help: "循环（L）") { engine.loop.toggle() }
                HoverIcon(symbol: "list.bullet", size: 12, active: showPlaylist, help: "播放列表（V）") {
                    withAnimation(.easeInOut(duration: 0.18)) { showPlaylist.toggle() }
                }
                HoverIcon(symbol: isFullScreen ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                          size: 12, help: "全屏（F）") { toggleFullScreen() }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(.black.opacity(0.46))
                )
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(.white.opacity(0.14), lineWidth: 0.6))
                .shadow(color: .black.opacity(0.5), radius: 16, y: 5)
        )
        .padding(.leading, 14)
        .padding(.trailing, showPlaylist ? 274 : 14)
        .padding(.bottom, 16)
        .animation(.easeInOut(duration: 0.18), value: showPlaylist)
    }

    private var scrubber: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let p = max(0, min(1, (scrubbing ? scrubValue : engine.position) / max(engine.duration, 0.001)))
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18)).frame(height: 4)
                Capsule().fill(.white.opacity(0.92)).frame(width: p * width, height: 4)
                if engine.duration > 0 {
                    Circle()
                        .fill(.white)
                        .frame(width: scrubbing ? 13 : 10, height: scrubbing ? 13 : 10)
                        .shadow(color: .black.opacity(0.35), radius: 2)
                        .offset(x: p * width - (scrubbing ? 6.5 : 5))
                }
            }
            .frame(height: 18)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        scrubbing = true
                        scrubValue = Double(max(0, min(width, v.location.x)) / max(width, 1)) * engine.duration
                    }
                    .onEnded { _ in
                        engine.seek(to: scrubValue)
                        scrubbing = false
                        flashControls()
                    }
            )
        }
        .frame(height: 18)
    }

    private var speedMenu: some View {
        Menu {
            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { s in
                Button(s == 1.0 ? "正常 1.0×" : String(format: "%.2g×", s)) { engine.setSpeed(s) }
            }
        } label: {
            Text(String(format: "%.2g×", engine.speed))
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(.white.opacity(0.10)))
        }
        .menuStyle(.borderlessButton)
        .frame(width: 52)
    }

    // MARK: 播放列表

    private var playlistPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet").font(.system(size: 11)).foregroundStyle(.white.opacity(0.7))
                Text("播放列表").font(.system(size: 12.5, weight: .semibold)).foregroundStyle(.white.opacity(0.92))
                Text("\(engine.playlist.count)").font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.45))
                Spacer()
                HoverIcon(symbol: "xmark", size: 10, help: "关闭") {
                    withAnimation(.easeInOut(duration: 0.18)) { showPlaylist = false }
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 11)

            Divider().overlay(.white.opacity(0.12))

            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(engine.playlist.enumerated()), id: \.offset) { i, u in
                        PlaylistRow(url: u, index: i, current: i == engine.index) {
                            engine.open(u, playlist: engine.playlist)
                            flashControls()
                        }
                    }
                }
                .padding(.horizontal, 7).padding(.vertical, 7)
            }
        }
        .frame(width: 262)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(.black.opacity(0.55)))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.6))
        )
        .padding(.trailing, 12)
        .padding(.vertical, 12)
    }

    // MARK: 交互

    private func flashControls() {
        withAnimation(.easeOut(duration: 0.14)) { controlsVisible = true }
        hideWorkItem?.cancel()
        let item = DispatchWorkItem {
            if engine.isPlaying && !showPlaylist {
                withAnimation(.easeIn(duration: 0.22)) { controlsVisible = false }
            }
        }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + hideDelay, execute: item)
    }

    private func toggleFullScreen() {
        (NSApp.keyWindow ?? NSApp.mainWindow)?.toggleFullScreen(nil)
        flashControls()
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let p = providers.first else { return false }
        _ = p.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            DispatchQueue.main.async { openTarget(url) }
        }
        return true
    }

    private func openTarget(_ url: URL) {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        if isDir.boolValue {
            let files = VideoBar.filesInFolder(url)
            if let first = files.first { engine.open(first, playlist: files) }
        } else {
            let files = VideoBar.filesInFolder(url.deletingLastPathComponent())
            if files.contains(url) { engine.open(url, playlist: files) } else { engine.open(url) }
        }
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 49: engine.togglePlay(); flashControls(); return true
        case 123: engine.skip(-seekStep); flashControls(); return true
        case 124: engine.skip(seekStep); flashControls(); return true
        case 126: engine.setVolume(min(1, engine.volume + 0.05)); flashControls(); return true
        case 125: engine.setVolume(max(0, engine.volume - 0.05)); flashControls(); return true
        case 3: toggleFullScreen(); return true
        default: break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "m": engine.toggleMute(); flashControls(); return true
        case "l": engine.loop.toggle(); flashControls(); return true
        case "v": withAnimation(.easeInOut(duration: 0.18)) { showPlaylist.toggle() }; flashControls(); return true
        case "]": engine.setSpeed(min(4, engine.speed + 0.25)); flashControls(); return true
        case "[": engine.setSpeed(max(0.25, engine.speed - 0.25)); flashControls(); return true
        default: return false
        }
    }
}

// MARK: - 播放列表行（悬停高亮）

struct PlaylistRow: View {
    let url: URL
    let index: Int
    let current: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: current ? "waveform" : "film")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(current ? Color.accentColor : .white.opacity(0.4))
                    .frame(width: 14)
                Text(url.lastPathComponent)
                    .font(.system(size: 11.5))
                    .foregroundStyle(current ? .white : .white.opacity(hover ? 0.95 : 0.72))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 2)
                Text(String(format: "%02d", index + 1))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.28))
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(current ? Color.accentColor.opacity(0.18)
                          : (hover ? Color.white.opacity(0.09) : Color.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}
