import AVFoundation
import Foundation

/// 4K60 的 HEVC 在这台机器上解码上限约 60–75 fps，2× 播放必然掉帧。
/// 办法：生成一份 1080p H.264 代理文件，高速播放时切换到代理（解码压力降到 1/4）。
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
        return cacheDir.appendingPathComponent("\(base)-\(size)-\(mtime)-1080p.mp4")
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
        try? FileManager.default.removeItem(at: out)
        let asset = AVURLAsset(url: src)
        guard let e = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1920x1080) else {
            completion(nil); return
        }
        e.outputURL = out
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
                let ok = e.status == .completed
                self.lastMessage = ok ? "代理已生成" : "代理生成失败：\(e.error?.localizedDescription ?? "未知错误")"
                completion(ok ? out : nil)
            }
        }
    }
}
