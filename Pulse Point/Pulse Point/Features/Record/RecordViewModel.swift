import Combine
import AVFoundation
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

    @Published private(set) var currentBPM: Int = 0
    @Published private(set) var isRecording = false
    @Published private(set) var isBLEConnected = false
    @Published private(set) var cameraLabel: String = "Back Camera"
    @Published private(set) var liveBPMGraphPoints: [Int] = []
    @Published var activeComparisonPVTPhase: ComparisonPVTPhase?
    @Published var isComparisonPVTPresented = false
    @Published var errorMessage: String?

    let cameraRecorder = CameraRecorder()

    private let heartRateMonitor = HeartRateMonitor()
    private let storage = SessionStorage()
    private let sessionClock = SessionClock()

    private var activeSessionFiles: SessionFiles?
    private var recordingStartDate: Date?
    private var recordingDurationAtStop: TimeInterval = 0
    private var recordedSamplesAtStop: [HeartRateSample] = []
    private var cancellables: Set<AnyCancellable> = []
    private let maxLiveGraphPoints = 120
    private var prePVTResult: RecordPVTResult?
    private var postPVTResult: RecordPVTResult?
    private var didCompleteRecordingForComparison = false

    init() {
        bindHeartRateMonitor()
    }

    func prepare() async {
        await cameraRecorder.configureSession()
        cameraRecorder.startRunningIfNeeded()
        heartRateMonitor.startSearching()
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
            heartRateMonitor.startStreaming(sessionClock: sessionClock)

            cameraRecorder.startRecording(to: sessionFiles.videoURL) { [weak self] result in
                Task { @MainActor in
                    self?.handleRecordingCompletion(result: result)
                }
            }

            if AppSettings.keepScreenAwakeDuringRecording {
                UIApplication.shared.isIdleTimerDisabled = true
            }
            isRecording = true
        } catch {
            errorMessage = "Failed to create session: \(error.localizedDescription)"
        }
    }

    func stopRecording() {
        recordingDurationAtStop = sessionClock.elapsedTime()
        recordedSamplesAtStop = heartRateMonitor.samples
        cameraRecorder.stopRecording()
        heartRateMonitor.stopStreaming()
        UIApplication.shared.isIdleTimerDisabled = false
        isRecording = false
        didCompleteRecordingForComparison = true
        if pvtComparisonEnabled && postPVTResult == nil {
            errorMessage = "Complete the Post-PVT to see comparison."
        }
    }

    func toggleCamera() {
        cameraRecorder.toggleCamera()
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
                self?.currentBPM = value
                self?.appendLiveGraphPoint(value)
            }
            .store(in: &cancellables)

        heartRateMonitor.$isConnected
            .sink { [weak self] value in
                self?.isBLEConnected = value
                if !value {
                    self?.liveBPMGraphPoints.removeAll()
                }
            }
            .store(in: &cancellables)

        cameraRecorder.$currentCameraPosition
            .sink { [weak self] position in
                self?.cameraLabel = position == .front ? "Front Camera" : "Back Camera"
            }
            .store(in: &cancellables)
    }

    private func handleRecordingCompletion(result: Result<URL, Error>) {
        guard let sessionFiles = activeSessionFiles else { return }

        switch result {
        case .failure(let error):
            errorMessage = "Recording failed: \(error.localizedDescription)"

        case .success:
            do {
                let samples = recordedSamplesAtStop
                try storage.saveHeartRateSamples(samples, to: sessionFiles.heartRateURL)

                let duration = max(recordingDurationAtStop, samples.last?.t ?? 0)
                let metadata = WorkoutSessionMetadata(
                    id: sessionFiles.sessionID,
                    startedAt: recordingStartDate ?? Date(),
                    duration: duration,
                    videoFileName: sessionFiles.videoURL.lastPathComponent,
                    heartRateFileName: sessionFiles.heartRateURL.lastPathComponent
                )
                try storage.saveMetadata(metadata, to: sessionFiles.metadataURL)

                Task {
                    await uploadSessionToAPI(samples: samples, metadata: metadata, sessionFiles: sessionFiles)
                }
            } catch {
                errorMessage = "Saving session failed: \(error.localizedDescription)"
            }
        }

        activeSessionFiles = nil
        recordingStartDate = nil
        recordingDurationAtStop = 0
        recordedSamplesAtStop = []
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func appendLiveGraphPoint(_ bpm: Int) {
        guard bpm > 0 else { return }
        liveBPMGraphPoints.append(bpm)
        if liveBPMGraphPoints.count > maxLiveGraphPoints {
            liveBPMGraphPoints.removeFirst(liveBPMGraphPoints.count - maxLiveGraphPoints)
        }
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
        let uploadedVideoURL = try? await APIClient.shared.uploadVideo(fileURL: sessionFiles.videoURL).videoUrl

        let request = APIFullSessionUploadRequest(
            session: .init(
                userId: 1,
                sessionUuid: UUID().uuidString,
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
        } catch {
            errorMessage = "Saved locally, but API sync failed: \(error.localizedDescription)"
        }
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
}
