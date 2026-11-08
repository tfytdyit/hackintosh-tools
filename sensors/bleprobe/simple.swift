import Foundation
import CoreBluetooth

let out = "/tmp/ble-simple.txt"
FileManager.default.createFile(atPath: out, contents: nil)
let fh = FileHandle(forWritingAtPath: out)!
func log(_ s: String) { print(s); fflush(stdout); if let d = (s+"\n").data(using:.utf8) { fh.write(d) } }

let HR = CBUUID(string: "180D")
let MEAS = CBUUID(string: "2A37")
var tried = Set<UUID>()
var cm: CBCentralManager!

final class D: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        log("state=\(c.state.rawValue) auth=\(CBManager.authorization.rawValue) managerState=\(c.state)")
        if c.state == .poweredOn {
            c.scanForPeripherals(withServices: [HR], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            log("扫描中（只扫 180D）…")
        }
    }
    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi R: NSNumber) {
        let name = p.name ?? "-"
        if !tried.contains(p.identifier) {
            tried.insert(p.identifier)
            let conn = (advertisementData[CBAdvertisementDataIsConnectable] as? Bool) ?? false
            log("发现 \(name) rssi=\(R) 可连接=\(conn) adv=(\(advertisementData.keys.sorted().joined(separator: ","))) → 连接")
            log("  状态 p.state=\(p.state.rawValue)")
            p.delegate = self
            c.connect(p, options: nil)
            var n = 0
            let t = Timer(timeInterval: 2.0, repeats: true) { tm in
                n += 1
                log("  [state] \(name) = \(p.state.rawValue)  (\(n*2)s)")
                if n >= 12 { tm.invalidate() }
            }
            RunLoop.main.add(t, forMode: .common)
        }
    }
    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        log("✅ 已连接 \(p.name ?? "-")，发现服务")
        p.discoverServices(nil)
    }
    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        log("❌ 连接失败 \(p.name ?? "-"): \(error?.localizedDescription ?? "nil")")
    }
    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        log("断开 \(p.name ?? "-"): \(error?.localizedDescription ?? "nil")")
    }
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        log("服务: \((p.services ?? []).map { $0.uuid.uuidString }.joined(separator: ","))")
        if let s = (p.services ?? []).first(where: { $0.uuid == HR }) {
            p.discoverCharacteristics([MEAS], for: s)
        }
    }
    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor s: CBService, error: Error?) {
        for ch in s.characteristics ?? [] {
            log("特征 \(ch.uuid.uuidString) props=\(ch.properties.rawValue)")
            if ch.uuid == MEAS { p.setNotifyValue(true, for: ch) }
        }
    }
    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard ch.uuid == MEAS, let d = ch.value, d.count >= 2 else { return }
        let v = (d[0] & 1) != 0 ? Int(d[1]) | (Int(d[2]) << 8) : Int(d[1])
        log("[❤️] \(p.name ?? "-") \(v) bpm")
    }
}

let d = D()
cm = CBCentralManager(delegate: d, queue: nil)
DispatchQueue.main.asyncAfter(deadline: .now() + 55) { log("== 结束 =="); exit(0) }
RunLoop.main.run()
