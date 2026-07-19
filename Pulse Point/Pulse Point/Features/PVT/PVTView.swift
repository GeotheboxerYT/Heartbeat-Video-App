import Charts
import SwiftUI
import UIKit

struct PVTView: View {
    @Environment(\.layoutViewportSize) private var layoutViewportSize
    @StateObject private var viewModel = PVTViewModel()
    @State private var selectedComparisonDayFilter: Date?
    private var stimulusSize: CGFloat { scaled(124) }

    var body: some View {
        ZStack {
            switch viewModel.phase {
            case .setup:
                setupView
            case .running:
                runningView
            case .result:
                resultView
            }
        }
    }

    private var setupView: some View {
        ScrollView {
            VStack(spacing: scaled(16)) {
                Text("Psychomotor Vigilancee Task (PVT)")
                    .font(.system(size: scaled(28), weight: .black, design: .rounded))
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("Choose duration")
                    .font(.system(size: scaled(20), weight: .bold, design: .rounded))
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: scaled(12)) {
                    ForEach(viewModel.durationOptions, id: \.self) { seconds in
                        Button(viewModel.durationButtonTitle(for: seconds)) {
                            viewModel.chooseDuration(seconds)
                        }
                        .buttonStyle(.borderedProminent)
                        .font(.system(size: scaled(18), weight: .bold, design: .rounded))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, scaled(4))
                        .tint(viewModel.selectedDurationSeconds == seconds ? .blue : .gray)
                    }
                }

                VStack(alignment: .leading, spacing: scaled(8)) {
                    Text("When is this test?")
                        .font(.system(size: scaled(18), weight: .bold, design: .rounded))

                    Picker("Timing", selection: $viewModel.selectedWorkoutTiming) {
                        ForEach(PVTSessionRecord.WorkoutTiming.allCases) { timing in
                            Text(timing.title).tag(timing)
                        }
                    }
                    .pickerStyle(.segmented)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if viewModel.selectedWorkoutTiming == .afterWorkout {
                    VStack(alignment: .leading, spacing: scaled(8)) {
                        Text("Select pre-workout PVT")
                            .font(.system(size: scaled(18), weight: .bold, design: .rounded))

                        if viewModel.availableBeforeSessions.isEmpty {
                            Text("No saved pre-workout sessions yet. Run a Before Workout PVT first.")
                                .font(.system(size: scaled(15), weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                        } else {
                            Picker("Pre-workout session", selection: $viewModel.selectedBeforeSessionID) {
                                Text("Select session").tag(Optional<UUID>.none)
                                ForEach(viewModel.availableBeforeSessions) { session in
                                    Text(viewModel.beforeSessionDisplayLabel(for: session))
                                        .tag(Optional(session.id))
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Text("Selected: \(viewModel.selectedBeforeSessionLabel)")
                                .font(.system(size: scaled(14), weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)

                            Text("Each pre-workout session can be used once for comparison.")
                                .font(.system(size: scaled(13), weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button(viewModel.selectedWorkoutTiming == .beforeWorkout ? "Start Before Workout PVT" : "Start After Workout PVT") {
                    viewModel.startFromSetup()
                }
                .buttonStyle(.borderedProminent)
                .font(.system(size: scaled(18), weight: .black, design: .rounded))
                .frame(maxWidth: .infinity)
                .padding(.top, scaled(4))
                .disabled(!viewModel.canStartFromSetup)

                if let status = viewModel.setupStatusMessage {
                    Text(status)
                        .font(.system(size: scaled(15), weight: .semibold, design: .rounded))
                        .foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                comparisonExplorerSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, scaled(10))
            .padding(.vertical, scaled(10))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                        viewModel.cancelRunningTask()
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
            VStack(alignment: .leading, spacing: scaled(12)) {
                Text("PVT Results")
                    .font(.system(size: scaled(28), weight: .black, design: .rounded))

                if let result = viewModel.result {
                    VStack(alignment: .leading, spacing: scaled(8)) {
                        Text("Session: \(result.workoutTiming.title)")
                        Text("Duration: \(viewModel.durationSummaryText(for: result.durationSeconds))")
                        Text("Stimuli shown: \(result.totalStimuliShown)")
                        Text("Correct taps: \(result.correctTaps)")
                        Text("Incorrect taps: \(result.incorrectTaps)")
                        Text("False starts: \(result.falseStarts)")
                        Text("Anticipatory taps (<100ms): \(result.anticipatoryTaps)")
                        Text("Misses: \(result.misses)")
                        Text("Lapses (>=500ms + misses): \(result.lapses)")
                        Text("Mean reaction: \(result.meanReactionMS) ms")
                        Text("Median reaction: \(result.medianReactionMS) ms")
                        Text("Fastest reaction: \(result.fastestReactionMS) ms")
                        Text("Slowest reaction: \(result.slowestReactionMS) ms")
                    }
                    .font(.system(size: scaled(17), weight: .regular, design: .rounded))
                    .padding(scaled(12))
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: scaled(14)))
                }

                if let comparisonSummary = viewModel.comparisonSummary {
                    VStack(alignment: .leading, spacing: scaled(8)) {
                        Text("Before vs After Analysis")
                            .font(.system(size: scaled(19), weight: .black, design: .rounded))
                        Text(comparisonSummary.headline)
                            .font(.system(size: scaled(17), weight: .bold, design: .rounded))
                        Text(comparisonSummary.detail)
                            .font(.system(size: scaled(15), weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("Mean reaction change: \(deltaLabel(for: comparisonSummary.meanDeltaMS, unit: "ms", lowerIsBetter: true))")
                        Text("Lapses change: \(deltaLabel(for: comparisonSummary.lapseDelta, unit: "", lowerIsBetter: true))")
                        Text("False starts change: \(deltaLabel(for: comparisonSummary.falseStartDelta, unit: "", lowerIsBetter: true))")
                        Text("Misses change: \(deltaLabel(for: comparisonSummary.missDelta, unit: "", lowerIsBetter: true))")
                    }
                    .font(.system(size: scaled(16), weight: .semibold, design: .rounded))
                    .padding(scaled(12))
                    .background(Color(.secondarySystemBackground))
                    .clipShape(RoundedRectangle(cornerRadius: scaled(14)))
                }

                Button("Back to Setup") {
                    viewModel.closeResult()
                }
                .buttonStyle(.borderedProminent)
                .font(.system(size: scaled(17), weight: .black, design: .rounded))
                .padding(.top, scaled(6))
            }
            .padding(.horizontal, scaled(10))
            .padding(.vertical, scaled(10))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var comparisonExplorerSection: some View {
        VStack(alignment: .leading, spacing: scaled(10)) {
            Text("Comparison Explorer")
                .font(.system(size: scaled(18), weight: .bold, design: .rounded))

            if viewModel.comparisonSections.isEmpty {
                Text("No saved Before vs After comparisons yet. Complete a before and after pair first.")
                    .font(.system(size: scaled(14), weight: .semibold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: scaled(8)) {
                        ForEach(viewModel.comparisonSections) { section in
                            Button {
                                selectedComparisonDayFilter = section.dayStart
                                viewModel.selectedComparisonAfterSessionID = section.entries.first?.after.id
                            } label: {
                                Text(section.title)
                                    .font(.system(size: scaled(13), weight: .bold, design: .rounded))
                                    .padding(.horizontal, scaled(10))
                                    .padding(.vertical, scaled(6))
                                    .background(isSelectedComparisonDay(section.dayStart) ? Color.blue : Color(.tertiarySystemFill))
                                    .foregroundStyle(isSelectedComparisonDay(section.dayStart) ? .white : .primary)
                                    .clipShape(Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                if let section = activeComparisonSection {
                    Picker("Comparison", selection: $viewModel.selectedComparisonAfterSessionID) {
                        ForEach(section.entries) { pair in
                            Text(viewModel.comparisonEntryLabel(for: pair)).tag(Optional(pair.after.id))
                        }
                    }
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let pair = activeComparisonPair {
                    VStack(alignment: .leading, spacing: scaled(8)) {
                        Text(viewModel.comparisonHeaderLabel(for: pair))
                            .font(.system(size: scaled(12), weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)

                        if let comparison = viewModel.savedResultComparisonText(for: pair.after) {
                            Text(comparison)
                                .font(.system(size: scaled(13), weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        VStack(alignment: .leading, spacing: scaled(6)) {
                            Text("Overall Pattern")
                                .font(.system(size: scaled(14), weight: .bold, design: .rounded))
                            radarComparisonChart(points: viewModel.normalizedSummaryPoints(for: pair))
                            Text("Normalized score (0-100), higher is better.")
                                .font(.system(size: scaled(11), weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                        }

                        VStack(alignment: .leading, spacing: scaled(6)) {
                            Text("Reaction Profile (ms)")
                                .font(.system(size: scaled(14), weight: .bold, design: .rounded))
                            dumbbellComparisonChart(points: viewModel.reactionProfilePoints(for: pair), defaultValueSuffix: " ms")
                        }

                        VStack(alignment: .leading, spacing: scaled(6)) {
                            Text("Error Breakdown")
                                .font(.system(size: scaled(14), weight: .bold, design: .rounded))
                            dumbbellComparisonChart(points: viewModel.errorBreakdownPoints(for: pair))
                        }

                        VStack(alignment: .leading, spacing: scaled(6)) {
                            Text("Output & Accuracy")
                                .font(.system(size: scaled(14), weight: .bold, design: .rounded))
                            dumbbellComparisonChart(points: viewModel.volumeComparisonPoints(for: pair))
                        }

                        VStack(alignment: .leading, spacing: scaled(6)) {
                            Text("All Metrics")
                                .font(.system(size: scaled(14), weight: .bold, design: .rounded))

                            ForEach(viewModel.metricRows(for: pair)) { row in
                                HStack(alignment: .firstTextBaseline, spacing: scaled(6)) {
                                    Text(row.title)
                                        .font(.system(size: scaled(12), weight: .semibold, design: .rounded))
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.85)
                                    Text(row.beforeValue)
                                        .font(.system(size: scaled(12), weight: .bold, design: .rounded))
                                        .foregroundStyle(.blue)
                                        .frame(width: scaled(72), alignment: .trailing)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.85)
                                    Text(row.afterValue)
                                        .font(.system(size: scaled(12), weight: .bold, design: .rounded))
                                        .foregroundStyle(.orange)
                                        .frame(width: scaled(72), alignment: .trailing)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.85)
                                    Text(row.deltaValue)
                                        .font(.system(size: scaled(12), weight: .bold, design: .rounded))
                                        .foregroundStyle(.secondary)
                                        .frame(width: scaled(68), alignment: .trailing)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.85)
                                }
                                .padding(.vertical, scaled(2))
                            }
                        }
                        .padding(.top, scaled(4))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(scaled(12))
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: scaled(14)))
    }

    private func deltaLabel(for value: Int, unit: String, lowerIsBetter: Bool) -> String {
        let sign = value > 0 ? "+" : ""
        let unitSuffix = unit.isEmpty ? "" : " \(unit)"
        let direction: String
        if value == 0 {
            direction = "no change"
        } else if lowerIsBetter {
            direction = value < 0 ? "(better)" : "(worse)"
        } else {
            direction = value > 0 ? "(better)" : "(worse)"
        }
        return "\(sign)\(value)\(unitSuffix) \(direction)"
    }

    private struct ComparisonMetricPair: Identifiable {
        let id: String
        let metric: String
        let before: Double
        let after: Double
    }

    private func radarComparisonChart(points: [PVTViewModel.ComparisonChartPoint]) -> some View {
        let metrics = orderedMetricKeys(from: points)
        let beforeValues = Dictionary(uniqueKeysWithValues: points.filter { $0.sessionLabel == "Before" }.map { ($0.metric, $0.value) })
        let afterValues = Dictionary(uniqueKeysWithValues: points.filter { $0.sessionLabel == "After" }.map { ($0.metric, $0.value) })

        return VStack(spacing: scaled(6)) {
            GeometryReader { geometry in
                let size = min(geometry.size.width, geometry.size.height)
                let center = CGPoint(x: geometry.size.width / 2, y: geometry.size.height / 2)
                let radius = size * 0.34
                let total = max(metrics.count, 1)

                ZStack {
                    ForEach(1...4, id: \.self) { step in
                        let normalized = Double(step) / 4.0
                        Path { path in
                            for index in 0..<total {
                                let point = radarPoint(index: index, total: total, normalized: normalized, center: center, radius: radius)
                                if index == 0 {
                                    path.move(to: point)
                                } else {
                                    path.addLine(to: point)
                                }
                            }
                            path.closeSubpath()
                        }
                        .stroke(Color.white.opacity(0.16), lineWidth: 1)
                    }

                    ForEach(0..<total, id: \.self) { index in
                        Path { path in
                            path.move(to: center)
                            path.addLine(to: radarPoint(index: index, total: total, normalized: 1.0, center: center, radius: radius))
                        }
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    }

                    Path { path in
                        for (index, metric) in metrics.enumerated() {
                            let value = beforeValues[metric] ?? 0
                            let point = radarPoint(
                                index: index,
                                total: total,
                                normalized: max(0, min(1, value / 100)),
                                center: center,
                                radius: radius
                            )
                            if index == 0 {
                                path.move(to: point)
                            } else {
                                path.addLine(to: point)
                            }
                        }
                        path.closeSubpath()
                    }
                    .fill(Color.blue.opacity(0.20))

                    Path { path in
                        for (index, metric) in metrics.enumerated() {
                            let value = beforeValues[metric] ?? 0
                            let point = radarPoint(
                                index: index,
                                total: total,
                                normalized: max(0, min(1, value / 100)),
                                center: center,
                                radius: radius
                            )
                            if index == 0 {
                                path.move(to: point)
                            } else {
                                path.addLine(to: point)
                            }
                        }
                        path.closeSubpath()
                    }
                    .stroke(Color.blue, lineWidth: 2)

                    Path { path in
                        for (index, metric) in metrics.enumerated() {
                            let value = afterValues[metric] ?? 0
                            let point = radarPoint(
                                index: index,
                                total: total,
                                normalized: max(0, min(1, value / 100)),
                                center: center,
                                radius: radius
                            )
                            if index == 0 {
                                path.move(to: point)
                            } else {
                                path.addLine(to: point)
                            }
                        }
                        path.closeSubpath()
                    }
                    .fill(Color.orange.opacity(0.20))

                    Path { path in
                        for (index, metric) in metrics.enumerated() {
                            let value = afterValues[metric] ?? 0
                            let point = radarPoint(
                                index: index,
                                total: total,
                                normalized: max(0, min(1, value / 100)),
                                center: center,
                                radius: radius
                            )
                            if index == 0 {
                                path.move(to: point)
                            } else {
                                path.addLine(to: point)
                            }
                        }
                        path.closeSubpath()
                    }
                    .stroke(Color.orange, lineWidth: 2)

                    ForEach(Array(metrics.enumerated()), id: \.offset) { index, metric in
                        let labelPoint = radarPoint(
                            index: index,
                            total: total,
                            normalized: 1.16,
                            center: center,
                            radius: radius
                        )
                        Text(metric)
                            .font(.system(size: scaled(10), weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .position(labelPoint)
                    }
                }
            }
            .frame(height: scaled(250))

            HStack(spacing: scaled(14)) {
                legendPill(color: .blue, label: "Before")
                legendPill(color: .orange, label: "After")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func dumbbellComparisonChart(
        points: [PVTViewModel.ComparisonChartPoint],
        defaultValueSuffix: String = ""
    ) -> some View {
        let pairs = metricPairs(from: points)
        let allValues = pairs.flatMap { [$0.before, $0.after] }
        let minValue = allValues.min() ?? 0
        let maxValue = allValues.max() ?? 1
        let span = max(1.0, maxValue - minValue)

        return VStack(alignment: .leading, spacing: scaled(8)) {
            HStack(spacing: scaled(14)) {
                legendPill(color: .blue, label: "Before")
                legendPill(color: .orange, label: "After")
            }

            ForEach(pairs) { pair in
                VStack(alignment: .leading, spacing: scaled(3)) {
                    HStack(spacing: scaled(6)) {
                        Text(pair.metric)
                            .font(.system(size: scaled(12), weight: .semibold, design: .rounded))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.9)
                        Spacer(minLength: scaled(4))
                        Text(formattedChartValue(pair.before, metric: pair.metric, defaultSuffix: defaultValueSuffix))
                            .font(.system(size: scaled(11), weight: .bold, design: .rounded))
                            .foregroundStyle(.blue)
                        Image(systemName: "arrow.right")
                            .font(.system(size: scaled(10), weight: .bold))
                            .foregroundStyle(.secondary)
                        Text(formattedChartValue(pair.after, metric: pair.metric, defaultSuffix: defaultValueSuffix))
                            .font(.system(size: scaled(11), weight: .bold, design: .rounded))
                            .foregroundStyle(.orange)
                    }

                    GeometryReader { geometry in
                        let inset = scaled(9)
                        let trackWidth = max(1, geometry.size.width - (inset * 2))
                        let y = geometry.size.height / 2
                        let beforeX = inset + (CGFloat((pair.before - minValue) / span) * trackWidth)
                        let afterX = inset + (CGFloat((pair.after - minValue) / span) * trackWidth)

                        ZStack {
                            Capsule()
                                .fill(Color.white.opacity(0.12))
                                .frame(height: scaled(4))
                                .padding(.horizontal, inset)

                            Path { path in
                                path.move(to: CGPoint(x: min(beforeX, afterX), y: y))
                                path.addLine(to: CGPoint(x: max(beforeX, afterX), y: y))
                            }
                            .stroke(Color.white.opacity(0.35), lineWidth: scaled(2.5))

                            Circle()
                                .fill(Color.blue)
                                .frame(width: scaled(10), height: scaled(10))
                                .position(x: beforeX, y: y)

                            Circle()
                                .fill(Color.orange)
                                .frame(width: scaled(10), height: scaled(10))
                                .position(x: afterX, y: y)
                        }
                    }
                    .frame(height: scaled(18))
                }
            }

            HStack {
                Text(formattedAxisValue(minValue, defaultSuffix: defaultValueSuffix))
                Spacer()
                Text(formattedAxisValue(maxValue, defaultSuffix: defaultValueSuffix))
            }
            .font(.system(size: scaled(10), weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .padding(.top, scaled(2))
        }
    }

    private func radarPoint(
        index: Int,
        total: Int,
        normalized: Double,
        center: CGPoint,
        radius: CGFloat
    ) -> CGPoint {
        guard total > 0 else { return center }
        let safeNormalized = max(0, normalized)
        let angleStep = (Double.pi * 2.0) / Double(total)
        let angle = (-Double.pi / 2.0) + (Double(index) * angleStep)
        let cgAngle = CGFloat(angle)
        let length = CGFloat(safeNormalized) * radius
        return CGPoint(
            x: center.x + (CoreGraphics.cos(cgAngle) * length),
            y: center.y + (CoreGraphics.sin(cgAngle) * length)
        )
    }

    private func legendPill(color: Color, label: String) -> some View {
        HStack(spacing: scaled(6)) {
            Circle()
                .fill(color)
                .frame(width: scaled(7), height: scaled(7))
            Text(label)
                .font(.system(size: scaled(11), weight: .bold, design: .rounded))
        }
        .padding(.horizontal, scaled(8))
        .padding(.vertical, scaled(4))
        .background(Color(.tertiarySystemFill))
        .clipShape(Capsule())
    }

    private func metricPairs(from points: [PVTViewModel.ComparisonChartPoint]) -> [ComparisonMetricPair] {
        let beforeValues = Dictionary(uniqueKeysWithValues: points.filter { $0.sessionLabel == "Before" }.map { ($0.metric, $0.value) })
        let afterValues = Dictionary(uniqueKeysWithValues: points.filter { $0.sessionLabel == "After" }.map { ($0.metric, $0.value) })
        return orderedMetricKeys(from: points).map { metric in
            ComparisonMetricPair(
                id: metric,
                metric: metric,
                before: beforeValues[metric] ?? 0,
                after: afterValues[metric] ?? 0
            )
        }
    }

    private func orderedMetricKeys(from points: [PVTViewModel.ComparisonChartPoint]) -> [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for point in points where !seen.contains(point.metric) {
            seen.insert(point.metric)
            ordered.append(point.metric)
        }
        return ordered
    }

    private func formattedChartValue(
        _ value: Double,
        metric: String,
        defaultSuffix: String
    ) -> String {
        let suffix: String
        if metric.contains("%") {
            suffix = "%"
        } else {
            suffix = defaultSuffix
        }

        let text: String
        if abs(value.rounded() - value) < 0.01 {
            text = "\(Int(value.rounded()))"
        } else {
            text = String(format: "%.1f", value)
        }
        return "\(text)\(suffix)"
    }

    private func formattedAxisValue(_ value: Double, defaultSuffix: String) -> String {
        let text: String
        if abs(value.rounded() - value) < 0.01 {
            text = "\(Int(value.rounded()))"
        } else {
            text = String(format: "%.1f", value)
        }
        return "\(text)\(defaultSuffix)"
    }

    private var activeComparisonSection: PVTViewModel.ComparisonDaySection? {
        let sections = viewModel.comparisonSections
        guard !sections.isEmpty else { return nil }
        guard let selectedComparisonDayFilter else { return sections.first }
        return sections.first { Calendar.current.isDate($0.dayStart, inSameDayAs: selectedComparisonDayFilter) } ?? sections.first
    }

    private var activeComparisonPair: PVTViewModel.ComparisonPair? {
        guard let section = activeComparisonSection else { return nil }
        if let selectedID = viewModel.selectedComparisonAfterSessionID,
           let match = section.entries.first(where: { $0.after.id == selectedID }) {
            return match
        }
        return section.entries.first
    }

    private func isSelectedComparisonDay(_ day: Date) -> Bool {
        guard let selectedComparisonDayFilter else {
            return activeComparisonSection?.dayStart == day
        }
        return Calendar.current.isDate(selectedComparisonDayFilter, inSameDayAs: day)
    }

    private func autoYDomain(for points: [PVTViewModel.ComparisonChartPoint]) -> ClosedRange<Double> {
        let values = points.map(\.value)
        guard let minValue = values.min(), let maxValue = values.max() else {
            return 0...100
        }
        let padding = max(1.0, (maxValue - minValue) * 0.15)
        let lower = max(0, minValue - padding)
        let upper = max(lower + 1, maxValue + padding)
        return lower...upper
    }

    private func stimulusPoint(in size: CGSize) -> CGPoint {
        let margin = stimulusSize / 2
        let usableWidth = max(1, size.width - (margin * 2))
        let usableHeight = max(1, size.height - (margin * 2))
        let x = margin + (viewModel.stimulusPosition.x * usableWidth)
        let y = margin + (viewModel.stimulusPosition.y * usableHeight)
        return CGPoint(x: x, y: y)
    }

    @ViewBuilder
    private func shapeView(stimulusType: PVTViewModel.StimulusType) -> some View {
        let stimulusColor = Color(
            red: viewModel.stimulusColor.red,
            green: viewModel.stimulusColor.green,
            blue: viewModel.stimulusColor.blue
        )

        if stimulusType == .circle {
            Circle()
                .fill(stimulusColor)
        } else {
            Triangle()
                .fill(stimulusColor)
        }
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

#Preview {
    PVTView()
}
