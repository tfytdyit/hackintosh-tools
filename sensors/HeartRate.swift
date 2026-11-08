// HeartRate.swift — 通过标准 BLE 心率服务（GATT 0x180D / 测量特征 0x2A37）读取心率
// 已在华为手环 Band 11 Pro 上实测可用（Intel Bluetooth 2.5.3 修复后）
import Foundation
import CoreBluetooth
import Combine

final class HeartRateMonitor: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    @Published var bpm: Int = 0
    @Published var deviceName: String = ""
    @Published var status: String = "准备中"
    @Published var history: [Int] = []
    @Published var lastUpdate: Date? = nil
    @Published var connected: Bool = false
    @Published var battery: Int = -1          // 手环电量（Battery Level 0x2A19）
    @Published var sensorLocation: String = "" // 佩戴位置（0x2A38）

    private var central: CBCentralManager!
    private var target: CBPeripheral?
    private var measChar: CBCharacteristic?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }

    // MARK: CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ c: CBCentralManager) {
        switch c.state {
        case .poweredOn:
            status = "扫描中"
            startScan()
        case .unauthorized:
            status = "无蓝牙权限"
        case .poweredOff:
            status = "蓝牙已关闭"
        case .unsupported:
            status = "不支持蓝牙"
        default:
            status = "蓝牙不可用"
        }
    }

    private func startScan() {
        guard central.state == .poweredOn, target == nil else { return }
        status = connected ? status : "扫描中"
        central.scanForPeripherals(withServices: [CBUUID(string: "180D")],
                                   options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func centralManager(_ c: CBCentralManager, didDiscover p: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard target == nil else { return }
        target = p
        p.delegate = self
        status = "连接中"
        c.stopScan()
        c.connect(p, options: nil)
    }

    func centralManager(_ c: CBCentralManager, didConnect p: CBPeripheral) {
        connected = true
        deviceName = p.name ?? "心率设备"
        status = "已连接"
        p.discoverServices([CBUUID(string: "180D"), CBUUID(string: "180F")])
    }

    func centralManager(_ c: CBCentralManager, didFailToConnect p: CBPeripheral, error: Error?) {
        resetAndRetry("连接失败，重试中")
    }

    func centralManager(_ c: CBCentralManager, didDisconnectPeripheral p: CBPeripheral, error: Error?) {
        connected = false
        bpm = 0
        resetAndRetry("已断开，重试中")
    }

    private func resetAndRetry(_ msg: String) {
        target = nil
        measChar = nil
        status = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.startScan() }
    }

    // MARK: CBPeripheralDelegate

    func peripheral(_ p: CBPeripheral, didDiscoverServices error: Error?) {
        guard let ss = p.services else { return }
        if let hr = ss.first(where: { $0.uuid == CBUUID(string: "180D") }) {
            p.discoverCharacteristics([CBUUID(string: "2A37"), CBUUID(string: "2A38")], for: hr)
        }
        if let batt = ss.first(where: { $0.uuid == CBUUID(string: "180F") }) {
            p.discoverCharacteristics([CBUUID(string: "2A19")], for: batt)
        }
        if ss.first(where: { $0.uuid == CBUUID(string: "180D") }) == nil {
            status = "设备没有心率服务"
            central.cancelPeripheralConnection(p)
        }
    }

    func peripheral(_ p: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let cs = service.characteristics else { return }
        for ch in cs {
            switch ch.uuid {
            case CBUUID(string: "2A37"):
                measChar = ch
                p.setNotifyValue(true, for: ch)
                status = "已连接（订阅中）"
            case CBUUID(string: "2A19"):
                if ch.properties.contains(.read) { p.readValue(for: ch) }
                p.setNotifyValue(true, for: ch)
            case CBUUID(string: "2A38"):
                if ch.properties.contains(.read) { p.readValue(for: ch) }
            default:
                break
            }
        }
    }

    func peripheral(_ p: CBPeripheral, didUpdateValueFor ch: CBCharacteristic, error: Error?) {
        guard let d = ch.value else { return }
        if ch.uuid == CBUUID(string: "2A19"), d.count >= 1 {
            battery = Int(d[0])
            return
        }
        if ch.uuid == CBUUID(string: "2A38"), d.count >= 1 {
            sensorLocation = ["其他", "胸部", "手腕", "手指", "手掌", "耳垂", "脚"][min(Int(d[0]), 6)]
            return
        }
        guard d.count >= 2 else { return }
        let flags = d[0]
        let v: Int
        if flags & 0x01 != 0 {              // 16 位心率
            guard d.count >= 3 else { return }
            v = Int(d[1]) | (Int(d[2]) << 8)
        } else {                            // 8 位心率
            v = Int(d[1])
        }
        guard v > 20 && v < 250 else { return }
        bpm = v
        lastUpdate = Date()
        status = "已连接"
        history.append(v)
        if history.count > 60 { history.removeFirst(history.count - 60) }
    }
}
