import AVFoundation
import Foundation

@MainActor
final class CameraRecorder: NSObject, ObservableObject {
    @Published private(set) var isConfigured = false
    @Published private(set) var isRecording = false

    let captureSession = AVCaptureSession()

    private let movieOutput = AVCaptureMovieFileOutput()
    private var onRecordingFinished: ((Result<URL, Error>) -> Void)?

    func configureSession() async {
        let authorized = await AVCaptureDevice.requestAccess(for: .video)
        guard authorized else { return }

        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        captureSession.sessionPreset = .high

        guard let frontCamera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
              let videoInput = try? AVCaptureDeviceInput(device: frontCamera),
              captureSession.canAddInput(videoInput) else {
            return
        }
        captureSession.addInput(videoInput)

        if captureSession.canAddOutput(movieOutput) {
            captureSession.addOutput(movieOutput)
        }

        if let connection = movieOutput.connection(with: .video), connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }

        isConfigured = true
    }

    func startRunningIfNeeded() {
        guard isConfigured, !captureSession.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            self.captureSession.startRunning()
        }
    }

    func stopRunningIfNeeded() {
        guard captureSession.isRunning else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            self.captureSession.stopRunning()
        }
    }

    func startRecording(to fileURL: URL, onFinished: @escaping (Result<URL, Error>) -> Void) {
        guard isConfigured, !movieOutput.isRecording else { return }
        onRecordingFinished = onFinished
        movieOutput.startRecording(to: fileURL, recordingDelegate: self)
        isRecording = true
    }

    func stopRecording() {
        guard movieOutput.isRecording else { return }
        movieOutput.stopRecording()
    }
}

extension CameraRecorder: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(
        _ output: AVCaptureFileOutput,
        didFinishRecordingTo outputFileURL: URL,
        from connections: [AVCaptureConnection],
        error: Error?
    ) {
        Task { @MainActor in
            isRecording = false
            if let error {
                onRecordingFinished?(.failure(error))
            } else {
                onRecordingFinished?(.success(outputFileURL))
            }
            onRecordingFinished = nil
        }
    }
}
