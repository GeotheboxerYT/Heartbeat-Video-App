import Foundation

struct PVTPerformanceMetrics: Codable, Hashable {
    let durationSeconds: Int
    let totalStimuliShown: Int
    let correctTaps: Int
    let incorrectTaps: Int
    let falseStarts: Int
    let anticipatoryTaps: Int
    let misses: Int
    let lapses: Int
    let meanReactionMS: Int
    let medianReactionMS: Int
    let fastestReactionMS: Int
    let slowestReactionMS: Int
    let reactionTimesMS: [Int]
}

struct PVTSessionRecord: Codable, Identifiable, Hashable {
    enum WorkoutTiming: String, Codable, CaseIterable, Identifiable {
        case beforeWorkout
        case afterWorkout

        var id: String { rawValue }

        var title: String {
            switch self {
            case .beforeWorkout:
                return "Before Workout"
            case .afterWorkout:
                return "After Workout"
            }
        }
    }

    let id: UUID
    let startedAt: Date
    let completedAt: Date
    let workoutTiming: WorkoutTiming
    let linkedBeforeSessionID: UUID?
    let metrics: PVTPerformanceMetrics
}
