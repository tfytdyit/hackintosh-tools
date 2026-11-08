// blc —— Hackintosh 内屏背光命令行工具（绕过 corebrightnessd，直接写 AppleBacklight 的 bklt 参数）
// 用法: blc get | blc set 0-100 | blc up [步长] | blc down [步长] | blc max | blc min
import Foundation
import IOKit
import IOKit.graphics

let DISPLAY_CLASS = "AppleBacklightDisplay"

func openBacklightService() -> io_service_t {
    IOServiceGetMatchingService(0, IOServiceMatching(DISPLAY_CLASS))
}

func readLevel(_ svc: io_service_t) -> (value: Int32, max: Int32)? {
    var value: Int32 = -1, minv: Int32 = -1, maxv: Int32 = -1
    let kr = IODisplayGetIntegerRangeParameter(svc, 0, "bklt" as CFString, &value, &minv, &maxv)
    guard kr == KERN_SUCCESS else { return nil }
    return (value, maxv)
}

func writeLevel(_ svc: io_service_t, _ v: Int32) -> kern_return_t {
    var value: Int32 = -1, minv: Int32 = -1, maxv: Int32 = -1
    _ = IODisplayGetIntegerRangeParameter(svc, 0, "bklt" as CFString, &value, &minv, &maxv)
    let clamped = Swift.max(minv, Swift.min(maxv, v))
    let kr = IODisplaySetIntegerParameter(svc, 0, "bklt" as CFString, clamped)
    _ = IODisplaySetIntegerParameter(svc, 0, "commit" as CFString, 1)
    _ = IODisplayCommitParameters(svc, 0)
    return kr
}

func usage() -> Never {
    print("""
    用法: blc <命令>
      get            显示当前亮度（0-100）
      set <n>        设置亮度百分比 0-100
      up [step]      提高，默认 10
      down [step]    降低，默认 10
      max / min      最亮 / 最暗
    """)
    exit(2)
}

let args = CommandLine.arguments
if args.count < 2 { usage() }
let svc = openBacklightService()
if svc == 0 {
    FileHandle.standardError.write("找不到 AppleBacklightDisplay 服务\n".data(using: .utf8)!)
    exit(1)
}
defer { IOObjectRelease(svc) }
guard let (cur, maxv) = readLevel(svc), maxv > 0 else {
    FileHandle.standardError.write("读取 bklt 参数失败\n".data(using: .utf8)!)
    exit(1)
}
let curPercent = Int((Double(cur) / Double(maxv) * 100).rounded())

func target(_ p: Int) -> Int32 {
    let pct = Swift.max(0, Swift.min(100, p))
    return Int32((Double(pct) / 100.0 * Double(maxv)).rounded())
}

switch args[1].lowercased() {
case "get":
    print(curPercent)
case "set":
    guard args.count >= 3, let p = Int(args[2]) else { usage() }
    if writeLevel(svc, target(p)) != KERN_SUCCESS { exit(1) }
    print("brightness -> \(Swift.max(0, Swift.min(100, p)))")
case "up", "down":
    let step = args.count >= 3 ? (Int(args[2]) ?? 10) : 10
    let delta = args[1].lowercased() == "up" ? step : -step
    let p = Swift.max(0, Swift.min(100, curPercent + delta))
    if writeLevel(svc, target(p)) != KERN_SUCCESS { exit(1) }
    print("brightness -> \(p)")
case "max":
    if writeLevel(svc, maxv) != KERN_SUCCESS { exit(1) }
    print("brightness -> 100")
case "min":
    if writeLevel(svc, 0) != KERN_SUCCESS { exit(1) }
    print("brightness -> 0")
default:
    usage()
}
