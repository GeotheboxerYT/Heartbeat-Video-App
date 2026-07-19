import CoreBluetooth
import Foundation

@MainActor
final class HeartRateMonitor: NSObject, ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var currentBPM: Int = 0
    @Published private(set) var samples: [HeartRateSample] = []
    @Published private(set) var discoveredDevices: [DiscoverableHeartRateDevice] = []
    @Published private(set) var connectedReadings: [ConnectedHeartRateReading] = []
    @Published private(set) var statusMessage: String = "Bluetooth is starting..."

    private var centralManager: CBCentralManager!
    private var knownPeripherals: [UUID: CBPeripheral] = [:]
    private var activePeripherals: [UUID: CBPeripheral] = [:]
    private var selectedPeripheralIDs: Set<UUID> = []
    private var connectingPeripheralIDs: Set<UUID> = []
    private var unsupportedPeripheralIDs: Set<UUID> = []
    private var latestBPMByPeripheral: [UUID: Int] = [:]
    private weak var sessionClock: SessionClock?

    private let heartRateServiceUUID = CBUUID(string: "180D")
    private let heartRateMeasurementUUID = CBUUID(string: "2A37")
    private let likelyHeartRateNameTokens = [
        "heart rate",
        "hrm",
        "strap",
        "h10",
        "h9",
        "h7",
        "tickr",
        "verity",
        "oh1",
        "myzone",
        "coospo",
        "wahoo",
        "garmin",
        "scosche",
        "polar"
    ]
    private let blockedNonHeartRateNameTokens = [
        "govee",
        "airpods",
        "beats",
        "bose",
        "jbl",
        "roku",
        "tv",
        "printer",
        "keyboard",
        "mouse"
    ]
    private let polarManufacturerCompanyID: UInt16 = 0x006B

    private var shouldScan = false

    override init() {
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    func startStreaming(sessionClock: SessionClock) {
        self.sessionClock = sessionClock
        samples.removeAll()
        currentBPM = 0
        startSearching()
        connectIfPossible()
    }

    func startSearching(resetDiscovered: Bool = false) {
        shouldScan = true
        if resetDiscovered {
            discoveredDevices.removeAll()
            knownPeripherals = activePeripherals
            unsupportedPeripheralIDs.removeAll()
        }

        statusMessage = selectedPeripheralIDs.isEmpty
            ? "Searching for heart-rate monitors..."
            : "Searching for selected monitor(s)..."

        if centralManager.state == .poweredOn {
            centralManager.scanForPeripherals(
                withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
            )
        }
    }

    func reconnectSelectedDevice() {
        guard shouldScan else { return }
        disconnectAllKnownPeripherals()
        isConnected = false
        currentBPM = 0
        statusMessage = "Reconnecting heart-rate monitor(s)..."
        connectIfPossible()
    }

    func selectPreferredPeripheral(id: UUID?) {
        if let id {
            setSelectedPeripheralIDs([id])
        } else {
            setSelectedPeripheralIDs([])
        }
    }

    func setSelectedPeripheralIDs(_ ids: Set<UUID>) {
        selectedPeripheralIDs = ids
        if shouldScan {
            reconnectSelectedDevice()
        }
    }

    func connectedDeviceName() -> String? {
        connectedReadings.first?.displayName
    }

    func stopStreaming() {
        shouldScan = false
        centralManager.stopScan()
        disconnectAllKnownPeripherals()
        activePeripherals.removeAll()
        connectingPeripheralIDs.removeAll()
        latestBPMByPeripheral.removeAll()
        connectedReadings.removeAll()
        isConnected = false
        currentBPM = 0
        statusMessage = "Disconnected"
        sessionClock = nil
    }

    private func disconnectAllKnownPeripherals() {
        let active = Array(activePeripherals.values)
        for peripheral in active {
            centralManager.cancelPeripheralConnection(peripheral)
        }

        let connecting = connectingPeripheralIDs.compactMap { knownPeripherals[$0] }
        for peripheral in connecting {
            centralManager.cancelPeripheralConnection(peripheral)
        }
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

    private func displayName(for peripheral: CBPeripheral, advertisedName: String?) -> String {
        let rawName = advertisedName ?? peripheral.name ?? ""
        if rawName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Unknown BLE Device \(peripheral.identifier.uuidString.prefix(4))"
        }
        return rawName
    }

    private func updateDiscoveredDevice(
        peripheral: CBPeripheral,
        advertisedName: String?,
        rssi: NSNumber,
        isLikelyHeartRateMonitor: Bool,
        advertisesHeartRateService: Bool
    ) {
        let device = DiscoverableHeartRateDevice(
            id: peripheral.identifier,
            name: displayName(for: peripheral, advertisedName: advertisedName),
            rssi: rssi.intValue,
            lastSeen: Date(),
            isLikelyHeartRateMonitor: isLikelyHeartRateMonitor,
            advertisesHeartRateService: advertisesHeartRateService
        )

        if let index = discoveredDevices.firstIndex(where: { $0.id == device.id }) {
            discoveredDevices[index] = device
        } else {
            discoveredDevices.append(device)
        }

        discoveredDevices.sort { lhs, rhs in
            if lhs.advertisesHeartRateService != rhs.advertisesHeartRateService {
                return lhs.advertisesHeartRateService && !rhs.advertisesHeartRateService
            }
            if lhs.isLikelyHeartRateMonitor != rhs.isLikelyHeartRateMonitor {
                return lhs.isLikelyHeartRateMonitor && !rhs.isLikelyHeartRateMonitor
            }
            if lhs.rssi == rhs.rssi {
                return lhs.displayName < rhs.displayName
            }
            return lhs.rssi > rhs.rssi
        }
    }

    private func candidatePeripheralIDs() -> [UUID] {
        if selectedPeripheralIDs.isEmpty {
            guard let first = discoveredDevices.first(where: {
                $0.isLikelyHeartRateMonitor && !unsupportedPeripheralIDs.contains($0.id)
            }) else {
                return []
            }
            return [first.id]
        }

        return selectedPeripheralIDs
            .sorted { lhs, rhs in
                let lhsName = discoveredDevices.first(where: { $0.id == lhs })?.displayName ?? lhs.uuidString
                let rhsName = discoveredDevices.first(where: { $0.id == rhs })?.displayName ?? rhs.uuidString
                return lhsName < rhsName
            }
    }

    private func shouldContinueScanning() -> Bool {
        guard shouldScan else { return false }

        if selectedPeripheralIDs.isEmpty {
            // Keep scanning so additional monitors can appear for manual multi-select.
            return true
        }

        let connectedOrConnecting = Set(activePeripherals.keys).union(connectingPeripheralIDs)
        let pending = selectedPeripheralIDs
            .subtracting(connectedOrConnecting)
        return !pending.isEmpty
    }

    private func updateScanState() {
        guard centralManager.state == .poweredOn else { return }

        if shouldContinueScanning() {
            centralManager.scanForPeripherals(
                withServices: nil,
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
            )
        } else {
            centralManager.stopScan()
        }
    }

    private func refreshConnectedReadings(updateStatus: Bool = true) {
        connectedReadings = activePeripherals.values
            .map { peripheral in
                ConnectedHeartRateReading(
                    id: peripheral.identifier,
                    name: displayName(for: peripheral, advertisedName: nil),
                    bpm: latestBPMByPeripheral[peripheral.identifier] ?? 0
                )
            }
            .sorted { lhs, rhs in
                lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }

        isConnected = !connectedReadings.isEmpty

        let valid = connectedReadings.map(\.bpm).filter { $0 > 0 }
        if valid.isEmpty {
            currentBPM = 0
        } else {
            currentBPM = Int((Double(valid.reduce(0, +)) / Double(valid.count)).rounded())
        }

        guard updateStatus else { return }

        if connectedReadings.isEmpty {
            statusMessage = shouldScan
                ? (selectedPeripheralIDs.isEmpty ? "Searching for heart-rate monitors..." : "Searching for selected monitor(s)...")
                : "Disconnected"
            return
        }

        if connectedReadings.count == 1 {
            statusMessage = "Connected: \(connectedReadings[0].displayName)"
        } else {
            statusMessage = "Connected: \(connectedReadings.count) monitors"
        }

        if !selectedPeripheralIDs.isEmpty {
            statusMessage = "Connected: \(connectedReadings.count)/\(selectedPeripheralIDs.count) monitors"
        }
    }

    private func connectIfPossible() {
        guard shouldScan else { return }
        guard centralManager.state == .poweredOn else { return }

        let candidates = candidatePeripheralIDs()
        guard !candidates.isEmpty else {
            updateScanState()
            return
        }

        for id in candidates {
            if activePeripherals[id] != nil || connectingPeripheralIDs.contains(id) {
                continue
            }
            guard let peripheral = knownPeripherals[id] else { continue }
            guard peripheral.state != .connected, peripheral.state != .connecting else {
                continue
            }

            peripheral.delegate = self
            connectingPeripheralIDs.insert(id)
            statusMessage = "Connecting to \(displayName(for: peripheral, advertisedName: nil))..."
            centralManager.connect(peripheral, options: nil)
        }

        updateScanState()
    }

    private func advertisementContainsHeartRateService(_ advertisementData: [String: Any]) -> Bool {
        let keys = [
            CBAdvertisementDataServiceUUIDsKey,
            CBAdvertisementDataSolicitedServiceUUIDsKey,
            CBAdvertisementDataOverflowServiceUUIDsKey
        ]

        for key in keys {
            if let uuids = advertisementData[key] as? [CBUUID],
               uuids.contains(heartRateServiceUUID) {
                return true
            }
        }
        return false
    }

    private func advertisementIsPolarManufacturer(_ advertisementData: [String: Any]) -> Bool {
        guard let manufacturerData = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data,
              manufacturerData.count >= 2 else {
            return false
        }

        let companyID = UInt16(manufacturerData[0]) | (UInt16(manufacturerData[1]) << 8)
        return companyID == polarManufacturerCompanyID
    }

    private func isLikelyHeartRateName(_ rawName: String?) -> Bool {
        guard let rawName,
              !rawName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        let normalized = rawName.lowercased()
        return likelyHeartRateNameTokens.contains(where: { normalized.contains($0) })
    }

    private func isBlockedNonHeartRateName(_ rawName: String?) -> Bool {
        guard let rawName,
              !rawName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        let normalized = rawName.lowercased()
        return blockedNonHeartRateNameTokens.contains(where: { normalized.contains($0) })
    }

    private func detectionFlags(
        peripheral: CBPeripheral,
        advertisedName: String?,
        advertisementData: [String: Any]
    ) -> (isLikely: Bool, advertisesService: Bool) {
        let advertisesService = advertisementContainsHeartRateService(advertisementData)
        let isPolarManufacturer = advertisementIsPolarManufacturer(advertisementData)
        let rawName = advertisedName ?? peripheral.name
        if isBlockedNonHeartRateName(rawName) {
            return (isLikely: false, advertisesService: false)
        }
        let likelyByName = isLikelyHeartRateName(rawName)
        return (
            isLikely: advertisesService || likelyByName || isPolarManufacturer,
            advertisesService: advertisesService
        )
    }

    private func appendSampleIfNeeded() {
        guard let sessionClock, currentBPM > 0 else { return }
        samples.append(HeartRateSample(t: sessionClock.elapsedTime(), bpm: currentBPM))
    }
}

extension HeartRateMonitor: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in
            switch central.state {
            case .poweredOn:
                statusMessage = "Bluetooth is on"
                if shouldScan {
                    updateScanState()
                    connectIfPossible()
                }
            case .poweredOff:
                statusMessage = "Bluetooth is off"
                activePeripherals.removeAll()
                connectingPeripheralIDs.removeAll()
                latestBPMByPeripheral.removeAll()
                refreshConnectedReadings(updateStatus: false)
                currentBPM = 0
            case .unauthorized:
                statusMessage = "Bluetooth permission denied"
            case .unsupported:
                statusMessage = "Bluetooth heart rate not supported"
            case .resetting:
                statusMessage = "Bluetooth resetting..."
            case .unknown:
                statusMessage = "Bluetooth state unknown"
            @unknown default:
                statusMessage = "Bluetooth unavailable"
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
            let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
            knownPeripherals[peripheral.identifier] = peripheral

            let flags = detectionFlags(
                peripheral: peripheral,
                advertisedName: advertisedName,
                advertisementData: advertisementData
            )
            guard flags.isLikely else { return }

            updateDiscoveredDevice(
                peripheral: peripheral,
                advertisedName: advertisedName,
                rssi: RSSI,
                isLikelyHeartRateMonitor: flags.isLikely,
                advertisesHeartRateService: flags.advertisesService
            )

            if flags.advertisesService {
                unsupportedPeripheralIDs.remove(peripheral.identifier)
            }

            if shouldScan {
                connectIfPossible()
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            connectingPeripheralIDs.remove(peripheral.identifier)
            activePeripherals[peripheral.identifier] = peripheral
            peripheral.delegate = self
            refreshConnectedReadings()
            peripheral.discoverServices([heartRateServiceUUID])
            updateScanState()
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            connectingPeripheralIDs.remove(peripheral.identifier)
            activePeripherals.removeValue(forKey: peripheral.identifier)
            latestBPMByPeripheral.removeValue(forKey: peripheral.identifier)
            refreshConnectedReadings(updateStatus: false)

            let name = displayName(for: peripheral, advertisedName: nil)
            statusMessage = "Could not connect to \(name). Searching..."

            if shouldScan {
                updateScanState()
                connectIfPossible()
            }
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { @MainActor in
            connectingPeripheralIDs.remove(peripheral.identifier)
            activePeripherals.removeValue(forKey: peripheral.identifier)
            latestBPMByPeripheral.removeValue(forKey: peripheral.identifier)
            refreshConnectedReadings(updateStatus: false)

            if shouldScan {
                statusMessage = "Disconnected. Searching..."
                updateScanState()
                connectIfPossible()
            } else {
                statusMessage = "Disconnected"
            }
        }
    }
}

extension HeartRateMonitor: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        Task { @MainActor in
            if error != nil {
                statusMessage = "Service check failed for \(displayName(for: peripheral, advertisedName: nil)). Retrying..."
                centralManager.cancelPeripheralConnection(peripheral)
                if shouldScan {
                    updateScanState()
                    connectIfPossible()
                }
                return
            }

            guard let services = peripheral.services else {
                peripheral.discoverServices([heartRateServiceUUID])
                return
            }

            if services.isEmpty {
                peripheral.discoverServices([heartRateServiceUUID])
                return
            }

            if let heartRateService = services.first(where: { $0.uuid == heartRateServiceUUID }) {
                unsupportedPeripheralIDs.remove(peripheral.identifier)
                peripheral.discoverCharacteristics([heartRateMeasurementUUID], for: heartRateService)
            } else {
                unsupportedPeripheralIDs.insert(peripheral.identifier)
                statusMessage = "\(displayName(for: peripheral, advertisedName: nil)) has no HR service"
                connectingPeripheralIDs.remove(peripheral.identifier)
                activePeripherals.removeValue(forKey: peripheral.identifier)
                latestBPMByPeripheral.removeValue(forKey: peripheral.identifier)
                refreshConnectedReadings(updateStatus: false)
                centralManager.cancelPeripheralConnection(peripheral)
                if shouldScan {
                    updateScanState()
                    connectIfPossible()
                }
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
                  let bpm = parseHeartRate(from: data) else {
                return
            }

            latestBPMByPeripheral[peripheral.identifier] = bpm
            refreshConnectedReadings()
            appendSampleIfNeeded()
        }
    }
}
