import AppKit
import Foundation

if CommandLine.arguments.contains("--sysleft") {
    let u = Uninstaller()
    let app = AppItem(id: "/Applications/State.app", name: "State", url: URL(fileURLWithPath: "/Applications/State.app"), bundleID: "com.better365.menubar", size: 0, icon: nil)
    for x in u.systemLeftovers(for: app) { print(Toolbox.human(Toolbox.size(of: x)), x.path) }
    exit(0)
}

if CommandLine.arguments.contains("--printmv") {
    // 打印将要执行的 shell 片段，便于核对引号
    let u = Uninstaller()
    let urls = [URL(fileURLWithPath: "/Applications/State.app"), URL(fileURLWithPath: "/Applications/My App's Test.app")]
    let trash = NSHomeDirectory() + "/.Trash"
    func sq(_ x: String) -> String { "'" + x.replacingOccurrences(of: "'", with: "'\\''") + "'" }
    print("/bin/mkdir -p " + sq(trash) + " && /bin/mv -f " + urls.map { sq($0.path) }.joined(separator: " ") + " " + sq(trash) + "/")
    _ = u
    exit(0)
}

if CommandLine.arguments.contains("--scanapps") {
    let u = Uninstaller()
    u.scan()
    RunLoop.current.run(until: Date().addingTimeInterval(8))
    for a in u.apps.prefix(6) { print(a.name, "|", a.bundleID, "|", Toolbox.human(a.size), "| icon:", a.icon != nil) }
    print("count:", u.apps.count)
    exit(0)
}

if CommandLine.arguments.contains("--trim") {
    print(Toolbox.trimStatus())
    exit(0)
}

if CommandLine.arguments.contains("--speedtest") {
    let sem = DispatchSemaphore(value: 0)
    Task {
        let d = await Metrics.measureDownload()
        let u = await Metrics.measureUpload()
        print(String(format: "download_mbps=%@ upload_mbps=%@",
                     d.map { String(format: "%.2f", $0) } ?? "nil",
                     u.map { String(format: "%.2f", $0) } ?? "nil"))
        sem.signal()
    }
    sem.wait()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
