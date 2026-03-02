import AVFoundation
import Foundation

@MainActor
final class CameraRecorder: NSObject, ObservableObject {
    @Published private(set) var isConfigured = false
    @Published private(set) var isRecording = false
    @Published private(set) var currentCameraPosition: AVCaptureDevice.Position

    let captureSession = AVCaptureSession()

    private let movieOutput = AVCaptureMovieFileOutput()
    private var onRecordingFinished: ((Result<URL, Error>) -> Void)?

    override init() {
        currentCameraPosition = AppSettings.defaultCameraPosition
        super.init()
    }

    func configureSession() async {
        let authorized = await AVCaptureDevice.requestAccess(for: .video)
        guard authorized else { return }

        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        captureSession.sessionPreset = .high
        guard configureVideoInput(position: currentCameraPosition) else { return }

        if captureSession.canAddOutput(movieOutput) {
            captureSession.addOutput(movieOutput)
        }

        isConfigured = true
    }

    func toggleCamera() {
        guard !isRecording else { return }
        let targetPosition: AVCaptureDevice.Position = currentCameraPosition == .back ? .front : .back

        captureSession.beginConfiguration()
        let didConfigure = configureVideoInput(position: targetPosition)
        captureSession.commitConfiguration()

        if didConfigure {
            currentCameraPosition = targetPosition
            if AppSettings.rememberLastUsedCamera {
                AppSettings.setDefaultCameraPosition(targetPosition)
            }
        }
    }

    @discardableResult
    private func configureVideoInput(position: AVCaptureDevice.Position) -> Bool {
        for input in captureSession.inputs {
            if let deviceInput = input as? AVCaptureDeviceInput, deviceInput.device.hasMediaType(.video) {
                captureSession.removeInput(deviceInput)
            }
        }

        let preferredDeviceTypes: [AVCaptureDevice.DeviceType] = position == .front
            ? [.builtInTrueDepthCamera, .builtInWideAngleCamera]
            : [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]

        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: preferredDeviceTypes,
            mediaType: .video,
            position: position
        )

        guard let camera = discovery.devices.first,
              let videoInput = try? AVCaptureDeviceInput(device: camera),
              captureSession.canAddInput(videoInput) else {
            return false
        }

        captureSession.addInput(videoInput)
        return true
    }

    func startRunningIfNeeded() {
        guard isConfigured, !captureSession.isRunning else { return }
        captureSession.startRunning()
    }

    func stopRunningIfNeeded() {
        guard captureSession.isRunning else { return }
        captureSession.stopRunning()
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
