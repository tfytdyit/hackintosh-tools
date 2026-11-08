import AVFoundation
import Foundation

/// 4K60 的 HEVC 在这台机器上解码上限约 60–75 fps，2× 播放必然掉帧。
/// 办法：生成一份 1080p H.264 代理文件，高速播放时切换到代理（解码压力降到 1/4）。
enum ProxyQuality: Int, CaseIterable, Identifiable {
    case p720 = 0, p1080 = 1
    var id: Int { rawValue }
    var title: String { self == .p720 ? "720p（更快）" : "1080p（更清晰）" }
    var presetName: String {
        self == .p720 ? AVAssetExportPreset1280x720 : AVAssetExportPreset1920x1080
    }
    static var current: ProxyQuality {
        let v = UserDefaults.standard.object(forKey: "vb.proxyQuality") as? Int ?? 0
        return ProxyQuality(rawValue: v) ?? .p720
    }
}

final class ProxyManager: ObservableObject {
    static let shared = ProxyManager()

    @Published var progress: Double = -1        // -1 = 空闲；0…1 = 正在转码
    @Published var busy = false
    @Published var lastMessage = ""

    private var session: AVAssetExportSession?
    private var progressTimer: Timer?

    private var cacheDir: URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VideoBar/Proxy", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func targetURL(for src: URL) -> URL {
        let attrs = try? FileManager.default.attributesOfItem(atPath: src.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        let mtime = Int((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)
        let base = src.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "/", with: "_")
        let tag = ProxyQuality.current == .p720 ? "720p" : "1080p"
        return cacheDir.appendingPathComponent("\(base)-\(size)-\(mtime)-\(tag).mp4")
    }

    /// 校验代理文件是否真的能用（能被打开、有视频轨、时长 > 0.5s）。
    /// 之前只判断「文件存在」，导出中断留下的半截文件会被当成好文件，切过去就是黑屏。
    func validate(_ url: URL) -> Bool {
        let asset = AVURLAsset(url: url)
        let sem = DispatchSemaphore(value: 0)
        var ok = false
        Task {
            do {
                let playable = try await asset.load(.isPlayable)
                let dur = try await asset.load(.duration)
                let tracks = try await asset.loadTracks(withMediaType: .video)
                ok = playable && !tracks.isEmpty && CMTimeGetSeconds(dur) > 0.5
            } catch {
                ok = false
            }
            sem.signal()
        }
        sem.wait()
        return ok
    }

    func existingProxy(for src: URL) -> URL? {
        let u = targetURL(for: src)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    func cachedCount() -> Int {
        (try? FileManager.default.contentsOfDirectory(atPath: cacheDir.path).count) ?? 0
    }

    func clearCache() -> Int {
        let n = cachedCount()
        try? FileManager.default.removeItem(at: cacheDir)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        return n
    }

    /// 转码成 1080p H.264。异步，完成后回调代理 URL（失败为 nil）。
    func makeProxy(for src: URL, completion: @escaping (URL?) -> Void) {
        guard session == nil else { completion(nil); return }
        let out = targetURL(for: src)
        let tmp = out.deletingPathExtension().appendingPathExtension("part.mp4")
        try? FileManager.default.removeItem(at: out)
        try? FileManager.default.removeItem(at: tmp)
        let asset = AVURLAsset(url: src)
        // 720p 转码比 1080p 快约 1.8 倍（实测 30s 切片：25.0s vs 45.5s），2× 播放时解码压力也最小
        let preset = ProxyQuality.current.presetName
        guard let e = AVAssetExportSession(asset: asset, presetName: preset) else {
            completion(nil); return
        }
        e.outputURL = tmp
        e.outputFileType = .mp4
        e.shouldOptimizeForNetworkUse = false
        session = e
        busy = true
        progress = 0
        DispatchQueue.main.async {
            self.progressTimer?.invalidate()
            self.progressTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                guard let self else { return }
                let p = Double(e.progress)
                if p > 0 { self.progress = min(0.999, p) }
            }
        }
        e.exportAsynchronously { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.progressTimer?.invalidate(); self.progressTimer = nil
                self.session = nil
                self.busy = false
                self.progress = -1
                var ok = e.status == .completed
                if ok {
                    // 只有导出成功才把临时文件改成正式名字，避免半截文件被当成有效代理
                    do {
                        try? FileManager.default.removeItem(at: out)
                        try FileManager.default.moveItem(at: tmp, to: out)
                    } catch {
                        ok = false
                    }
                }
                if !ok { try? FileManager.default.removeItem(at: tmp) }
                self.lastMessage = ok ? "代理已生成" : "代理生成失败：\(e.error?.localizedDescription ?? "未知错误")"
                completion(ok ? out : nil)
            }
        }
    }
}
