import Combine
import AVFoundation
import AudioToolbox
import Foundation
import UIKit

@MainActor
final class RecordViewModel: ObservableObject {
    enum ComparisonPVTPhase {
        case pre
        case post
    }

    struct PVTChartPoint: Identifiable {
        let id = UUID()
        let trial: Int
        let reactionMS: Int
    }

    enum IntervalPhase {
        case round
        case rest

        var title: String {
            switch self {
            case .round:
                return "Round"
            case .rest:
                return "Rest"
            }
        }
    }

    private struct DeviceSampleBuffer {
        var name: String
        var samples: [HeartRateSample]
    }

    @Published private(set) var currentBPM: Int = 0
    @Published private(set) var isRecording = false
    @Published private(set) var isHeartRateConnected = false
    @Published private(set) var cameraLabel: String = "Back Camera"
    @Published private(set) var cameraAspectRatio: CGFloat = 9.0 / 16.0
    @Published private(set) var cameraPreviewRotationAngle: CGFloat = 90
    @Published private(set) var cameraZoomFactor: CGFloat = 1.0
    @Published private(set) var maxCameraZoomFactor: CGFloat = 1.0
    @Published private(set) var liveBPMGraphPoints: [Int] = []
    @Published private(set) var firstStrapGraphPoints: [Int] = []
    @Published private(set) var secondStrapGraphPoints: [Int] = []
    @Published private(set) var availableBluetoothDevices: [DiscoverableHeartRateDevice] = []
    @Published private(set) var connectedBluetoothReadings: [ConnectedHeartRateReading] = []
    @Published private(set) var participantProfiles: [PvPParticipantProfile] = []
    @Published private(set) var participantAssignmentsByDevice: [UUID: UUID] = [:]
    @Published private(set) var heartRateStatusText: String = "Searching for heart-rate monitor..."
    @Published private(set) var captureVideoEnabled: Bool = true
    @Published private(set) var recordingElapsedSeconds: TimeInterval = 0
    @Published var intervalBellEnabled = false
    @Published var intervalRoundSeconds = 180
    @Published var intervalRestSeconds = 60
    @Published var intervalWarningSeconds = 10
    @Published private(set) var intervalPhase: IntervalPhase = .round
    @Published private(set) var intervalRoundIndex = 1
    @Published private(set) var intervalSecondsRemaining = 0
    @Published var allowMultipleBluetoothConnections = true {
        didSet {
            guard oldValue != allowMultipleBluetoothConnections else { return }
            if !allowMultipleBluetoothConnections {
                enforceSingleBluetoothSelectionIfNeeded()
                clearDualBluetoothGraph()
            }
        }
    }
    @Published var selectedHeartRateSource: HeartRateInputSource = AppSettings.preferredHeartRateSource {
        didSet {
            guard oldValue != selectedHeartRateSource else { return }
            AppSettings.setPreferredHeartRateSource(selectedHeartRateSource)
            handleHeartRateSourceChanged()
        }
    }
    @Published var selectedBluetoothDeviceIDs: Set<UUID> = AppSettings.preferredHeartRateDeviceIDs {
        didSet {
            guard oldValue != selectedBluetoothDeviceIDs else { return }
            AppSettings.setPreferredHeartRateDeviceIDs(selectedBluetoothDeviceIDs)
            heartRateMonitor.setSelectedPeripheralIDs(selectedBluetoothDeviceIDs)
            clearDualBluetoothGraph()
            refreshHeartRateConnectionState()
        }
    }
    @Published var activeComparisonPVTPhase: ComparisonPVTPhase?
    @Published var isComparisonPVTPresented = false
    @Published var errorMessage: String?

    let cameraRecorder = CameraRecorder()

    private let heartRateMonitor = HeartRateMonitor()
    private let appleHealthHeartRateMonitor = AppleHealthHeartRateMonitor()
    private let pvpProfileStore = PvPProfileStore()
    private let storage = SessionStorage()
    private let sessionClock = SessionClock()

    private var activeSessionFiles: SessionFiles?
    private var recordingStartDate: Date?
    private var recordingDurationAtStop: TimeInterval = 0
    private var recordedSamplesAtStop: [HeartRateSample] = []
    private var recordedDeviceSeriesAtStop: [HeartRateDeviceSeries] = []
    private var cancellables: Set<AnyCancellable> = []
    private let maxLiveGraphPoints = 120
    private let minDeviceSampleInterval: TimeInterval = 0.25
    private var prePVTResult: RecordPVTResult?
    private var postPVTResult: RecordPVTResult?
    private var didCompleteRecordingForComparison = false
    private var isCameraPreparing = false
    private var recordingTimerTask: Task<Void, Never>?
    private var intervalTimerTask: Task<Void, Never>?
    private var bellPlaybackTask: Task<Void, Never>?
    private let intervalDingToneData = RecordViewModel.makeIntervalDingToneWAVData()
    private var activeBellPlayers: [AVAudioPlayer] = []
    private var pinchGestureStartZoom: CGFloat?
    private var dualGraphDeviceIDs: [UUID] = []
    private var bluetoothDeviceSampleBuffers: [UUID: DeviceSampleBuffer] = [:]
    private var currentUserEmail: String?
    private var currentUserDisplayName: String?
    private var currentFirebaseUID: String?
    private var currentUserProfile: UserOnboardingProfile?

    func setCurrentUser(email: String?, displayName: String?, firebaseUID: String?, profile: UserOnboardingProfile?) {
        currentUserEmail = email?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        currentUserDisplayName = displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        currentFirebaseUID = firebaseUID?.trimmingCharacters(in: .whitespacesAndNewlines)
        currentUserProfile = profile
    }
    private var participantOwnerKey = "default"
    private var didTriggerRoundWarning = false

    init() {
        bindHeartRateMonitor()
    }

    func prepare() async {
        if !allowMultipleBluetoothConnections {
            allowMultipleBluetoothConnections = true
        }
        await syncCameraForCurrentMode()
        enforceSingleBluetoothSelectionIfNeeded()
        if selectedHeartRateSource == .bluetooth {
            heartRateMonitor.setSelectedPeripheralIDs(selectedBluetoothDeviceIDs)
            heartRateMonitor.startSearching()
        } else {
            heartRateMonitor.stopStreaming()
            await appleHealthHeartRateMonitor.requestAuthorization()
            appleHealthHeartRateMonitor.startPreviewMonitoring()
        }
        refreshHeartRateConnectionState()
    }

    func loadParticipantProfiles(ownerKey: String) {
        participantOwnerKey = ownerKey
        let bundle = pvpProfileStore.loadBundle(ownerKey: ownerKey)
        participantProfiles = bundle.profiles.sorted { lhs, rhs in
            lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }

        let validProfileIDs = Set(participantProfiles.map(\.id))
        participantAssignmentsByDevice = bundle.deviceAssignments.reduce(into: [:]) { partial, entry in
            guard let deviceID = UUID(uuidString: entry.key),
                  validProfileIDs.contains(entry.value) else {
                return
            }
            partial[deviceID] = entry.value
        }
    }

    func startRecording() {
        guard canStartRecording else {
            errorMessage = "Complete the Pre-PVT first."
            return
        }

        do {
            let sessionFiles = try storage.createSessionFiles()
            activeSessionFiles = sessionFiles
            didCompleteRecordingForComparison = false
            postPVTResult = nil

            recordingStartDate = Date()
            sessionClock.start()
            recordedSamplesAtStop = []
            recordedDeviceSeriesAtStop = []
            bluetoothDeviceSampleBuffers.removeAll()
            liveBPMGraphPoints.removeAll()
            clearDualBluetoothGraph()
            currentBPM = 0

            switch selectedHeartRateSource {
            case .bluetooth:
                heartRateMonitor.setSelectedPeripheralIDs(selectedBluetoothDeviceIDs)
                heartRateMonitor.startStreaming(sessionClock: sessionClock)
            case .appleWatch:
                appleHealthHeartRateMonitor.startStreaming(sessionClock: sessionClock)
            }

            if captureVideoEnabled {
                guard cameraRecorder.isConfigured else {
                    errorMessage = "Camera is still preparing. Try again in a moment."
                    activeSessionFiles = nil
                    recordingStartDate = nil
                    recordingDurationAtStop = 0
                    recordedSamplesAtStop = []
                    stopActiveHeartRateStreaming()
                    return
                }
                cameraRecorder.startRunningIfNeeded()
                cameraRecorder.startRecording(to: sessionFiles.videoURL) { [weak self] result in
                    Task { @MainActor in
                        self?.handleRecordingCompletion(result: result.map(Optional.some))
                    }
                }
            }

            if AppSettings.keepScreenAwakeDuringRecording {
                UIApplication.shared.isIdleTimerDisabled = true
            }
            isRecording = true
            startRecordingTimer()
            startIntervalTimerIfNeeded()
        } catch {
            errorMessage = "Failed to create session: \(error.localizedDescription)"
        }
    }

    func stopRecording() {
        recordingDurationAtStop = sessionClock.elapsedTime()
        recordedSamplesAtStop = activeSamples()
        recordedDeviceSeriesAtStop = activeDeviceSeries()
        if captureVideoEnabled {
            cameraRecorder.stopRecording()
        } else {
            handleRecordingCompletion(result: .success(nil))
        }
        stopActiveHeartRateStreaming()
        UIApplication.shared.isIdleTimerDisabled = false
        isRecording = false
        stopRecordingTimer(resetValue: false)
        stopIntervalTimer(resetValue: true)
        didCompleteRecordingForComparison = true
        if selectedHeartRateSource == .bluetooth {
            heartRateMonitor.startSearching()
        } else {
            appleHealthHeartRateMonitor.startPreviewMonitoring()
        }
        if pvtComparisonEnabled && postPVTResult == nil {
            errorMessage = "Complete the Post-PVT to see comparison."
        }
    }

    func toggleCamera() {
        guard captureVideoEnabled else { return }
        cameraRecorder.toggleCamera()
    }

    func updateCameraZoomGesture(scale: CGFloat) {
        guard captureVideoEnabled else { return }
        if pinchGestureStartZoom == nil {
            pinchGestureStartZoom = cameraZoomFactor
        }
        let base = pinchGestureStartZoom ?? cameraZoomFactor
        cameraRecorder.setZoomFactor(base * scale)
    }

    func endCameraZoomGesture() {
        pinchGestureStartZoom = nil
    }

    var cameraZoomLabel: String {
        String(format: "%.1fx", cameraZoomFactor)
    }

    func setCaptureVideoEnabled(_ enabled: Bool) {
        guard !isRecording, captureVideoEnabled != enabled else { return }
        captureVideoEnabled = enabled
        Task { @MainActor in
            await syncCameraForCurrentMode()
        }
    }

    func updateIntervalRoundSeconds(_ value: Int) {
        intervalRoundSeconds = max(10, value)
        if intervalWarningSeconds >= intervalRoundSeconds {
            intervalWarningSeconds = max(0, intervalRoundSeconds - 1)
        }
        if isRecording, intervalPhase == .round, intervalSecondsRemaining > intervalRoundSeconds {
            intervalSecondsRemaining = intervalRoundSeconds
        }
    }

    func updateIntervalRestSeconds(_ value: Int) {
        intervalRestSeconds = max(0, value)
        if isRecording, intervalPhase == .rest, intervalSecondsRemaining > intervalRestSeconds {
            intervalSecondsRemaining = intervalRestSeconds
        }
    }

    func updateIntervalWarningSeconds(_ value: Int) {
        let maxWarning = max(0, intervalRoundSeconds - 1)
        intervalWarningSeconds = min(max(0, value), maxWarning)
    }

    func rescanBluetoothHeartRateDevices() {
        heartRateMonitor.setSelectedPeripheralIDs(selectedBluetoothDeviceIDs)
        heartRateMonitor.startSearching(resetDiscovered: true)
    }

    func toggleBluetoothDeviceSelection(_ id: UUID) {
        var next = selectedBluetoothDeviceIDs
        if next.contains(id) {
            next.remove(id)
        } else {
            next.insert(id)
        }
        selectedBluetoothDeviceIDs = next
    }

    func assignParticipant(_ profileID: UUID?, to deviceID: UUID) {
        if let profileID {
            participantAssignmentsByDevice[deviceID] = profileID
        } else {
            participantAssignmentsByDevice.removeValue(forKey: deviceID)
        }
        persistParticipantAssignments()
    }

    func clearBluetoothDeviceSelection() {
        selectedBluetoothDeviceIDs = []
    }

    func isBluetoothDeviceSelected(_ id: UUID) -> Bool {
        selectedBluetoothDeviceIDs.contains(id)
    }

    var bluetoothSelectionSummary: String {
        guard !selectedBluetoothDeviceIDs.isEmpty else { return "Select" }

        let selectedDevices = availableBluetoothDevices.filter { selectedBluetoothDeviceIDs.contains($0.id) }
        guard let first = selectedDevices.first else {
            return "\(selectedBluetoothDeviceIDs.count) selected"
        }

        let firstLabel = compactDeviceName(first.displayName)
        if selectedBluetoothDeviceIDs.count == 1 {
            return firstLabel
        }
        return "\(firstLabel) +\(selectedBluetoothDeviceIDs.count - 1)"
    }

    var primaryBPMLabel: String {
        if selectedHeartRateSource == .bluetooth && connectedBluetoothReadings.count > 1 {
            return "Avg \(currentBPM) BPM"
        }
        return "\(currentBPM) BPM"
    }

    var displayedBluetoothReadings: [ConnectedHeartRateReading] {
        connectedBluetoothReadings
    }

    var dualDisplayedBluetoothReadings: [ConnectedHeartRateReading] {
        guard selectedHeartRateSource == .bluetooth else { return [] }

        let byID = Dictionary(uniqueKeysWithValues: connectedBluetoothReadings.map { ($0.id, $0) })
        let orderedByGraph = dualGraphDeviceIDs.compactMap { byID[$0] }
        if orderedByGraph.count >= 2 {
            return Array(orderedByGraph.prefix(2))
        }

        return Array(connectedBluetoothReadings.prefix(2))
    }

    var selectedDevicesForParticipantAssignment: [DiscoverableHeartRateDevice] {
        availableBluetoothDevices.filter { selectedBluetoothDeviceIDs.contains($0.id) }
    }

    func participantName(for deviceID: UUID) -> String? {
        guard let profileID = participantAssignmentsByDevice[deviceID],
              let profile = participantProfiles.first(where: { $0.id == profileID }) else {
            return nil
        }
        return profile.displayName
    }

    func participantDetailLabel(for deviceID: UUID) -> String? {
        guard let name = participantName(for: deviceID) else { return nil }
        return "Participant: \(name)"
    }

    func displayName(for reading: ConnectedHeartRateReading) -> String {
        if let participant = participantName(for: reading.id) {
            return participant
        }
        return compactDeviceName(reading.displayName)
    }

    var shouldRenderDualBluetoothGraph: Bool {
        selectedHeartRateSource == .bluetooth &&
            dualGraphDeviceIDs.count == 2 &&
            firstStrapGraphPoints.count >= 2 &&
            secondStrapGraphPoints.count >= 2
    }

    func requestAppleWatchPermission() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.appleHealthHeartRateMonitor.requestAuthorization()
            if self.selectedHeartRateSource == .appleWatch, !self.isRecording {
                self.appleHealthHeartRateMonitor.startPreviewMonitoring()
            }
            self.refreshHeartRateConnectionState()
        }
    }

    var pvtComparisonEnabled: Bool {
        AppSettings.requirePrePostPVTForRecording
    }

    var comparisonPVTDurationSeconds: Int {
        AppSettings.pvtComparisonDurationSeconds
    }

    var canStartRecording: Bool {
        !isRecording && (!pvtComparisonEnabled || prePVTResult != nil)
    }

    var canRunPrePVT: Bool {
        !isRecording
    }

    var canRunPostPVT: Bool {
        !isRecording && didCompleteRecordingForComparison
    }

    var shouldShowPVTComparison: Bool {
        pvtComparisonEnabled && didCompleteRecordingForComparison && prePVTResult != nil && postPVTResult != nil
    }

    var preSummaryText: String {
        summaryText(for: prePVTResult)
    }

    var postSummaryText: String {
        summaryText(for: postPVTResult)
    }

    var prePVTChartPoints: [PVTChartPoint] {
        chartPoints(for: prePVTResult)
    }

    var postPVTChartPoints: [PVTChartPoint] {
        chartPoints(for: postPVTResult)
    }

    func beginPrePVT() {
        guard canRunPrePVT else { return }
        activeComparisonPVTPhase = .pre
        isComparisonPVTPresented = true
    }

    func beginPostPVT() {
        guard canRunPostPVT else {
            errorMessage = "Record a session first, then run Post-PVT."
            return
        }
        activeComparisonPVTPhase = .post
        isComparisonPVTPresented = true
    }

    func completeComparisonPVT(with result: RecordPVTResult) {
        guard let phase = activeComparisonPVTPhase else { return }
        switch phase {
        case .pre:
            prePVTResult = result
            postPVTResult = nil
            didCompleteRecordingForComparison = false
        case .post:
            postPVTResult = result
        }
        isComparisonPVTPresented = false
        activeComparisonPVTPhase = nil
        errorMessage = nil
    }

    func cancelComparisonPVT() {
        isComparisonPVTPresented = false
        activeComparisonPVTPhase = nil
    }

    private func bindHeartRateMonitor() {
        heartRateMonitor.$currentBPM
            .sink { [weak self] value in
                guard let self, self.selectedHeartRateSource == .bluetooth else { return }
                self.currentBPM = value
                self.appendLiveGraphPoint(value)
            }
            .store(in: &cancellables)

        heartRateMonitor.$isConnected
            .sink { [weak self] _ in
                guard let self else { return }
                if self.selectedHeartRateSource == .bluetooth && !self.heartRateMonitor.isConnected {
                    self.liveBPMGraphPoints.removeAll()
                }
                self.refreshHeartRateConnectionState()
            }
            .store(in: &cancellables)

        heartRateMonitor.$discoveredDevices
            .sink { [weak self] devices in
                guard let self else { return }
                self.availableBluetoothDevices = devices
                let availableIDs = Set(devices.map(\.id))
                let filteredSelection = self.selectedBluetoothDeviceIDs.intersection(availableIDs)
                if filteredSelection != self.selectedBluetoothDeviceIDs {
                    self.selectedBluetoothDeviceIDs = filteredSelection
                }
                self.enforceSingleBluetoothSelectionIfNeeded()
                self.refreshHeartRateConnectionState()
            }
            .store(in: &cancellables)

        heartRateMonitor.$connectedReadings
            .sink { [weak self] readings in
                guard let self else { return }
                if self.selectedHeartRateSource == .bluetooth {
                    self.updateDualBluetoothGraph(using: readings)
                    self.captureBluetoothDeviceSamples(from: readings)
                }
                self.refreshHeartRateConnectionState()
            }
            .store(in: &cancellables)

        heartRateMonitor.$statusMessage
            .sink { [weak self] _ in
                self?.refreshHeartRateConnectionState()
            }
            .store(in: &cancellables)

        appleHealthHeartRateMonitor.$currentBPM
            .sink { [weak self] value in
                guard let self, self.selectedHeartRateSource == .appleWatch else { return }
                self.currentBPM = value
                self.appendLiveGraphPoint(value)
            }
            .store(in: &cancellables)

        appleHealthHeartRateMonitor.$isConnected
            .sink { [weak self] _ in
                guard let self else { return }
                if self.selectedHeartRateSource == .appleWatch && !self.appleHealthHeartRateMonitor.isConnected {
                    self.liveBPMGraphPoints.removeAll()
                }
                self.refreshHeartRateConnectionState()
            }
            .store(in: &cancellables)

        appleHealthHeartRateMonitor.$statusMessage
            .sink { [weak self] _ in
                self?.refreshHeartRateConnectionState()
            }
            .store(in: &cancellables)

        cameraRecorder.$currentCameraPosition
            .sink { [weak self] position in
                self?.cameraLabel = position == .front ? "Front Camera" : "Back Camera"
            }
            .store(in: &cancellables)

        cameraRecorder.$activeAspectRatio
            .sink { [weak self] ratio in
                self?.cameraAspectRatio = ratio
            }
            .store(in: &cancellables)

        cameraRecorder.$previewRotationAngle
            .sink { [weak self] angle in
                self?.cameraPreviewRotationAngle = angle
            }
            .store(in: &cancellables)

        cameraRecorder.$zoomFactor
            .sink { [weak self] value in
                self?.cameraZoomFactor = value
            }
            .store(in: &cancellables)

        cameraRecorder.$maxZoomFactor
            .sink { [weak self] value in
                self?.maxCameraZoomFactor = value
            }
            .store(in: &cancellables)
    }

    private func handleRecordingCompletion(result: Result<URL?, Error>) {
        guard let sessionFiles = activeSessionFiles else { return }

        let videoFileName: String?
        switch result {
        case .success(let outputURL):
            videoFileName = outputURL?.lastPathComponent
        case .failure(let error):
            videoFileName = nil
            errorMessage = "Video failed. Saved heart-rate data only. \(error.localizedDescription)"
        }

        do {
            let samples = recordedSamplesAtStop
            try storage.saveHeartRateSamples(samples, to: sessionFiles.heartRateURL)
            try storage.saveHeartRateDeviceSeries(recordedDeviceSeriesAtStop, to: sessionFiles.heartRateDeviceSeriesURL)

            let duration = max(recordingDurationAtStop, samples.last?.t ?? 0)
            let metadata = WorkoutSessionMetadata(
                id: sessionFiles.sessionID,
                startedAt: recordingStartDate ?? Date(),
                duration: duration,
                videoFileName: videoFileName,
                heartRateFileName: sessionFiles.heartRateURL.lastPathComponent,
                uploadState: .syncing,
                uploadErrorMessage: nil
            )
            try storage.saveMetadata(metadata, to: sessionFiles.metadataURL)
            NotificationCenter.default.post(name: Notification.Name("SessionLibraryDidChange"), object: nil)

            Task {
                await uploadSessionToAPI(samples: samples, metadata: metadata, sessionFiles: sessionFiles)
            }
        } catch {
            errorMessage = "Saving session failed: \(error.localizedDescription)"
        }

        activeSessionFiles = nil
        recordingStartDate = nil
        recordingDurationAtStop = 0
        recordedSamplesAtStop = []
        recordedDeviceSeriesAtStop = []
        bluetoothDeviceSampleBuffers.removeAll()
        stopRecordingTimer(resetValue: true)
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func syncCameraForCurrentMode() async {
        if captureVideoEnabled {
            if !cameraRecorder.isConfigured && !isCameraPreparing {
                isCameraPreparing = true
                await cameraRecorder.configureSession()
                isCameraPreparing = false
            }
            guard captureVideoEnabled else {
                cameraRecorder.stopRunningIfNeeded()
                return
            }
            cameraRecorder.startRunningIfNeeded()
        } else {
            cameraRecorder.stopRunningIfNeeded()
        }
    }

    private func handleHeartRateSourceChanged() {
        liveBPMGraphPoints.removeAll()
        clearDualBluetoothGraph()
        currentBPM = 0

        if !isRecording {
            switch selectedHeartRateSource {
            case .bluetooth:
                appleHealthHeartRateMonitor.stopStreaming()
                heartRateMonitor.setSelectedPeripheralIDs(selectedBluetoothDeviceIDs)
                heartRateMonitor.startSearching()
            case .appleWatch:
                heartRateMonitor.stopStreaming()
                requestAppleWatchPermission()
            }
        }

        refreshHeartRateConnectionState()
    }

    private func refreshHeartRateConnectionState() {
        switch selectedHeartRateSource {
        case .bluetooth:
            currentBPM = heartRateMonitor.currentBPM
            isHeartRateConnected = heartRateMonitor.isConnected
            heartRateStatusText = heartRateMonitor.statusMessage
            connectedBluetoothReadings = heartRateMonitor.connectedReadings

        case .appleWatch:
            currentBPM = appleHealthHeartRateMonitor.currentBPM
            isHeartRateConnected = appleHealthHeartRateMonitor.isConnected
            heartRateStatusText = appleHealthHeartRateMonitor.statusMessage
            connectedBluetoothReadings = []
            clearDualBluetoothGraph()
        }
    }

    private func activeSamples() -> [HeartRateSample] {
        switch selectedHeartRateSource {
        case .bluetooth:
            return heartRateMonitor.samples
        case .appleWatch:
            return appleHealthHeartRateMonitor.samples
        }
    }

    private func activeDeviceSeries() -> [HeartRateDeviceSeries] {
        bluetoothDeviceSampleBuffers
            .map { id, bucket in
                HeartRateDeviceSeries(
                    deviceID: id,
                    deviceName: bucket.name,
                    samples: bucket.samples
                )
            }
            .filter { !$0.samples.isEmpty }
            .sorted { lhs, rhs in
                lhs.deviceName.localizedCaseInsensitiveCompare(rhs.deviceName) == .orderedAscending
            }
    }

    private func stopActiveHeartRateStreaming() {
        switch selectedHeartRateSource {
        case .bluetooth:
            heartRateMonitor.stopStreaming()
        case .appleWatch:
            appleHealthHeartRateMonitor.stopStreaming()
        }
        refreshHeartRateConnectionState()
    }

    private func appendLiveGraphPoint(_ bpm: Int) {
        guard bpm > 0 else { return }
        liveBPMGraphPoints.append(bpm)
        if liveBPMGraphPoints.count > maxLiveGraphPoints {
            liveBPMGraphPoints.removeFirst(liveBPMGraphPoints.count - maxLiveGraphPoints)
        }
    }

    private func captureBluetoothDeviceSamples(from readings: [ConnectedHeartRateReading]) {
        guard isRecording, selectedHeartRateSource == .bluetooth else { return }
        let t = sessionClock.elapsedTime()

        for reading in readings where reading.bpm > 0 {
            var bucket = bluetoothDeviceSampleBuffers[reading.id] ?? DeviceSampleBuffer(
                name: reading.displayName,
                samples: []
            )
            bucket.name = reading.displayName

            if let last = bucket.samples.last,
               last.bpm == reading.bpm,
               (t - last.t) < minDeviceSampleInterval {
                bluetoothDeviceSampleBuffers[reading.id] = bucket
                continue
            }

            bucket.samples.append(HeartRateSample(t: t, bpm: reading.bpm))
            bluetoothDeviceSampleBuffers[reading.id] = bucket
        }
    }

    private func enforceSingleBluetoothSelectionIfNeeded() {
        guard !allowMultipleBluetoothConnections else { return }
        guard selectedBluetoothDeviceIDs.count > 1 else { return }

        if let primary = availableBluetoothDevices.first(where: { selectedBluetoothDeviceIDs.contains($0.id) })?.id {
            selectedBluetoothDeviceIDs = [primary]
            return
        }

        if let fallback = selectedBluetoothDeviceIDs.first {
            selectedBluetoothDeviceIDs = [fallback]
        } else {
            selectedBluetoothDeviceIDs = []
        }
    }

    private func updateDualBluetoothGraph(using readings: [ConnectedHeartRateReading]) {
        guard selectedHeartRateSource == .bluetooth else {
            clearDualBluetoothGraph()
            return
        }

        let preferredIDs = preferredDualGraphDeviceIDs()
        guard preferredIDs.count == 2 else {
            clearDualBluetoothGraph()
            return
        }

        if preferredIDs != dualGraphDeviceIDs {
            clearDualBluetoothGraph()
            dualGraphDeviceIDs = preferredIDs
        }

        let bpmByID = Dictionary(uniqueKeysWithValues: readings.map { ($0.id, $0.bpm) })
        let firstBPM = bpmByID[preferredIDs[0]] ?? 0
        let secondBPM = bpmByID[preferredIDs[1]] ?? 0

        // Keep both series synchronized so visual overlap and ordering stay correct.
        let resolvedFirst = firstBPM > 0 ? firstBPM : (firstStrapGraphPoints.last ?? 0)
        let resolvedSecond = secondBPM > 0 ? secondBPM : (secondStrapGraphPoints.last ?? 0)
        guard resolvedFirst > 0, resolvedSecond > 0 else { return }

        appendDualBluetoothGraphPair(first: resolvedFirst, second: resolvedSecond)
    }

    private func preferredDualGraphDeviceIDs() -> [UUID] {
        let selectedIDs = selectedBluetoothDeviceIDs
        guard selectedIDs.count >= 2 else { return [] }

        let ordered = Array(selectedIDs).sorted { lhs, rhs in
            let lhsName = resolvedDeviceName(for: lhs)
            let rhsName = resolvedDeviceName(for: rhs)
            let comparison = lhsName.localizedCaseInsensitiveCompare(rhsName)
            if comparison == .orderedSame {
                return lhs.uuidString < rhs.uuidString
            }
            return comparison == .orderedAscending
        }
        return Array(ordered.prefix(2))
    }

    private func resolvedDeviceName(for id: UUID) -> String {
        if let connected = connectedBluetoothReadings.first(where: { $0.id == id })?.displayName {
            return connected
        }
        if let available = availableBluetoothDevices.first(where: { $0.id == id })?.displayName {
            return available
        }
        return id.uuidString
    }

    private func appendDualBluetoothGraphPair(first: Int, second: Int) {
        firstStrapGraphPoints.append(first)
        secondStrapGraphPoints.append(second)

        let overflow = max(0, firstStrapGraphPoints.count - maxLiveGraphPoints)
        if overflow > 0 {
            firstStrapGraphPoints.removeFirst(overflow)
            secondStrapGraphPoints.removeFirst(min(overflow, secondStrapGraphPoints.count))
        }
    }

    private func clearDualBluetoothGraph() {
        firstStrapGraphPoints.removeAll()
        secondStrapGraphPoints.removeAll()
        dualGraphDeviceIDs.removeAll()
    }

    private func persistParticipantAssignments() {
        let validProfileIDs = Set(participantProfiles.map(\.id))
        participantAssignmentsByDevice = participantAssignmentsByDevice.filter { validProfileIDs.contains($0.value) }

        let assignmentMap = participantAssignmentsByDevice.reduce(into: [String: UUID]()) { partial, entry in
            partial[entry.key.uuidString] = entry.value
        }
        let bundle = PvPProfileBundle(
            profiles: participantProfiles,
            deviceAssignments: assignmentMap
        )

        do {
            try pvpProfileStore.saveBundle(bundle, ownerKey: participantOwnerKey)
        } catch {
            errorMessage = "Failed saving participant assignment: \(error.localizedDescription)"
        }
    }

    private func compactDeviceName(_ name: String) -> String {
        let normalized = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return "Device" }

        let tokens = normalized
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
        let candidate = tokens.first(where: { $0.rangeOfCharacter(from: .decimalDigits) != nil }) ?? tokens.first ?? normalized

        if candidate.count <= 4 {
            return candidate
        }

        return "\(candidate.prefix(4))..."
    }

    private func summaryText(for result: RecordPVTResult?) -> String {
        guard let result else { return "Not completed" }
        return "Mean \(result.meanReactionMS) ms • Lapses \(result.lapses) • False starts \(result.falseStarts)"
    }

    private func chartPoints(for result: RecordPVTResult?) -> [PVTChartPoint] {
        guard let result else { return [] }
        return result.reactionTimesMS.enumerated().map { idx, ms in
            PVTChartPoint(trial: idx + 1, reactionMS: ms)
        }
    }

    private func uploadSessionToAPI(samples: [HeartRateSample], metadata: WorkoutSessionMetadata, sessionFiles: SessionFiles) async {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current

        let startedAt = formatter.string(from: metadata.startedAt)
        let endedAt = formatter.string(from: metadata.startedAt.addingTimeInterval(metadata.duration))
        let uploadedVideoURL: String?
        if metadata.videoFileName != nil,
           FileManager.default.fileExists(atPath: sessionFiles.videoURL.path) {
            uploadedVideoURL = try? await APIClient.shared.uploadVideo(fileURL: sessionFiles.videoURL).videoUrl
        } else {
            uploadedVideoURL = nil
        }

        let userEmail = currentUserEmail?.isEmpty == false ? currentUserEmail : "local-user@tickerflip.local"
        let profile = currentUserProfile
        let request = APIFullSessionUploadRequest(
            session: .init(
                userId: nil,
                userEmail: userEmail,
                firebaseUid: currentFirebaseUID,
                displayName: currentUserDisplayName,
                age: profile?.age,
                weightLb: profile?.weightLb,
                heightCm: profile?.heightCm,
                gender: profile?.gender,
                sessionUuid: metadata.id,
                title: nil,
                note: nil,
                startedAt: startedAt,
                endedAt: endedAt,
                durationSeconds: metadata.duration,
                minBpm: samples.map(\.bpm).min(),
                avgBpm: samples.isEmpty ? nil : Int(round(Double(samples.reduce(0) { $0 + $1.bpm }) / Double(samples.count))),
                maxBpm: samples.map(\.bpm).max(),
                videoUrl: uploadedVideoURL
            ),
            heartRateSamples: samples.map { .init(tSeconds: $0.t, bpm: $0.bpm) },
            prePvt: apiPVTResult(from: prePVTResult, phase: "pre"),
            postPvt: apiPVTResult(from: postPVTResult, phase: "post")
        )

        do {
            _ = try await APIClient.shared.uploadFullSession(request)
            var updatedMetadata = metadata
            updatedMetadata.uploadState = .synced
            updatedMetadata.uploadErrorMessage = nil
            try? storage.saveMetadata(updatedMetadata, to: sessionFiles.metadataURL)
            NotificationCenter.default.post(name: Notification.Name("SessionLibraryDidChange"), object: nil)
        } catch {
            var updatedMetadata = metadata
            updatedMetadata.uploadState = .failed
            updatedMetadata.uploadErrorMessage = error.localizedDescription
            try? storage.saveMetadata(updatedMetadata, to: sessionFiles.metadataURL)
            NotificationCenter.default.post(name: Notification.Name("SessionLibraryDidChange"), object: nil)
            errorMessage = "Session saved on this device. API sync failed: \(error.localizedDescription)"
        }
    }

    private func startRecordingTimer() {
        stopRecordingTimer(resetValue: true)
        recordingTimerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.isRecording {
                self.recordingElapsedSeconds = self.sessionClock.elapsedTime()
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func stopRecordingTimer(resetValue: Bool) {
        recordingTimerTask?.cancel()
        recordingTimerTask = nil
        if resetValue {
            recordingElapsedSeconds = 0
        }
    }

    func recordingElapsedLabel() -> String {
        let clamped = max(0, Int(recordingElapsedSeconds.rounded(.down)))
        let mins = clamped / 60
        let secs = clamped % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    var intervalRoundLabel: String {
        formatClockLabel(seconds: intervalRoundSeconds)
    }

    var intervalRestLabel: String {
        intervalRestSeconds == 0 ? "Off" : formatClockLabel(seconds: intervalRestSeconds)
    }

    var intervalWarningLabel: String {
        intervalWarningSeconds == 0 ? "Off" : "\(intervalWarningSeconds)s left"
    }

    var intervalLiveLabel: String {
        guard intervalBellEnabled, isRecording else { return "" }
        let phaseLabel: String = {
            if intervalPhase == .round {
                return "\(intervalPhase.title) \(intervalRoundIndex)"
            }
            return intervalPhase.title
        }()
        return "\(phaseLabel) • \(formatClockLabel(seconds: max(0, intervalSecondsRemaining)))"
    }

    private func apiPVTResult(from result: RecordPVTResult?, phase: String) -> APIFullSessionUploadRequest.PVTResult? {
        guard let result else { return nil }
        return .init(
            phase: phase,
            durationSeconds: result.durationSeconds,
            totalStimuli: result.totalStimuli,
            correctTaps: result.correctTaps,
            incorrectTaps: result.incorrectTaps,
            falseStarts: result.falseStarts,
            misses: result.misses,
            lapses: result.lapses,
            meanReactionMs: result.meanReactionMS,
            medianReactionMs: result.medianReactionMS,
            fastestReactionMs: result.fastestReactionMS,
            slowestReactionMs: result.slowestReactionMS,
            trialPoints: result.reactionTimesMS.enumerated().map { idx, ms in
                .init(trialIndex: idx + 1, reactionMs: ms)
            }
        )
    }

    private func startIntervalTimerIfNeeded() {
        stopIntervalTimer(resetValue: false)
        guard intervalBellEnabled else { return }

        intervalPhase = .round
        intervalRoundIndex = 1
        intervalSecondsRemaining = max(1, intervalRoundSeconds)
        didTriggerRoundWarning = false

        activateBellAudioSession()
        playRoundBell()

        intervalTimerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled && self.isRecording && self.intervalBellEnabled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                guard !Task.isCancelled else { return }
                self.tickIntervalTimer()
            }
        }
    }

    private func stopIntervalTimer(resetValue: Bool) {
        intervalTimerTask?.cancel()
        intervalTimerTask = nil
        bellPlaybackTask?.cancel()
        bellPlaybackTask = nil
        activeBellPlayers.removeAll()
        deactivateBellAudioSession()

        if resetValue {
            intervalPhase = .round
            intervalRoundIndex = 1
            intervalSecondsRemaining = 0
            didTriggerRoundWarning = false
        }
    }

    private func tickIntervalTimer() {
        guard intervalSecondsRemaining > 0 else {
            advanceIntervalPhase()
            return
        }

        intervalSecondsRemaining -= 1

        if intervalPhase == .round,
           intervalWarningSeconds > 0,
           !didTriggerRoundWarning,
           intervalSecondsRemaining == intervalWarningSeconds {
            didTriggerRoundWarning = true
            playWarningBell()
        }

        if intervalSecondsRemaining <= 0 {
            advanceIntervalPhase()
        }
    }

    private func advanceIntervalPhase() {
        switch intervalPhase {
        case .round:
            if intervalRestSeconds > 0 {
                intervalPhase = .rest
                intervalSecondsRemaining = intervalRestSeconds
                didTriggerRoundWarning = false
                playRestBell()
            } else {
                intervalRoundIndex += 1
                intervalPhase = .round
                intervalSecondsRemaining = max(1, intervalRoundSeconds)
                didTriggerRoundWarning = false
                playRoundBell()
            }

        case .rest:
            intervalRoundIndex += 1
            intervalPhase = .round
            intervalSecondsRemaining = max(1, intervalRoundSeconds)
            didTriggerRoundWarning = false
            playRoundBell()
        }
    }

    private func formatClockLabel(seconds: Int) -> String {
        let clamped = max(0, seconds)
        let mins = clamped / 60
        let secs = clamped % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    private func activateBellAudioSession() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .videoRecording, options: [.duckOthers, .defaultToSpeaker])
            try session.setActive(true)
        } catch {
            // Keep recording flow active even if audio session configuration fails.
        }
    }

    private func deactivateBellAudioSession() {
        // Intentionally left active; recording components manage their own audio session lifecycle.
    }

    private func playRoundBell() {
        playBellPattern(count: 3, spacingNanoseconds: 320_000_000)
    }

    private func playRestBell() {
        playBellPattern(count: 2, spacingNanoseconds: 320_000_000)
    }

    private func playWarningBell() {
        AudioServicesPlaySystemSound(SystemSoundID(1005))
    }

    private func playBellPattern(count: Int, spacingNanoseconds: UInt64) {
        bellPlaybackTask?.cancel()
        bellPlaybackTask = Task { @MainActor [weak self] in
            guard let self else { return }
            for index in 0..<max(1, count) {
                guard !Task.isCancelled else { return }
                playIntervalDing()
                if index < count - 1, spacingNanoseconds > 0 {
                    try? await Task.sleep(nanoseconds: spacingNanoseconds)
                }
            }
        }
    }

    private func playIntervalDing() {
        cleanupFinishedBellPlayers()

        do {
            let player = try AVAudioPlayer(data: intervalDingToneData)
            player.volume = 1.0
            player.prepareToPlay()
            player.play()
            activeBellPlayers.append(player)
        } catch {
            AudioServicesPlaySystemSound(SystemSoundID(1005))
        }
    }

    private func cleanupFinishedBellPlayers() {
        activeBellPlayers.removeAll(where: { !$0.isPlaying })
    }

    private static func makeIntervalDingToneWAVData() -> Data {
        let sampleRate = 44_100
        let durationSeconds = 0.72
        let sampleCount = max(1, Int(Double(sampleRate) * durationSeconds))
        let attackSeconds = 0.003
        let twoPi = Double.pi * 2.0
        let baseFrequency = 620.0
        // Inharmonic partials produce a more bell-like tone than harmonic sine stacks.
        let partials: [(ratio: Double, amplitude: Double, decay: Double, phase: Double)] = [
            (1.0, 1.00, 3.6, 0.00),
            (2.32, 0.65, 4.2, 0.45),
            (2.95, 0.42, 5.0, 1.10),
            (4.21, 0.30, 5.8, 1.85),
            (5.43, 0.20, 6.4, 2.70)
        ]

        var synthesized = [Double](repeating: 0, count: sampleCount)
        var peak = 0.000_001
        for index in 0..<sampleCount {
            let t = Double(index) / Double(sampleRate)
            let attack = min(1.0, t / attackSeconds)
            let strikeDecay = exp(-170.0 * t)
            let bodyDecay = exp(-2.6 * t)

            var sample = 0.0
            for partial in partials {
                let driftedFrequency = baseFrequency * partial.ratio * (1.0 - 0.0008 * t)
                sample += partial.amplitude
                    * exp(-partial.decay * t)
                    * sin(twoPi * driftedFrequency * t + partial.phase)
            }

            // Deterministic pseudo-noise to emulate the mallet strike transient.
            let strikeNoise = sin(twoPi * 4_700.0 * t + 0.31) * sin(twoPi * 3_100.0 * t + 1.73)
            sample += 0.24 * strikeNoise * strikeDecay

            // Subtle high shimmer.
            sample += 0.06 * sin(twoPi * 2_750.0 * t + 0.52) * exp(-8.0 * t)

            sample *= attack * bodyDecay
            synthesized[index] = sample
            peak = max(peak, abs(sample))
        }

        let gain = 0.96 / peak
        var pcmData = Data(capacity: sampleCount * MemoryLayout<Int16>.size)
        for sample in synthesized {
            let scaled = max(-1.0, min(1.0, sample * gain))
            let intSample = Int16(scaled * Double(Int16.max)).littleEndian
            withUnsafeBytes(of: intSample) { bytes in
                pcmData.append(contentsOf: bytes)
            }
        }

        return makeWAVData(fromPCM16Mono: pcmData, sampleRate: sampleRate)
    }

    private static func makeWAVData(fromPCM16Mono pcmData: Data, sampleRate: Int) -> Data {
        let channels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let blockAlign: UInt16 = channels * (bitsPerSample / 8)
        let byteRate: UInt32 = UInt32(sampleRate) * UInt32(blockAlign)
        let dataChunkSize: UInt32 = UInt32(pcmData.count)
        let riffChunkSize: UInt32 = 36 + dataChunkSize

        var wavData = Data()
        appendASCII("RIFF", to: &wavData)
        appendUInt32LE(riffChunkSize, to: &wavData)
        appendASCII("WAVE", to: &wavData)
        appendASCII("fmt ", to: &wavData)
        appendUInt32LE(16, to: &wavData)
        appendUInt16LE(1, to: &wavData) // PCM format
        appendUInt16LE(channels, to: &wavData)
        appendUInt32LE(UInt32(sampleRate), to: &wavData)
        appendUInt32LE(byteRate, to: &wavData)
        appendUInt16LE(blockAlign, to: &wavData)
        appendUInt16LE(bitsPerSample, to: &wavData)
        appendASCII("data", to: &wavData)
        appendUInt32LE(dataChunkSize, to: &wavData)
        wavData.append(pcmData)
        return wavData
    }

    private static func appendASCII(_ text: String, to data: inout Data) {
        if let asciiData = text.data(using: .ascii) {
            data.append(asciiData)
        }
    }

    private static func appendUInt16LE(_ value: UInt16, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    private static func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { bytes in
            data.append(contentsOf: bytes)
        }
    }
}
