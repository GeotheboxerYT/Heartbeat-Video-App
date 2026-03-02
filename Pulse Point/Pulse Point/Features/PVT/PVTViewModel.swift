import AudioToolbox
import Foundation

@MainActor
final class PVTViewModel: ObservableObject {
    enum Phase {
        case setup
        case instructions
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
    }

    @Published var phase: Phase = .setup
    @Published var selectedDurationSeconds: Int = 60
    @Published private(set) var remainingSeconds: TimeInterval = 0

    @Published private(set) var isStimulusVisible = false
    @Published private(set) var correctIndex: Int = 0

    @Published private(set) var flashColor: FlashColor?
    @Published private(set) var result: Result?

    private var sessionEndTime: Date?
    private var stimulusShownAt: Date?
    private var previousCorrectIndex: Int?

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

    private let minIntervalSeconds: UInt64 = 3
    private let maxIntervalSeconds: UInt64 = 5

    enum FlashColor {
        case red
        case green
    }

    var durationOptions: [Int] {
        [60, 180, 300, 600]
    }

    func chooseDuration(_ seconds: Int) {
        selectedDurationSeconds = seconds
    }

    func showInstructions() {
        phase = .instructions
    }

    func backToSetup() {
        phase = .setup
    }

    func startTask() {
        resetStateForRun()
        phase = .running

        let end = Date().addingTimeInterval(TimeInterval(selectedDurationSeconds))
        sessionEndTime = end
        remainingSeconds = TimeInterval(selectedDurationSeconds)

        startCountdown()
        scheduleNextStimulus()
    }

    func tapBackgroundWhileWaiting() {
        guard phase == .running, !isStimulusVisible else { return }
        falseStarts += 1
        triggerFlash(.red)
    }

    func tapShape(index: Int) {
        guard phase == .running, isStimulusVisible else { return }

        responseTimeoutTask?.cancel()
        responseTimeoutTask = nil

        let now = Date()
        let reactionMS = Int((now.timeIntervalSince(stimulusShownAt ?? now)) * 1000)

        if index == correctIndex {
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

    func discardResult() {
        result = nil
        phase = .setup
    }

    private func resetStateForRun() {
        cancelAllTasks()

        sessionEndTime = nil
        stimulusShownAt = nil
        isStimulusVisible = false
        correctIndex = 0
        previousCorrectIndex = nil
        flashColor = nil

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

            let delay = UInt64.random(in: minIntervalSeconds...maxIntervalSeconds)
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
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

        var newIndex = Int.random(in: 0..<4)
        if let previousCorrectIndex, newIndex == previousCorrectIndex {
            newIndex = (newIndex + Int.random(in: 1...3)) % 4
        }
        correctIndex = newIndex
        previousCorrectIndex = newIndex
        isStimulusVisible = true
        stimulusShownAt = Date()
        totalStimuliShown += 1

        responseTimeoutTask?.cancel()
        responseTimeoutTask = Task { [weak self] in
            guard let self else { return }
            let timeoutNS = UInt64(max(0.2, AppSettings.pvtResponseTimeoutSeconds) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: timeoutNS)
            guard !Task.isCancelled else { return }

            self.handleMissIfStillVisible()
        }
    }

    private func handleMissIfStillVisible() {
        guard phase == .running, isStimulusVisible else { return }
        misses += 1
        triggerFlash(.red)
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

        let report = Result(
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
            slowestReactionMS: sorted.last ?? 0
        )

        result = report
        print("PVT Result: \(report)")
        phase = .result
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

    private func cancelAllTasks() {
        schedulerTask?.cancel()
        responseTimeoutTask?.cancel()
        countdownTask?.cancel()

        schedulerTask = nil
        responseTimeoutTask = nil
        countdownTask = nil
    }
}
