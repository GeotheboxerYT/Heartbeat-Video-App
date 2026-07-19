import AVKit
import Charts
import SwiftUI

struct PlaybackView: View {
    @EnvironmentObject private var authStore: AuthStore
    @Environment(\.layoutViewportSize) private var layoutViewportSize
    @StateObject private var viewModel = PlaybackViewModel()
    @AppStorage(AppSettings.Keys.chartScrubMode) private var chartScrubMode = "normal"
    @State private var selectedDayFilter: Date?
    @State private var showDeleteConfirmation = false
    @State private var showFullscreenVideo = false

    var body: some View {
        ScrollView {
            VStack(spacing: scaled(14)) {
                Text("Review")
                    .font(.title2.bold())
                    .frame(maxWidth: .infinity, alignment: .leading)

                sessionsCard

                if viewModel.selectedSession != nil {
                    summaryCard
                    statsCard
                    videoCard
                    syncActionCard
                    if viewModel.selectedSessionHasVideo {
                        controlsCard
                    }
                    deleteSessionCard
                } else {
                    Text("Record a session to start review.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(scaled(12))
                        .background(Color(.secondarySystemBackground))
                        .clipShape(RoundedRectangle(cornerRadius: scaled(14)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, scaled(4))
            .padding(.vertical, scaled(8))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            syncViewModelUser()
            viewModel.updateParticipantOwnerKey(currentOwnerKey)
            viewModel.loadSessions()
        }
        .onChange(of: authStore.currentUserEmail) { _, _ in
            syncViewModelUser()
            viewModel.updateParticipantOwnerKey(currentOwnerKey)
            viewModel.loadSessions(forceReloadSelected: true)
        }
        .onChange(of: authStore.currentUsername) { _, _ in
            syncViewModelUser()
            viewModel.updateParticipantOwnerKey(currentOwnerKey)
        }
        .onChange(of: authStore.currentFirebaseUID) { _, _ in
            syncViewModelUser()
        }
        .onChange(of: viewModel.sessionSections.map(\.dayStart)) { _, _ in
            guard let selectedDayFilter else { return }
            let stillAvailable = viewModel.sessionSections.contains { section in
                Calendar.current.isDate(section.dayStart, inSameDayAs: selectedDayFilter)
            }
            if !stillAvailable {
                self.selectedDayFilter = nil
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("SessionLibraryDidChange"))) { _ in
            viewModel.loadSessions()
        }
        .onReceive(NotificationCenter.default.publisher(for: .pauseReviewPlayback)) { _ in
            viewModel.pausePlaybackIfNeeded()
        }
        .alert("Delete this session from this device?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                viewModel.deleteSelectedSession()
            }
        } message: {
            Text("This deletes only the selected session and frees storage on this phone.")
        }
        .fullScreenCover(isPresented: $showFullscreenVideo) {
            PlaybackFullscreenVideoView(
                player: viewModel.player,
                isPresented: $showFullscreenVideo
            )
        }
    }

    private var sessionsCard: some View {
        VStack(alignment: .leading, spacing: scaled(10)) {
            HStack {
                Text("Sessions")
                    .font(.headline)

                Spacer()

                if viewModel.isLoadingSessions {
                    ProgressView()
                        .controlSize(.small)
                }

                Button {
                    viewModel.refreshSessions()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
            }

            Text(viewModel.lastRefreshLabel)
                .font(.caption)
                .foregroundStyle(.secondary)

            Menu {
                Button("All Dates") {
                    selectedDayFilter = nil
                }
                ForEach(viewModel.sessionSections) { section in
                    Button(section.title) {
                        selectedDayFilter = section.dayStart
                    }
                }
            } label: {
                Label(dayFilterLabel, systemImage: "calendar")
                    .font(.caption)
            }
            .buttonStyle(.bordered)

            if let pendingBannerText = viewModel.pendingBannerText {
                HStack(spacing: scaled(8)) {
                    ProgressView()
                        .controlSize(.small)
                    Text(pendingBannerText)
                        .font(.caption)
                }
                .padding(scaled(8))
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.yellow.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: scaled(10)))
            }

            if viewModel.sessionSections.isEmpty {
                Text("No sessions found yet.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(filteredSessionSections) { section in
                    VStack(alignment: .leading, spacing: scaled(6)) {
                        Text(section.title)
                            .font(.caption.bold())
                            .foregroundStyle(.secondary)

                        ForEach(section.entries) { entry in
                            Button {
                                viewModel.selectSession(id: entry.id)
                            } label: {
                                HStack(spacing: scaled(10)) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(viewModel.sessionTimeLabel(for: entry))
                                            .font(.subheadline.weight(.semibold))
                                        Text(viewModel.sessionMetaLabel(for: entry))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }

                                    Spacer()

                                    syncIndicator(for: entry)
                                }
                                .padding(.horizontal, scaled(10))
                                .padding(.vertical, scaled(8))
                                .background(
                                    viewModel.selectedSessionID == entry.id
                                        ? Color.accentColor.opacity(0.17)
                                        : Color.black.opacity(0.06)
                                )
                                .clipShape(RoundedRectangle(cornerRadius: scaled(10)))
                            }
                            .buttonStyle(.plain)
                            .disabled(viewModel.isLoadingSelectedSession)
                        }
                    }
                }

                if filteredSessionSections.isEmpty {
                    Text("No sessions for this date.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(scaled(12))
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: scaled(14)))
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: scaled(8)) {
            Text("Session Summary")
                .font(.headline)

            HStack {
                Text("Date")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(viewModel.selectedSessionDateLabel)
                    .fontWeight(.semibold)
            }
            .font(.footnote)

            HStack {
                Text("Sync")
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: scaled(6)) {
                    if let selectedSession = viewModel.selectedSession {
                        Image(systemName: viewModel.syncSymbol(for: selectedSession))
                            .foregroundStyle(syncColor(for: selectedSession.syncState))
                    }
                    Text(viewModel.selectedSessionSyncLabel)
                        .fontWeight(.semibold)
                }
            }
            .font(.footnote)

            HStack {
                Text("Type")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(viewModel.selectedSessionTypeLabel)
                    .fontWeight(.semibold)
            }
            .font(.footnote)

            HStack {
                Text("Duration")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(viewModel.summaryDurationLabel)
                    .fontWeight(.semibold)
            }
            .font(.footnote)

            HStack {
                Text("HR Samples")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(viewModel.summarySampleCountLabel)
                    .fontWeight(.semibold)
            }
            .font(.footnote)

            Divider()

            Text(viewModel.trainingTypeTitle)
                .font(.subheadline.bold())
            Text(viewModel.trainingTypeDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(scaled(12))
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: scaled(14)))
    }

    private var syncActionCard: some View {
        VStack(alignment: .leading, spacing: scaled(8)) {
            HStack {
                Text("API Sync")
                    .font(.headline)
                Spacer()
                if viewModel.isRetryingSync {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            Text("Local save and API upload are tracked separately. If API upload fails, your session can still be safe on this phone.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let selectedSession = viewModel.selectedSession,
               let message = selectedSession.syncErrorMessage,
               !message.isEmpty {
                Text("Last API error: \(message)")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                viewModel.retrySelectedSessionSync()
            } label: {
                Label("Retry API Upload", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, scaled(6))
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canRetrySelectedSessionSync)

            if let syncActionMessage = viewModel.syncActionMessage {
                Text(syncActionMessage)
                    .font(.caption)
                    .foregroundStyle(syncActionMessage.contains("failed") ? .red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(scaled(12))
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: scaled(14)))
    }

    private var videoCard: some View {
        Group {
            if viewModel.selectedSessionHasVideo {
                ZStack(alignment: .bottom) {
                    VideoPlayer(player: viewModel.player)
                        .frame(maxWidth: .infinity, minHeight: scaled(300))

                    chartView(height: scaled(92), overlayStyle: true)
                        .padding(.horizontal, scaled(72))
                        .padding(.bottom, scaled(10))

                    if viewModel.isLoadingSelectedSession {
                        ZStack {
                            Color.black.opacity(0.35)
                            VStack(spacing: 8) {
                                ProgressView()
                                Text("Loading session...")
                                    .font(.caption)
                                    .foregroundStyle(.white)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }

                    VStack {
                        if viewModel.hasMultipleDeviceSeries {
                            HStack(alignment: .top) {
                                if let first = comparisonReading(at: 0) {
                                    comparisonVideoOverlayBadge(for: first, index: 0, alignLeading: true)
                                }

                                Spacer(minLength: 0)

                                if let second = comparisonReading(at: 1) {
                                    comparisonVideoOverlayBadge(for: second, index: 1, alignLeading: false)
                                }
                            }

                            HStack {
                                Spacer()
                                fullscreenButton
                            }
                        } else {
                            HStack(alignment: .top) {
                                bpmVideoOverlayBadge

                                Spacer()
                                fullscreenButton
                            }
                        }
                        Spacer()
                    }
                    .padding(scaled(10))
                }
                .clipShape(RoundedRectangle(cornerRadius: scaled(14)))
            } else {
                VStack(alignment: .leading, spacing: scaled(8)) {
                    Text("Data-only session (no video)")
                        .font(.subheadline.weight(.semibold))
                    chartView(height: scaled(168), overlayStyle: false)
                        .padding(.horizontal, scaled(48))
                }
                .padding(scaled(12))
                .background(Color(.secondarySystemBackground))
                .clipShape(RoundedRectangle(cornerRadius: scaled(14)))
            }
        }
    }

    private var bpmVideoOverlayBadge: some View {
        VStack(alignment: .leading, spacing: 4) {
            if viewModel.hasMultipleDeviceSeries {
                ForEach(Array(viewModel.displayedDeviceReadings.prefix(2).enumerated()), id: \.element.id) { index, reading in
                    HStack(spacing: 6) {
                        Text(reading.displayName)
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Text("\(reading.bpm)")
                            .fontWeight(.bold)
                    }
                    .font(.system(size: scaled(10), weight: .semibold, design: .rounded))
                    .foregroundStyle(lineColor(for: index, overlayStyle: true))
                }
            } else {
                Text("\(viewModel.displayedBPM) BPM")
                    .font(.system(size: scaled(13), weight: .bold, design: .rounded))
                    .foregroundStyle(bpmZoneColor(for: viewModel.displayedBPM))
            }
        }
        .padding(.horizontal, scaled(10))
        .padding(.vertical, scaled(6))
        .background(Color.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: scaled(10)))
    }

    private var fullscreenButton: some View {
        Button {
            showFullscreenVideo = true
        } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: scaled(14), weight: .bold))
                .foregroundStyle(.white)
                .padding(scaled(9))
                .background(Color.black.opacity(0.55))
                .clipShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private func comparisonReading(at index: Int) -> ConnectedHeartRateReading? {
        let readings = Array(viewModel.displayedDeviceReadings.prefix(2))
        guard index >= 0, index < readings.count else { return nil }
        return readings[index]
    }

    private func comparisonVideoOverlayBadge(
        for reading: ConnectedHeartRateReading,
        index: Int,
        alignLeading: Bool
    ) -> some View {
        VStack(alignment: alignLeading ? .leading : .trailing, spacing: 4) {
            Text(reading.displayName)
                .lineLimit(1)
                .truncationMode(.tail)

            Text("\(reading.bpm) BPM")
                .fontWeight(.bold)
                .foregroundStyle(lineColor(for: index, overlayStyle: true))
        }
        .font(.system(size: scaled(10), weight: .semibold, design: .rounded))
        .padding(.horizontal, scaled(10))
        .padding(.vertical, scaled(6))
        .background(Color.black.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: scaled(10)))
        .frame(maxWidth: scaled(150), alignment: alignLeading ? .leading : .trailing)
    }

    private var statsCard: some View {
        VStack(spacing: scaled(8)) {
            if viewModel.hasMultipleDeviceSeries {
                HStack {
                    Text(viewModel.timeLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                }

                ForEach(Array(viewModel.displayedDeviceReadings.prefix(2).enumerated()), id: \.element.id) { index, reading in
                    HStack(spacing: scaled(8)) {
                        Text(reading.displayName)
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.tail)

                        Spacer()

                        Text("\(reading.bpm) BPM")
                            .font(.caption.bold())
                            .foregroundStyle(lineColor(for: index, overlayStyle: false))
                    }
                }
            } else {
                HStack {
                    Text("\(viewModel.displayedBPM) BPM")
                        .font(.system(size: scaled(13), weight: .bold, design: .rounded))
                        .foregroundStyle(bpmZoneColor(for: viewModel.displayedBPM))
                    Spacer()
                    Text(viewModel.timeLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: scaled(8)) {
                    statPill(title: "Min", value: "\(viewModel.minBPM)")
                    statPill(title: "Avg", value: "\(viewModel.avgBPM)")
                    statPill(title: "Max", value: "\(viewModel.maxBPM)")
                }
            }
        }
        .padding(scaled(12))
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: scaled(14)))
    }

    private var controlsCard: some View {
        VStack(spacing: scaled(10)) {
            HStack(spacing: scaled(10)) {
                Button("-5s") {
                    viewModel.jump(seconds: -5)
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)

                Button {
                    viewModel.togglePlayback()
                } label: {
                    Image(systemName: viewModel.player.timeControlStatus == .playing ? "pause.fill" : "play.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, scaled(6))
                }
                .buttonStyle(.borderedProminent)

                Button("+5s") {
                    viewModel.jump(seconds: 5)
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
            }

            HStack(spacing: scaled(10)) {
                Button("- Frame") {
                    viewModel.stepFrame(forward: false)
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)

                Button("+ Frame") {
                    viewModel.stepFrame(forward: true)
                }
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
            }

            Button {
                viewModel.exportSelectedVideoToPhotoLibrary()
            } label: {
                HStack {
                    if viewModel.isExportingOverlayVideo {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "square.and.arrow.down")
                    }
                    Text(viewModel.isExportingOverlayVideo ? "Saving to Photos..." : "Save to Photos (BPM Overlay)")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, scaled(6))
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canExportSelectedSessionVideo)

            if let exportStatusMessage = viewModel.exportStatusMessage {
                Text(exportStatusMessage)
                    .font(.caption)
                    .foregroundStyle(exportStatusMessage.hasPrefix("Export failed") ? .red : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(scaled(12))
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: scaled(14)))
    }

    private var deleteSessionCard: some View {
        VStack(alignment: .leading, spacing: scaled(8)) {
            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                HStack {
                    Image(systemName: "trash")
                    Text("Delete This Session")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, scaled(6))
            }
            .buttonStyle(.borderedProminent)
            .disabled(!viewModel.canDeleteSelectedSession || viewModel.isDeletingSelectedSession)

            Text("Deletes only this session from this device.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let deleteStatusMessage = viewModel.deleteStatusMessage {
                Text(deleteStatusMessage)
                    .font(.caption)
                    .foregroundStyle(deleteStatusMessage.contains("Could not") ? .red : .secondary)
            }
        }
        .padding(scaled(12))
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: scaled(14)))
    }

    private func syncColor(for state: PlaybackViewModel.SessionEntry.SyncState) -> Color {
        switch state {
        case .pending:
            return .orange
        case .syncing:
            return .yellow
        case .synced:
            return .green
        case .failed:
            return .red
        }
    }

    private func statPill(title: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.bold())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, scaled(6))
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: scaled(10)))
    }

    @ViewBuilder
    private func chartView(height: CGFloat, overlayStyle: Bool) -> some View {
        if viewModel.chartSamples.isEmpty {
            Text("No heart-rate data available.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: height)
                .background(overlayStyle ? Color.black.opacity(0.15) : Color.black.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: scaled(10)))
        } else {
            let chartDuration = max(1.0, viewModel.duration)
            let yDomain = chartYDomain()
            Chart {
                sampleLineMarks(overlayStyle: overlayStyle)

                RuleMark(x: .value("Current Time", viewModel.scrubTime))
                    .foregroundStyle((overlayStyle ? Color.white : Color.primary).opacity(viewModel.hasMultipleDeviceSeries ? 0.9 : 1.0))
                    .lineStyle(
                        viewModel.hasMultipleDeviceSeries
                            ? StrokeStyle(lineWidth: 1.5, dash: [4, 4])
                            : StrokeStyle(lineWidth: 2)
                    )
            }
            .chartYScale(domain: yDomain)
            .chartXScale(domain: 0...chartDuration)
            .chartYAxis(.hidden)
            .chartXAxis(.hidden)
            .chartForegroundStyleScale([
                seriesStyleKey(for: 0): lineColor(for: 0, overlayStyle: overlayStyle),
                seriesStyleKey(for: 1): lineColor(for: 1, overlayStyle: overlayStyle)
            ])
            .frame(height: height)
            .background(overlayStyle ? Color.black.opacity(0.15) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: scaled(10)))
            .chartOverlay { proxy in
                scrubOverlay(proxy: proxy)
            }
        }
    }

    @ChartContentBuilder
    private func sampleLineMarks(overlayStyle: Bool) -> some ChartContent {
        if viewModel.hasMultipleDeviceSeries {
            let allSeries = viewModel.comparisonDeviceSeries
            ForEach(Array(allSeries.enumerated()), id: \.element.id) { index, series in
                ForEach(Array(series.samples.enumerated()), id: \.offset) { _, sample in
                    LineMark(
                        x: .value("Time", sample.t),
                        y: .value("BPM", renderedBPM(sample.bpm, at: sample.t, forSeries: index, series: allSeries))
                    )
                    .foregroundStyle(by: .value("Strap", seriesStyleKey(for: index)))
                }
            }
        } else {
            ForEach(Array(viewModel.chartSamples.enumerated()), id: \.offset) { _, sample in
                LineMark(
                    x: .value("Time", sample.t),
                    y: .value("BPM", sample.bpm)
                )
                .foregroundStyle(overlayStyle ? Color.white : Color.accentColor)
            }
        }
    }

    private func scrubOverlay(proxy: ChartProxy) -> some View {
        GeometryReader { geometry in
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            applyScrub(
                                at: value.location.x,
                                proxy: proxy,
                                geometry: geometry,
                                commit: chartScrubMode == "smooth"
                            )
                        }
                        .onEnded { value in
                            applyScrub(
                                at: value.location.x,
                                proxy: proxy,
                                geometry: geometry,
                                commit: true
                            )
                        }
                )
        }
    }

    private func applyScrub(
        at xLocation: CGFloat,
        proxy: ChartProxy,
        geometry: GeometryProxy,
        commit: Bool
    ) {
        guard let plotFrame = proxy.plotFrame else { return }
        let plotArea = geometry[plotFrame]
        let xPosition = xLocation - plotArea.origin.x
        guard let time: Double = proxy.value(atX: xPosition) else { return }

        let clamped = min(max(0, time), viewModel.duration)
        if commit {
            viewModel.commitScrub(to: clamped)
        } else {
            viewModel.previewScrub(to: clamped)
        }
    }

    @ViewBuilder
    private func syncIndicator(for entry: PlaybackViewModel.SessionEntry) -> some View {
        switch entry.syncState {
        case .pending, .syncing:
            ProgressView()
                .controlSize(.small)
        case .synced, .failed:
            Image(systemName: viewModel.syncSymbol(for: entry))
                .foregroundStyle(syncColor(for: entry.syncState))
        }
    }

    private var filteredSessionSections: [PlaybackViewModel.SessionDaySection] {
        guard let selectedDayFilter else { return viewModel.sessionSections }

        let calendar = Calendar.current
        return viewModel.sessionSections.filter { section in
            calendar.isDate(section.dayStart, inSameDayAs: selectedDayFilter)
        }
    }

    private var dayFilterLabel: String {
        guard let selectedDayFilter else { return "All Dates" }

        if let title = viewModel.sessionSections.first(where: {
            Calendar.current.isDate($0.dayStart, inSameDayAs: selectedDayFilter)
        })?.title {
            return title
        }

        return selectedDayFilter.formatted(date: .abbreviated, time: .omitted)
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

    private func lineColor(for index: Int, overlayStyle: Bool) -> Color {
        let base: Color = index == 0 ? .blue : .red
        return overlayStyle ? base.opacity(0.95) : base
    }

    private func seriesStyleKey(for index: Int) -> String {
        index == 0 ? "strap_1" : "strap_2"
    }

    private func chartYDomain() -> ClosedRange<Double> {
        // Tighter adaptive vertical zoom to make rises/drops feel much more dramatic in review.
        let absoluteMin = 45.0
        let absoluteMax = 208.0
        let minimumSpan = viewModel.hasMultipleDeviceSeries ? 10.0 : 8.0
        let padding = 1.5

        let seriesValues: [Double]
        if viewModel.hasMultipleDeviceSeries {
            seriesValues = viewModel.comparisonDeviceSeries
                .flatMap { $0.samples.map { Double($0.bpm) } }
                .filter { $0 > 0 }
        } else {
            seriesValues = viewModel.chartSamples
                .map { Double($0.bpm) }
                .filter { $0 > 0 }
        }

        guard !seriesValues.isEmpty else {
            return 60...120
        }

        let sorted = seriesValues.sorted()
        let trimCount = sorted.count >= 20 ? max(1, Int(Double(sorted.count) * 0.05)) : 0
        let lowerIndex = min(trimCount, max(0, sorted.count - 1))
        let upperIndex = max(lowerIndex, sorted.count - trimCount - 1)

        var lower = sorted[lowerIndex] - padding
        var upper = sorted[upperIndex] + padding

        // Always include current readouts to prevent badges and chart from disagreeing at scrub position.
        let activeReadings: [Double]
        if viewModel.hasMultipleDeviceSeries {
            activeReadings = viewModel.displayedDeviceReadings.prefix(2).map { Double($0.bpm) }.filter { $0 > 0 }
        } else {
            activeReadings = viewModel.displayedBPM > 0 ? [Double(viewModel.displayedBPM)] : []
        }
        for reading in activeReadings {
            lower = min(lower, reading - 1.0)
            upper = max(upper, reading + 1.0)
        }

        if (upper - lower) < minimumSpan {
            let center = (upper + lower) / 2
            lower = center - (minimumSpan / 2)
            upper = center + (minimumSpan / 2)
        }

        lower = max(absoluteMin, lower)
        upper = min(absoluteMax, upper)

        if (upper - lower) < minimumSpan {
            let center = min(max((upper + lower) / 2, absoluteMin + (minimumSpan / 2)), absoluteMax - (minimumSpan / 2))
            lower = center - (minimumSpan / 2)
            upper = center + (minimumSpan / 2)
        }

        return lower...upper
    }

    private func renderedBPM(
        _ bpm: Int,
        at time: TimeInterval,
        forSeries index: Int,
        series: [HeartRateDeviceSeries]
    ) -> Double {
        guard series.count == 2 else { return Double(bpm) }

        let selfValue = Double(bpm)
        let otherIndex = (index == 0) ? 1 : 0
        let otherValue = interpolatedBPM(at: time, in: series[otherIndex].samples)
        let midpoint = (selfValue + otherValue) / 2
        let halfSeparation = max(abs(selfValue - otherValue) / 2, 0.7)

        if abs(selfValue - otherValue) < 0.0001 {
            return index == 0 ? (midpoint + halfSeparation) : (midpoint - halfSeparation)
        }

        return selfValue > otherValue ? (midpoint + halfSeparation) : (midpoint - halfSeparation)
    }

    private func interpolatedBPM(at time: TimeInterval, in samples: [HeartRateSample]) -> Double {
        guard !samples.isEmpty else { return 0 }
        if samples.count == 1 { return Double(samples[0].bpm) }

        var left = 0
        var right = samples.count - 1

        while left < right {
            let mid = (left + right) / 2
            if samples[mid].t < time {
                left = mid + 1
            } else {
                right = mid
            }
        }

        let upper = left
        let lower = max(0, upper - 1)
        let lowerSample = samples[lower]
        let upperSample = samples[upper]
        return abs(lowerSample.t - time) <= abs(upperSample.t - time)
            ? Double(lowerSample.bpm)
            : Double(upperSample.bpm)
    }

    private var uiScale: CGFloat {
        let referenceWidth: CGFloat = 393 // iPhone 16 Pro width in points
        let referenceHeight: CGFloat = 852
        let measuredWidth = layoutViewportSize.width > 0 ? layoutViewportSize.width : UIScreen.main.bounds.width
        let measuredHeight = layoutViewportSize.height > 0 ? layoutViewportSize.height : UIScreen.main.bounds.height
        let rawScale = min(measuredWidth / referenceWidth, measuredHeight / referenceHeight)
        return min(max(rawScale, 0.88), 1.18)
    }

    private func scaled(_ value: CGFloat) -> CGFloat {
        value * uiScale
    }

    private var currentOwnerKey: String {
        authStore.currentUserEmail ?? authStore.currentUsername ?? "default"
    }

    private func syncViewModelUser() {
        viewModel.updateCurrentUser(
            email: authStore.currentUserEmail,
            displayName: authStore.currentUsername,
            firebaseUID: authStore.currentFirebaseUID
        )
    }
}

private struct PlaybackFullscreenVideoView: View {
    let player: AVPlayer
    @Binding var isPresented: Bool

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()

            VideoPlayer(player: player)
                .ignoresSafeArea()

            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .shadow(radius: 6)
            }
            .buttonStyle(.plain)
            .padding(.top, 14)
            .padding(.trailing, 14)
        }
        .statusBarHidden(true)
    }
}

#Preview {
    PlaybackView()
        .environmentObject(AuthStore())
}
