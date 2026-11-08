import Foundation
import CoreBluetooth

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/ble-probe.log"
let fm = FileManager.default
fm.createFile(atPath: outPath, contents: nil)
let fh = FileHandle(forWritingAtPath: outPath)!

func log(_ s: String) {
    print(s)
    fflush(stdout)
    if let d = (s + "\n").data(using: .utf8) { fh.write(d) }
}

let HR_SVC = CBUUID(string: "180D")
let HR_MEAS = CBUUID(string: "2A37")

struct Dev {
    var id: UUID
    var name: String
    var rssi: Int
    var advServices: [String]
    var mfg: String
}

var devices: [UUID: Dev] = [:]
var cm: CBCentralManager!
var scanning = false
var finished = false
var hrSamples: [String: [Int]] = [:]
var probed: [String] = []

func authText() -> String {
    switch CBManager.authorization {
    case .allowedAlways: return "allowedAlways"
    case .denied: return "denied"
    case .restricted: return "restricted"
    case .notDetermined: return "notDetermined"
    @unknown default: return "unknown"
    }
}

func finish() {
    if finished { return }
    finished = true
    log("\n===== 汇总 =====")
    let suspects = devices.values.filter { d in
        let n = d.name.lowercased()
        return n.contains("huawei") || n.contains("honor") || n.contains("watch") || n.contains("band")
            || n.contains("fit") || n.contains("hr") || n.contains("polar") || n.contains("garmin")
            || d.advServices.contains("180D")
    }
    log("共发现 \(devices.count) 个蓝牙设备，可疑目标 \(suspects.count) 个")
    for d in devices.values.sorted(by: { $0.rssi > $1.rssi }) {
        let mark = suspects.contains(where: { $0.id == d.id }) ? "  <== 可能" : ""
        log(String(format: "  %-28s rssi=%4d  adv=[%@]%@", (d.name as NSString).utf8String!, d.rssi,
                   d.advServices.joined(separator: ","), mark))
    }
    log("")
    for (name, samples) in hrSamples {
        let avg = samples.reduce(0, +) / max(1, samples.count)
        log("[❤️] \(name): 平均 \(avg) bpm（样本 \(samples.count)）")
    }
    if hrSamples.isEmpty { log("[❤️] 没有读到任何心率数据") }
    log("\n===== 每个可疑设备的探测结果 =====")
    for p in probed { log(p) }
    log("\n===== 蓝牙授权状态: \(authText()) =====")
    exit(0)
}

final class C: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var pending: [CBPeripheral] = []
    var current: CBPeripheral?
    var currentName = ""

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        log("蓝牙状态: \(central.state.rawValue)（2=poweredOn 5=unauthorized） 授权=\(authText())")
        if central.state == .poweredOn {
            scanning = true
            central.scanForPeripherals(withServices: nil,
                                       options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
            log("开始扫描 12 秒…")
        } else {
            log("蓝牙不可用，等待/退出")
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { finish() }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = p.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        var svcs: [String] = []
        if let s = advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
            svcs = s.map { $0.uuidString }
        }
        var mfg = ""
        if let m = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data, m.count >= 2 {
            mfg = String(format: "%02X%02X", m[0], m[1])
        }
        if devices[p.identifier] == nil {
            devices[p.identifier] = Dev(id: p.identifier, name: name, rssi: RSSI.intValue, advServices: svcs, mfg: mfg)
            log(String(format: "发现: %-24s rssi=%4d adv=[%@] mfg=%@", (name as NSString).utf8String!,
                       RSSI.intValue, svcs.joined(separator: ","), mfg))
        } else {
            devices[p.identifier]?.rssi = RSSI.intValue
            if devices[p.identifier]?.name.isEmpty == true && !name.isEmpty { devices[p.identifier]?.name = name }
        }
    }

    func startProbing() {
        guard scanning else { return }
        scanning = false
        cm.stopScan()
        let suspects = devices.values.filter { d in
            let n = d.name.lowercased()
            return n.contains("huawei") || n.contains("honor") || n.contains("watch") || n.contains("band")
                || n.contains("fit") || n.contains("polar") || n.contains("garmin")
                || d.advServices.contains("180D")
        }
        log("\n扫描结束，共 \(devices.count) 个设备，开始连接 \(min(suspects.count, 6)) 个可疑目标…")
        var list: [CBPeripheral] = []
        let found = cm.retrievePeripherals(withIdentifiers: suspects.compactMap { $0.id })
        list = found
        if list.isEmpty { log("retrievePeripherals 返回空（可能设备已不可见）"); DispatchQueue.main.asyncAfter(deadline: .now() + 1) { finish() }; return }
        pending = Array(list.prefix(6))
        connectNext()
    }

    func connectNext() {
        guard let p = pending.first else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { finish() }
            return
        }
        pending.removeFirst()
        current = p
        currentName = p.name ?? "?"
        p.delegate = self
        log("连接 \(currentName) …")
        cm.connect(p, options: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
            if self?.current === p { log("  \(self?.currentName ?? "") 连接超时"); cm.cancelPeripheralConnection(p); self?.connectNext() }
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect p: CBPeripheral) {
        log("已连接 \(p.name ?? "?")，发现服务…")
        p.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        log("连接失败 \(p.name ?? "?"): \(error?.localizedDescription ?? "?")")
        connectNext()
    }

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        let svcs = p.services?.map { $0.uuid.uuidString } ?? []
        let names = svcs.prefix(8).joined(separator: ",")
        let hasHR = (p.services ?? []).contains { $0.uuid == HR_SVC }
        probed.append("\(p.name ?? "?"): services=[\(names)] 有心率服务=\(hasHR ? "是" : "否")")
        log("  \(p.name ?? "?") 服务: [\(names)] 含180D=\(hasHR)")
        if hasHR {
            if let s = (p.services ?? []).first(where: { $0.uuid == HR_SVC }) {
                p.discoverCharacteristics([HR_MEAS], for: s)
                return
            }
        }
        cm.cancelPeripheralConnection(p)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.connectNext() }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let ch = service.characteristics?.first(where: { $0.uuid == HR_MEAS }) else {
            log("  没找到心率测量特征")
            cm.cancelPeripheralConnection(p)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.connectNext() }
            return
        }
        log("  订阅心率测量特征 2A37 …")
        p.setNotifyValue(true, for: ch)
        hrSamples[p.name ?? "?", default: []] = []
        // 同时读一次
        if ch.properties.contains(.read) { p.readValue(for: ch) }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard ch.uuid == HR_MEAS, let d = ch.value, d.count >= 2 else { return }
        let flags = d[0]
        let v: Int
        if flags & 0x01 != 0 {
            v = d.count >= 3 ? Int(d[1]) | (Int(d[2]) << 8) : Int(d[1])
        } else {
            v = Int(d[1])
        }
        if v > 25 && v < 240 {
            let n = p.name ?? "?"
            hrSamples[n, default: []].append(v)
            log("[❤️] \(n): \(v) bpm")
            if (hrSamples[n]?.count ?? 0) >= 3 {
                p.setNotifyValue(false, for: ch)
                cm.cancelPeripheralConnection(p)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.connectNext() }
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        if current === p { current = nil }
    }
}

let delegate = C()
cm = CBCentralManager(delegate: delegate, queue: nil)

DispatchQueue.main.asyncAfter(deadline: .now() + 12) { delegate.startProbing() }
DispatchQueue.main.asyncAfter(deadline: .now() + 100) { finish() }

RunLoop.main.run()
