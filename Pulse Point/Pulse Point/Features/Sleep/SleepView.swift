import SwiftUI

struct SleepView: View {
    @StateObject private var viewModel = SleepViewModel()

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                Text("Sleep")
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)

                sourceCard
                trackingCard
                liveCard
                nightsCard

                if let night = viewModel.selectedNight {
                    sleepTrendCard(
                        analysis: night.metadata.analysis,
                        samples: viewModel.selectedNightSamples
                    )
                    reconstructionCard(for: night.metadata.analysis)
                    recoveryCard(for: night.metadata.analysis)
                    readinessCard(for: night.metadata.analysis)
                } else {
                    emptyStateCard
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task {
            await viewModel.prepare()
        }
    }

    private var sourceCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Heart-Rate Source")
                .font(.headline)

            Picker("Source", selection: $viewModel.selectedHeartRateSource) {
                ForEach(HeartRateInputSource.allCases) { source in
                    Text(source.title).tag(source)
                }
            }
            .pickerStyle(.segmented)

            switch viewModel.selectedHeartRateSource {
            case .bluetooth:
                HStack(spacing: 10) {
                    Menu {
                        Button("Auto") {
                            viewModel.selectedBluetoothDeviceID = nil
                        }

                        if !viewModel.availableBluetoothDevices.isEmpty {
                            Divider()
                        }

                        ForEach(viewModel.availableBluetoothDevices) { device in
                            Button {
                                viewModel.selectedBluetoothDeviceID = device.id
                            } label: {
                                if viewModel.selectedBluetoothDeviceID == device.id {
                                    Label(device.displayName, systemImage: "checkmark")
                                } else {
                                    Text(device.displayName)
                                }
                            }
                        }
                    } label: {
                        Label(selectedDeviceLabel, systemImage: "dot.radiowaves.left.and.right")
                            .lineLimit(1)
                    }

                    Button {
                        viewModel.rescanBluetoothDevices()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                }

            case .appleWatch:
                Button("Health Access") {
                    viewModel.requestAppleHealthAccess()
                }
                .buttonStyle(.bordered)
            }

            Text(viewModel.heartRateStatusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var trackingCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(viewModel.isTracking ? "Sleep Session Active" : "Sleep Session")
                    .font(.headline)
                Spacer()
                Text(viewModel.elapsedLabel)
                    .font(.system(.body, design: .monospaced).weight(.semibold))
            }

            if let recoveryNotice = viewModel.recoveryNotice {
                Text(recoveryNotice)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }

            Text(viewModel.backgroundTrackingNote)
                .font(.caption)
                .foregroundStyle(.secondary)

            Button {
                if viewModel.isTracking {
                    viewModel.stopSleepTracking()
                } else {
                    viewModel.startSleepTracking()
                }
            } label: {
                Label(
                    viewModel.isTracking ? "Stop Sleep Tracking" : "Start Sleep Tracking",
                    systemImage: viewModel.isTracking ? "stop.fill" : "moon.stars.fill"
                )
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canStart && !viewModel.isTracking)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var liveCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(viewModel.currentBPM) BPM")
                    .font(.system(size: 20, weight: .black, design: .rounded))
                    .foregroundStyle(bpmZoneColor(for: viewModel.currentBPM))
                Spacer()
                Text(viewModel.isHeartRateConnected ? "Connected" : "Waiting")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(viewModel.isHeartRateConnected ? .green : .orange)
            }

            if viewModel.liveBPMGraphPoints.isEmpty {
                Text("Live overnight graph appears after incoming heart-rate samples.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            } else {
                LiveHeartRateGraphOverlayView(bpmPoints: viewModel.liveBPMGraphPoints)
                    .frame(height: 120)
                    .background(Color.black.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var nightsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recent Nights")
                .font(.headline)

            if viewModel.nights.isEmpty {
                Text("No sleep sessions yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.nights) { night in
                    Button {
                        viewModel.selectedNightID = night.id
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(night.metadata.startedAt.formatted(date: .abbreviated, time: .shortened))
                                    .font(.subheadline.weight(.semibold))
                                Text("Sleep \(formatDuration(night.metadata.analysis.totalSleepTimeSeconds)) • Readiness \(night.metadata.analysis.readinessScore)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("\(night.sampleCount)")
                                .font(.caption2.bold())
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.black.opacity(0.08))
                                .clipShape(Capsule())
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(viewModel.selectedNightID == night.id ? Color.accentColor.opacity(0.16) : Color.black.opacity(0.05))
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func sleepTrendCard(analysis: SleepAnalysisReport, samples: [HeartRateSample]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sleep Trend Graph")
                .font(.headline)

            if samples.count < 2 {
                Text("Not enough overnight samples to draw trend lines yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 150, alignment: .center)
            } else {
                SleepTrendGraphView(
                    samples: samples,
                    onsetSeconds: analysis.sleepOnsetSeconds,
                    awakeningMoments: analysis.estimatedAwakeningMomentsSeconds ?? []
                )
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            HStack(spacing: 12) {
                legendDot(.red, "Raw HR")
                legendDot(.cyan, "Trend")
                legendDot(.yellow, "Onset")
                legendDot(.orange, "Awakening")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func reconstructionCard(for analysis: SleepAnalysisReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sleep Reconstruction")
                .font(.headline)
            metricRow("Total Sleep Time", formatDuration(analysis.totalSleepTimeSeconds))
            metricRow("Time In Bed", formatDuration(analysis.timeInBedSeconds))
            metricRow("Sleep Efficiency", "\(Int(analysis.sleepEfficiencyPercent.rounded()))%")
            metricRow("Sleep Latency", formatDuration(analysis.sleepLatencySeconds))
            metricRow("WASO", formatDuration(analysis.wakeAfterSleepOnsetSeconds))
            metricRow("Estimated Awakenings", "\(analysis.estimatedAwakenings)")
            metricRow("Deep / Light / REM-like", "\(Int(analysis.deepSleepPercent.rounded()))% / \(Int(analysis.lightSleepPercent.rounded()))% / \(Int(analysis.remLikePercent.rounded()))%")
            Divider()
            Text(analysis.reconstructionSummary)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func recoveryCard(for analysis: SleepAnalysisReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Recovery Metrics")
                .font(.headline)
            metricRow("Resting HR", "\(analysis.restingHeartRate) bpm")
            metricRow("Average Sleep HR", "\(analysis.averageSleepHeartRate) bpm")
            metricRow("Overnight HR Drop", "\(String(format: "%.1f", analysis.overnightHeartRateDropPercent))%")
            metricRow("HRV Proxy (RMSSD)", "\(String(format: "%.1f", analysis.hrvRMSSD)) ms")
            metricRow("Recovery Score", "\(analysis.recoveryScore) / 100")
            Divider()
            Text(analysis.recoverySummary)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func readinessCard(for analysis: SleepAnalysisReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Performance / Readiness")
                .font(.headline)
            Text("\(analysis.readinessScore)")
                .font(.system(size: 44, weight: .black, design: .rounded))
                .foregroundStyle(readinessColor(for: analysis.readinessScore))
            Text(analysis.readinessLabel)
                .font(.subheadline.weight(.semibold))
            Text(analysis.readinessSummary)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var emptyStateCard: some View {
        Text("Start a sleep session to generate sleep reconstruction, recovery metrics, and readiness score.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var selectedDeviceLabel: String {
        guard let selectedID = viewModel.selectedBluetoothDeviceID,
              let selected = viewModel.availableBluetoothDevices.first(where: { $0.id == selectedID }) else {
            return "Auto"
        }
        return selected.displayName
    }

    private func metricRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
        }
        .font(.footnote)
    }

    private func legendDot(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
        }
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return "\(hours)h \(minutes)m"
    }

    private func bpmZoneColor(for bpm: Int) -> Color {
        guard bpm > 0 else { return .secondary }
        switch HeartRateZone.zone(for: bpm) {
        case .easy:
            return .gray
        case .light:
            return Color(red: 0.47, green: 0.82, blue: 0.98)
        case .aerobic:
            return .green
        case .hard:
            return .yellow
        case .peak:
            return .red
        }
    }

    private func readinessColor(for score: Int) -> Color {
        switch score {
        case 85...100:
            return .green
        case 70..<85:
            return .mint
        case 50..<70:
            return .yellow
        default:
            return .orange
        }
    }
}

private struct SleepTrendGraphView: View {
    let samples: [HeartRateSample]
    let onsetSeconds: TimeInterval?
    let awakeningMoments: [TimeInterval]

    private let dangerLowBPM: Double = 35
    private let hardFloorBPM: Double = 30
    private let hardCeilingBPM: Double = 120
    private let targetLowBPM: Double = 40
    private let targetHighBPM: Double = 100

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let duration = max(samples.last?.t ?? 0, 1)
            let raw = downsample(samples: samples, maxPoints: 500)
            let trend = movingAverage(samples: raw, window: max(5, raw.count / 30))
            let range = bpmRange(raw: raw, trend: trend)

            ZStack(alignment: .topLeading) {
                sleepBands(in: size, range: range)
                horizontalGrid(in: size, range: range)

                linePath(samples: raw, duration: duration, in: size, range: range)
                    .stroke(Color.red.opacity(0.85), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))

                linePath(samples: trend, duration: duration, in: size, range: range)
                    .stroke(Color.cyan, style: StrokeStyle(lineWidth: 2.0, lineJoin: .round))

                if let onsetSeconds {
                    verticalMarker(
                        x: xPosition(time: onsetSeconds, duration: duration, width: size.width),
                        in: size,
                        color: .yellow
                    )
                }

                ForEach(Array(awakeningMoments.prefix(24).enumerated()), id: \.offset) { _, wakeTime in
                    verticalMarker(
                        x: xPosition(time: wakeTime, duration: duration, width: size.width),
                        in: size,
                        color: .orange
                    )
                }

                axisLabels(duration: duration, in: size, range: range)
            }
            .background(Color.black.opacity(0.10))
        }
    }

    private func sleepBands(in size: CGSize, range: ClosedRange<Double>) -> some View {
        ZStack {
            let lowDangerUpper = min(dangerLowBPM, range.upperBound)
            if lowDangerUpper > range.lowerBound {
                let yLow = yPosition(bpm: range.lowerBound, height: size.height, range: range)
                let yDanger = yPosition(bpm: lowDangerUpper, height: size.height, range: range)
                let top = min(yLow, yDanger)
                let height = max(1, abs(yLow - yDanger))

                Rectangle()
                    .fill(Color.red.opacity(0.18))
                    .frame(height: height)
                    .offset(y: top)
            }
        }
    }

    private func horizontalGrid(in size: CGSize, range: ClosedRange<Double>) -> some View {
        let marks = gridMarks(for: range)
        return Path { path in
            for bpm in marks {
                let y = yPosition(bpm: bpm, height: size.height, range: range)
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
        }
        .stroke(Color.white.opacity(0.18), style: StrokeStyle(lineWidth: 0.7))
    }

    private func linePath(samples: [HeartRateSample], duration: TimeInterval, in size: CGSize, range: ClosedRange<Double>) -> Path {
        Path { path in
            guard let first = samples.first else { return }
            path.move(
                to: CGPoint(
                    x: xPosition(time: first.t, duration: duration, width: size.width),
                    y: yPosition(bpm: Double(first.bpm), height: size.height, range: range)
                )
            )
            for sample in samples.dropFirst() {
                path.addLine(
                    to: CGPoint(
                        x: xPosition(time: sample.t, duration: duration, width: size.width),
                        y: yPosition(bpm: Double(sample.bpm), height: size.height, range: range)
                    )
                )
            }
        }
    }

    private func verticalMarker(x: CGFloat, in size: CGSize, color: Color) -> some View {
        Path { path in
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))
        }
        .stroke(color.opacity(0.9), style: StrokeStyle(lineWidth: 1.0, dash: [3, 3]))
    }

    private func axisLabels(duration: TimeInterval, in size: CGSize, range: ClosedRange<Double>) -> some View {
        ZStack {
            VStack {
                HStack {
                    Text("\(Int(range.upperBound.rounded()))")
                    Spacer()
                }
                Spacer()
                HStack {
                    if range.lowerBound < dangerLowBPM {
                        Text("Danger < \(Int(dangerLowBPM.rounded()))")
                            .foregroundStyle(.red.opacity(0.95))
                    } else {
                        Text("\(Int(range.lowerBound.rounded()))")
                    }
                    Spacer()
                }
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white.opacity(0.8))
            .padding(.horizontal, 6)
            .padding(.vertical, 4)

            VStack {
                Spacer()
                HStack {
                    Text("0h")
                    Spacer()
                    Text(timeLabel(duration * 0.5))
                    Spacer()
                    Text(timeLabel(duration))
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 8)
                .padding(.bottom, 4)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func xPosition(time: TimeInterval, duration: TimeInterval, width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        let ratio = max(0, min(1, time / duration))
        return CGFloat(ratio) * width
    }

    private func yPosition(bpm: Double, height: CGFloat, range: ClosedRange<Double>) -> CGFloat {
        let clamped = max(range.lowerBound, min(range.upperBound, bpm))
        let ratio = (clamped - range.lowerBound) / (range.upperBound - range.lowerBound)
        return height - (CGFloat(ratio) * height)
    }

    private func bpmRange(raw: [HeartRateSample], trend: [HeartRateSample]) -> ClosedRange<Double> {
        let all = raw + trend
        let observedMin = Double(all.map(\.bpm).min() ?? Int(targetLowBPM))
        let observedMax = Double(all.map(\.bpm).max() ?? Int(targetHighBPM))

        var lower = min(targetLowBPM, observedMin - 6)
        var upper = max(targetHighBPM, observedMax + 8)

        lower = max(hardFloorBPM, lower)
        upper = min(hardCeilingBPM, upper)

        if upper - lower < 24 {
            upper = min(hardCeilingBPM, lower + 24)
        }
        if lower >= upper {
            lower = hardFloorBPM
            upper = targetHighBPM
        }
        return lower...upper
    }

    private func gridMarks(for range: ClosedRange<Double>) -> [Double] {
        let span = range.upperBound - range.lowerBound
        let step: Double
        switch span {
        case ..<30:
            step = 5
        case ..<50:
            step = 10
        case ..<80:
            step = 15
        default:
            step = 20
        }

        var marks: [Double] = [range.lowerBound, range.upperBound]
        if dangerLowBPM > range.lowerBound && dangerLowBPM < range.upperBound {
            marks.append(dangerLowBPM)
        }

        var next = (floor(range.lowerBound / step) + 1) * step
        while next < range.upperBound {
            marks.append(next)
            next += step
        }

        marks.sort()
        var deduped: [Double] = []
        deduped.reserveCapacity(marks.count)
        for mark in marks {
            if let last = deduped.last, abs(last - mark) < 0.5 {
                continue
            }
            deduped.append(mark)
        }
        return deduped
    }

    private func downsample(samples: [HeartRateSample], maxPoints: Int) -> [HeartRateSample] {
        guard samples.count > maxPoints else { return samples }
        let step = max(1, samples.count / maxPoints)
        var result: [HeartRateSample] = []
        result.reserveCapacity(maxPoints + 1)
        var index = 0
        while index < samples.count {
            result.append(samples[index])
            index += step
        }
        if result.last?.t != samples.last?.t, let last = samples.last {
            result.append(last)
        }
        return result
    }

    private func movingAverage(samples: [HeartRateSample], window: Int) -> [HeartRateSample] {
        guard !samples.isEmpty else { return [] }
        let clampedWindow = max(1, window)
        guard clampedWindow > 1 else { return samples }

        var result: [HeartRateSample] = []
        result.reserveCapacity(samples.count)
        var sum = 0.0
        var queue: [Double] = []
        queue.reserveCapacity(clampedWindow)

        for sample in samples {
            let value = Double(sample.bpm)
            sum += value
            queue.append(value)

            if queue.count > clampedWindow {
                sum -= queue.removeFirst()
            }

            let avg = sum / Double(queue.count)
            result.append(HeartRateSample(t: sample.t, bpm: Int(avg.rounded())))
        }
        return result
    }

    private func timeLabel(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        return String(format: "%dh %02dm", hours, minutes)
    }

}

#Preview {
    SleepView()
}
