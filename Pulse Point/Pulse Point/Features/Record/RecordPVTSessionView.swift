import AudioToolbox
import SwiftUI

struct RecordPVTResult {
    let durationSeconds: Int
    let totalStimuli: Int
    let correctTaps: Int
    let incorrectTaps: Int
    let falseStarts: Int
    let misses: Int
    let lapses: Int
    let meanReactionMS: Int
    let medianReactionMS: Int
    let fastestReactionMS: Int
    let slowestReactionMS: Int
    let reactionTimesMS: [Int]
}

struct RecordPVTSessionView: View {
    let durationSeconds: Int
    let title: String
    let onCancel: () -> Void
    let onComplete: (RecordPVTResult) -> Void

    @StateObject private var viewModel: ViewModel

    init(durationSeconds: Int, title: String, onCancel: @escaping () -> Void, onComplete: @escaping (RecordPVTResult) -> Void) {
        self.durationSeconds = durationSeconds
        self.title = title
        self.onCancel = onCancel
        self.onComplete = onComplete
        _viewModel = StateObject(wrappedValue: ViewModel(durationSeconds: durationSeconds))
    }

    var body: some View {
        ZStack {
            switch viewModel.phase {
            case .instructions:
                instructionsView
            case .running:
                runningView
            case .result:
                resultView
            }
        }
    }

    private var instructionsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.title2.bold())
            Text("Duration: \(durationSeconds / 60) mins")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Text("Only tap the red circle.")
            Text("Do not tap triangles.")
            Text("Tapping before shapes appear counts as a false start.")

            HStack(spacing: 12) {
                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.bordered)

                Button("Start PVT") {
                    viewModel.start()
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 8)
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var runningView: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 20) {
                Text("\(Int(ceil(viewModel.remainingSeconds)))s")
                    .font(.headline)
                    .foregroundStyle(.white)

                if viewModel.isStimulusVisible {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 18) {
                        ForEach(0..<4, id: \.self) { index in
                            Button {
                                viewModel.tapShape(index: index)
                            } label: {
                                shapeView(isCircle: index == viewModel.correctIndex)
                                    .frame(width: 95, height: 95)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 24)
                }
            }

            if let flash = viewModel.flashColor {
                (flash == .green ? Color.green : Color.red)
                    .opacity(0.5)
                    .ignoresSafeArea()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.tapBackgroundWhileWaiting()
        }
    }

    private var resultView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(title) Result")
                    .font(.title2.bold())

                if let result = viewModel.result {
                    Group {
                        Text("Correct taps: \(result.correctTaps)")
                        Text("Incorrect taps: \(result.incorrectTaps)")
                        Text("False starts: \(result.falseStarts)")
                        Text("Misses: \(result.misses)")
                        Text("Mean reaction: \(result.meanReactionMS) ms")
                        Text("Median reaction: \(result.medianReactionMS) ms")
                    }
                    .font(.body)

                    Button("Use Result") {
                        onComplete(result)
                    }
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 8)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func shapeView(isCircle: Bool) -> some View {
        if isCircle {
            Circle().fill(.red)
        } else {
            Triangle().fill(.red)
        }
    }
}

extension RecordPVTSessionView {
    @MainActor
    final class ViewModel: ObservableObject {
        enum Phase {
            case instructions
            case running
            case result
        }

        enum FlashColor {
            case red
            case green
        }

        @Published private(set) var phase: Phase = .instructions
        @Published private(set) var remainingSeconds: TimeInterval = 0
        @Published private(set) var isStimulusVisible = false
        @Published private(set) var correctIndex = 0
        @Published private(set) var flashColor: FlashColor?
        @Published private(set) var result: RecordPVTResult?

        private let durationSeconds: Int
        private let minIntervalSeconds: UInt64 = 3
        private let maxIntervalSeconds: UInt64 = 5

        private var endTime: Date?
        private var shownAt: Date?
        private var previousCorrectIndex: Int?
        private var schedulerTask: Task<Void, Never>?
        private var timeoutTask: Task<Void, Never>?
        private var countdownTask: Task<Void, Never>?

        private var reactionTimesMS: [Int] = []
        private var totalStimuli = 0
        private var correctTaps = 0
        private var incorrectTaps = 0
        private var falseStarts = 0
        private var misses = 0

        init(durationSeconds: Int) {
            self.durationSeconds = durationSeconds
        }

        func start() {
            reset()
            phase = .running
            endTime = Date().addingTimeInterval(TimeInterval(durationSeconds))
            remainingSeconds = TimeInterval(durationSeconds)
            startCountdown()
            scheduleNext()
        }

        func tapBackgroundWhileWaiting() {
            guard phase == .running, !isStimulusVisible else { return }
            falseStarts += 1
            flash(.red)
        }

        func tapShape(index: Int) {
            guard phase == .running, isStimulusVisible else { return }
            timeoutTask?.cancel()
            timeoutTask = nil

            let reactionMS = Int((Date().timeIntervalSince(shownAt ?? Date())) * 1000)
            if index == correctIndex && reactionMS >= 100 {
                correctTaps += 1
                reactionTimesMS.append(reactionMS)
                flash(.green)
            } else {
                incorrectTaps += 1
                flash(.red)
            }

            isStimulusVisible = false
            shownAt = nil
            scheduleNext()
        }

        private func reset() {
            cancelTasks()
            remainingSeconds = 0
            isStimulusVisible = false
            correctIndex = 0
            flashColor = nil
            result = nil
            previousCorrectIndex = nil

            reactionTimesMS = []
            totalStimuli = 0
            correctTaps = 0
            incorrectTaps = 0
            falseStarts = 0
            misses = 0
        }

        private func scheduleNext() {
            guard phase == .running else { return }
            schedulerTask?.cancel()
            schedulerTask = Task { [weak self] in
                guard let self else { return }
                let delay = UInt64.random(in: minIntervalSeconds...maxIntervalSeconds)
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                guard !Task.isCancelled else { return }
                self.showStimulus()
            }
        }

        private func showStimulus() {
            guard phase == .running else { return }
            guard let endTime else { return }
            if Date() >= endTime {
                finish()
                return
            }

            var nextIndex = Int.random(in: 0..<4)
            if let previousCorrectIndex, nextIndex == previousCorrectIndex {
                nextIndex = (nextIndex + Int.random(in: 1...3)) % 4
            }
            correctIndex = nextIndex
            previousCorrectIndex = nextIndex

            isStimulusVisible = true
            shownAt = Date()
            totalStimuli += 1

            timeoutTask?.cancel()
            timeoutTask = Task { [weak self] in
                guard let self else { return }
                let timeoutNS = UInt64(max(0.2, AppSettings.pvtResponseTimeoutSeconds) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: timeoutNS)
                guard !Task.isCancelled else { return }
                self.handleMiss()
            }
        }

        private func handleMiss() {
            guard phase == .running, isStimulusVisible else { return }
            misses += 1
            flash(.red)
            isStimulusVisible = false
            shownAt = nil
            scheduleNext()
        }

        private func startCountdown() {
            countdownTask?.cancel()
            countdownTask = Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    guard let endTime else { return }
                    let remaining = endTime.timeIntervalSinceNow
                    if remaining <= 0 {
                        self.remainingSeconds = 0
                        self.finish()
                        return
                    }
                    self.remainingSeconds = remaining
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
        }

        private func finish() {
            guard phase == .running else { return }
            cancelTasks()
            isStimulusVisible = false
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

            result = RecordPVTResult(
                durationSeconds: durationSeconds,
                totalStimuli: totalStimuli,
                correctTaps: correctTaps,
                incorrectTaps: incorrectTaps,
                falseStarts: falseStarts,
                misses: misses,
                lapses: lapses,
                meanReactionMS: mean,
                medianReactionMS: median,
                fastestReactionMS: sorted.first ?? 0,
                slowestReactionMS: sorted.last ?? 0,
                reactionTimesMS: sorted
            )
            phase = .result
        }

        private func flash(_ color: FlashColor) {
            if AppSettings.pvtFlashFeedbackEnabled {
                flashColor = color
            }
            if AppSettings.pvtSoundEffectsEnabled {
                AudioServicesPlaySystemSound(color == .green ? 1057 : 1053)
            }
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 120_000_000)
                await MainActor.run { self?.flashColor = nil }
            }
        }

        private func cancelTasks() {
            schedulerTask?.cancel()
            timeoutTask?.cancel()
            countdownTask?.cancel()
            schedulerTask = nil
            timeoutTask = nil
            countdownTask = nil
        }
    }
}

private struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}
