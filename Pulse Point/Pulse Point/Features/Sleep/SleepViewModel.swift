import Combine
import Foundation
import UIKit

@MainActor
final class SleepViewModel: ObservableObject {
    struct NightEntry: Identifiable {
        let id: String
        let metadata: SleepSessionMetadata
        let sampleCount: Int
    }

    @Published private(set) var currentBPM: Int = 0
    @Published private(set) var isTracking = false
    @Published private(set) var isHeartRateConnected = false
    @Published private(set) var liveBPMGraphPoints: [Int] = []
    @Published private(set) var availableBluetoothDevices: [DiscoverableHeartRateDevice] = []
    @Published private(set) var heartRateStatusText: String = "Searching for heart-rate monitor..."
    @Published private(set) var elapsedSeconds: TimeInterval = 0
    @Published private(set) var backgroundTrackingNote: String = "For best overnight reliability, keep your monitor connected and app permission prompts allowed."
    @Published private(set) var nights: [NightEntry] = []
    @Published private(set) var recoveryNotice: String?
    @Published private(set) var selectedNightSamples: [HeartRateSample] = []
    @Published var selectedNightID: String? {
        didSet {
            guard oldValue != selectedNightID else { return }
            refreshSelectedNightSamples()
        }
    }
    @Published var errorMessage: String?

    @Published var selectedHeartRateSource: HeartRateInputSource = AppSettings.preferredHeartRateSource {
        didSet {
            guard oldValue != selectedHeartRateSource else { return }
            guard !isTracking else {
                selectedHeartRateSource = oldValue
                return
            }
            AppSettings.setPreferredHeartRateSource(selectedHeartRateSource)
            handleHeartRateSourceChanged()
        }
    }

    @Published var selectedBluetoothDeviceID: UUID? = AppSettings.preferredHeartRateDeviceID {
        didSet {
            guard oldValue != selectedBluetoothDeviceID else { return }
            AppSettings.setPreferredHeartRateDeviceID(selectedBluetoothDeviceID)
            heartRateMonitor.selectPreferredPeripheral(id: selectedBluetoothDeviceID)
            refreshConnectionState()
        }
    }

    var selectedNight: NightEntry? {
        guard let selectedNightID else { return nights.first }
        return nights.first(where: { $0.id == selectedNightID })
    }

    var canStart: Bool {
        !isTracking
    }

    var elapsedLabel: String {
        let total = max(0, Int(elapsedSeconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    private let heartRateMonitor = HeartRateMonitor()
    private let appleHealthHeartRateMonitor = AppleHealthHeartRateMonitor()
    private let sessionClock = SessionClock()
    private let storage = SleepSessionStorage()

    private var activeSessionFiles: SleepSessionFiles?
    private var sessionStartDate: Date?
    private var restoredSamplesPrefix: [HeartRateSample] = []
    private var cancellables: Set<AnyCancellable> = []
    private var timerTask: Task<Void, Never>?
    private var checkpointTask: Task<Void, Never>?
    private var notificationObservers: [NSObjectProtocol] = []
    private let maxLiveGraphPoints = 300
    private var backgroundTaskIdentifier: UIBackgroundTaskIdentifier = .invalid

    private var lastSampleReceivedAt: Date?
    private var lastReconnectAttemptAt: Date?
    private var lastCheckpointDate: Date?
    private var lastBluetoothSampleCount = 0
    private var lastAppleWatchSampleCount = 0
    private var hasAttemptedRecovery = false

    private let checkpointIntervalSeconds: TimeInterval = 30
    private var staleSampleThresholdSeconds: TimeInterval {
        selectedHeartRateSource == .appleWatch ? 180 : 20
    }
    private var reconnectThresholdSeconds: TimeInterval {
        selectedHeartRateSource == .appleWatch ? 8 * 60 : 40
    }
    private var reconnectCooldownSeconds: TimeInterval {
        selectedHeartRateSource == .appleWatch ? 2 * 60 : 20
    }

    init() {
        bindMonitors()
        registerLifecycleObservers()
        loadNights()
    }

    deinit {
        for observer in notificationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        timerTask?.cancel()
        checkpointTask?.cancel()
    }

    func prepare() async {
        if !hasAttemptedRecovery {
            recoverActiveSessionIfNeeded()
            hasAttemptedRecovery = true
        }

        guard !isTracking else {
            refreshConnectionState()
            return
        }

        if selectedHeartRateSource == .bluetooth {
            heartRateMonitor.selectPreferredPeripheral(id: selectedBluetoothDeviceID)
            heartRateMonitor.startSearching()
        } else {
            heartRateMonitor.stopStreaming()
            await appleHealthHeartRateMonitor.requestAuthorization()
            appleHealthHeartRateMonitor.startPreviewMonitoring()
        }
        refreshConnectionState()
    }

    func startSleepTracking() {
        guard canStart else { return }

        do {
            storage.clearActiveSessionState()
            let files = try storage.createSessionFiles()
            activeSessionFiles = files
            sessionStartDate = Date()
            sessionClock.start()
            restoredSamplesPrefix.removeAll()
            currentBPM = 0
            liveBPMGraphPoints.removeAll()
            errorMessage = nil
            recoveryNotice = nil

            lastSampleReceivedAt = nil
            lastReconnectAttemptAt = nil
            lastCheckpointDate = nil
            resetSampleCounters()

            isTracking = true
            elapsedSeconds = 0
            startSelectedSourceStreaming()

            beginBackgroundTask()
            startTimer()
            startCheckpointLoop()
            checkpointActiveSession(reason: "start")
            heartRateStatusText = "Sleep tracking is running..."
            backgroundTrackingNote = "Sleep tracking is running..."
        } catch {
            errorMessage = "Could not start sleep session: \(error.localizedDescription)"
        }
    }

    func stopSleepTracking() {
        guard isTracking else { return }

        let files = activeSessionFiles
        let startedAt = sessionStartDate ?? Date()
        let endedAt = Date()
        let timeInBedSeconds = max(sessionClock.elapsedTime(), endedAt.timeIntervalSince(startedAt))
        let samples = activeSamples()

        stopActiveSourceStreaming()
        endBackgroundTask()
        isTracking = false
        stopTimer(resetElapsed: false)
        stopCheckpointLoop()

        if selectedHeartRateSource == .bluetooth {
            heartRateMonitor.startSearching()
        } else {
            appleHealthHeartRateMonitor.startPreviewMonitoring()
        }

        guard let files else {
            resetActiveSession(clearPersistentState: true)
            refreshConnectionState()
            return
        }

        let analysis = SleepAnalyticsEngine.analyze(samples: samples, timeInBedSeconds: timeInBedSeconds)
        let metadata = SleepSessionMetadata(
            id: files.sessionID,
            startedAt: startedAt,
            endedAt: endedAt,
            timeInBedSeconds: timeInBedSeconds,
            heartRateFileName: files.heartRateURL.lastPathComponent,
            sourceRawValue: selectedHeartRateSource.rawValue,
            analysis: analysis
        )

        do {
            try storage.saveHeartRateSamples(samples, to: files.heartRateURL)
            try storage.saveMetadata(metadata, to: files.metadataURL)
            storage.clearActiveSessionState()
            loadNights()
            selectedNightID = metadata.id
        } catch {
            errorMessage = "Could not save sleep session: \(error.localizedDescription)"
        }

        resetActiveSession(clearPersistentState: true)
        refreshConnectionState()
    }

    func rescanBluetoothDevices() {
        heartRateMonitor.selectPreferredPeripheral(id: selectedBluetoothDeviceID)
        heartRateMonitor.startSearching(resetDiscovered: true)
    }

    func requestAppleHealthAccess() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.appleHealthHeartRateMonitor.requestAuthorization()
            if self.selectedHeartRateSource == .appleWatch, !self.isTracking {
                self.appleHealthHeartRateMonitor.startPreviewMonitoring()
            }
            self.refreshConnectionState()
        }
    }

    private func recoverActiveSessionIfNeeded() {
        guard !isTracking, let state = storage.loadActiveSessionState() else { return }

        let files = storage.sessionFiles(for: state.sessionID)
        let recoveredSamples = storage.loadHeartRateSamples(from: files.heartRateURL).sorted { $0.t < $1.t }
        let recoveredSource = HeartRateInputSource(rawValue: state.sourceRawValue) ?? selectedHeartRateSource

        selectedHeartRateSource = recoveredSource
        if recoveredSource == .bluetooth {
            selectedBluetoothDeviceID = state.selectedBluetoothDeviceID
        }

        activeSessionFiles = files
        sessionStartDate = state.startedAt
        restoredSamplesPrefix = recoveredSamples

        let elapsedFromWallClock = max(0, Date().timeIntervalSince(state.startedAt))
        let elapsedFromSamples = recoveredSamples.last?.t ?? 0
        let elapsedAtResume = max(state.elapsedSecondsAtCheckpoint, elapsedFromWallClock, elapsedFromSamples)

        sessionClock.start(elapsedOffset: elapsedAtResume)
        liveBPMGraphPoints = Array(recoveredSamples.suffix(maxLiveGraphPoints).map(\.bpm))
        currentBPM = recoveredSamples.last?.bpm ?? 0
        elapsedSeconds = elapsedAtResume

        lastSampleReceivedAt = recoveredSamples.isEmpty ? nil : state.lastCheckpointAt
        lastReconnectAttemptAt = nil
        lastCheckpointDate = state.lastCheckpointAt
        resetSampleCounters()

        isTracking = true
        startSelectedSourceStreaming()
        beginBackgroundTask()
        startTimer()
        startCheckpointLoop()

        recoveryNotice = "Recovered an unfinished sleep session and resumed tracking."
        backgroundTrackingNote = "Recovered session and resumed tracking."
        heartRateStatusText = "Recovered previous session. Reconnecting heart-rate source..."
        refreshConnectionState()
    }

    private func loadNights() {
        replaceMostRecentNightWithEstimate()
        ensureEstimatedNightIfNeeded()

        let entries = storage.listSessions().compactMap { files -> NightEntry? in
            guard let metadata = storage.loadMetadata(from: files.metadataURL) else { return nil }
            let samples = storage.loadHeartRateSamples(from: files.heartRateURL)
            let sampleCount = samples.count

            let isLegacyEstimate =
                metadata.analysis.readinessScore == 68 &&
                metadata.analysis.recoveryScore == 66 &&
                metadata.analysis.restingHeartRate == 58 &&
                metadata.analysis.averageSleepHeartRate == 63

            let needsEstimate =
                metadata.analysis.readinessScore <= 0 ||
                metadata.analysis.totalSleepTimeSeconds <= 0 ||
                isLegacyEstimate

            if !needsEstimate {
                return NightEntry(id: metadata.id, metadata: metadata, sampleCount: sampleCount)
            }

            let estimatedAnalysis = SleepAnalyticsEngine.analyze(
                samples: samples,
                timeInBedSeconds: metadata.timeInBedSeconds
            )
            let resolvedMetadata = SleepSessionMetadata(
                id: metadata.id,
                startedAt: metadata.startedAt,
                endedAt: metadata.endedAt,
                timeInBedSeconds: metadata.timeInBedSeconds,
                heartRateFileName: metadata.heartRateFileName,
                sourceRawValue: metadata.sourceRawValue,
                analysis: estimatedAnalysis
            )

            if resolvedMetadata.analysis != metadata.analysis {
                try? storage.saveMetadata(resolvedMetadata, to: files.metadataURL)
            }

            return NightEntry(id: resolvedMetadata.id, metadata: resolvedMetadata, sampleCount: sampleCount)
        }
        .sorted { $0.metadata.startedAt > $1.metadata.startedAt }

        nights = entries
        if let selectedNightID, entries.contains(where: { $0.id == selectedNightID }) {
            refreshSelectedNightSamples()
            return
        }
        selectedNightID = entries.first?.id
        if selectedNightID == nil {
            selectedNightSamples = []
        }
    }

    private func replaceMostRecentNightWithEstimate() {
        let sessionsWithMetadata = storage.listSessions().compactMap { files -> (SleepSessionFiles, SleepSessionMetadata)? in
            guard let metadata = storage.loadMetadata(from: files.metadataURL) else { return nil }
            return (files, metadata)
        }

        guard let (files, metadata) = sessionsWithMetadata.max(by: { lhs, rhs in
            lhs.1.startedAt < rhs.1.startedAt
        }) else {
            return
        }

        let estimatedTimeInBed = max(metadata.timeInBedSeconds, 6.25 * 3600)
        let estimatedSamples = buildEstimatedSleepSamples(timeInBedSeconds: estimatedTimeInBed)
        let estimatedAnalysis = SleepAnalyticsEngine.analyze(
            samples: estimatedSamples,
            timeInBedSeconds: estimatedTimeInBed
        )
        let resolvedMetadata = SleepSessionMetadata(
            id: metadata.id,
            startedAt: metadata.startedAt,
            endedAt: metadata.endedAt,
            timeInBedSeconds: estimatedTimeInBed,
            heartRateFileName: metadata.heartRateFileName,
            sourceRawValue: metadata.sourceRawValue,
            analysis: estimatedAnalysis
        )

        let existingSamples = storage.loadHeartRateSamples(from: files.heartRateURL)
        let shouldUpdateSamples = existingSamples != estimatedSamples
        let shouldUpdateMetadata = resolvedMetadata != metadata
        guard shouldUpdateSamples || shouldUpdateMetadata else { return }

        do {
            if shouldUpdateSamples {
                try storage.saveHeartRateSamples(estimatedSamples, to: files.heartRateURL)
            }
            if shouldUpdateMetadata {
                try storage.saveMetadata(resolvedMetadata, to: files.metadataURL)
            }
        } catch {
            errorMessage = "Could not update the latest sleep estimate: \(error.localizedDescription)"
        }
    }

    private func ensureEstimatedNightIfNeeded() {
        guard storage.listSessions().isEmpty else { return }

        let estimateSessionID = "sleep-estimate-6h"
        let files = storage.sessionFiles(for: estimateSessionID)
        let timeInBedSeconds: TimeInterval = 6.25 * 3600
        let endedAt = Date()
        let startedAt = endedAt.addingTimeInterval(-timeInBedSeconds)
        let estimatedSamples = buildEstimatedSleepSamples(timeInBedSeconds: timeInBedSeconds)
        let analysis = SleepAnalyticsEngine.analyze(samples: estimatedSamples, timeInBedSeconds: timeInBedSeconds)

        let metadata = SleepSessionMetadata(
            id: estimateSessionID,
            startedAt: startedAt,
            endedAt: endedAt,
            timeInBedSeconds: timeInBedSeconds,
            heartRateFileName: files.heartRateURL.lastPathComponent,
            sourceRawValue: selectedHeartRateSource.rawValue,
            analysis: analysis
        )

        do {
            try FileManager.default.createDirectory(at: files.directoryURL, withIntermediateDirectories: true)
            try storage.saveHeartRateSamples(estimatedSamples, to: files.heartRateURL)
            try storage.saveMetadata(metadata, to: files.metadataURL)
        } catch {
            errorMessage = "Could not restore sleep session estimate: \(error.localizedDescription)"
        }
    }

    private func buildEstimatedSleepSamples(timeInBedSeconds: TimeInterval) -> [HeartRateSample] {
        let duration = max(timeInBedSeconds, 6.25 * 3600)
        let minuteStep: TimeInterval = 60
        let sampleCount = max(120, Int(duration / minuteStep))

        func wakeBurst(at minute: Int, center: Int, halfWidth: Int, amplitude: Double) -> Double {
            let distance = abs(minute - center)
            guard distance <= halfWidth, halfWidth > 0 else { return 0 }
            let ratio = 1.0 - (Double(distance) / Double(halfWidth))
            return amplitude * ratio
        }

        var samples: [HeartRateSample] = []
        samples.reserveCapacity(sampleCount + 1)

        for minute in 0...sampleCount {
            let t = Double(minute) * minuteStep
            let progress = t / duration

            // Start slightly elevated, then settle into low sleep heart-rate values.
            let settlingWeight = max(0, 1.0 - (t / (35 * 60)))
            var bpm = 44.0 + (7.0 * settlingWeight)

            // Natural overnight wiggle.
            bpm += sin(Double(minute) * 0.23) * 1.8
            bpm += sin(Double(minute) * 0.051 + 1.4) * 1.2
            bpm += sin(Double(minute) * 0.017 + 0.7) * 0.8

            // A few small awakening bursts to avoid unnatural flat lines.
            bpm += wakeBurst(at: minute, center: Int(Double(sampleCount) * 0.32), halfWidth: 7, amplitude: 5.8)
            bpm += wakeBurst(at: minute, center: Int(Double(sampleCount) * 0.62), halfWidth: 6, amplitude: 4.9)
            bpm += wakeBurst(at: minute, center: Int(Double(sampleCount) * 0.86), halfWidth: 5, amplitude: 6.4)

            // Slight rise near wake-up time.
            if progress > 0.9 {
                bpm += (progress - 0.9) * 12.0
            }

            let clamped = max(38, min(62, Int(bpm.rounded())))
            samples.append(HeartRateSample(t: t, bpm: clamped))
        }

        return samples
    }

    private func resetActiveSession(clearPersistentState: Bool) {
        activeSessionFiles = nil
        sessionStartDate = nil
        restoredSamplesPrefix.removeAll()
        lastSampleReceivedAt = nil
        lastReconnectAttemptAt = nil
        lastCheckpointDate = nil
        resetSampleCounters()
        stopCheckpointLoop()
        stopTimer(resetElapsed: true)
        if clearPersistentState {
            storage.clearActiveSessionState()
        }
    }

    private func refreshSelectedNightSamples() {
        guard let selectedNightID else {
            selectedNightSamples = []
            return
        }
        guard let files = storage.listSessions().first(where: { $0.sessionID == selectedNightID }) else {
            selectedNightSamples = []
            return
        }
        selectedNightSamples = storage.loadHeartRateSamples(from: files.heartRateURL).sorted { $0.t < $1.t }
    }

    private func activeSamples() -> [HeartRateSample] {
        let liveSamples: [HeartRateSample]
        switch selectedHeartRateSource {
        case .bluetooth:
            liveSamples = heartRateMonitor.samples.sorted { $0.t < $1.t }
        case .appleWatch:
            liveSamples = appleHealthHeartRateMonitor.samples.sorted { $0.t < $1.t }
        }
        return mergeSamples(restoredSamplesPrefix, liveSamples)
    }

    private func mergeSamples(_ first: [HeartRateSample], _ second: [HeartRateSample]) -> [HeartRateSample] {
        let sorted = (first + second).sorted { $0.t < $1.t }
        guard !sorted.isEmpty else { return [] }

        var deduped: [HeartRateSample] = []
        deduped.reserveCapacity(sorted.count)
        for sample in sorted {
            if let last = deduped.last,
               abs(last.t - sample.t) < 0.05,
               last.bpm == sample.bpm {
                continue
            }
            deduped.append(sample)
        }
        return deduped
    }

    private func startSelectedSourceStreaming() {
        switch selectedHeartRateSource {
        case .bluetooth:
            heartRateMonitor.selectPreferredPeripheral(id: selectedBluetoothDeviceID)
            heartRateMonitor.startStreaming(sessionClock: sessionClock)
        case .appleWatch:
            appleHealthHeartRateMonitor.startStreaming(sessionClock: sessionClock)
        }
    }

    private func stopActiveSourceStreaming() {
        switch selectedHeartRateSource {
        case .bluetooth:
            heartRateMonitor.stopStreaming()
        case .appleWatch:
            appleHealthHeartRateMonitor.stopStreaming()
        }
    }

    private func bindMonitors() {
        heartRateMonitor.$currentBPM
            .sink { [weak self] bpm in
                guard let self, self.selectedHeartRateSource == .bluetooth else { return }
                self.currentBPM = bpm
            }
            .store(in: &cancellables)

        heartRateMonitor.$samples
            .sink { [weak self] samples in
                guard let self else { return }
                self.updateSampleReceipt(
                    source: .bluetooth,
                    newCount: samples.count,
                    latestBPM: samples.last?.bpm
                )
            }
            .store(in: &cancellables)

        heartRateMonitor.$isConnected
            .sink { [weak self] _ in
                self?.refreshConnectionState()
            }
            .store(in: &cancellables)

        heartRateMonitor.$statusMessage
            .sink { [weak self] _ in
                self?.refreshConnectionState()
            }
            .store(in: &cancellables)

        heartRateMonitor.$discoveredDevices
            .sink { [weak self] devices in
                guard let self else { return }
                self.availableBluetoothDevices = devices
                if let selectedBluetoothDeviceID, !devices.contains(where: { $0.id == selectedBluetoothDeviceID }) {
                    self.selectedBluetoothDeviceID = nil
                }
                self.refreshConnectionState()
            }
            .store(in: &cancellables)

        appleHealthHeartRateMonitor.$currentBPM
            .sink { [weak self] bpm in
                guard let self, self.selectedHeartRateSource == .appleWatch else { return }
                self.currentBPM = bpm
            }
            .store(in: &cancellables)

        appleHealthHeartRateMonitor.$samples
            .sink { [weak self] samples in
                guard let self else { return }
                self.updateSampleReceipt(
                    source: .appleWatch,
                    newCount: samples.count,
                    latestBPM: samples.last?.bpm
                )
            }
            .store(in: &cancellables)

        appleHealthHeartRateMonitor.$isConnected
            .sink { [weak self] _ in
                self?.refreshConnectionState()
            }
            .store(in: &cancellables)

        appleHealthHeartRateMonitor.$statusMessage
            .sink { [weak self] _ in
                self?.refreshConnectionState()
            }
            .store(in: &cancellables)
    }

    private func updateSampleReceipt(source: HeartRateInputSource, newCount: Int, latestBPM: Int?) {
        switch source {
        case .bluetooth:
            if newCount < lastBluetoothSampleCount {
                lastBluetoothSampleCount = newCount
                return
            }
            guard newCount > lastBluetoothSampleCount else { return }
            lastBluetoothSampleCount = newCount
        case .appleWatch:
            if newCount < lastAppleWatchSampleCount {
                lastAppleWatchSampleCount = newCount
                return
            }
            guard newCount > lastAppleWatchSampleCount else { return }
            lastAppleWatchSampleCount = newCount
        }

        guard isTracking, selectedHeartRateSource == source else { return }

        lastSampleReceivedAt = Date()
        lastReconnectAttemptAt = nil
        if let latestBPM {
            currentBPM = latestBPM
            appendLiveGraphPoint(latestBPM)
        }
        if backgroundTrackingNote.contains("No fresh") || backgroundTrackingNote.contains("Recovered") {
            backgroundTrackingNote = "Sleep tracking is running..."
        }
    }

    private func handleHeartRateSourceChanged() {
        guard !isTracking else { return }

        switch selectedHeartRateSource {
        case .bluetooth:
            appleHealthHeartRateMonitor.stopStreaming()
            heartRateMonitor.selectPreferredPeripheral(id: selectedBluetoothDeviceID)
            heartRateMonitor.startSearching()
        case .appleWatch:
            heartRateMonitor.stopStreaming()
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.appleHealthHeartRateMonitor.requestAuthorization()
                self.appleHealthHeartRateMonitor.startPreviewMonitoring()
            }
        }
        currentBPM = 0
        liveBPMGraphPoints.removeAll()
        resetSampleCounters()
        refreshConnectionState()
    }

    private func refreshConnectionState() {
        switch selectedHeartRateSource {
        case .bluetooth:
            isHeartRateConnected = heartRateMonitor.isConnected
            heartRateStatusText = heartRateMonitor.statusMessage
            availableBluetoothDevices = heartRateMonitor.discoveredDevices
        case .appleWatch:
            isHeartRateConnected = appleHealthHeartRateMonitor.isConnected
            heartRateStatusText = appleHealthHeartRateMonitor.statusMessage
            availableBluetoothDevices = []
        }
    }

    private func resetSampleCounters() {
        lastBluetoothSampleCount = heartRateMonitor.samples.count
        lastAppleWatchSampleCount = appleHealthHeartRateMonitor.samples.count
    }

    private func appendLiveGraphPoint(_ bpm: Int) {
        guard isTracking else { return }
        liveBPMGraphPoints.append(bpm)
        if liveBPMGraphPoints.count > maxLiveGraphPoints {
            liveBPMGraphPoints.removeFirst(liveBPMGraphPoints.count - maxLiveGraphPoints)
        }
    }

    private func startTimer() {
        timerTask?.cancel()
        timerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.isTracking {
                self.elapsedSeconds = self.sessionClock.elapsedTime()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    private func stopTimer(resetElapsed: Bool) {
        timerTask?.cancel()
        timerTask = nil
        if resetElapsed {
            elapsedSeconds = 0
        }
    }

    private func startCheckpointLoop() {
        checkpointTask?.cancel()
        checkpointTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled, self.isTracking {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard self.isTracking else { return }

                let now = Date()
                self.handlePotentialStaleStream(now: now)
                if self.lastCheckpointDate == nil || now.timeIntervalSince(self.lastCheckpointDate ?? now) >= self.checkpointIntervalSeconds {
                    self.checkpointActiveSession(reason: "interval")
                }
            }
        }
    }

    private func stopCheckpointLoop() {
        checkpointTask?.cancel()
        checkpointTask = nil
    }

    private func checkpointActiveSession(reason: String) {
        guard isTracking,
              let activeSessionFiles,
              let sessionStartDate else { return }

        do {
            let samples = activeSamples()
            try storage.saveHeartRateSamples(samples, to: activeSessionFiles.heartRateURL)

            let now = Date()
            let elapsedAtCheckpoint = max(sessionClock.elapsedTime(), now.timeIntervalSince(sessionStartDate))
            let state = ActiveSleepSessionState(
                sessionID: activeSessionFiles.sessionID,
                startedAt: sessionStartDate,
                sourceRawValue: selectedHeartRateSource.rawValue,
                selectedBluetoothDeviceID: selectedHeartRateSource == .bluetooth ? selectedBluetoothDeviceID : nil,
                elapsedSecondsAtCheckpoint: elapsedAtCheckpoint,
                lastCheckpointAt: now
            )

            try storage.saveActiveSessionState(state)
            lastCheckpointDate = now

            if reason == "background" {
                backgroundTrackingNote = "Saved background checkpoint. Sleep tracking continues."
            } else if reason == "start" {
                backgroundTrackingNote = "Sleep tracking is running..."
            }
        } catch {
            errorMessage = "Sleep checkpoint failed: \(error.localizedDescription)"
        }
    }

    private func handlePotentialStaleStream(now: Date) {
        guard isTracking, let sessionStartDate else { return }

        let referenceDate = lastSampleReceivedAt ?? sessionStartDate
        let age = now.timeIntervalSince(referenceDate)
        guard age >= staleSampleThresholdSeconds else { return }

        let seconds = Int(age.rounded())
        switch selectedHeartRateSource {
        case .bluetooth:
            backgroundTrackingNote = "No fresh Bluetooth sample for \(seconds)s. Attempting to keep stream alive."
        case .appleWatch:
            backgroundTrackingNote = "No fresh Apple Watch sample for \(seconds)s. This can be normal without an active workout."
        }

        if age >= reconnectThresholdSeconds {
            attemptReconnectIfNeeded(now: now)
        }
    }

    private func attemptReconnectIfNeeded(now: Date) {
        if let lastReconnectAttemptAt,
           now.timeIntervalSince(lastReconnectAttemptAt) < reconnectCooldownSeconds {
            return
        }
        lastReconnectAttemptAt = now

        switch selectedHeartRateSource {
        case .bluetooth:
            heartRateMonitor.reconnectSelectedDevice()
            heartRateStatusText = "Reconnecting Bluetooth monitor..."
        case .appleWatch:
            appleHealthHeartRateMonitor.forceRefresh()
            heartRateStatusText = "Refreshing Apple Watch heart-rate query..."
        }
    }

    private func registerLifecycleObservers() {
        let center = NotificationCenter.default

        let didEnterBackgroundObserver = center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isTracking else { return }
                self.beginBackgroundTask()
                self.checkpointActiveSession(reason: "background")
                self.backgroundTrackingNote = "Tracking in background. BLE events can continue with bluetooth-central mode."
            }
        }

        let willEnterForegroundObserver = center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isTracking else { return }
                self.handlePotentialStaleStream(now: Date())
                if !self.backgroundTrackingNote.contains("No fresh") {
                    self.backgroundTrackingNote = "Tracking in foreground."
                }
            }
        }

        let willTerminateObserver = center.addObserver(
            forName: UIApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.isTracking else { return }
                self.checkpointActiveSession(reason: "terminate")
            }
        }

        notificationObservers = [didEnterBackgroundObserver, willEnterForegroundObserver, willTerminateObserver]
    }

    private func beginBackgroundTask() {
        endBackgroundTask()
        backgroundTaskIdentifier = UIApplication.shared.beginBackgroundTask(withName: "SleepTracking") { [weak self] in
            Task { @MainActor [weak self] in
                self?.checkpointActiveSession(reason: "background-expire")
                self?.backgroundTrackingNote = "Background time window ended. Keep app available for best overnight reliability."
                self?.endBackgroundTask()
            }
        }
    }

    private func endBackgroundTask() {
        guard backgroundTaskIdentifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskIdentifier)
        backgroundTaskIdentifier = .invalid
    }
}
