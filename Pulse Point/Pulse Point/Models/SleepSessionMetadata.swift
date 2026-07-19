import Foundation

struct SleepSessionMetadata: Codable, Identifiable, Hashable {
    let id: String
    let startedAt: Date
    let endedAt: Date
    let timeInBedSeconds: TimeInterval
    let heartRateFileName: String
    let sourceRawValue: String
    let analysis: SleepAnalysisReport
}

struct SleepAnalysisReport: Codable, Hashable {
    let timeInBedSeconds: TimeInterval
    let totalSleepTimeSeconds: TimeInterval
    let sleepLatencySeconds: TimeInterval
    let sleepOnsetSeconds: TimeInterval?
    let wakeAfterSleepOnsetSeconds: TimeInterval
    let estimatedAwakeningMomentsSeconds: [TimeInterval]?
    let sleepEfficiencyPercent: Double
    let estimatedAwakenings: Int

    let deepSleepPercent: Double
    let lightSleepPercent: Double
    let remLikePercent: Double

    let restingHeartRate: Int
    let averageSleepHeartRate: Int
    let overnightHeartRateDropPercent: Double
    let hrvRMSSD: Double

    let recoveryScore: Int
    let readinessScore: Int
    let readinessLabel: String

    let reconstructionSummary: String
    let recoverySummary: String
    let readinessSummary: String
}
