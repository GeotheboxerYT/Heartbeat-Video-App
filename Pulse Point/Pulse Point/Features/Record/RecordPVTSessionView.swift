import AudioToolbox
import SwiftUI
import UIKit

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

    @Environment(\.layoutViewportSize) private var layoutViewportSize
    @StateObject private var viewModel: ViewModel
    private var stimulusSize: CGFloat { scaled(124) }

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
        VStack(alignment: .leading, spacing: scaled(14)) {
            Text(title)
                .font(.system(size: scaled(28), weight: .black, design: .rounded))
            Text("Duration: \(durationSeconds / 60) mins")
                .font(.system(size: scaled(17), weight: .semibold, design: .rounded))
                .foregroundStyle(.secondary)

            Text("Tap circles only.")
                .font(.system(size: scaled(18), weight: .semibold, design: .rounded))
            Text("Do not tap triangles.")
                .font(.system(size: scaled(18), weight: .semibold, design: .rounded))
            Text("Early taps = false starts.")
                .font(.system(size: scaled(18), weight: .semibold, design: .rounded))

            HStack(spacing: scaled(12)) {
                Button("Cancel") {
                    onCancel()
                }
                .buttonStyle(.bordered)
                .font(.system(size: scaled(17), weight: .bold, design: .rounded))
                .padding(.vertical, scaled(4))

                Button("Start PVT") {
                    viewModel.start()
                }
                .buttonStyle(.borderedProminent)
                .font(.system(size: scaled(17), weight: .black, design: .rounded))
                .padding(.vertical, scaled(4))
            }
            .padding(.top, scaled(8))
        }
        .padding(scaled(14))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var runningView: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Color.black.ignoresSafeArea()

                Text("\(Int(ceil(viewModel.remainingSeconds)))s")
                    .font(.system(size: scaled(28), weight: .black, design: .rounded))
                    .foregroundStyle(.white)
                    .padding(.top, scaled(16))
                    .allowsHitTesting(false)

                HStack {
                    Spacer()
                    Button("Cancel") {
                        viewModel.cancelRun()
                        onCancel()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                    .font(.system(size: scaled(14), weight: .black, design: .rounded))
                }
                .padding(.top, scaled(16))
                .padding(.horizontal, scaled(16))

                if viewModel.isStimulusVisible {
                    Button {
                        viewModel.tapStimulus()
                    } label: {
                        shapeView(stimulusType: viewModel.stimulusType)
                            .frame(width: stimulusSize, height: stimulusSize)
                    }
                    .buttonStyle(.plain)
                    .position(stimulusPoint(in: geometry.size))
                }

                if let flash = viewModel.flashColor {
                    (flash == .green ? Color.green : Color.red)
                        .opacity(0.5)
                        .ignoresSafeArea()
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.tapBackgroundWhileWaiting()
        }
    }

    private var resultView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: scaled(10)) {
                Text("\(title) Result")
                    .font(.system(size: scaled(28), weight: .black, design: .rounded))

                if let result = viewModel.result {
                    Group {
                        Text("Correct taps: \(result.correctTaps)")
                        Text("Incorrect taps: \(result.incorrectTaps)")
                        Text("False starts: \(result.falseStarts)")
                        Text("Misses: \(result.misses)")
                        Text("Mean reaction: \(result.meanReactionMS) ms")
                        Text("Median reaction: \(result.medianReactionMS) ms")
                    }
                    .font(.system(size: scaled(17), weight: .regular, design: .rounded))

                    Button("Use Result") {
                        onComplete(result)
                    }
                    .buttonStyle(.borderedProminent)
                    .font(.system(size: scaled(17), weight: .black, design: .rounded))
                    .padding(.top, scaled(8))
                }
            }
            .padding(scaled(14))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func shapeView(stimulusType: ViewModel.StimulusType) -> some View {
        if stimulusType == .circle {
            Circle().fill(.red)
        } else {
            Triangle().fill(.red)
        }
    }

    private func stimulusPoint(in size: CGSize) -> CGPoint {
        let margin = stimulusSize / 2
        let usableWidth = max(1, size.width - (margin * 2))
        let usableHeight = max(1, size.height - (margin * 2))
        let x = margin + (viewModel.stimulusPosition.x * usableWidth)
        let y = margin + (viewModel.stimulusPosition.y * usableHeight)
        return CGPoint(x: x, y: y)
    }

    private var uiScale: CGFloat {
        let referenceWidth: CGFloat = 393 // iPhone 16 Pro
        let referenceHeight: CGFloat = 852
        let measuredWidth = layoutViewportSize.width > 0 ? layoutViewportSize.width : UIScreen.main.bounds.width
        let measuredHeight = layoutViewportSize.height > 0 ? layoutViewportSize.height : UIScreen.main.bounds.height
        let rawScale = min(measuredWidth / referenceWidth, measuredHeight / referenceHeight)
        return min(max(rawScale, 0.9), 1.22)
    }

    private func scaled(_ value: CGFloat) -> CGFloat {
        value * uiScale
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

        enum StimulusType {
            case circle
            case triangle
        }

        @Published private(set) var phase: Phase = .instructions
        @Published private(set) var remainingSeconds: TimeInterval = 0
        @Published private(set) var isStimulusVisible = false
        @Published private(set) var stimulusType: StimulusType = .circle
        @Published private(set) var stimulusPosition: CGPoint = CGPoint(x: 0.5, y: 0.5)
        @Published private(set) var flashColor: FlashColor?
        @Published private(set) var result: RecordPVTResult?

        private let durationSeconds: Int
        private let minIntervalSeconds: TimeInterval = 0.5
        private let maxIntervalSeconds: TimeInterval = 2.5
        private let triangleChanceDivisor = 8

        private var endTime: Date?
        private var shownAt: Date?
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

        func tapStimulus() {
            guard phase == .running, isStimulusVisible else { return }
            timeoutTask?.cancel()
            timeoutTask = nil

            let reactionMS = Int((Date().timeIntervalSince(shownAt ?? Date())) * 1000)
            if stimulusType == .circle {
                if reactionMS >= 100 {
                    correctTaps += 1
                    reactionTimesMS.append(reactionMS)
                    flash(.green)
                } else {
                    incorrectTaps += 1
                    flash(.red)
                }
            } else {
                incorrectTaps += 1
                flash(.red)
            }

            isStimulusVisible = false
            shownAt = nil
            scheduleNext()
        }

        func cancelRun() {
            guard phase == .running else { return }
            reset()
            endTime = nil
            shownAt = nil
            phase = .instructions
        }

        private func reset() {
            cancelTasks()
            remainingSeconds = 0
            isStimulusVisible = false
            stimulusType = .circle
            stimulusPosition = CGPoint(x: 0.5, y: 0.5)
            flashColor = nil
            result = nil

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
                let delay = Double.random(in: minIntervalSeconds...maxIntervalSeconds)
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
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

            stimulusType = Int.random(in: 1...triangleChanceDivisor) == 1 ? .triangle : .circle
            stimulusPosition = CGPoint(x: CGFloat.random(in: 0...1), y: CGFloat.random(in: 0...1))

            isStimulusVisible = true
            shownAt = Date()
            totalStimuli += 1

            timeoutTask?.cancel()
            timeoutTask = Task { [weak self] in
                guard let self else { return }
                let timeoutSeconds = self.stimulusType == .triangle ? 1.0 : max(0.2, AppSettings.pvtResponseTimeoutSeconds)
                let timeoutNS = UInt64(timeoutSeconds * 1_000_000_000)
                try? await Task.sleep(nanoseconds: timeoutNS)
                guard !Task.isCancelled else { return }
                self.handleMiss()
            }
        }

        private func handleMiss() {
            guard phase == .running, isStimulusVisible else { return }
            if stimulusType == .circle {
                misses += 1
                flash(.red)
            }
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
