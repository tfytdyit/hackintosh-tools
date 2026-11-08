import Foundation
import CoreBluetooth
let out = "/tmp/ble-any.txt"
FileManager.default.createFile(atPath: out, contents: nil)
let fh = FileHandle(forWritingAtPath: out)!
func log(_ s: String) { print(s); fflush(stdout); if let d = (s+"\n").data(using:.utf8) { fh.write(d) } }
var cm: CBCentralManager!
var tried = Set<UUID>()
final class D: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        log("state=\(c.state.rawValue) auth=\(CBManager.authorization.rawValue)")
        if c.state == .poweredOn { c.scanForPeripherals(withServices: nil, options: nil); log("扫描全部…") }
    }
    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral, advertisementData: [String: Any], rssi R: NSNumber) {
        let name = p.name ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
        guard !name.isEmpty, !tried.contains(p.identifier) else { return }
        tried.insert(p.identifier)
        let conn = (advertisementData[CBAdvertisementDataIsConnectable] as? Bool) ?? false
        log("发现 \(name) rssi=\(R) connectable=\(conn) → 尝试连接")
        p.delegate = self
        c.connect(p, options: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            if p.state != .connected { log("  ⏱ \(name) 8 秒未连上 (state=\(p.state.rawValue))") }
        }
    }
    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        log("✅ 连接成功 \(p.name ?? "?")")
        p.discoverServices(nil)
    }
    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        log("❌ 失败 \(p.name ?? "?"): \(error?.localizedDescription ?? "?")")
    }
    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        log("服务 \(p.name ?? "?"): \((p.services ?? []).map{$0.uuid.uuidString}.joined(separator: ","))")
        cm.cancelPeripheralConnection(p)
    }
}
let d = D()
cm = CBCentralManager(delegate: d, queue: nil)
DispatchQueue.main.asyncAfter(deadline: .now() + 45) { log("== 结束 =="); exit(0) }
RunLoop.main.run()
