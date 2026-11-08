import AVFoundation
import AppKit
import SwiftUI
import VideoToolbox

// MARK: - 媒体信息

struct MediaMeta {
    var name: String = ""
    var width: Int = 0
    var height: Int = 0
    var fps: Double = 0
    var bitrateMbps: Double = 0
    var codec: String = ""
    var bitDepth: Int = 0
    var hwDecode: Bool = false
    var colorSpace: String = ""

    var resText: String { width > 0 ? "\(width)×\(height)" : "—" }
    var fpsText: String { fps > 0 ? String(format: "%.2f fps", fps) : "—" }
    var bitrateText: String { bitrateMbps > 0 ? String(format: "%.0f Mbps", bitrateMbps) : "—" }
    var hwText: String { hwDecode ? "硬件解码" : "软件解码" }
}

func codecName(_ type: CMVideoCodecType) -> String {
    switch type {
    case kCMVideoCodecType_HEVC: return "HEVC"
    case kCMVideoCodecType_H264: return "H.264"
    case kCMVideoCodecType_VP9: return "VP9"
    case kCMVideoCodecType_AppleProRes422: return "ProRes 422"
    case kCMVideoCodecType_AppleProRes4444: return "ProRes 4444"
    default: return "codec \(type)"
    }
}

// MARK: - 播放引擎

final class PlayerEngine: NSObject, ObservableObject {
    let player = AVPlayer()

    @Published var currentURL: URL?
    @Published var meta = MediaMeta()
    @Published var isPlaying = false
    @Published var duration: Double = 0
    @Published var position: Double = 0
    @Published var volume: Double = 1.0
    @Published var muted = false
    @Published var loop = false
    @Published var speed: Double = 1.0
    @Published var effectiveSpeed: Double = 1.0     // currentTime 推进 / 墙钟
    @Published var stalls = 0
    @Published var playlist: [URL] = []
    @Published var index: Int = 0
    @Published var status: String = ""
    @Published var usingProxy = false        // 当前播放的是 1080p 代理
    @Published var sourceURL: URL?           // 原始文件（代理模式下 currentURL 指向代理）
    @Published var proxyPreparing = false
    @Published var proxyProgress: Double = -1

    private var timeObserver: Any?
    private var lastWall = CACurrentMediaTime()
    private var lastPos: Double = 0
    private var endObserver: NSObjectProtocol?
    private var stallObserver: NSObjectProtocol?
    private var itemStatusObserver: NSKeyValueObservation?
    @Published var lastErrorText: String = ""
    private var saveTimer: Timer?

    override init() {
        super.init()
        player.actionAtItemEnd = .none
        let d = UserDefaults.standard
        let startVolume = d.object(forKey: VBSettings.defaultVolume) as? Double ?? 1.0
        volume = startVolume
        player.volume = Float(startVolume)
        loop = d.bool(forKey: VBSettings.loopByDefault)
        addPeriodicObserver()
        saveTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.savePosition()
        }
        RunLoop.main.add(saveTimer!, forMode: .common)
    }

    deinit {
        if let o = timeObserver { player.removeTimeObserver(o) }
        if let e = endObserver { NotificationCenter.default.removeObserver(e) }
        if let s = stallObserver { NotificationCenter.default.removeObserver(s) }
    }

    private func addPeriodicObserver() {
        var ticks = 0
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 4),
                                                      queue: .main) { [weak self] t in
            guard let self else { return }
            ticks += 1
            // 高速播放时把 UI 刷新降到 2Hz，减少主线程/SwiftUI 重绘抢解码资源
            if self.speed > 1.5 && ticks % 2 != 0 { return }
            self.position = t.seconds.isFinite ? t.seconds : 0
            self.measureSmoothness(pos: self.position)
        }
    }

    private func measureSmoothness(pos: Double) {
        let now = CACurrentMediaTime()
        let dt = now - lastWall
        if dt >= 0.9 {
            let dp = pos - lastPos
            if isPlaying, speed > 0, dp >= 0, dp < dt * speed * 1.5 {
                effectiveSpeed = dp / dt / speed
            } else {
                effectiveSpeed = 1.0
            }
            lastWall = now
            lastPos = pos
        }
    }

    // MARK: 打开文件

    func open(_ url: URL, playlist: [URL]? = nil) {
        if let list = playlist, !list.isEmpty {
            self.playlist = list
            self.index = list.firstIndex(of: url) ?? 0
        } else if self.playlist.isEmpty || !self.playlist.contains(url) {
            self.playlist = [url]
            self.index = 0
        }

        sourceURL = url
        usingProxy = false
        currentURL = url
        isPlaying = false
        position = 0
        effectiveSpeed = 1.0
        lastWall = CACurrentMediaTime()
        lastPos = 0
        duration = 0
        stalls = 0
        effectiveSpeed = 1.0
        meta = MediaMeta(name: url.lastPathComponent)
        status = "正在打开…"

        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 3
        player.automaticallyWaitsToMinimizeStalling = false
        player.replaceCurrentItem(with: item)

        if let e = endObserver { NotificationCenter.default.removeObserver(e) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                             object: item, queue: .main) { [weak self] _ in
            self?.handleEnded()
        }
        if let s = stallObserver { NotificationCenter.default.removeObserver(s) }
        stallObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemPlaybackStalled,
                                                              object: item, queue: .main) { [weak self] _ in
            self?.stalls += 1
        }

        loadMeta(url: url, item: item)
        let autoPlay = UserDefaults.standard.object(forKey: VBSettings.autoPlay) as? Bool ?? true
        if autoPlay {
            player.play()
            isPlaying = true
        } else {
            isPlaying = false
            status = "已暂停"
        }
        applySpeed()
        ensureProxyState()
    }

    // MARK: 1080p 代理（高速播放用）

    private var autoProxyEnabled: Bool {
        UserDefaults.standard.object(forKey: VBSettings.autoProxy) as? Bool ?? true
    }

    private func observe(_ item: AVPlayerItem) {
        if let e = endObserver { NotificationCenter.default.removeObserver(e) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                             object: item, queue: .main) { [weak self] _ in
            self?.handleEnded()
        }
        if let s = stallObserver { NotificationCenter.default.removeObserver(s) }
        stallObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemPlaybackStalled,
                                                              object: item, queue: .main) { [weak self] _ in
            self?.stalls += 1
        }
    }

    /// 在「原片」与「1080p 代理」之间无缝切换（保留进度与播放状态）
    private func swapItem(to url: URL, proxy: Bool) {
        let pos = player.currentTime().seconds
        let wasPlaying = isPlaying
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 3
        player.automaticallyWaitsToMinimizeStalling = false
        player.replaceCurrentItem(with: item)
        observe(item)
        usingProxy = proxy
        currentURL = url
        watchItemStatus(item, proxy: proxy, url: url)
        player.seek(to: CMTime(seconds: pos, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            guard let self else { return }
            if wasPlaying { self.player.playImmediately(atRate: Float(self.speed)) }
            self.position = pos
            self.lastPos = pos
            self.lastWall = CACurrentMediaTime()
            self.applySpeed()
        }
    }

    /// 切过去之后盯着状态：代理文件坏（黑屏的典型来源）就自动退回原片
    private func watchItemStatus(_ item: AVPlayerItem, proxy: Bool, url: URL) {
        if let t = itemStatusObserver { t.invalidate(); itemStatusObserver = nil }
        itemStatusObserver = item.observe(\.status, options: [.new]) { [weak self] it, _ in
            guard let self else { return }
            guard it.status == .failed else { return }
            DispatchQueue.main.async {
                self.lastErrorText = it.error?.localizedDescription ?? "播放失败"
                if proxy, let src = self.sourceURL {
                    // 坏代理：删掉，回原片
                    try? FileManager.default.removeItem(at: url)
                    self.swapItem(to: src, proxy: false)
                }
            }
        }
    }

    private func revertToSourceIfNeeded() {
        guard usingProxy, let src = sourceURL else { return }
        swapItem(to: src, proxy: false)
    }

    /// 速度 ≥1.4 且开启了自动代理时：有代理就切过去，没有就后台生成
    func ensureProxyState() {
        guard let src = sourceURL else { return }
        let wantProxy = autoProxyEnabled && speed >= 1.4
        if wantProxy {
            if usingProxy { return }
            if let ready = ProxyManager.shared.existingProxy(for: src) {
                guard !proxyPreparing else { return }
                proxyPreparing = true
                DispatchQueue.global(qos: .userInitiated).async {
                    let ok = ProxyManager.shared.validate(ready)
                    DispatchQueue.main.async {
                        guard let self = self as PlayerEngine? else { return }
                        self.proxyPreparing = false
                        if ok {
                            if self.autoProxyEnabled, self.speed >= 1.4, self.sourceURL == src, !self.usingProxy {
                                self.swapItem(to: ready, proxy: true)
                            }
                        } else {
                            try? FileManager.default.removeItem(at: ready)
                            self.ensureProxyState()
                        }
                    }
                }
                return
            }
            guard !proxyPreparing else { return }
            proxyPreparing = true
            ProxyManager.shared.makeProxy(for: src) { [weak self] out in
                guard let self else { return }
                self.proxyPreparing = false
                guard let out else { return }
                if self.autoProxyEnabled, self.speed >= 1.4, self.sourceURL == src, !self.usingProxy {
                    self.swapItem(to: out, proxy: true)
                }
            }
        } else if usingProxy, let ready = src as URL? {
            swapItem(to: ready, proxy: false)
        }
    }

    private func loadMeta(url: URL, item: AVPlayerItem) {
        let asset = AVURLAsset(url: url)
        Task.detached(priority: .userInitiated) {
            var m = MediaMeta(name: url.lastPathComponent)
            do {
                let tracks = try await asset.loadTracks(withMediaType: .video)
                if let t = tracks.first {
                    let size = try await t.load(.naturalSize)
                    let tf = try await t.load(.preferredTransform)
                    let real = size.applying(tf)
                    m.width = Int(abs(real.width).rounded())
                    m.height = Int(abs(real.height).rounded())
                    m.fps = Double(try await t.load(.nominalFrameRate))
                    m.bitrateMbps = Double(try await t.load(.estimatedDataRate)) / 1_000_000.0
                    if let fd = try await t.load(.formatDescriptions).first {
                        let desc = fd
                        let codec = CMFormatDescriptionGetMediaSubType(desc)
                        m.codec = codecName(codec)
                        m.hwDecode = VTIsHardwareDecodeSupported(codec)
                        let dims = CMVideoFormatDescriptionGetDimensions(desc)
                        if dims.width > 0 { m.width = Int(dims.width); m.height = Int(dims.height) }
                        if let ext = CMFormatDescriptionGetExtensions(desc) as? [String: Any] {
                            if let depth = ext["Depth"] as? Int { m.bitDepth = depth }
                            if let prim = ext["ColorPrimaries"] as? String { m.colorSpace = prim }
                        }
                    }
                }
                let d = try await asset.load(.duration)
                let dur = d.seconds
                let finalMeta = m
                await MainActor.run {
                    self.meta = finalMeta
                    if dur.isFinite, dur > 0 { self.duration = dur }
                    self.status = ""
                    self.restorePosition(for: url)
                }
            } catch {
                await MainActor.run { self.status = "读取媒体信息失败：\(error.localizedDescription)" }
            }
        }
    }

    // MARK: 播放控制

    func togglePlay() {
        if isPlaying { pause() } else { play() }
    }

    func play() {
        if duration > 0, position >= duration - 0.12 { seek(to: 0) }
        player.play()
        isPlaying = true
        applySpeed()
        lastWall = CACurrentMediaTime()
        lastPos = position
    }

    func pause() {
        player.pause()
        isPlaying = false
        savePosition()
    }

    func toggleMute() { muted.toggle(); player.isMuted = muted }
    func setVolume(_ v: Double) { volume = v; player.volume = Float(v); if v > 0 { muted = false; player.isMuted = false } }

    func setSpeed(_ s: Double) {
        speed = s
        applySpeed()
        ensureProxyState()
    }

    private func applySpeed() {
        // 2x 时 spectral 时间伸缩很吃 CPU，会挤占 HEVC 硬解；用 varispeed（变调不变速）更省
        player.currentItem?.audioTimePitchAlgorithm = speed == 1.0 ? .spectral : .varispeed
        player.rate = isPlaying ? Float(speed) : 0
    }

    func seek(to t: Double) {
        let target = max(0, min(t, max(duration - 0.05, 0)))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        position = target
        lastPos = target
        lastWall = CACurrentMediaTime()
    }

    func skip(_ seconds: Double) { seek(to: position + seconds) }

    func handleEnded() {
        savePosition(clear: true)
        let autoAdvance = UserDefaults.standard.object(forKey: VBSettings.autoAdvance) as? Bool ?? true
        if loop {
            seek(to: 0); play()
        } else if autoAdvance && index + 1 < playlist.count {
            next()
        } else {
            isPlaying = false
        }
    }

    func next() {
        guard !playlist.isEmpty else { return }
        index = (index + 1) % playlist.count
        open(playlist[index], playlist: playlist)
    }

    func prev() {
        guard !playlist.isEmpty else { return }
        index = (index - 1 + playlist.count) % playlist.count
        open(playlist[index], playlist: playlist)
    }

    // MARK: 记录播放位置

    private var posKey: String? { currentURL.map { "pos:" + $0.path } }

    private func restorePosition(for url: URL) {
        let remember = UserDefaults.standard.object(forKey: VBSettings.rememberPosition) as? Bool ?? true
        guard remember else { return }
        let key = "pos:" + url.path
        let saved = UserDefaults.standard.double(forKey: key)
        if saved > 3, saved < duration - 3 {
            seek(to: saved)
        }
    }

    func savePosition(clear: Bool = false) {
        let remember = UserDefaults.standard.object(forKey: VBSettings.rememberPosition) as? Bool ?? true
        guard remember else { return }
        guard let key = posKey else { return }
        if clear || duration <= 0 {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(position, forKey: key)
        }
    }
}

// MARK: - 播放视图（AVPlayerLayer）

struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> PlayerLayerView {
        let v = PlayerLayerView()
        v.playerLayer.player = player
        v.playerLayer.videoGravity = .resizeAspect
        return v
    }

    func updateNSView(_ nsView: PlayerLayerView, context: Context) {
        nsView.playerLayer.player = player
    }
}

final class PlayerLayerView: NSView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

// MARK: - 键盘捕获

struct KeyboardCatcher: NSViewRepresentable {
    let onKey: (NSEvent) -> Bool

    func makeNSView(context: Context) -> NSView {
        let v = KeyView()
        v.onKey = onKey
        DispatchQueue.main.async { v.window?.makeFirstResponder(v) }
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class KeyView: NSView {
        var onKey: ((NSEvent) -> Bool)?
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {
            if onKey?(event) == true { return }
            super.keyDown(with: event)
        }
    }
}

// MARK: - 帮助函数

enum VideoBar {
    static func filesInFolder(_ url: URL) -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isRegularFileKey],
                                                      options: [.skipsHiddenFiles]) else { return [] }
        let movies = items.filter { isMovie($0) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        return movies.isEmpty ? [url] : movies
    }

    static func isMovie(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .audiovisualContent)
    }

    static func fmt(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "00:00" }
        let s = Int(t)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }
}
