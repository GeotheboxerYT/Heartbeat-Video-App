import AudioToolbox
import CoreGraphics
import Foundation

@MainActor
final class PVTViewModel: ObservableObject {
    enum Phase {
        case setup
        case running
        case result
    }

    struct Result {
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
        let workoutTiming: PVTSessionRecord.WorkoutTiming
        let linkedBeforeSessionID: UUID?
        let savedSessionID: UUID?
    }

    struct ComparisonSummary {
        let headline: String
        let detail: String
        let meanDeltaMS: Int
        let lapseDelta: Int
        let falseStartDelta: Int
        let missDelta: Int
    }

    struct ComparisonChartPoint: Identifiable {
        let id: String
        let metric: String
        let sessionLabel: String
        let value: Double
    }

    struct ComparisonPair: Identifiable {
        let before: PVTSessionRecord
        let after: PVTSessionRecord

        var id: UUID { after.id }
    }

    struct ComparisonDaySection: Identifiable {
        let dayStart: Date
        let title: String
        let entries: [ComparisonPair]

        var id: Date { dayStart }
    }

    struct ComparisonMetricRow: Identifiable {
        let id: String
        let title: String
        let beforeValue: String
        let afterValue: String
        let deltaValue: String
    }

    enum FlashColor {
        case red
        case green
    }

    enum StimulusType {
        case circle
        case triangle
    }

    struct StimulusColor {
        let red: Double
        let green: Double
        let blue: Double

        static func random() -> StimulusColor {
            let h = Double.random(in: 0...1)
            let s = Double.random(in: 0.70...1.0)
            let v = Double.random(in: 0.75...1.0)

            let i = Int(floor(h * 6.0))
            let f = h * 6.0 - Double(i)
            let p = v * (1.0 - s)
            let q = v * (1.0 - f * s)
            let t = v * (1.0 - (1.0 - f) * s)

            switch i % 6 {
            case 0: return StimulusColor(red: v, green: t, blue: p)
            case 1: return StimulusColor(red: q, green: v, blue: p)
            case 2: return StimulusColor(red: p, green: v, blue: t)
            case 3: return StimulusColor(red: p, green: q, blue: v)
            case 4: return StimulusColor(red: t, green: p, blue: v)
            default: return StimulusColor(red: v, green: p, blue: q)
            }
        }
    }

    @Published var phase: Phase = .setup
    @Published var selectedDurationSeconds: Int = 300
    @Published var selectedWorkoutTiming: PVTSessionRecord.WorkoutTiming = .beforeWorkout {
        didSet {
            if selectedWorkoutTiming == .afterWorkout && selectedBeforeSessionID == nil {
                selectedBeforeSessionID = availableBeforeSessions.first?.id
            }
        }
    }
    @Published var selectedBeforeSessionID: UUID?
    @Published private(set) var remainingSeconds: TimeInterval = 0

    @Published private(set) var isStimulusVisible = false
    @Published private(set) var stimulusType: StimulusType = .circle
    @Published private(set) var stimulusPosition: CGPoint = CGPoint(x: 0.5, y: 0.5)
    @Published private(set) var stimulusColor: StimulusColor = .random()

    @Published private(set) var flashColor: FlashColor?
    @Published private(set) var result: Result?
    @Published private(set) var comparisonSummary: ComparisonSummary?
    @Published private(set) var setupStatusMessage: String?
    @Published private(set) var availableBeforeSessions: [PVTSessionRecord] = []
    @Published private(set) var savedSessions: [PVTSessionRecord] = []
    @Published private(set) var comparisonSections: [ComparisonDaySection] = []
    @Published var selectedComparisonAfterSessionID: UUID?

    private var sessionEndTime: Date?
    private var stimulusShownAt: Date?
    private var schedulerTask: Task<Void, Never>?
    private var responseTimeoutTask: Task<Void, Never>?
    private var countdownTask: Task<Void, Never>?

    private var reactionTimesMS: [Int] = []
    private var correctTaps = 0
    private var incorrectTaps = 0
    private var falseStarts = 0
    private var anticipatoryTaps = 0
    private var misses = 0
    private var totalStimuliShown = 0

    private var activeWorkoutTiming: PVTSessionRecord.WorkoutTiming = .beforeWorkout
    private var activeLinkedBeforeSessionID: UUID?
    private var activeStartedAt: Date?

    private let storage = PVTSessionStorage()

    private let shortDurationSeconds = 45
    private let shortMinIntervalSeconds: TimeInterval = 0.3
    private let shortMaxIntervalSeconds: TimeInterval = 2.0
    private let standardMinIntervalSeconds: TimeInterval = 0.5
    private let standardMaxIntervalSeconds: TimeInterval = 2.5
    private let triangleChanceDivisor = 8

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
    private var activeDurationSeconds: Int = 300

    init() {
        reloadSavedSessions()
    }

    var durationOptions: [Int] {
        [shortDurationSeconds, 300, 600]
    }

    var canStartFromSetup: Bool {
        switch selectedWorkoutTiming {
        case .beforeWorkout:
            return true
        case .afterWorkout:
            return selectedBeforeSessionID != nil && !availableBeforeSessions.isEmpty
        }
    }

    var selectedBeforeSessionLabel: String {
        guard let selectedBeforeSessionID,
              let session = availableBeforeSessions.first(where: { $0.id == selectedBeforeSessionID }) else {
            return "None selected"
        }
        return beforeSessionDisplayLabel(for: session)
    }

    var savedResultsForDisplay: [PVTSessionRecord] {
        savedSessions
    }

    var allComparisonPairs: [ComparisonPair] {
        comparisonSections.flatMap(\.entries)
    }

    var selectedComparisonPair: ComparisonPair? {
        guard let selectedComparisonAfterSessionID else { return allComparisonPairs.first }
        return allComparisonPairs.first(where: { $0.after.id == selectedComparisonAfterSessionID }) ?? allComparisonPairs.first
    }

    func chooseDuration(_ seconds: Int) {
        selectedDurationSeconds = seconds
    }

    func durationButtonTitle(for seconds: Int) -> String {
        if seconds < 60 {
            return "\(seconds) Sec"
        }
        return "\(seconds / 60) Mins"
    }

    func durationSummaryText(for seconds: Int) -> String {
        if seconds < 60 {
            return "\(seconds) sec"
        }
        return "\(seconds / 60) mins"
    }

    func savedResultTitle(for session: PVTSessionRecord) -> String {
        let dateText = dateFormatter.string(from: session.completedAt)
        return "\(session.workoutTiming.title) • \(dateText) • \(durationSummaryText(for: session.metrics.durationSeconds))"
    }

    func savedResultMetricsText(for session: PVTSessionRecord) -> String {
        let metrics = session.metrics
        return "Mean \(metrics.meanReactionMS)ms • Lapses \(metrics.lapses) • False starts \(metrics.falseStarts) • Misses \(metrics.misses)"
    }

    func savedResultComparisonText(for session: PVTSessionRecord) -> String? {
        guard session.workoutTiming == .afterWorkout,
              let beforeID = session.linkedBeforeSessionID,
              let before = savedSessions.first(where: { $0.id == beforeID }) else {
            return nil
        }

        let after = session.metrics
        let meanDelta = after.meanReactionMS - before.metrics.meanReactionMS
        let lapseDelta = after.lapses - before.metrics.lapses
        let falseStartDelta = after.falseStarts - before.metrics.falseStarts
        let missDelta = after.misses - before.metrics.misses

        return "Compared to baseline: Mean \(deltaText(meanDelta, suffix: "ms")), Lapses \(deltaText(lapseDelta)), False starts \(deltaText(falseStartDelta)), Misses \(deltaText(missDelta))."
    }

    func savedResultComparisonChartPoints(for session: PVTSessionRecord) -> [ComparisonChartPoint]? {
        guard session.workoutTiming == .afterWorkout,
              let beforeID = session.linkedBeforeSessionID,
              let beforeSession = savedSessions.first(where: { $0.id == beforeID }) else {
            return nil
        }
        return normalizedSummaryPoints(for: ComparisonPair(before: beforeSession, after: session))
    }

    func normalizedSummaryPoints(for pair: ComparisonPair) -> [ComparisonChartPoint] {
        let before = pair.before.metrics
        let after = pair.after.metrics

        return [
            ComparisonChartPoint(
                id: "mean_before_\(pair.id)",
                metric: "Reaction",
                sessionLabel: "Before",
                value: normalizedComparisonScore(rawValue: Double(before.meanReactionMS), bestValue: 180, worstValue: 500, lowerIsBetter: true)
            ),
            ComparisonChartPoint(
                id: "mean_after_\(pair.id)",
                metric: "Reaction",
                sessionLabel: "After",
                value: normalizedComparisonScore(rawValue: Double(after.meanReactionMS), bestValue: 180, worstValue: 500, lowerIsBetter: true)
            ),
            ComparisonChartPoint(
                id: "lapses_before_\(pair.id)",
                metric: "Lapses",
                sessionLabel: "Before",
                value: normalizedComparisonScore(rawValue: Double(before.lapses), bestValue: 0, worstValue: 20, lowerIsBetter: true)
            ),
            ComparisonChartPoint(
                id: "lapses_after_\(pair.id)",
                metric: "Lapses",
                sessionLabel: "After",
                value: normalizedComparisonScore(rawValue: Double(after.lapses), bestValue: 0, worstValue: 20, lowerIsBetter: true)
            ),
            ComparisonChartPoint(
                id: "false_before_\(pair.id)",
                metric: "False Starts",
                sessionLabel: "Before",
                value: normalizedComparisonScore(rawValue: Double(before.falseStarts), bestValue: 0, worstValue: 15, lowerIsBetter: true)
            ),
            ComparisonChartPoint(
                id: "false_after_\(pair.id)",
                metric: "False Starts",
                sessionLabel: "After",
                value: normalizedComparisonScore(rawValue: Double(after.falseStarts), bestValue: 0, worstValue: 15, lowerIsBetter: true)
            ),
            ComparisonChartPoint(
                id: "misses_before_\(pair.id)",
                metric: "Misses",
                sessionLabel: "Before",
                value: normalizedComparisonScore(rawValue: Double(before.misses), bestValue: 0, worstValue: 15, lowerIsBetter: true)
            ),
            ComparisonChartPoint(
                id: "misses_after_\(pair.id)",
                metric: "Misses",
                sessionLabel: "After",
                value: normalizedComparisonScore(rawValue: Double(after.misses), bestValue: 0, worstValue: 15, lowerIsBetter: true)
            )
        ]
    }

    func reactionProfilePoints(for pair: ComparisonPair) -> [ComparisonChartPoint] {
        let before = pair.before.metrics
        let after = pair.after.metrics
        return [
            ComparisonChartPoint(id: "fast_before_\(pair.id)", metric: "Fastest", sessionLabel: "Before", value: Double(before.fastestReactionMS)),
            ComparisonChartPoint(id: "fast_after_\(pair.id)", metric: "Fastest", sessionLabel: "After", value: Double(after.fastestReactionMS)),
            ComparisonChartPoint(id: "median_before_\(pair.id)", metric: "Median", sessionLabel: "Before", value: Double(before.medianReactionMS)),
            ComparisonChartPoint(id: "median_after_\(pair.id)", metric: "Median", sessionLabel: "After", value: Double(after.medianReactionMS)),
            ComparisonChartPoint(id: "mean_before_\(pair.id)_profile", metric: "Mean", sessionLabel: "Before", value: Double(before.meanReactionMS)),
            ComparisonChartPoint(id: "mean_after_\(pair.id)_profile", metric: "Mean", sessionLabel: "After", value: Double(after.meanReactionMS)),
            ComparisonChartPoint(id: "slow_before_\(pair.id)", metric: "Slowest", sessionLabel: "Before", value: Double(before.slowestReactionMS)),
            ComparisonChartPoint(id: "slow_after_\(pair.id)", metric: "Slowest", sessionLabel: "After", value: Double(after.slowestReactionMS))
        ]
    }

    func errorBreakdownPoints(for pair: ComparisonPair) -> [ComparisonChartPoint] {
        let before = pair.before.metrics
        let after = pair.after.metrics
        return [
            ComparisonChartPoint(id: "inc_before_\(pair.id)", metric: "Incorrect", sessionLabel: "Before", value: Double(before.incorrectTaps)),
            ComparisonChartPoint(id: "inc_after_\(pair.id)", metric: "Incorrect", sessionLabel: "After", value: Double(after.incorrectTaps)),
            ComparisonChartPoint(id: "false_before_\(pair.id)_err", metric: "False", sessionLabel: "Before", value: Double(before.falseStarts)),
            ComparisonChartPoint(id: "false_after_\(pair.id)_err", metric: "False", sessionLabel: "After", value: Double(after.falseStarts)),
            ComparisonChartPoint(id: "ant_before_\(pair.id)", metric: "Anticip.", sessionLabel: "Before", value: Double(before.anticipatoryTaps)),
            ComparisonChartPoint(id: "ant_after_\(pair.id)", metric: "Anticip.", sessionLabel: "After", value: Double(after.anticipatoryTaps)),
            ComparisonChartPoint(id: "miss_before_\(pair.id)_err", metric: "Misses", sessionLabel: "Before", value: Double(before.misses)),
            ComparisonChartPoint(id: "miss_after_\(pair.id)_err", metric: "Misses", sessionLabel: "After", value: Double(after.misses)),
            ComparisonChartPoint(id: "lapses_before_\(pair.id)_err", metric: "Lapses", sessionLabel: "Before", value: Double(before.lapses)),
            ComparisonChartPoint(id: "lapses_after_\(pair.id)_err", metric: "Lapses", sessionLabel: "After", value: Double(after.lapses))
        ]
    }

    func volumeComparisonPoints(for pair: ComparisonPair) -> [ComparisonChartPoint] {
        let before = pair.before.metrics
        let after = pair.after.metrics
        let beforeAccuracy = accuracyPercent(correct: before.correctTaps, total: before.totalStimuliShown)
        let afterAccuracy = accuracyPercent(correct: after.correctTaps, total: after.totalStimuliShown)

        return [
            ComparisonChartPoint(id: "stim_before_\(pair.id)", metric: "Stimuli", sessionLabel: "Before", value: Double(before.totalStimuliShown)),
            ComparisonChartPoint(id: "stim_after_\(pair.id)", metric: "Stimuli", sessionLabel: "After", value: Double(after.totalStimuliShown)),
            ComparisonChartPoint(id: "corr_before_\(pair.id)", metric: "Correct", sessionLabel: "Before", value: Double(before.correctTaps)),
            ComparisonChartPoint(id: "corr_after_\(pair.id)", metric: "Correct", sessionLabel: "After", value: Double(after.correctTaps)),
            ComparisonChartPoint(id: "acc_before_\(pair.id)", metric: "Accuracy %", sessionLabel: "Before", value: Double(beforeAccuracy)),
            ComparisonChartPoint(id: "acc_after_\(pair.id)", metric: "Accuracy %", sessionLabel: "After", value: Double(afterAccuracy))
        ]
    }

    func startFromSetup() {
        setupStatusMessage = nil
        comparisonSummary = nil

        switch selectedWorkoutTiming {
        case .beforeWorkout:
            startTask(workoutTiming: .beforeWorkout, linkedBeforeSessionID: nil)
        case .afterWorkout:
            guard !availableBeforeSessions.isEmpty else {
                setupStatusMessage = "No saved pre-workout PVT session found. Run a Before Workout session first."
                return
            }
            guard let selectedBeforeSessionID else {
                setupStatusMessage = "Select a pre-workout PVT session first."
                return
            }
            startTask(workoutTiming: .afterWorkout, linkedBeforeSessionID: selectedBeforeSessionID)
        }
    }

    func tapBackgroundWhileWaiting() {
        guard phase == .running, !isStimulusVisible else { return }
        falseStarts += 1
        triggerFlash(.red)
    }

    func tapStimulus() {
        guard phase == .running, isStimulusVisible else { return }

        responseTimeoutTask?.cancel()
        responseTimeoutTask = nil

        let now = Date()
        let reactionMS = Int((now.timeIntervalSince(stimulusShownAt ?? now)) * 1000)

        if stimulusType == .circle {
            if reactionMS < 100 {
                anticipatoryTaps += 1
                triggerFlash(.red)
            } else {
                correctTaps += 1
                reactionTimesMS.append(reactionMS)
                triggerFlash(.green)
            }
        } else {
            incorrectTaps += 1
            triggerFlash(.red)
        }

        isStimulusVisible = false
        stimulusShownAt = nil
        scheduleNextStimulus()
    }

    func closeResult() {
        result = nil
        comparisonSummary = nil
        setupStatusMessage = nil
        phase = .setup
        reloadSavedSessions()
    }

    func cancelRunningTask() {
        guard phase == .running else { return }
        cancelAllTasks()
        sessionEndTime = nil
        stimulusShownAt = nil
        isStimulusVisible = false
        flashColor = nil
        remainingSeconds = 0
        phase = .setup
        setupStatusMessage = "PVT canceled."
    }

    func beforeSessionDisplayLabel(for session: PVTSessionRecord) -> String {
        let dateText = dateFormatter.string(from: session.completedAt)
        return "\(dateText) • \(durationSummaryText(for: session.metrics.durationSeconds)) • Mean \(session.metrics.meanReactionMS)ms"
    }

    func comparisonEntryLabel(for pair: ComparisonPair) -> String {
        let afterTime = timeFormatter.string(from: pair.after.completedAt)
        let durationText = durationSummaryText(for: pair.after.metrics.durationSeconds)
        return "\(afterTime) • \(durationText)"
    }

    func comparisonHeaderLabel(for pair: ComparisonPair) -> String {
        let beforeDate = dateFormatter.string(from: pair.before.completedAt)
        let afterDate = dateFormatter.string(from: pair.after.completedAt)
        return "Before: \(beforeDate)  |  After: \(afterDate)"
    }

    func metricRows(for pair: ComparisonPair) -> [ComparisonMetricRow] {
        let before = pair.before.metrics
        let after = pair.after.metrics

        let beforeAccuracy = accuracyPercent(correct: before.correctTaps, total: before.totalStimuliShown)
        let afterAccuracy = accuracyPercent(correct: after.correctTaps, total: after.totalStimuliShown)

        return [
            row(
                id: "duration",
                title: "Duration",
                beforeValue: durationSummaryText(for: before.durationSeconds),
                afterValue: durationSummaryText(for: after.durationSeconds),
                deltaValue: deltaDurationText(after.durationSeconds - before.durationSeconds)
            ),
            row(
                id: "stimuli",
                title: "Stimuli",
                beforeValue: "\(before.totalStimuliShown)",
                afterValue: "\(after.totalStimuliShown)",
                deltaValue: deltaNumberText(after.totalStimuliShown - before.totalStimuliShown)
            ),
            row(
                id: "correct",
                title: "Correct taps",
                beforeValue: "\(before.correctTaps)",
                afterValue: "\(after.correctTaps)",
                deltaValue: deltaNumberText(after.correctTaps - before.correctTaps)
            ),
            row(
                id: "incorrect",
                title: "Incorrect taps",
                beforeValue: "\(before.incorrectTaps)",
                afterValue: "\(after.incorrectTaps)",
                deltaValue: deltaNumberText(after.incorrectTaps - before.incorrectTaps)
            ),
            row(
                id: "accuracy",
                title: "Accuracy",
                beforeValue: "\(beforeAccuracy)%",
                afterValue: "\(afterAccuracy)%",
                deltaValue: deltaNumberText(afterAccuracy - beforeAccuracy, suffix: "%")
            ),
            row(
                id: "false",
                title: "False starts",
                beforeValue: "\(before.falseStarts)",
                afterValue: "\(after.falseStarts)",
                deltaValue: deltaNumberText(after.falseStarts - before.falseStarts)
            ),
            row(
                id: "anticipatory",
                title: "Anticipatory",
                beforeValue: "\(before.anticipatoryTaps)",
                afterValue: "\(after.anticipatoryTaps)",
                deltaValue: deltaNumberText(after.anticipatoryTaps - before.anticipatoryTaps)
            ),
            row(
                id: "misses",
                title: "Misses",
                beforeValue: "\(before.misses)",
                afterValue: "\(after.misses)",
                deltaValue: deltaNumberText(after.misses - before.misses)
            ),
            row(
                id: "lapses",
                title: "Lapses",
                beforeValue: "\(before.lapses)",
                afterValue: "\(after.lapses)",
                deltaValue: deltaNumberText(after.lapses - before.lapses)
            ),
            row(
                id: "mean",
                title: "Mean reaction",
                beforeValue: "\(before.meanReactionMS) ms",
                afterValue: "\(after.meanReactionMS) ms",
                deltaValue: deltaNumberText(after.meanReactionMS - before.meanReactionMS, suffix: " ms")
            ),
            row(
                id: "median",
                title: "Median reaction",
                beforeValue: "\(before.medianReactionMS) ms",
                afterValue: "\(after.medianReactionMS) ms",
                deltaValue: deltaNumberText(after.medianReactionMS - before.medianReactionMS, suffix: " ms")
            ),
            row(
                id: "fastest",
                title: "Fastest reaction",
                beforeValue: "\(before.fastestReactionMS) ms",
                afterValue: "\(after.fastestReactionMS) ms",
                deltaValue: deltaNumberText(after.fastestReactionMS - before.fastestReactionMS, suffix: " ms")
            ),
            row(
                id: "slowest",
                title: "Slowest reaction",
                beforeValue: "\(before.slowestReactionMS) ms",
                afterValue: "\(after.slowestReactionMS) ms",
                deltaValue: deltaNumberText(after.slowestReactionMS - before.slowestReactionMS, suffix: " ms")
            )
        ]
    }

    private func startTask(
        workoutTiming: PVTSessionRecord.WorkoutTiming,
        linkedBeforeSessionID: UUID?
    ) {
        resetStateForRun()
        phase = .running

        activeWorkoutTiming = workoutTiming
        activeLinkedBeforeSessionID = linkedBeforeSessionID
        activeStartedAt = Date()
        activeDurationSeconds = selectedDurationSeconds

        let end = Date().addingTimeInterval(TimeInterval(selectedDurationSeconds))
        sessionEndTime = end
        remainingSeconds = TimeInterval(selectedDurationSeconds)

        startCountdown()
        scheduleNextStimulus()
    }

    private func resetStateForRun() {
        cancelAllTasks()

        sessionEndTime = nil
        stimulusShownAt = nil
        isStimulusVisible = false
        stimulusType = .circle
        stimulusPosition = CGPoint(x: 0.5, y: 0.5)
        stimulusColor = .random()
        flashColor = nil
        setupStatusMessage = nil

        reactionTimesMS = []
        correctTaps = 0
        incorrectTaps = 0
        falseStarts = 0
        anticipatoryTaps = 0
        misses = 0
        totalStimuliShown = 0
    }

    private func scheduleNextStimulus() {
        guard phase == .running else { return }

        schedulerTask?.cancel()
        schedulerTask = Task { [weak self] in
            guard let self else { return }

            let range = intervalRange(for: activeDurationSeconds)
            let delay = Double.random(in: range)
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }

            self.showStimulusIfStillRunning()
        }
    }

    private func showStimulusIfStillRunning() {
        guard phase == .running else { return }
        guard let sessionEndTime else { return }

        if Date() >= sessionEndTime {
            finishTask()
            return
        }

        stimulusType = Int.random(in: 1...triangleChanceDivisor) == 1 ? .triangle : .circle
        stimulusPosition = CGPoint(x: CGFloat.random(in: 0...1), y: CGFloat.random(in: 0...1))
        stimulusColor = .random()
        isStimulusVisible = true
        stimulusShownAt = Date()
        totalStimuliShown += 1

        responseTimeoutTask?.cancel()
        responseTimeoutTask = Task { [weak self] in
            guard let self else { return }
            let timeoutSeconds = self.stimulusType == .triangle ? 1.0 : max(0.2, AppSettings.pvtResponseTimeoutSeconds)
            let timeoutNS = UInt64(timeoutSeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: timeoutNS)
            guard !Task.isCancelled else { return }

            self.handleMissIfStillVisible()
        }
    }

    private func handleMissIfStillVisible() {
        guard phase == .running, isStimulusVisible else { return }
        if stimulusType == .circle {
            misses += 1
            triggerFlash(.red)
        }
        isStimulusVisible = false
        stimulusShownAt = nil
        scheduleNextStimulus()
    }

    private func startCountdown() {
        countdownTask?.cancel()
        countdownTask = Task { [weak self] in
            guard let self else { return }

            while !Task.isCancelled {
                guard let sessionEndTime else { return }
                let remaining = sessionEndTime.timeIntervalSinceNow

                if remaining <= 0 {
                    await MainActor.run {
                        self.remainingSeconds = 0
                        self.finishTask()
                    }
                    return
                }

                await MainActor.run {
                    self.remainingSeconds = remaining
                }

                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func finishTask() {
        guard phase == .running else { return }

        cancelAllTasks()
        isStimulusVisible = false
        stimulusShownAt = nil
        remainingSeconds = 0

        let sorted = reactionTimesMS.sorted()
        let mean = sorted.isEmpty ? 0 : Int(round(Double(sorted.reduce(0, +)) / Double(sorted.count)))
        let median: Int
        if sorted.isEmpty {
            median = 0
        } else {
            let mid = sorted.count / 2
            median = sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
        }

        let lapses = reactionTimesMS.filter { $0 >= 500 }.count + misses

        let metrics = PVTPerformanceMetrics(
            durationSeconds: selectedDurationSeconds,
            totalStimuliShown: totalStimuliShown,
            correctTaps: correctTaps,
            incorrectTaps: incorrectTaps,
            falseStarts: falseStarts,
            anticipatoryTaps: anticipatoryTaps,
            misses: misses,
            lapses: lapses,
            meanReactionMS: mean,
            medianReactionMS: median,
            fastestReactionMS: sorted.first ?? 0,
            slowestReactionMS: sorted.last ?? 0,
            reactionTimesMS: sorted
        )

        let baselineSession = activeLinkedBeforeSessionID.flatMap { id in
            availableBeforeSessions.first(where: { $0.id == id })
        }

        let sessionRecord = PVTSessionRecord(
            id: UUID(),
            startedAt: activeStartedAt ?? Date().addingTimeInterval(-TimeInterval(selectedDurationSeconds)),
            completedAt: Date(),
            workoutTiming: activeWorkoutTiming,
            linkedBeforeSessionID: activeLinkedBeforeSessionID,
            metrics: metrics
        )

        do {
            try storage.saveSession(sessionRecord)
        } catch {
            setupStatusMessage = "PVT finished, but save failed: \(error.localizedDescription)"
        }

        reloadSavedSessions()

        result = Result(
            durationSeconds: metrics.durationSeconds,
            totalStimuliShown: metrics.totalStimuliShown,
            correctTaps: metrics.correctTaps,
            incorrectTaps: metrics.incorrectTaps,
            falseStarts: metrics.falseStarts,
            anticipatoryTaps: metrics.anticipatoryTaps,
            misses: metrics.misses,
            lapses: metrics.lapses,
            meanReactionMS: metrics.meanReactionMS,
            medianReactionMS: metrics.medianReactionMS,
            fastestReactionMS: metrics.fastestReactionMS,
            slowestReactionMS: metrics.slowestReactionMS,
            reactionTimesMS: metrics.reactionTimesMS,
            workoutTiming: activeWorkoutTiming,
            linkedBeforeSessionID: activeLinkedBeforeSessionID,
            savedSessionID: sessionRecord.id
        )

        if let beforeSession = baselineSession, activeWorkoutTiming == .afterWorkout {
            comparisonSummary = buildComparisonSummary(before: beforeSession.metrics, after: metrics)
        } else {
            comparisonSummary = nil
        }

        phase = .result
    }

    private func buildComparisonSummary(
        before: PVTPerformanceMetrics,
        after: PVTPerformanceMetrics
    ) -> ComparisonSummary {
        let meanDelta = after.meanReactionMS - before.meanReactionMS
        let lapseDelta = after.lapses - before.lapses
        let falseStartDelta = after.falseStarts - before.falseStarts
        let missDelta = after.misses - before.misses

        var score = 0
        if meanDelta <= -20 { score += 2 }
        if meanDelta >= 20 { score -= 2 }
        if lapseDelta < 0 { score += 1 }
        if lapseDelta > 0 { score -= 1 }
        if falseStartDelta < 0 { score += 1 }
        if falseStartDelta > 0 { score -= 1 }
        if missDelta < 0 { score += 1 }
        if missDelta > 0 { score -= 1 }

        let headline: String
        let detail: String
        if score >= 2 {
            headline = "You performed better after workout."
            detail = "Reaction speed and error control improved versus your selected pre-workout baseline."
        } else if score <= -2 {
            headline = "You performed worse after workout."
            detail = "Reaction speed or error control dropped versus your selected pre-workout baseline."
        } else {
            headline = "Mixed result after workout."
            detail = "Some metrics improved while others declined versus your selected pre-workout baseline."
        }

        return ComparisonSummary(
            headline: headline,
            detail: detail,
            meanDeltaMS: meanDelta,
            lapseDelta: lapseDelta,
            falseStartDelta: falseStartDelta,
            missDelta: missDelta
        )
    }

    private func triggerFlash(_ color: FlashColor) {
        if AppSettings.pvtFlashFeedbackEnabled {
            flashColor = color
        }

        if AppSettings.pvtSoundEffectsEnabled {
            switch color {
            case .green:
                AudioServicesPlaySystemSound(1057)
            case .red:
                AudioServicesPlaySystemSound(1053)
            }
        }

        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            await MainActor.run {
                self?.flashColor = nil
            }
        }
    }

    private func reloadSavedSessions() {
        let sessions = storage.listSessions()
        savedSessions = sessions

        comparisonSections = buildComparisonSections(from: sessions)

        let usedBeforeSessionIDs: Set<UUID> = Set(
            sessions.compactMap { session -> UUID? in
                guard session.workoutTiming == .afterWorkout else { return nil }
                return session.linkedBeforeSessionID
            }
        )
        availableBeforeSessions = sessions.filter { session in
            session.workoutTiming == .beforeWorkout && !usedBeforeSessionIDs.contains(session.id)
        }

        if let selectedBeforeSessionID,
           !availableBeforeSessions.contains(where: { $0.id == selectedBeforeSessionID }) {
            self.selectedBeforeSessionID = nil
        }

        if selectedWorkoutTiming == .afterWorkout && selectedBeforeSessionID == nil {
            selectedBeforeSessionID = availableBeforeSessions.first?.id
        }

        let availableAfterIDs = Set(comparisonSections.flatMap { $0.entries.map { $0.after.id } })
        if let selectedComparisonAfterSessionID,
           !availableAfterIDs.contains(selectedComparisonAfterSessionID) {
            self.selectedComparisonAfterSessionID = nil
        }

        if selectedComparisonAfterSessionID == nil {
            selectedComparisonAfterSessionID = comparisonSections.first?.entries.first?.after.id
        }
    }

    private func buildComparisonSections(from sessions: [PVTSessionRecord]) -> [ComparisonDaySection] {
        let pairs = sessions
            .compactMap { afterSession -> ComparisonPair? in
                guard afterSession.workoutTiming == .afterWorkout,
                      let beforeID = afterSession.linkedBeforeSessionID,
                      let beforeSession = sessions.first(where: { $0.id == beforeID }) else {
                    return nil
                }
                return ComparisonPair(before: beforeSession, after: afterSession)
            }
            .sorted { lhs, rhs in
                lhs.after.completedAt > rhs.after.completedAt
            }

        let calendar = Calendar.current
        let grouped = Dictionary(grouping: pairs) { pair in
            calendar.startOfDay(for: pair.after.completedAt)
        }

        return grouped.keys.sorted(by: >).map { day in
            let title: String
            if calendar.isDateInToday(day) {
                title = "Today"
            } else if calendar.isDateInYesterday(day) {
                title = "Yesterday"
            } else {
                title = dayFormatter.string(from: day)
            }
            let entries = (grouped[day] ?? []).sorted { $0.after.completedAt > $1.after.completedAt }
            return ComparisonDaySection(dayStart: day, title: title, entries: entries)
        }
    }

    private func cancelAllTasks() {
        schedulerTask?.cancel()
        responseTimeoutTask?.cancel()
        countdownTask?.cancel()

        schedulerTask = nil
        responseTimeoutTask = nil
        countdownTask = nil
    }

    private func intervalRange(for durationSeconds: Int) -> ClosedRange<TimeInterval> {
        if durationSeconds == shortDurationSeconds {
            return shortMinIntervalSeconds...shortMaxIntervalSeconds
        }
        return standardMinIntervalSeconds...standardMaxIntervalSeconds
    }

    private func deltaText(_ value: Int, suffix: String = "") -> String {
        let sign = value > 0 ? "+" : ""
        let suffixText = suffix.isEmpty ? "" : "\(suffix)"
        return "\(sign)\(value)\(suffixText)"
    }

    private func row(
        id: String,
        title: String,
        beforeValue: String,
        afterValue: String,
        deltaValue: String
    ) -> ComparisonMetricRow {
        ComparisonMetricRow(
            id: id,
            title: title,
            beforeValue: beforeValue,
            afterValue: afterValue,
            deltaValue: deltaValue
        )
    }

    private func accuracyPercent(correct: Int, total: Int) -> Int {
        guard total > 0 else { return 0 }
        return Int(round((Double(correct) / Double(total)) * 100))
    }

    private func deltaNumberText(_ value: Int, suffix: String = "") -> String {
        let sign = value > 0 ? "+" : ""
        return "\(sign)\(value)\(suffix)"
    }

    private func deltaDurationText(_ value: Int) -> String {
        let sign = value > 0 ? "+" : ""
        if abs(value) < 60 {
            return "\(sign)\(value)s"
        }
        let mins = value / 60
        let secs = abs(value % 60)
        return String(format: "%@%d:%02d", sign, mins, secs)
    }

    private func normalizedComparisonScore(
        rawValue: Double,
        bestValue: Double,
        worstValue: Double,
        lowerIsBetter: Bool
    ) -> Double {
        let clamped = max(min(rawValue, max(bestValue, worstValue)), min(bestValue, worstValue))
        let span = max(0.0001, abs(worstValue - bestValue))
        let ratio = lowerIsBetter
            ? (worstValue - clamped) / span
            : (clamped - bestValue) / span
        return max(0, min(100, ratio * 100))
    }
}
