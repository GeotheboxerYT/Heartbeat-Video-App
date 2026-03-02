import Combine
import Foundation

@MainActor
final class RecordViewModel: ObservableObject {
    @Published private(set) var currentBPM: Int = 0
    @Published private(set) var isRecording = false
    @Published private(set) var isBLEConnected = false
    @Published var errorMessage: String?

    let cameraRecorder = CameraRecorder()

    private let heartRateMonitor = HeartRateMonitor()
    private let storage = SessionStorage()
    private let sessionClock = SessionClock()

    private var activeSessionFiles: SessionFiles?
    private var recordingStartDate: Date?
    private var recordingDurationAtStop: TimeInterval = 0
    private var cancellables: Set<AnyCancellable> = []

    init() {
        bindHeartRateMonitor()
    }

    func prepare() async {
        await cameraRecorder.configureSession()
        cameraRecorder.startRunningIfNeeded()
    }

    func startRecording() {
        do {
            let sessionFiles = try storage.createSessionFiles()
            activeSessionFiles = sessionFiles

            recordingStartDate = Date()
            sessionClock.start()
            heartRateMonitor.startStreaming(sessionClock: sessionClock)

            cameraRecorder.startRecording(to: sessionFiles.videoURL) { [weak self] result in
                Task { @MainActor in
                    self?.handleRecordingCompletion(result: result)
                }
            }

            isRecording = true
        } catch {
            errorMessage = "Failed to create session: \(error.localizedDescription)"
        }
    }

    func stopRecording() {
        recordingDurationAtStop = sessionClock.elapsedTime()
        cameraRecorder.stopRecording()
        heartRateMonitor.stopStreaming()
        isRecording = false
    }

    private func bindHeartRateMonitor() {
        heartRateMonitor.$currentBPM
            .sink { [weak self] value in
                self?.currentBPM = value
            }
            .store(in: &cancellables)

        heartRateMonitor.$isConnected
            .sink { [weak self] value in
                self?.isBLEConnected = value
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
                let samples = heartRateMonitor.samples
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
            } catch {
                errorMessage = "Saving session failed: \(error.localizedDescription)"
            }
        }

        activeSessionFiles = nil
        recordingStartDate = nil
        recordingDurationAtStop = 0
    }
}
