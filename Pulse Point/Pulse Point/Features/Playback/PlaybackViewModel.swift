import AVFoundation
import Foundation

@MainActor
final class PlaybackViewModel: ObservableObject {
    @Published private(set) var sessions: [SessionFiles] = []
    @Published private(set) var chartSamples: [HeartRateSample] = []
    @Published var selectedSessionID: String?
    @Published var displayedBPM: Int = 0
    @Published var scrubTime: TimeInterval = 0
    @Published var duration: TimeInterval = 1

    private let storage = SessionStorage()
    private var samples: [HeartRateSample] = []
    private var timeObserver: Any?
    private var remoteSessionIDMap: [String: Int] = [:]
    private let remoteCacheDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("RemoteSessions", isDirectory: true)

    let player = AVPlayer()

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

    func loadSessions() {
        Task {
            let loaded = await loadSessionsFromAPIOrLocal()
            await MainActor.run {
                sessions = loaded
                if let selectedSessionID,
                   sessions.contains(where: { $0.sessionID == selectedSessionID }) {
                    loadSelectedSession()
                } else {
                    selectedSessionID = sessions.first?.sessionID
                    loadSelectedSession()
                }
            }
        }
    }

    func loadSelectedSession() {
        guard let selectedSessionID,
              let session = sessions.first(where: { $0.sessionID == selectedSessionID }) else {
            return
        }

        Task {
            let loadedSamples: [HeartRateSample]
            if let remoteSessionId = remoteSessionIDMap[selectedSessionID] {
                loadedSamples = (try? await APIClient.shared.heartRateSamples(sessionId: remoteSessionId)) ?? []
            } else {
                loadedSamples = storage.loadHeartRateSamples(from: session.heartRateURL)
            }

            await MainActor.run {
                samples = loadedSamples
                chartSamples = loadedSamples
                scrubTime = 0
                displayedBPM = bpm(at: 0)
            }
        }

        player.replaceCurrentItem(with: AVPlayerItem(url: session.videoURL))
        duration = 1
        Task {
            let asset = AVAsset(url: session.videoURL)
            let loadedDuration = try? await asset.load(.duration)
            let videoDuration = loadedDuration.map(CMTimeGetSeconds) ?? 0
            await MainActor.run {
                self.duration = videoDuration.isFinite && videoDuration > 0 ? videoDuration : 1
            }
        }
        addPeriodicObserver()
        if AppSettings.autoPlayOnSessionOpen {
            player.play()
            objectWillChange.send()
        }
    }

    func seek(to seconds: TimeInterval) {
        scrubTime = seconds
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        displayedBPM = bpm(at: seconds)
    }

    func previewScrub(to seconds: TimeInterval) {
        scrubTime = seconds
        displayedBPM = bpm(at: seconds)
    }

    func commitScrub(to seconds: TimeInterval) {
        seek(to: seconds)
    }

    func stepFrame(forward: Bool) {
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
        } else {
            player.play()
        }
        objectWillChange.send()
    }

    private func addPeriodicObserver() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }

        let interval = CMTime(seconds: 0.2, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            let seconds = CMTimeGetSeconds(time)
            if seconds.isFinite {
                Task { @MainActor in
                    self.scrubTime = seconds
                    self.displayedBPM = self.bpm(at: seconds)
                }
            }
        }
    }

    private func bpm(at seconds: TimeInterval) -> Int {
        guard !samples.isEmpty else { return 0 }
        var left = 0
        var right = samples.count - 1

        while left < right {
            let mid = (left + right) / 2
            if samples[mid].t < seconds {
                left = mid + 1
            } else {
                right = mid
            }
        }

        let upper = left
        let lower = max(0, upper - 1)

        let lowerSample = samples[lower]
        let upperSample = samples[upper]
        return abs(lowerSample.t - seconds) <= abs(upperSample.t - seconds) ? lowerSample.bpm : upperSample.bpm
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let clamped = max(0, Int(seconds.rounded(.down)))
        let mins = clamped / 60
        let secs = clamped % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    private func analyzeTraining() -> (title: String, description: String) {
        let effectiveDuration = max(duration, samples.last?.t ?? 0)
        if effectiveDuration < 30 {
            return ("N/A", "Record for 30 seconds or more to get results.")
        }
        guard samples.count >= 10 else {
            return ("N/A", "Not enough heart-rate samples to classify this session.")
        }

        let bpmValues = samples.map(\.bpm)
        let minVal = bpmValues.min() ?? 0
        let maxVal = bpmValues.max() ?? 0
        let avgVal = avgBPM
        let range = maxVal - minVal

        let highRatio = Double(bpmValues.filter { $0 >= 150 }.count) / Double(bpmValues.count)
        let midRatio = Double(bpmValues.filter { $0 >= 120 && $0 < 150 }.count) / Double(bpmValues.count)

        let startCount = max(1, bpmValues.count / 5)
        let endCount = max(1, bpmValues.count / 5)
        let startAvg = Double(bpmValues.prefix(startCount).reduce(0, +)) / Double(startCount)
        let endAvg = Double(bpmValues.suffix(endCount).reduce(0, +)) / Double(endCount)
        let trendUp = endAvg - startAvg

        let mean = Double(avgVal)
        let variance = bpmValues.reduce(0.0) { partial, bpm in
            partial + pow(Double(bpm) - mean, 2)
        } / Double(bpmValues.count)
        let stdDev = sqrt(variance)

        if highRatio >= 0.55 && avgVal >= 145 {
            return ("High Intensity", "Heart rate stayed elevated for most of the session, with sustained hard effort.")
        }

        if highRatio >= 0.35 && range >= 25 {
            return ("High Intensity Intervals", "Frequent swings between hard pushes and recovery suggest interval-style training.")
        }

        if trendUp >= 12 && endAvg >= 130 {
            return ("Progressive Build", "Heart rate trended upward over time, consistent with gradually increasing effort.")
        }

        if stdDev <= 8 && avgVal >= 115 && avgVal <= 150 {
            return ("Steady-State Cardio", "Heart rate remained relatively stable, suggesting continuous, even-paced cardio.")
        }

        if avgVal < 115 && maxVal < 140 {
            return ("Low-Intensity / Recovery", "Heart rate stayed in a lower range, consistent with light aerobic or recovery work.")
        }

        if midRatio >= 0.5 {
            return ("Moderate Cardio", "Most of the session sat in a moderate aerobic zone with some variation.")
        }

        return ("Mixed Session", "Pattern did not strongly match one profile; this session appears to mix multiple effort levels.")
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
    }

    private func loadSessionsFromAPIOrLocal() async -> [SessionFiles] {
        remoteSessionIDMap = [:]

        if let apiSessions = try? await APIClient.shared.listSessions(userId: 1) {
            let mapped = apiSessions.compactMap(makeRemoteSessionFile)
            if !mapped.isEmpty {
                return mapped
            }
        }

        return storage.listSessions()
    }

    private func makeRemoteSessionFile(from item: APISessionListItem) -> SessionFiles? {
        guard let videoURLString = item.video_url,
              let videoURL = URL(string: videoURLString) else {
            return nil
        }

        let sessionDirectory = remoteCacheDirectory.appendingPathComponent(item.session_uuid, isDirectory: true)
        try? FileManager.default.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)

        let session = SessionFiles(
            sessionID: item.session_uuid,
            directoryURL: sessionDirectory,
            videoURL: videoURL,
            heartRateURL: sessionDirectory.appendingPathComponent("heartRate.json"),
            metadataURL: sessionDirectory.appendingPathComponent("session.json")
        )
        remoteSessionIDMap[item.session_uuid] = item.id
        return session
    }
}
