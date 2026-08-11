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
    private var scanRetryTimer: Timer?
    private var scanningUnfiltered = false
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

    /// Flow-controlled write. High-frequency commands (trackpad cursor_move) make
    /// per-chunk acknowledgement (.withResponse) far too slow — the queue backs up
    /// and the glasses cursor lags/stutters. We therefore prefer
    /// .withoutResponse and pace by CoreBluetooth's canSendWriteWithoutResponse
    /// back-pressure signal (peripheralIsReadyToSendWriteWithoutResponse), which is
    /// both fast and lossless at the link layer. Falls back to .withResponse only
    /// if the peripheral does not expose write-without-response.
    private func pumpTx() {
        guard let p = peripheral, let tx = txChar else { return }
        let canNoResp = tx.properties.contains(.writeWithoutResponse)
        if canNoResp {
            while !txQueue.isEmpty {
                if !p.canSendWriteWithoutResponse {
                    // Wait for peripheralIsReadyToSendWriteWithoutResponse.
                    return
                }
                let chunk = txQueue.removeFirst()
                p.writeValue(chunk, for: tx, type: .withoutResponse)
            }
            return
        }
        // Reliable path (typing/wifi on peripherals lacking no-response writes).
        if txInFlight { return }
        guard !txQueue.isEmpty else { return }
        txInFlight = true
        let chunk = txQueue.removeFirst()
        p.writeValue(chunk, for: tx, type: .withResponse)
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
        guard central.state == .poweredOn else { return }
        onStatus?("scanning")
        NSLog("[BleCentral] beginScan (filtered)")

        // 1) Grab a peripheral already connected at the iOS system level
        //    (e.g. after the glasses app restarts) — connect directly.
        let already = central.retrieveConnectedPeripherals(
            withServices: [BleCentral.serviceUUID])
        if let p = already.first {
            NSLog("[BleCentral] retrieveConnected -> \(p.name ?? "?")")
            self.peripheral = p
            p.delegate = self
            central.connect(p, options: nil)
        }

        // 2) Start ONE continuous scan (do NOT stop/restart — that creates blind
        //    windows). Begin service-filtered; Android legacy advertising sometimes
        //    reports the 128-bit UUID inconsistently between the primary packet and
        //    the scan response, so if we don't see it quickly we widen to an
        //    unfiltered scan and match the UUID from the advertisement data
        //    ourselves. AllowDuplicates so a re-advertising peripheral is re-seen.
        central.scanForPeripherals(
            withServices: [BleCentral.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        scanningUnfiltered = false

        // Widen to unfiltered after a short grace period if still not connected.
        scanRetryTimer?.invalidate()
        scanRetryTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            guard self.wantScan, self.txChar == nil, self.peripheral == nil else { return }
            NSLog("[BleCentral] widening to UNFILTERED scan")
            self.scanningUnfiltered = true
            self.central.scanForPeripherals(
                withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        }
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
        // When scanning unfiltered we must verify the advertisement actually
        // carries our service UUID (Android may put it only in the scan response).
        if scanningUnfiltered {
            let uuids = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID]) ?? []
            let overflow = (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID]) ?? []
            let localName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? ""
            let matches = uuids.contains(BleCentral.serviceUUID)
                || overflow.contains(BleCentral.serviceUUID)
                || localName.hasPrefix("RokidBrowser")
            if !matches { return }
        }
        guard self.peripheral == nil || self.peripheral?.identifier == peripheral.identifier else { return }
        NSLog("[BleCentral] didDiscover \(peripheral.name ?? "?") rssi=\(RSSI) unfiltered=\(scanningUnfiltered)")
        central.stopScan()
        scanRetryTimer?.invalidate(); scanRetryTimer = nil
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager,
                        didConnect peripheral: CBPeripheral) {
        NSLog("[BleCentral] didConnect -> discoverServices")
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
        NSLog("[BleCentral] didDiscoverServices count=\(services.count)")
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
        NSLog("[BleCentral] chars: tx=\(txChar != nil) rx=\(rxChar != nil)")
        if txChar != nil && rxChar != nil {
            let name = peripheral.name ?? peripheral.identifier.uuidString
            onStatus?("connected:\(name)")
            scanRetryTimer?.invalidate(); scanRetryTimer = nil
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
        pumpTx() // send the next queued chunk (reliable path)
    }

    /// BLE link is ready for more write-without-response traffic — drain the queue.
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        pumpTx()
    }
}
