import AVFoundation
import Foundation

enum AppSettings {
    enum Keys {
        static let defaultCameraPosition = "settings.defaultCameraPosition"
        static let rememberLastUsedCamera = "settings.rememberLastUsedCamera"
        static let autoPlayOnSessionOpen = "settings.autoPlayOnSessionOpen"
        static let chartScrubMode = "settings.chartScrubMode"
        static let pvtResponseTimeoutSeconds = "settings.pvtResponseTimeoutSeconds"
        static let pvtSoundEffectsEnabled = "settings.pvtSoundEffectsEnabled"
        static let pvtFlashFeedbackEnabled = "settings.pvtFlashFeedbackEnabled"
        static let requirePrePostPVTForRecording = "settings.requirePrePostPVTForRecording"
        static let pvtComparisonDurationSeconds = "settings.pvtComparisonDurationSeconds"
        static let keepScreenAwakeDuringRecording = "settings.keepScreenAwakeDuringRecording"
        static let hapticsEnabled = "settings.hapticsEnabled"
        static let apiBaseURL = "settings.apiBaseURL"
        static let apiKey = "settings.apiKey"
    }

    static var defaultCameraPosition: AVCaptureDevice.Position {
        let raw = UserDefaults.standard.string(forKey: Keys.defaultCameraPosition) ?? "back"
        return raw == "front" ? .front : .back
    }

    static func setDefaultCameraPosition(_ position: AVCaptureDevice.Position) {
        UserDefaults.standard.set(position == .front ? "front" : "back", forKey: Keys.defaultCameraPosition)
    }

    static var rememberLastUsedCamera: Bool {
        if UserDefaults.standard.object(forKey: Keys.rememberLastUsedCamera) == nil { return true }
        return UserDefaults.standard.bool(forKey: Keys.rememberLastUsedCamera)
    }

    static var autoPlayOnSessionOpen: Bool {
        UserDefaults.standard.bool(forKey: Keys.autoPlayOnSessionOpen)
    }

    static var chartScrubMode: String {
        UserDefaults.standard.string(forKey: Keys.chartScrubMode) ?? "normal"
    }

    static var pvtResponseTimeoutSeconds: Double {
        let value = UserDefaults.standard.double(forKey: Keys.pvtResponseTimeoutSeconds)
        return value > 0 ? value : 2.0
    }

    static var pvtSoundEffectsEnabled: Bool {
        if UserDefaults.standard.object(forKey: Keys.pvtSoundEffectsEnabled) == nil { return true }
        return UserDefaults.standard.bool(forKey: Keys.pvtSoundEffectsEnabled)
    }

    static var pvtFlashFeedbackEnabled: Bool {
        if UserDefaults.standard.object(forKey: Keys.pvtFlashFeedbackEnabled) == nil { return true }
        return UserDefaults.standard.bool(forKey: Keys.pvtFlashFeedbackEnabled)
    }

    static var keepScreenAwakeDuringRecording: Bool {
        if UserDefaults.standard.object(forKey: Keys.keepScreenAwakeDuringRecording) == nil { return true }
        return UserDefaults.standard.bool(forKey: Keys.keepScreenAwakeDuringRecording)
    }

    static var requirePrePostPVTForRecording: Bool {
        UserDefaults.standard.bool(forKey: Keys.requirePrePostPVTForRecording)
    }

    static var pvtComparisonDurationSeconds: Int {
        let value = UserDefaults.standard.integer(forKey: Keys.pvtComparisonDurationSeconds)
        return [60, 180, 300, 600].contains(value) ? value : 60
    }

    static var apiBaseURL: String {
        UserDefaults.standard.string(forKey: Keys.apiBaseURL) ?? "http://127.0.0.1:3000"
    }

    static var apiKey: String {
        UserDefaults.standard.string(forKey: Keys.apiKey) ?? "pp_local_9f3k2m8x7q1w4z6r"
    }
}
