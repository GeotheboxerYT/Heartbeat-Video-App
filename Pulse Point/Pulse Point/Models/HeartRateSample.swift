import Foundation

struct HeartRateSample: Codable, Hashable {
    let t: TimeInterval
    let bpm: Int
}

struct HeartRateDeviceSeries: Codable, Hashable, Identifiable {
    let deviceID: UUID
    let deviceName: String
    let samples: [HeartRateSample]

    var id: UUID { deviceID }
}

enum HeartRateZone: String, CaseIterable, Identifiable {
    case easy = "60-121"
    case light = "121-141"
    case aerobic = "141-162"
    case hard = "162-182"
    case peak = "182-202"

    var id: String { rawValue }

    var lowerBound: Int {
        switch self {
        case .easy: return 60
        case .light: return 121
        case .aerobic: return 141
        case .hard: return 162
        case .peak: return 182
        }
    }

    var upperBound: Int {
        switch self {
        case .easy: return 121
        case .light: return 141
        case .aerobic: return 162
        case .hard: return 182
        case .peak: return 202
        }
    }

    static func zone(for bpm: Int) -> HeartRateZone {
        let value = min(max(bpm, 60), 202)
        switch value {
        case ..<121: return .easy
        case ..<141: return .light
        case ..<162: return .aerobic
        case ..<182: return .hard
        default: return .peak
        }
    }

    static func ratios(from samples: [HeartRateSample]) -> [HeartRateZone: Double] {
        guard !samples.isEmpty else {
            return Dictionary(uniqueKeysWithValues: allCases.map { ($0, 0) })
        }

        var counts = Dictionary(uniqueKeysWithValues: allCases.map { ($0, 0) })
        for sample in samples {
            let zone = zone(for: sample.bpm)
            counts[zone, default: 0] += 1
        }

        let total = Double(samples.count)
        return counts.mapValues { Double($0) / total }
    }
}
