import Foundation

struct WorkoutSessionMetadata: Codable, Identifiable, Hashable {
    let id: String
    let startedAt: Date
    let duration: TimeInterval
    let videoFileName: String
    let heartRateFileName: String
}
