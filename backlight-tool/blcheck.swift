// blcheck —— 亮度链路自检：打印系统是否认为内屏可控、浮点 brightness 参数是否可用、bklt 当前值
import Foundation
import IOKit
import IOKit.graphics
import CoreGraphics
import Darwin

typealias CanChangeFn = @convention(c) (CGDirectDisplayID) -> Bool
typealias GetBrightnessFn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Double>) -> Int32
typealias SetBrightnessFn = @convention(c) (CGDirectDisplayID, Double) -> Int32

let display = CGMainDisplayID()
print("main display id: 0x\(String(display, radix: 16)) builtin=\(CGDisplayIsBuiltin(display)) main=\(CGDisplayIsMain(display))")

if let h = dlopen("/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_NOW) {
    let can = dlsym(h, "DisplayServicesCanChangeBrightness").map { unsafeBitCast($0, to: CanChangeFn.self) }
    let get = dlsym(h, "DisplayServicesGetBrightness").map { unsafeBitCast($0, to: GetBrightnessFn.self) }
    if let can = can { print("DisplayServicesCanChangeBrightness = \(can(display))") } else { print("DisplayServicesCanChangeBrightness = (符号缺失)") }
    var v = -1.0
    if let get = get { print("DisplayServicesGetBrightness rc=\(get(display, &v)) value=\(v)") }
} else {
    print("DisplayServices 加载失败")
}

let svc = IOServiceGetMatchingService(0, IOServiceMatching("AppleBacklightDisplay"))
if svc != 0 {
    defer { IOObjectRelease(svc) }
    var f: Float = -1
    let krf = IODisplayGetFloatParameter(svc, 0, kIODisplayBrightnessKey as CFString, &f)
    print("IODisplayGetFloatParameter(brightness) kr=0x\(String(UInt32(bitPattern: krf), radix: 16))")
    var value: Int32 = -1, minv: Int32 = -1, maxv: Int32 = -1
    let kri = IODisplayGetIntegerRangeParameter(svc, 0, "bklt" as CFString, &value, &minv, &maxv)
    print("IODisplayGetIntegerRangeParameter(bklt) kr=0x\(String(UInt32(bitPattern: kri), radix: 16)) value=\(value) min=\(minv) max=\(maxv)")
} else {
    print("没有 AppleBacklightDisplay 服务")
}
