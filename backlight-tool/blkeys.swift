// blkeys —— 按键识别器：按下你的亮度键，看它到底产生了什么事件
// 用法: ./blkeys [--seconds 20]
import Cocoa

let args = CommandLine.arguments
var seconds: Double = 25
if let i = args.firstIndex(of: "--seconds"), i + 1 < args.count, let v = Double(args[i + 1]) { seconds = v }

func keyName(_ code: Int) -> String {
    switch code {
    case 2:  return "NX_KEYTYPE_BRIGHTNESS_DOWN (媒体亮度-)"
    case 3:  return "NX_KEYTYPE_BRIGHTNESS_UP (媒体亮度+)"
    case 21: return "NX_KEYTYPE_ILLUMINATION_DOWN (键盘背光-)"
    case 22: return "NX_KEYTYPE_ILLUMINATION_UP (键盘背光+)"
    case 0:  return "NX_KEYTYPE_SOUND_UP"
    case 1:  return "NX_KEYTYPE_SOUND_DOWN"
    case 7:  return "NX_KEYTYPE_PLAY"
    case 16: return "NX_KEYTYPE_MUTE"
    default: return "keyType=\(code)"
    }
}

func modifierNames(_ flags: CGEventFlags) -> String {
    var s: [String] = []
    if flags.contains(.maskCommand) { s.append("Cmd") }
    if flags.contains(.maskAlternate) { s.append("Opt") }
    if flags.contains(.maskControl) { s.append("Ctrl") }
    if flags.contains(.maskShift) { s.append("Shift") }
    if flags.contains(.maskSecondaryFn) { s.append("Fn") }
    return s.isEmpty ? "-" : s.joined(separator: "+")
}

// NX_SYSDEFINED = 14（Swift 的 CGEventType 没给它起名）
let mask = (CGEventMask(1) << 14) | (CGEventMask(1) << CGEventType.keyDown.rawValue)

guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                  place: .headInsertEventTap,
                                  options: .listenOnly,
                                  eventsOfInterest: mask,
                                  callback: { _, type, event, _ in
    if type.rawValue == 14 {
        if let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 {
            let data1 = ns.data1
            let keyType = (data1 & 0xFFFF0000) >> 16
            let keyFlags = (data1 & 0x0000FF00) >> 8
            let down = (keyFlags == 0x0A)
            print(String(format: "[系统键] %@  状态=%@  (data1=0x%08X)",
                         keyName(keyType), down ? "按下" : "抬起", data1))
            fflush(stdout)
        }
    } else if type == .keyDown {
        let code = event.getIntegerValueField(.keyboardEventKeycode)
        print("[普通键] keyCode=\(code)  修饰键=\(modifierNames(event.flags))  repeated=\(event.getIntegerValueField(.keyboardEventAutorepeat))")
        print("         ↑ 这行就是要绑定用的信息")
        fflush(stdout)
    }
    return Unmanaged.passUnretained(event)
}, userInfo: nil) else {
    print("❌ 无法创建事件监听（CGEventTap 返回 nil）。")
    print("   解决：系统设置 → 隐私与安全性 → 输入监控 / 辅助功能，把「终端」(Terminal) 打开，退出终端重开再跑。")
    exit(2)
}

let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
CGEvent.tapEnable(tap: tap, enable: true)
print("🎧 监听中（\(Int(seconds)) 秒）：现在按一下你要用来调亮度的那个键，多按几次也行。")
print("   按完等它自动退出，或 Ctrl-C 结束。")
fflush(stdout)
DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
    CGEvent.tapEnable(tap: tap, enable: false)
    print("== 监听结束 ==")
    exit(0)
}
CFRunLoopRun()
