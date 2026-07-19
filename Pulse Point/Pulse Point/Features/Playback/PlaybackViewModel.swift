import AVFoundation
import Foundation

@MainActor
final class PlaybackViewModel: ObservableObject {
    private struct SelectedSessionSnapshot: Sendable {
        let startedAt: Date
        let durationSeconds: TimeInterval
    }

    struct SessionEntry: Identifiable {
        enum SyncState {
            case pending
            case syncing
            case synced
            case failed
        }

        let id: String
        let files: SessionFiles
        let startedAt: Date
        let durationSeconds: TimeInterval
        let hasVideo: Bool
        let syncState: SyncState
        let syncErrorMessage: String?
        let remoteSessionID: Int?
    }

    struct SessionDaySection: Identifiable {
        let dayStart: Date
        let title: String
        let entries: [SessionEntry]

        var id: Date { dayStart }
    }

    @Published private(set) var sessions: [SessionEntry] = []
    @Published private(set) var sessionSections: [SessionDaySection] = []
    @Published private(set) var chartSamples: [HeartRateSample] = []
    @Published private(set) var deviceSeries: [HeartRateDeviceSeries] = []

    @Published var selectedSessionID: String?
    @Published var displayedBPM: Int = 0
    @Published private(set) var displayedDeviceReadings: [ConnectedHeartRateReading] = []
    @Published var scrubTime: TimeInterval = 0
    @Published var duration: TimeInterval = 1

    @Published private(set) var isLoadingSessions = false
    @Published private(set) var isLoadingSelectedSession = false
    @Published private(set) var pendingSessionCount = 0
    @Published private(set) var lastRefreshDate: Date?
    @Published private(set) var isDeletingSelectedSession = false
    @Published private(set) var isExportingOverlayVideo = false
    @Published private(set) var isRetryingSync = false
    @Published var deleteStatusMessage: String?
    @Published var exportStatusMessage: String?
    @Published var syncActionMessage: String?

    private let storage = SessionStorage()
    private let pvpProfileStore = PvPProfileStore()
    private var samples: [HeartRateSample] = []
    private var timeObserver: Any?
    private var audioNotificationObservers: [NSObjectProtocol] = []
    private var shouldResumeAfterAudioInterruption = false
    private var isPlaybackAudioSessionActive = false
    private var loadedSessionID: String?
    private var participantOwnerKey: String = "default"
    private var participantNameByDevice: [UUID: String] = [:]
    private var originalDeviceNameByID: [UUID: String] = [:]
    private var currentUserEmail: String?
    private var currentUserDisplayName: String?
    private var currentFirebaseUID: String?

    private let remoteCacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("RemoteSessions", isDirectory: true)

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

    private let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    let player = AVPlayer()

    init() {
        registerAudioSessionObservers()
        reloadParticipantNames()
    }

    var selectedSession: SessionEntry? {
        guard let selectedSessionID else { return nil }
        return sessions.first(where: { $0.id == selectedSessionID })
    }

    var selectedSessionHasVideo: Bool {
        selectedSession?.hasVideo ?? false
    }

    var chartDeviceSeries: [HeartRateDeviceSeries] {
        deviceSeries
            .filter { !$0.samples.isEmpty }
            .sorted { lhs, rhs in
                let nameCompare = lhs.deviceName.localizedCaseInsensitiveCompare(rhs.deviceName)
                if nameCompare == .orderedSame {
                    return lhs.deviceID.uuidString < rhs.deviceID.uuidString
                }
                return nameCompare == .orderedAscending
            }
    }

    var comparisonDeviceSeries: [HeartRateDeviceSeries] {
        Array(chartDeviceSeries.prefix(2))
    }

    var hasMultipleDeviceSeries: Bool {
        comparisonDeviceSeries.count >= 2
    }

    var pendingBannerText: String? {
        guard pendingSessionCount > 0 else { return nil }
        if pendingSessionCount == 1 {
            return "1 session is still syncing."
        }
        return "\(pendingSessionCount) sessions are still syncing."
    }

    var lastRefreshLabel: String {
        guard let lastRefreshDate else { return "Not refreshed yet" }
        return "Updated \(relativeFormatter.localizedString(for: lastRefreshDate, relativeTo: Date()))"
    }

    var selectedSessionDateLabel: String {
        guard let selectedSession else { return "No session selected" }
        return dateTimeFormatter.string(from: selectedSession.startedAt)
    }

    var selectedSessionSyncLabel: String {
        guard let selectedSession else { return "No status" }
        return syncLabel(for: selectedSession)
    }

    var selectedSessionTypeLabel: String {
        guard let selectedSession else { return "N/A" }
        return selectedSession.hasVideo ? "Video + HR" : "HR Only"
    }

    var canDeleteSelectedSession: Bool {
        guard let selectedSession else { return false }
        return storage.hasLocalSessionFiles(selectedSession.files)
    }

    var canExportSelectedSessionVideo: Bool {
        guard let selectedSession else { return false }
        return selectedSession.hasVideo && storage.hasLocalSessionFiles(selectedSession.files) && !isExportingOverlayVideo
    }

    var canRetrySelectedSessionSync: Bool {
        guard let selectedSession else { return false }
        guard storage.hasLocalSessionFiles(selectedSession.files) else { return false }
        return !isRetryingSync && selectedSession.syncState != .synced
    }

    var minBPM: Int {
        samples.map(\.bpm).min() ?? 0
    }

    var avgBPM: Int {
        guard !samples.isEmpty else { return 0 }
        let total = samples.reduce(0) { $0 + $1.bpm }
        return Int(round(Double(total) / Double(samples.count)))
    }

    var maxBPM: Int {
        samples.map(\.bpm).max() ?? 0
    }

    var timeLabel: String {
        "\(formatTime(scrubTime)) / \(formatTime(duration))"
    }

    var summaryDurationLabel: String {
        formatTime(duration)
    }

    var summarySampleCountLabel: String {
        "\(samples.count)"
    }

    var trainingTypeTitle: String {
        analyzeTraining().title
    }

    var trainingTypeDescription: String {
        analyzeTraining().description
    }

    func loadSessions(forceReloadSelected: Bool = false) {
        isLoadingSessions = true
        let previousSelectedID = selectedSessionID
        let previousSelectedSnapshot = selectedSession.map {
            SelectedSessionSnapshot(
                startedAt: $0.startedAt,
                durationSeconds: $0.durationSeconds
            )
        }

        Task {
            let mergedSessions = await buildMergedSessions()

            await MainActor.run {
                let selectionResolution = resolveSelectedSession(
                    previousSelectedID: previousSelectedID,
                    previousSelectedSession: previousSelectedSnapshot,
                    in: mergedSessions
                )
                sessions = mergedSessions
                sessionSections = buildSections(from: mergedSessions)
                pendingSessionCount = mergedSessions.filter { $0.syncState == .pending || $0.syncState == .syncing }.count
                lastRefreshDate = Date()
                isLoadingSessions = false

                guard let resolvedSelectedID = selectionResolution.id else {
                    selectedSessionID = nil
                    clearSelection()
                    return
                }

                selectedSessionID = resolvedSelectedID

                if selectionResolution.wasEquivalentRemap,
                   loadedSessionID == previousSelectedID {
                    loadedSessionID = resolvedSelectedID
                    return
                }

                if let previousSelectedID,
                   previousSelectedID == resolvedSelectedID {
                    loadSelectedSession(force: forceReloadSelected)
                } else {
                    loadSelectedSession(force: true)
                }
            }
        }
    }

    func updateParticipantOwnerKey(_ ownerKey: String) {
        let normalized = ownerKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolved = normalized.isEmpty ? "default" : normalized
        guard participantOwnerKey != resolved || participantNameByDevice.isEmpty else { return }
        participantOwnerKey = resolved
        reloadParticipantNames()

        if !deviceSeries.isEmpty {
            deviceSeries = deviceSeries.map { series in
                HeartRateDeviceSeries(
                    deviceID: series.deviceID,
                    deviceName: displayName(for: series.deviceID, fallback: originalDeviceNameByID[series.deviceID] ?? series.deviceName),
                    samples: series.samples
                )
            }
            displayedDeviceReadings = deviceReadings(at: scrubTime)
        }
    }

    func updateCurrentUser(email: String?, displayName: String?, firebaseUID: String?) {
        let normalizedEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedFirebaseUID = firebaseUID?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard currentUserEmail != normalizedEmail ||
            currentUserDisplayName != normalizedName ||
            currentFirebaseUID != normalizedFirebaseUID else { return }

        currentUserEmail = normalizedEmail
        currentUserDisplayName = normalizedName
        currentFirebaseUID = normalizedFirebaseUID
    }

    func refreshSessions() {
        loadSessions(forceReloadSelected: false)
    }

    func deleteSelectedSession() {
        guard !isDeletingSelectedSession, let selectedSession else { return }
        guard storage.hasLocalSessionFiles(selectedSession.files) else {
            deleteStatusMessage = "No local files found for this session."
            return
        }

        isDeletingSelectedSession = true
        deleteStatusMessage = nil
        exportStatusMessage = nil
        player.pause()
        deactivatePlaybackAudioSession()
        if loadedSessionID == selectedSession.id {
            clearSelection()
        }

        do {
            try storage.deleteSession(selectedSession.files)
            selectedSessionID = nil
            NotificationCenter.default.post(name: Notification.Name("SessionLibraryDidChange"), object: nil)
            loadSessions(forceReloadSelected: true)
            deleteStatusMessage = "Session deleted from this device."
        } catch {
            deleteStatusMessage = "Could not delete session: \(error.localizedDescription)"
        }

        isDeletingSelectedSession = false
    }

    func exportSelectedVideoToPhotoLibrary() {
        guard !isExportingOverlayVideo else { return }
        guard let selectedSession else {
            exportStatusMessage = "No session selected."
            return
        }
        guard selectedSession.hasVideo else {
            exportStatusMessage = "This session has no video to export."
            return
        }
        let videoURL = selectedSession.files.videoURL
        guard FileManager.default.fileExists(atPath: videoURL.path) else {
            exportStatusMessage = "Video file not found on this device."
            return
        }

        let exportSamples = samples
        isExportingOverlayVideo = true
        exportStatusMessage = "Exporting video with BPM overlay..."

        Task {
            do {
                try await BPMOverlayVideoExporter.exportToPhotoLibrary(
                    sourceVideoURL: videoURL,
                    samples: exportSamples
                )
                await MainActor.run {
                    self.isExportingOverlayVideo = false
                    self.exportStatusMessage = "Saved to Photos."
                }
            } catch {
                await MainActor.run {
                    self.isExportingOverlayVideo = false
                    self.exportStatusMessage = "Export failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func retrySelectedSessionSync() {
        guard let selectedSession else {
            syncActionMessage = "No session selected."
            return
        }
        guard storage.hasLocalSessionFiles(selectedSession.files) else {
            syncActionMessage = "This session is not stored locally, so it cannot be retried from this phone."
            return
        }
        guard let metadata = storage.loadMetadata(from: selectedSession.files.metadataURL) else {
            syncActionMessage = "Missing local session metadata."
            return
        }

        let files = selectedSession.files
        let localSamples = storage.loadHeartRateSamples(from: files.heartRateURL)
        let userEmail = currentUserEmail?.isEmpty == false ? currentUserEmail : "local-user@tickerflip.local"
        let displayName = currentUserDisplayName
        let firebaseUID = currentFirebaseUID

        isRetryingSync = true
        syncActionMessage = "Retrying API sync..."

        var syncingMetadata = metadata
        syncingMetadata.uploadState = .syncing
        syncingMetadata.uploadErrorMessage = nil
        try? storage.saveMetadata(syncingMetadata, to: files.metadataURL)
        loadSessions(forceReloadSelected: false)

        Task {
            do {
                let uploadedVideoURL: String?
                if metadata.videoFileName != nil,
                   FileManager.default.fileExists(atPath: files.videoURL.path) {
                    uploadedVideoURL = try await APIClient.shared.uploadVideo(fileURL: files.videoURL).videoUrl
                } else {
                    uploadedVideoURL = nil
                }

                let request = APIFullSessionUploadRequest(
                    session: .init(
                        userId: nil,
                        userEmail: userEmail,
                        firebaseUid: firebaseUID,
                        displayName: displayName,
                        age: nil,
                        weightLb: nil,
                        heightCm: nil,
                        gender: nil,
                        sessionUuid: metadata.id,
                        title: nil,
                        note: nil,
                        startedAt: Self.sqlTimestamp(from: metadata.startedAt),
                        endedAt: Self.sqlTimestamp(from: metadata.startedAt.addingTimeInterval(metadata.duration)),
                        durationSeconds: metadata.duration,
                        minBpm: localSamples.map(\.bpm).min(),
                        avgBpm: localSamples.isEmpty ? nil : Int(round(Double(localSamples.reduce(0) { $0 + $1.bpm }) / Double(localSamples.count))),
                        maxBpm: localSamples.map(\.bpm).max(),
                        videoUrl: uploadedVideoURL
                    ),
                    heartRateSamples: localSamples.map { .init(tSeconds: $0.t, bpm: $0.bpm) },
                    prePvt: nil,
                    postPvt: nil
                )

                _ = try await APIClient.shared.uploadFullSession(request)

                await MainActor.run {
                    var updatedMetadata = metadata
                    updatedMetadata.uploadState = .synced
                    updatedMetadata.uploadErrorMessage = nil
                    try? self.storage.saveMetadata(updatedMetadata, to: files.metadataURL)
                    self.isRetryingSync = false
                    self.syncActionMessage = "API sync completed."
                    NotificationCenter.default.post(name: Notification.Name("SessionLibraryDidChange"), object: nil)
                    self.loadSessions(forceReloadSelected: true)
                }
            } catch {
                await MainActor.run {
                    var updatedMetadata = metadata
                    updatedMetadata.uploadState = .failed
                    updatedMetadata.uploadErrorMessage = error.localizedDescription
                    try? self.storage.saveMetadata(updatedMetadata, to: files.metadataURL)
                    self.isRetryingSync = false
                    self.syncActionMessage = "API sync failed: \(error.localizedDescription)"
                    NotificationCenter.default.post(name: Notification.Name("SessionLibraryDidChange"), object: nil)
                    self.loadSessions(forceReloadSelected: true)
                }
            }
        }
    }

    func selectSession(id: String) {
        guard selectedSessionID != id else { return }
        selectedSessionID = id
        loadSelectedSession(force: true)
    }

    func loadSelectedSession(force: Bool = false) {
        guard let selectedSession else {
            clearSelection()
            return
        }
        let selectedID = selectedSession.id
        let selectedVideoURL = selectedSession.files.videoURL
        let selectedHeartRateURL = selectedSession.files.heartRateURL
        let selectedHeartRateDevicesURL = selectedSession.files.heartRateDeviceSeriesURL
        let selectedRemoteSessionID = selectedSession.remoteSessionID
        let selectedFallbackDuration = selectedSession.durationSeconds
        let selectedHasVideo = selectedSession.hasVideo

        if !force, loadedSessionID == selectedID {
            return
        }

        loadedSessionID = selectedID
        isLoadingSelectedSession = true

        player.pause()
        deactivatePlaybackAudioSession(notifyOthers: false)
        if selectedHasVideo {
            player.replaceCurrentItem(with: AVPlayerItem(url: selectedVideoURL))
            addPeriodicObserver()
        } else {
            player.replaceCurrentItem(with: nil)
            removePeriodicObserver()
        }

        samples = []
        chartSamples = []
        deviceSeries = []
        scrubTime = 0
        displayedBPM = 0
        displayedDeviceReadings = []
        duration = max(1, selectedFallbackDuration)
        exportStatusMessage = nil

        Task {
            let loadedSamples = await loadSamples(
                localHeartRateURL: selectedHeartRateURL,
                remoteSessionID: selectedRemoteSessionID
            )
            let rawDeviceSeries = storage.loadHeartRateDeviceSeries(from: selectedHeartRateDevicesURL)
            let loadedDeviceSeries = rawDeviceSeries
                .map { series in
                    HeartRateDeviceSeries(
                        deviceID: series.deviceID,
                        deviceName: displayName(for: series.deviceID, fallback: series.deviceName),
                        samples: series.samples.sorted { lhs, rhs in lhs.t < rhs.t }
                    )
                }
            let loadedDuration = selectedHasVideo ? await loadDuration(for: selectedVideoURL) : 0

            await MainActor.run {
                guard self.loadedSessionID == selectedID else { return }

                let sortedSamples = loadedSamples.sorted { lhs, rhs in lhs.t < rhs.t }
                self.samples = sortedSamples
                self.chartSamples = sortedSamples
                self.deviceSeries = loadedDeviceSeries
                self.originalDeviceNameByID = Dictionary(uniqueKeysWithValues: rawDeviceSeries.map { ($0.deviceID, $0.deviceName) })
                self.scrubTime = 0
                self.displayedBPM = self.bpm(at: 0)
                self.displayedDeviceReadings = self.deviceReadings(at: 0)

                if loadedDuration > 0 {
                    self.duration = loadedDuration
                } else if selectedFallbackDuration > 0 {
                    self.duration = selectedFallbackDuration
                } else {
                    self.duration = 1
                }

                self.isLoadingSelectedSession = false

                if selectedHasVideo && AppSettings.autoPlayOnSessionOpen {
                    self.playVideoSession()
                    self.objectWillChange.send()
                }
            }
        }
    }

    func sessionTimeLabel(for session: SessionEntry) -> String {
        timeFormatter.string(from: session.startedAt)
    }

    func sessionMetaLabel(for session: SessionEntry) -> String {
        let durationText = formatTime(session.durationSeconds)
        let modeLabel = session.hasVideo ? "Video + HR" : "HR Only"
        return "\(durationText) • \(modeLabel) • \(syncLabel(for: session))"
    }

    func syncLabel(for session: SessionEntry) -> String {
        switch session.syncState {
        case .pending:
            return "Pending"
        case .syncing:
            return "Syncing"
        case .synced:
            return "Ready"
        case .failed:
            return "Upload Failed"
        }
    }

    func syncSymbol(for session: SessionEntry) -> String {
        switch session.syncState {
        case .pending:
            return "clock.fill"
        case .syncing:
            return "arrow.triangle.2.circlepath"
        case .synced:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.triangle.fill"
        }
    }

    func seek(to seconds: TimeInterval) {
        let clamped = min(max(0, seconds), duration)
        scrubTime = clamped
        if selectedSessionHasVideo {
            let time = CMTime(seconds: clamped, preferredTimescale: 600)
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        }
        displayedBPM = bpm(at: clamped)
        displayedDeviceReadings = deviceReadings(at: clamped)
    }

    func previewScrub(to seconds: TimeInterval) {
        scrubTime = seconds
        displayedBPM = bpm(at: seconds)
        displayedDeviceReadings = deviceReadings(at: seconds)
    }

    func commitScrub(to seconds: TimeInterval) {
        seek(to: seconds)
    }

    func stepFrame(forward: Bool) {
        player.pause()
        objectWillChange.send()
        let frameDuration = 1.0 / 30.0
        let target = max(0, scrubTime + (forward ? frameDuration : -frameDuration))
        seek(to: target)
    }

    func jump(seconds: TimeInterval) {
        let target = min(max(0, scrubTime + seconds), duration)
        seek(to: target)
    }

    func togglePlayback() {
        if player.timeControlStatus == .playing {
            player.pause()
            deactivatePlaybackAudioSession()
        } else {
            playVideoSession()
        }
        objectWillChange.send()
    }

    func pausePlaybackIfNeeded() {
        if player.timeControlStatus == .playing {
            player.pause()
        }
        deactivatePlaybackAudioSession()
        objectWillChange.send()
    }

    private func clearSelection() {
        loadedSessionID = nil
        isLoadingSelectedSession = false
        samples = []
        chartSamples = []
        deviceSeries = []
        originalDeviceNameByID = [:]
        displayedBPM = 0
        displayedDeviceReadings = []
        scrubTime = 0
        duration = 1
        exportStatusMessage = nil
        removePeriodicObserver()
        player.pause()
        deactivatePlaybackAudioSession(notifyOthers: false)
        player.replaceCurrentItem(with: nil)
    }

    private func removePeriodicObserver() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
            self.timeObserver = nil
        }
    }

    private func addPeriodicObserver() {
        removePeriodicObserver()

        let interval = CMTime(seconds: 0.2, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let seconds = CMTimeGetSeconds(time)
            guard seconds.isFinite else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.scrubTime = seconds
                self.displayedBPM = self.bpm(at: seconds)
                self.displayedDeviceReadings = self.deviceReadings(at: seconds)
            }
        }
    }

    private func bpm(at seconds: TimeInterval) -> Int {
        bpm(at: seconds, in: samples)
    }

    private func bpm(at seconds: TimeInterval, in source: [HeartRateSample]) -> Int {
        guard !source.isEmpty else { return 0 }
        var left = 0
        var right = source.count - 1

        while left < right {
            let mid = (left + right) / 2
            if source[mid].t < seconds {
                left = mid + 1
            } else {
                right = mid
            }
        }

        let upper = left
        let lower = max(0, upper - 1)

        let lowerSample = source[lower]
        let upperSample = source[upper]
        return abs(lowerSample.t - seconds) <= abs(upperSample.t - seconds) ? lowerSample.bpm : upperSample.bpm
    }

    private func deviceReadings(at seconds: TimeInterval) -> [ConnectedHeartRateReading] {
        let activeSeries = hasMultipleDeviceSeries ? comparisonDeviceSeries : chartDeviceSeries
        return activeSeries
            .map { series in
                ConnectedHeartRateReading(
                    id: series.deviceID,
                    name: series.deviceName,
                    bpm: bpm(at: seconds, in: series.samples)
                )
            }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let clamped = max(0, Int(seconds.rounded(.down)))
        let mins = clamped / 60
        let secs = clamped % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    private static func sqlTimestamp(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter.string(from: date)
    }

    private func analyzeTraining() -> (title: String, description: String) {
        let effectiveDuration = max(duration, samples.last?.t ?? 0)
        if effectiveDuration < 30 {
            return ("N/A", "Record for 30 seconds or more to get results.")
        }
        guard samples.count >= 10 else {
            return ("N/A", "Not enough heart-rate samples to classify this session.")
        }

        let zoneRatios = HeartRateZone.ratios(from: samples)
        let easy = zoneRatios[.easy, default: 0]
        let light = zoneRatios[.light, default: 0]
        let aerobic = zoneRatios[.aerobic, default: 0]
        let hard = zoneRatios[.hard, default: 0]
        let peak = zoneRatios[.peak, default: 0]

        let highLoad = hard + peak
        let lowLoad = easy + light

        if peak >= 0.25 || highLoad >= 0.60 {
            return (
                "Very High Intensity",
                "Large time in 162-202 BPM zones (\(Int((highLoad * 100).rounded()))%) suggests near-max effort."
            )
        }

        if highLoad >= 0.35 {
            return (
                "High Intensity",
                "Significant time in hard zones (\(Int((highLoad * 100).rounded()))%) indicates demanding cardio work."
            )
        }

        if aerobic >= 0.45 && highLoad < 0.35 {
            return (
                "Steady Aerobic",
                "Most of the session sat in 141-162 BPM (\(Int((aerobic * 100).rounded()))%), consistent with steady cardio."
            )
        }

        if lowLoad >= 0.70 {
            return (
                "Low-Intensity / Recovery",
                "Most time remained in 60-141 BPM (\(Int((lowLoad * 100).rounded()))%), typical of easy or recovery effort."
            )
        }

        return (
            "Mixed Intensity",
            "Zone split was mixed (60-121: \(Int((easy * 100).rounded()))%, 121-141: \(Int((light * 100).rounded()))%, 141-162: \(Int((aerobic * 100).rounded()))%, 162-182: \(Int((hard * 100).rounded()))%, 182-202: \(Int((peak * 100).rounded()))%)."
        )
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        for observer in audioNotificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    private func playVideoSession() {
        activatePlaybackAudioSession()
        player.play()
    }

    private func activatePlaybackAudioSession() {
        guard !isPlaybackAudioSessionActive else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playback,
                mode: .moviePlayback,
                options: []
            )
            try session.setActive(true, options: [])
            isPlaybackAudioSessionActive = true
        } catch {
            // Keep playback functional even if audio-session configuration fails.
        }
    }

    private func deactivatePlaybackAudioSession(notifyOthers: Bool = true) {
        guard isPlaybackAudioSessionActive else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: notifyOthers ? [.notifyOthersOnDeactivation] : [])
        } catch {
            // Best-effort deactivation.
        }
        isPlaybackAudioSessionActive = false
    }

    private func registerAudioSessionObservers() {
        let center = NotificationCenter.default
        let interruptionObserver = center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            Task { @MainActor [weak self] in
                self?.handleAudioInterruption(notification)
            }
        }

        let mediaServicesResetObserver = center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isPlaybackAudioSessionActive = false
                if self.player.timeControlStatus == .playing {
                    self.activatePlaybackAudioSession()
                }
            }
        }

        audioNotificationObservers = [interruptionObserver, mediaServicesResetObserver]
    }

    private func handleAudioInterruption(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let rawType = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let interruptionType = AVAudioSession.InterruptionType(rawValue: rawType) else {
            return
        }

        switch interruptionType {
        case .began:
            shouldResumeAfterAudioInterruption = player.timeControlStatus == .playing
            if shouldResumeAfterAudioInterruption {
                player.pause()
                objectWillChange.send()
            }

        case .ended:
            let rawOptions = userInfo[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            if shouldResumeAfterAudioInterruption && options.contains(.shouldResume) {
                playVideoSession()
                objectWillChange.send()
            } else {
                deactivatePlaybackAudioSession()
            }
            shouldResumeAfterAudioInterruption = false

        @unknown default:
            shouldResumeAfterAudioInterruption = false
        }
    }

    private func loadSamples(
        localHeartRateURL: URL,
        remoteSessionID: Int?
    ) async -> [HeartRateSample] {
        let localSamples = storage.loadHeartRateSamples(from: localHeartRateURL)

        guard let remoteSessionID,
              let remoteSamples = try? await APIClient.shared.heartRateSamples(sessionId: remoteSessionID),
              !remoteSamples.isEmpty else {
            return localSamples.sorted { lhs, rhs in lhs.t < rhs.t }
        }

        return remoteSamples.sorted { lhs, rhs in lhs.t < rhs.t }
    }

    private func reloadParticipantNames() {
        let bundle = pvpProfileStore.loadBundle(ownerKey: participantOwnerKey)
        let profilesByID = Dictionary(uniqueKeysWithValues: bundle.profiles.map { ($0.id, $0.displayName) })
        participantNameByDevice = bundle.deviceAssignments.reduce(into: [:]) { partial, entry in
            guard let deviceID = UUID(uuidString: entry.key),
                  let displayName = profilesByID[entry.value],
                  !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return
            }
            partial[deviceID] = displayName
        }
    }

    private func displayName(for deviceID: UUID, fallback: String) -> String {
        if let participantName = participantNameByDevice[deviceID] {
            return participantName
        }
        return fallback
    }

    private func loadDuration(for videoURL: URL) async -> TimeInterval {
        let asset = AVAsset(url: videoURL)
        let loadedDuration = try? await asset.load(.duration)
        let seconds = loadedDuration.map(CMTimeGetSeconds) ?? 0
        return (seconds.isFinite && seconds > 0) ? seconds : 0
    }

    private func buildMergedSessions() async -> [SessionEntry] {
        var entriesByID = Dictionary(uniqueKeysWithValues: loadLocalSessions().map { ($0.id, $0) })

        let remoteSessions: [APISessionListItem]?
        if let currentUserEmail, !currentUserEmail.isEmpty {
            remoteSessions = try? await APIClient.shared.listSessions(userEmail: currentUserEmail)
        } else {
            remoteSessions = try? await APIClient.shared.listSessions(userId: 1)
        }

        if let apiSessions = remoteSessions {
            for item in apiSessions {
                guard let remoteEntry = makeRemoteEntry(from: item) else { continue }

                if let localEntry = entriesByID[remoteEntry.id] {
                    let merged = SessionEntry(
                        id: localEntry.id,
                        files: localEntry.files,
                        startedAt: localEntry.startedAt,
                        durationSeconds: max(localEntry.durationSeconds, remoteEntry.durationSeconds),
                        hasVideo: localEntry.hasVideo || remoteEntry.hasVideo,
                        syncState: .synced,
                        syncErrorMessage: nil,
                        remoteSessionID: remoteEntry.remoteSessionID
                    )
                    entriesByID[merged.id] = merged
                } else {
                    entriesByID[remoteEntry.id] = remoteEntry
                }
            }
        }

        return entriesByID.values.sorted { lhs, rhs in
            if lhs.startedAt == rhs.startedAt {
                return lhs.id > rhs.id
            }
            return lhs.startedAt > rhs.startedAt
        }
    }

    private func loadLocalSessions() -> [SessionEntry] {
        storage.listSessions().map { files in
            let metadata = storage.loadMetadata(from: files.metadataURL)
            let startedAt = metadata?.startedAt ?? fallbackDate(for: files)
            let durationSeconds = metadata?.duration ?? 0
            let videoFileName = metadata?.videoFileName
            let hasVideo: Bool
            if let videoFileName, !videoFileName.isEmpty {
                let videoPath = files.directoryURL.appendingPathComponent(videoFileName).path
                hasVideo = FileManager.default.fileExists(atPath: videoPath)
            } else {
                hasVideo = FileManager.default.fileExists(atPath: files.videoURL.path)
            }

            return SessionEntry(
                id: metadata?.id ?? files.sessionID,
                files: files,
                startedAt: startedAt,
                durationSeconds: durationSeconds,
                hasVideo: hasVideo,
                syncState: mapSyncState(metadata?.uploadState),
                syncErrorMessage: metadata?.uploadErrorMessage,
                remoteSessionID: nil
            )
        }
    }

    private func makeRemoteEntry(from item: APISessionListItem) -> SessionEntry? {
        let sessionDirectory = remoteCacheDirectory.appendingPathComponent(item.session_uuid, isDirectory: true)
        try? FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)
        let remoteVideoURL = item.video_url.flatMap(URL.init(string:))

        let files = SessionFiles(
            sessionID: item.session_uuid,
            directoryURL: sessionDirectory,
            videoURL: remoteVideoURL ?? sessionDirectory.appendingPathComponent("video.mov"),
            heartRateURL: sessionDirectory.appendingPathComponent("heartRate.json"),
            heartRateDeviceSeriesURL: sessionDirectory.appendingPathComponent("heartRateDevices.json"),
            metadataURL: sessionDirectory.appendingPathComponent("session.json")
        )

        let startedAt = parseServerDate(item.started_at) ?? Date()

        return SessionEntry(
            id: item.session_uuid,
            files: files,
            startedAt: startedAt,
            durationSeconds: item.duration_seconds,
            hasVideo: remoteVideoURL != nil,
            syncState: .synced,
            syncErrorMessage: nil,
            remoteSessionID: item.id
        )
    }

    private func mapSyncState(_ state: WorkoutSessionMetadata.UploadState?) -> SessionEntry.SyncState {
        switch state ?? .pending {
        case .pending:
            return .pending
        case .syncing:
            return .syncing
        case .synced:
            return .synced
        case .failed:
            return .failed
        }
    }

    private func buildSections(from sessions: [SessionEntry]) -> [SessionDaySection] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: sessions) { session in
            calendar.startOfDay(for: session.startedAt)
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

            let daySessions = (grouped[day] ?? []).sorted { $0.startedAt > $1.startedAt }
            return SessionDaySection(dayStart: day, title: title, entries: daySessions)
        }
    }

    private func parseServerDate(_ value: String) -> Date? {
        let isoWithFractional = ISO8601DateFormatter()
        isoWithFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoWithFractional.date(from: value) {
            return date
        }

        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: value) {
            return date
        }

        let sql = DateFormatter()
        sql.locale = Locale(identifier: "en_US_POSIX")
        sql.timeZone = TimeZone(secondsFromGMT: 0)
        sql.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return sql.date(from: value)
    }

    private func fallbackDate(for files: SessionFiles) -> Date {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .creationDateKey]
        let values = try? files.directoryURL.resourceValues(forKeys: keys)
        return values?.contentModificationDate ?? values?.creationDate ?? Date()
    }

    private func resolveSelectedSession(
        previousSelectedID: String?,
        previousSelectedSession: SelectedSessionSnapshot?,
        in mergedSessions: [SessionEntry]
    ) -> (id: String?, wasEquivalentRemap: Bool) {
        guard !mergedSessions.isEmpty else {
            return (nil, false)
        }

        if let previousSelectedID,
           mergedSessions.contains(where: { $0.id == previousSelectedID }) {
            return (previousSelectedID, false)
        }

        guard let previousSelectedSession else {
            return (mergedSessions.first?.id, false)
        }

        let equivalentMatch = mergedSessions
            .map { session -> (session: SessionEntry, score: TimeInterval) in
                let startDelta = abs(session.startedAt.timeIntervalSince(previousSelectedSession.startedAt))
                let durationDelta = abs(session.durationSeconds - previousSelectedSession.durationSeconds)
                return (session, startDelta + durationDelta)
            }
            .filter { candidate in
                let startDelta = abs(candidate.session.startedAt.timeIntervalSince(previousSelectedSession.startedAt))
                let durationDelta = abs(candidate.session.durationSeconds - previousSelectedSession.durationSeconds)
                return startDelta <= 2 && durationDelta <= 3
            }
            .min { lhs, rhs in lhs.score < rhs.score }
            .map(\.session)

        if let equivalentMatch {
            return (equivalentMatch.id, true)
        }

        return (mergedSessions.first?.id, false)
    }
}

extension Notification.Name {
    static let pauseReviewPlayback = Notification.Name("PauseReviewPlayback")
}
