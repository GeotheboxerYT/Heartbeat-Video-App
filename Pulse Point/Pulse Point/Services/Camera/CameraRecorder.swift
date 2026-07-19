@preconcurrency import AVFoundation
import Foundation
import UIKit

@MainActor
final class CameraRecorder: NSObject, ObservableObject {
    private enum CameraRecorderError: LocalizedError {
        case microphoneUnavailable

        var errorDescription: String? {
            switch self {
            case .microphoneUnavailable:
                return "Microphone is unavailable. Check app microphone permissions and try again."
            }
        }
    }

    @Published private(set) var isConfigured = false
    @Published private(set) var isRecording = false
    @Published private(set) var currentCameraPosition: AVCaptureDevice.Position
    @Published private(set) var activeAspectRatio: CGFloat = 9.0 / 16.0
    @Published private(set) var previewRotationAngle: CGFloat = 90
    @Published private(set) var zoomFactor: CGFloat = 1.0
    @Published private(set) var maxZoomFactor: CGFloat = 1.0

    let captureSession = AVCaptureSession()
    private let sessionQueue = DispatchQueue(
        label: "com.pulsepoint.camera.session",
        qos: .userInitiated,
        attributes: [],
        autoreleaseFrequency: .workItem,
        target: DispatchQueue.global(qos: .userInitiated)
    )

    private let movieOutput = AVCaptureMovieFileOutput()
    private var onRecordingFinished: ((Result<URL, Error>) -> Void)?
    private var orientationObserver: NSObjectProtocol?
    private var lastKnownInterfaceOrientation: UIInterfaceOrientation = .portrait

    override init() {
        currentCameraPosition = AppSettings.defaultCameraPosition
        super.init()
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        orientationObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshOrientationLayout()
            }
        }
        refreshOrientationLayout()
    }

    deinit {
        if let orientationObserver {
            NotificationCenter.default.removeObserver(orientationObserver)
        }
    }

    func configureSession() async {
        let videoAuthorized = await AVCaptureDevice.requestAccess(for: .video)
        guard videoAuthorized else { return }
        _ = await AVCaptureDevice.requestAccess(for: .audio)

        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }

        captureSession.sessionPreset = captureSession.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high
        guard configureVideoInput(position: currentCameraPosition) else { return }

        if captureSession.canAddOutput(movieOutput) {
            captureSession.addOutput(movieOutput)
        }

        applyRecordingOrientation()
        updateZoomState(preserveCurrentZoom: false)
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
            applyRecordingOrientation()
            updateZoomState(preserveCurrentZoom: true)
        }
    }

    @discardableResult
    private func configureVideoInput(position: AVCaptureDevice.Position) -> Bool {
        for input in captureSession.inputs {
            if let deviceInput = input as? AVCaptureDeviceInput, deviceInput.device.hasMediaType(.video) {
                captureSession.removeInput(deviceInput)
            }
        }

        // Force the standard wide-angle lens first to avoid "fisheye" look at 1.0x.
        let primaryDeviceType: AVCaptureDevice.DeviceType = .builtInWideAngleCamera
        let fallbackDeviceTypes: [AVCaptureDevice.DeviceType] = position == .front
            ? [.builtInTrueDepthCamera]
            : [.builtInDualCamera, .builtInTripleCamera, .builtInDualWideCamera]

        var camera = AVCaptureDevice.default(primaryDeviceType, for: .video, position: position)

        if camera == nil {
            let discovery = AVCaptureDevice.DiscoverySession(
                deviceTypes: fallbackDeviceTypes + [primaryDeviceType],
                mediaType: .video,
                position: position
            )
            camera = discovery.devices.first
        }

        guard let camera,
              let videoInput = try? AVCaptureDeviceInput(device: camera),
              captureSession.canAddInput(videoInput) else {
            return false
        }

        captureSession.addInput(videoInput)
        return true
    }

    @discardableResult
    private func configureAudioInput() -> Bool {
        for input in captureSession.inputs {
            if let deviceInput = input as? AVCaptureDeviceInput, deviceInput.device.hasMediaType(.audio) {
                captureSession.removeInput(deviceInput)
            }
        }

        guard let microphone = AVCaptureDevice.default(for: .audio),
              let audioInput = try? AVCaptureDeviceInput(device: microphone),
              captureSession.canAddInput(audioInput) else {
            return false
        }

        captureSession.addInput(audioInput)
        return true
    }

    func startRunningIfNeeded() {
        guard isConfigured else { return }
        let session = captureSession
        sessionQueue.async {
            guard !session.isRunning else { return }
            session.startRunning()
        }
    }

    func stopRunningIfNeeded() {
        let session = captureSession
        sessionQueue.async {
            guard session.isRunning else { return }
            session.stopRunning()
        }
    }

    func startRecording(to fileURL: URL, onFinished: @escaping (Result<URL, Error>) -> Void) {
        guard isConfigured, !movieOutput.isRecording else { return }
        refreshOrientationLayout()
        applyRecordingOrientation()
        guard addAudioInputIfNeeded() else {
            onFinished(.failure(CameraRecorderError.microphoneUnavailable))
            return
        }
        activateRecordingAudioSession()
        onRecordingFinished = onFinished
        movieOutput.startRecording(to: fileURL, recordingDelegate: self)
        isRecording = true
    }

    func stopRecording() {
        guard movieOutput.isRecording else { return }
        movieOutput.stopRecording()
    }

    func setZoomFactor(_ factor: CGFloat) {
        guard let device = activeVideoDevice() else { return }
        let clampedMax = min(max(device.activeFormat.videoMaxZoomFactor, 1.0), 6.0)
        let clamped = min(max(factor, 1.0), clampedMax)

        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = clamped
            device.unlockForConfiguration()
            zoomFactor = clamped
            maxZoomFactor = clampedMax
        } catch {
            // Ignore zoom updates if device configuration lock fails.
        }
    }

    private func refreshOrientationLayout() {
        guard !isRecording else { return }
        let orientation = resolvedInterfaceOrientation()
        activeAspectRatio = orientation.isLandscape ? (16.0 / 9.0) : (9.0 / 16.0)
        previewRotationAngle = rotationAngle(for: orientation)
    }

    private func resolvedInterfaceOrientation() -> UIInterfaceOrientation {
        if let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive }) {
            let current = scene.interfaceOrientation
            if current != .unknown {
                lastKnownInterfaceOrientation = current
                return current
            }
        }

        let deviceOrientation = UIDevice.current.orientation
        switch deviceOrientation {
        case .portrait:
            lastKnownInterfaceOrientation = .portrait
        case .portraitUpsideDown:
            lastKnownInterfaceOrientation = .portraitUpsideDown
        case .landscapeLeft:
            lastKnownInterfaceOrientation = .landscapeRight
        case .landscapeRight:
            lastKnownInterfaceOrientation = .landscapeLeft
        default:
            break
        }
        return lastKnownInterfaceOrientation
    }

    private func applyRecordingOrientation() {
        guard let connection = movieOutput.connection(with: .video) else { return }
        let orientation = resolvedInterfaceOrientation()
        let angle = rotationAngle(for: orientation)
        if connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
    }

    private func rotationAngle(for orientation: UIInterfaceOrientation) -> CGFloat {
        switch orientation {
        case .portrait:
            return 90
        case .portraitUpsideDown:
            return 270
        case .landscapeRight:
            return 0
        case .landscapeLeft:
            return 180
        default:
            return 90
        }
    }

    private func activeVideoDevice() -> AVCaptureDevice? {
        captureSession.inputs
            .compactMap { $0 as? AVCaptureDeviceInput }
            .first(where: { $0.device.hasMediaType(.video) })?
            .device
    }

    private func updateZoomState(preserveCurrentZoom: Bool) {
        guard let device = activeVideoDevice() else {
            zoomFactor = 1.0
            maxZoomFactor = 1.0
            return
        }

        let clampedMax = min(max(device.activeFormat.videoMaxZoomFactor, 1.0), 6.0)
        let target = preserveCurrentZoom ? min(max(zoomFactor, 1.0), clampedMax) : 1.0

        do {
            try device.lockForConfiguration()
            device.videoZoomFactor = target
            device.unlockForConfiguration()
            zoomFactor = target
            maxZoomFactor = clampedMax
        } catch {
            zoomFactor = min(max(device.videoZoomFactor, 1.0), clampedMax)
            maxZoomFactor = clampedMax
        }
    }

    private func addAudioInputIfNeeded() -> Bool {
        let alreadyConfigured = captureSession.inputs
            .compactMap { $0 as? AVCaptureDeviceInput }
            .contains(where: { $0.device.hasMediaType(.audio) })
        if alreadyConfigured {
            return true
        }

        captureSession.beginConfiguration()
        defer { captureSession.commitConfiguration() }
        return configureAudioInput()
    }

    private func removeAudioInputIfNeeded() {
        captureSession.beginConfiguration()
        for input in captureSession.inputs {
            if let deviceInput = input as? AVCaptureDeviceInput, deviceInput.device.hasMediaType(.audio) {
                captureSession.removeInput(deviceInput)
            }
        }
        captureSession.commitConfiguration()
    }

    private func activateRecordingAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .videoRecording,
                options: [.defaultToSpeaker]
            )
            try session.setActive(true, options: [])
        } catch {
            // Keep recording flow resilient if audio-session configuration fails.
        }
    }

    private func deactivateRecordingAudioSession() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setActive(false, options: [.notifyOthersOnDeactivation])
        } catch {
            // Best-effort deactivation; ignore failures.
        }
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
            removeAudioInputIfNeeded()
            deactivateRecordingAudioSession()
            if let error {
                onRecordingFinished?(.failure(error))
            } else {
                onRecordingFinished?(.success(outputFileURL))
            }
            onRecordingFinished = nil
        }
    }
}
