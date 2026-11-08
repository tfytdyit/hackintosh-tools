import AVFoundation
import Foundation
import AppKit

/// 代理分辨率档位
enum ProxyTier: Int, CaseIterable, Identifiable {
    case p540 = 0, p720 = 1, p1080 = 2
    var id: Int { rawValue }
    var title: String { self == .p540 ? "540p" : (self == .p720 ? "720p" : "1080p") }
    var presetName: String {
        switch self {
        case .p540: return AVAssetExportPreset960x540
        case .p720: return AVAssetExportPreset1280x720
        case .p1080: return AVAssetExportPreset1920x1080
        }
    }
    /// 当前正在用的档位（切到代理时写入，用于顶栏标识）
    static var currentTitle: String {
        UserDefaults.standard.string(forKey: "vb.activeProxyTier") ?? "720p"
    }
    var pixels: Double {
        switch self {
        case .p540: return 960 * 540
        case .p720: return 1280 * 720
        case .p1080: return 1920 * 1080
        }
    }
}

/// 用户设置：自动 / 强制某档 / 关闭
enum ProxyMode: Int, CaseIterable, Identifiable {
    case auto = 0, p1080 = 1, p720 = 2, p540 = 3, off = 4
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .auto: return "自动"
        case .p1080: return "1080p"
        case .p720: return "720p"
        case .p540: return "540p"
        case .off: return "关闭"
        }
    }
    static var current: ProxyMode {
        ProxyMode(rawValue: UserDefaults.standard.object(forKey: "vb.proxyMode") as? Int ?? 0) ?? .auto
    }
}

/// 跑一次「纯解码」基准，估算这台机器对某分辨率的解码吞吐，再把代理档位算出来。
enum ProxyPlanner {
    private struct Profile: Codable {
        var width: Int
        var height: Int
        var decodeFPS: Double
    }

    private static let key = "vb.decodeProfiles"
    private static let lock = NSLock()
    private static var inFlight: Set<String> = []

    private static func sig(width: Int, height: Int, codec: String) -> String {
        "\(width)x\(height)@\(codec)"
    }

    private static func load() -> [String: Profile] {
        guard let d = UserDefaults.standard.data(forKey: key),
              let m = try? JSONDecoder().decode([String: Profile].self, from: d) else { return [:] }
        return m
    }

    private static func save(_ m: [String: Profile]) {
        if let d = try? JSONEncoder().encode(m) { UserDefaults.standard.set(d, forKey: key) }
    }

    static func cachedDecodeFPS(width: Int, height: Int, codec: String) -> Double? {
        lock.lock(); defer { lock.unlock() }
        return load()[sig(width: width, height: height, codec: codec)]?.decodeFPS
    }

    /// 后台跑一次解码基准（只解 90 帧，几十毫秒到一两秒），结果按 分辨率+编码 缓存到 UserDefaults
    static func prepare(asset: AVURLAsset) {
        Task.detached(priority: .utility) {
            guard let (w, h, codec) = try? await geometry(asset) else { return }
            let k = sig(width: w, height: h, codec: codec)
            lock.lock()
            let already = load()[k] != nil
            let busy = inFlight.contains(k)
            if !already && !busy { inFlight.insert(k) }
            lock.unlock()
            if already || busy { return }
            defer { lock.lock(); inFlight.remove(k); lock.unlock() }

            let t0 = Date()
            let frames = await decodeProbe(asset, maxFrames: 90)
            let dt = Date().timeIntervalSince(t0)
            guard frames > 10, dt > 0 else { return }
            let fps = Double(frames) / dt
            lock.lock()
            var m = load()
            m[k] = Profile(width: w, height: h, decodeFPS: fps)
            save(m)
            lock.unlock()
            NSLog("VideoBar decode probe: %dx%d %@ %.1f fps", w, h, codec, fps)
            NotificationCenter.default.post(name: .init("VBDecodeProfileReady"), object: nil)
        }
    }

    private static func geometry(_ asset: AVURLAsset) async throws -> (Int, Int, String) {
        guard let t = try await asset.loadTracks(withMediaType: .video).first else { throw NSError(domain: "vbar", code: 1) }
        let size = try await t.load(.naturalSize)
        let descs = try await t.load(.formatDescriptions)
        var codec = "?"
        if let d = descs.first { codec = String(describing: CMFormatDescriptionGetMediaSubType(d)) }
        return (Int(size.width), Int(size.height), codec)
    }

    private static func decodeProbe(_ asset: AVURLAsset, maxFrames: Int) async -> Int {
        guard let reader = try? AVAssetReader(asset: asset),
              let t = try? await asset.loadTracks(withMediaType: .video).first else { return 0 }
        let settings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ]
        let out = AVAssetReaderTrackOutput(track: t, outputSettings: settings)
        out.alwaysCopiesSampleData = false
        guard reader.canAdd(out) else { return 0 }
        reader.add(out)
        guard reader.startReading() else { return 0 }
        var n = 0
        while n < maxFrames, let _ = out.copyNextSampleBuffer() { n += 1 }
        reader.cancelReading()
        return n
    }

    /// 需求：2× 播放时每秒要交付 speed × 源帧率 帧。实机交付 ≈ 纯解码的 65%，
    /// 所以要求 decodeFPS × (源像素/代理像素) × 0.65 ≥ 需求 × 1.15
    static func decide(width: Int, height: Int, srcFPS: Double, decodeFPS: Double,
                       targetSpeed: Double, mode: ProxyMode) -> ProxyTier? {
        switch mode {
        case .off: return nil
        case .p1080: return .p1080
        case .p720: return .p720
        case .p540: return .p540
        case .auto: break
        }
        let need = max(30, targetSpeed * max(24, srcFPS)) * 1.15
        let srcPixels = Double(max(1, width * height))
        let realFactor = 0.65
        // 屏幕高度上限：1080p 屏没必要用 4K 代理
        let screenMax = Int(NSScreen.main?.frame.height ?? 1080) * 2
        // 先看原片能不能直接播（不生成代理）
        if decodeFPS * realFactor >= need { return nil }
        for tier in [ProxyTier.p1080, .p720, .p540] where Int(tier.pixels) <= max(1, width * height) {
            if tier == .p1080 && screenMax < 1080 { continue }
            let gain = srcPixels / tier.pixels
            if decodeFPS * gain * realFactor >= need { return tier }
        }
        return .p540
    }
}
