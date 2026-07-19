import Foundation

enum HeartRateInputSource: String, CaseIterable, Identifiable {
    case bluetooth
    case appleWatch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bluetooth:
            return "Bluetooth"
        case .appleWatch:
            return "Apple Watch"
        }
    }

    var shortDescription: String {
        switch self {
        case .bluetooth:
            return "Any BLE chest strap or heart-rate monitor"
        case .appleWatch:
            return "Uses heart rate from Apple Health / Watch"
        }
    }
}

struct DiscoverableHeartRateDevice: Identifiable, Hashable {
    let id: UUID
    let name: String
    let rssi: Int
    let lastSeen: Date
    let isLikelyHeartRateMonitor: Bool
    let advertisesHeartRateService: Bool

    var displayName: String {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Unknown BLE Device \(id.uuidString.prefix(4))"
        }
        return name
    }

    var signalLabel: String {
        "Signal \(rssi) dBm"
    }
}

struct ConnectedHeartRateReading: Identifiable, Hashable {
    let id: UUID
    let name: String
    let bpm: Int

    var displayName: String {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return "Monitor \(id.uuidString.prefix(4))"
        }
        return name
    }
}
