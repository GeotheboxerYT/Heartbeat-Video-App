import Foundation

struct HeartRateSample: Codable, Hashable {
    let t: TimeInterval
    let bpm: Int
}
