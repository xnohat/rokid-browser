import Foundation
import CoreBluetooth

/// BLE Central for iOS — replaces the Android RFCOMM BrowserBtServer.
/// The iPhone acts as GATT Central; the glasses (Android) act as Peripheral.
///
/// Protocol (kept identical to the original RFCOMM app):
///   * Messages are newline-delimited JSON strings.
///   * Phone -> Glasses commands go out on the TX characteristic (Write).
///   * Glasses -> Phone state updates arrive on the RX characteristic (Notify).
///   * A ping ("{\"type\":\"ping\"}\n") is used as keepalive and is filtered out.
///
/// Long payloads (typing text, wifi passwords) are chunked to fit the BLE MTU
/// and reassembled on newline framing at both ends.
final class BleCentral: NSObject {

    // Service = original app UUID. Characteristics derived from it.
    static let serviceUUID = CBUUID(string: "a1b2c3d4-e5f6-7890-abcd-ef1234567890")
    // TX: phone writes commands to glasses.
    static let txCharUUID  = CBUUID(string: "a1b2c3d4-e5f6-7890-abcd-ef1234560001")
    // RX: glasses notify state to phone.
    static let rxCharUUID  = CBUUID(string: "a1b2c3d4-e5f6-7890-abcd-ef1234560002")

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var txChar: CBCharacteristic?
    private var rxChar: CBCharacteristic?

    /// Emits status strings: "listening" | "scanning" | "connected:<name>" |
    /// "disconnected" | "resetting" | "permission_denied" | "bluetooth_off".
    var onStatus: ((String) -> Void)?
    /// Emits full JSON lines received from the glasses (ping filtered out).
    var onMessage: ((String) -> Void)?

    private var rxBuffer = Data()
    private var wantScan = false
    private var maxWriteLen = 180 // updated after connect from maximumWriteValueLength

    // Outgoing chunk queue with flow control (send next only after didWriteValueFor).
    private var txQueue: [Data] = []
    private var txInFlight = false

    // Keepalive
    private var pingTimer: Timer?
    private let pingLine = "{\"type\":\"ping\"}\n"

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    // MARK: - Public API (mirrors the old MethodChannel surface)

    func start() {
        wantScan = true
        if central.state == .poweredOn { beginScan() }
    }

    func send(_ json: String) {
        guard txChar != nil else { return }
        var line = json
        if !line.hasSuffix("\n") { line += "\n" }
        guard let data = line.data(using: .utf8) else { return }
        // Chunk on UTF-8 BYTES (not characters) to the negotiated payload size.
        let limit = max(20, maxWriteLen)
        var offset = 0
        let n = data.count
        while offset < n {
            let end = min(offset + limit, n)
            txQueue.append(data.subdata(in: offset..<end))
            offset = end
        }
        pumpTx()
    }

    /// Flow-controlled write: one chunk outstanding at a time.
    /// Uses .withResponse so the next chunk is only sent from didWriteValueFor,
    /// which matches the Android TX characteristic's WRITE property and prevents
    /// silent loss/reordering on multi-chunk payloads (typing, wifi passwords).
    private func pumpTx() {
        guard let p = peripheral, let tx = txChar else { return }
        if txInFlight { return }
        guard !txQueue.isEmpty else { return }
        let useResponse = tx.properties.contains(.write)
        let chunk = txQueue.removeFirst()
        if useResponse {
            txInFlight = true
            p.writeValue(chunk, for: tx, type: .withResponse)
        } else {
            // Peripheral only supports write-without-response.
            p.writeValue(chunk, for: tx, type: .withoutResponse)
            pumpTx()
        }
    }

    func reset() {
        onStatus?("resetting")
        stopPing()
        if let p = peripheral {
            central.cancelPeripheralConnection(p)
        }
        peripheral = nil
        txChar = nil
        rxChar = nil
        rxBuffer.removeAll()
        txQueue.removeAll(); txInFlight = false
        if central.state == .poweredOn { beginScan() }
    }

    func stop() {
        wantScan = false
        stopPing()
        central.stopScan()
        if let p = peripheral { central.cancelPeripheralConnection(p) }
        peripheral = nil
    }

    // MARK: - Internals

    private func beginScan() {
        guard wantScan else { return }
        onStatus?("scanning")
        central.scanForPeripherals(withServices: [BleCentral.serviceUUID], options: nil)
    }

    private func startPing() {
        stopPing()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.send(self.pingLine)
        }
    }

    private func stopPing() {
        pingTimer?.invalidate()
        pingTimer = nil
    }

    private func handleIncoming(_ data: Data) {
        rxBuffer.append(data)
        // Split on newline (0x0A).
        while let idx = rxBuffer.firstIndex(of: 0x0A) {
            let lineData = rxBuffer.subdata(in: rxBuffer.startIndex..<idx)
            rxBuffer.removeSubrange(rxBuffer.startIndex...idx)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if trimmed.contains("\"type\":\"ping\"") { continue }
            onMessage?(trimmed)
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension BleCentral: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            onStatus?("listening")
            if wantScan { beginScan() }
        case .unauthorized:
            onStatus?("permission_denied")
        case .poweredOff:
            onStatus?("bluetooth_off")
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager,
                        didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any],
                        rssi RSSI: NSNumber) {
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager,
                        didConnect peripheral: CBPeripheral) {
        maxWriteLen = peripheral.maximumWriteValueLength(for: .withoutResponse)
        peripheral.discoverServices([BleCentral.serviceUUID])
    }

    func centralManager(_ central: CBCentralManager,
                        didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        onStatus?("disconnected")
        if wantScan { beginScan() }
    }

    func centralManager(_ central: CBCentralManager,
                        didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        stopPing()
        txChar = nil
        rxChar = nil
        rxBuffer.removeAll()
        txQueue.removeAll(); txInFlight = false
        onStatus?("disconnected")
        // Auto-reconnect.
        if wantScan { beginScan() }
    }
}

// MARK: - CBPeripheralDelegate

extension BleCentral: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for svc in services where svc.uuid == BleCentral.serviceUUID {
            peripheral.discoverCharacteristics(
                [BleCentral.txCharUUID, BleCentral.rxCharUUID], for: svc)
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService,
                    error: Error?) {
        guard let chars = service.characteristics else { return }
        for c in chars {
            if c.uuid == BleCentral.txCharUUID { txChar = c }
            if c.uuid == BleCentral.rxCharUUID {
                rxChar = c
                peripheral.setNotifyValue(true, for: c)
            }
        }
        if txChar != nil && rxChar != nil {
            let name = peripheral.name ?? peripheral.identifier.uuidString
            onStatus?("connected:\(name)")
            startPing()
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard characteristic.uuid == BleCentral.rxCharUUID,
              let value = characteristic.value else { return }
        handleIncoming(value)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didWriteValueFor characteristic: CBCharacteristic,
                    error: Error?) {
        guard characteristic.uuid == BleCentral.txCharUUID else { return }
        txInFlight = false
        pumpTx() // send the next queued chunk
    }
}
