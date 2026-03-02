import CoreBluetooth
import Foundation

@MainActor
final class HeartRateMonitor: NSObject, ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var currentBPM: Int = 0
    @Published private(set) var samples: [HeartRateSample] = []

    private var centralManager: CBCentralManager!
    private var heartRatePeripheral: CBPeripheral?
    private weak var sessionClock: SessionClock?

    private let heartRateServiceUUID = CBUUID(string: "180D")
    private let heartRateMeasurementUUID = CBUUID(string: "2A37")

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    func startStreaming(sessionClock: SessionClock) {
        self.sessionClock = sessionClock
        samples.removeAll()
        if centralManager.state == .poweredOn {
            centralManager.scanForPeripherals(withServices: [heartRateServiceUUID], options: nil)
        }
    }

    func stopStreaming() {
        centralManager.stopScan()
        if let heartRatePeripheral {
            centralManager.cancelPeripheralConnection(heartRatePeripheral)
        }
        heartRatePeripheral = nil
        isConnected = false
    }

    private func parseHeartRate(from data: Data) -> Int? {
        guard data.count >= 2 else { return nil }

        let flags = data[0]
        let isUInt16 = (flags & 0x01) != 0

        if isUInt16 {
            guard data.count >= 3 else { return nil }
            return Int(UInt16(data[1]) | (UInt16(data[2]) << 8))
        } else {
            return Int(data[1])
        }
    }
}

extension HeartRateMonitor: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            if central.state == .poweredOn {
                central.scanForPeripherals(withServices: [heartRateServiceUUID], options: nil)
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        Task { @MainActor in
            if heartRatePeripheral == nil {
                heartRatePeripheral = peripheral
                peripheral.delegate = self
                central.stopScan()
                central.connect(peripheral, options: nil)
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            isConnected = true
            peripheral.discoverServices([heartRateServiceUUID])
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            isConnected = false
            if peripheral == heartRatePeripheral {
                heartRatePeripheral = nil
                central.scanForPeripherals(withServices: [heartRateServiceUUID], options: nil)
            }
        }
    }
}

extension HeartRateMonitor: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            guard let services = peripheral.services else { return }
            for service in services where service.uuid == heartRateServiceUUID {
                peripheral.discoverCharacteristics([heartRateMeasurementUUID], for: service)
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        Task { @MainActor in
            guard let characteristics = service.characteristics else { return }
            for characteristic in characteristics where characteristic.uuid == heartRateMeasurementUUID {
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        Task { @MainActor in
            guard characteristic.uuid == heartRateMeasurementUUID,
                  let data = characteristic.value,
                  let bpm = parseHeartRate(from: data),
                  let sessionClock else {
                return
            }

            currentBPM = bpm
            samples.append(HeartRateSample(t: sessionClock.elapsedTime(), bpm: bpm))
        }
    }
}
