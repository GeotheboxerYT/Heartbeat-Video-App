import AVFoundation
import Foundation

@MainActor
final class PlaybackViewModel: ObservableObject {
    @Published private(set) var sessions: [SessionFiles] = []
    @Published var selectedSessionID: String?
    @Published var displayedBPM: Int = 0
    @Published var scrubTime: TimeInterval = 0
    @Published var duration: TimeInterval = 1

    private let storage = SessionStorage()
    private var samples: [HeartRateSample] = []
    private var timeObserver: Any?

    let player = AVPlayer()

    func loadSessions() {
        sessions = storage.listSessions()
        if selectedSessionID == nil {
            selectedSessionID = sessions.first?.sessionID
            loadSelectedSession()
        }
    }

    func loadSelectedSession() {
        guard let selectedSessionID,
              let session = sessions.first(where: { $0.sessionID == selectedSessionID }) else {
            return
        }

        samples = storage.loadHeartRateSamples(from: session.heartRateURL)
        player.replaceCurrentItem(with: AVPlayerItem(url: session.videoURL))
        let videoDuration = CMTimeGetSeconds(AVAsset(url: session.videoURL).duration)
        duration = videoDuration.isFinite && videoDuration > 0 ? videoDuration : 1
        scrubTime = 0
        displayedBPM = bpm(at: 0)
        addPeriodicObserver()
    }

    func seek(to seconds: TimeInterval) {
        scrubTime = seconds
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero)
        displayedBPM = bpm(at: seconds)
    }

    func stepFrame(forward: Bool) {
        let frameDuration = 1.0 / 30.0
        let target = max(0, scrubTime + (forward ? frameDuration : -frameDuration))
        seek(to: target)
    }

    private func addPeriodicObserver() {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }

        let interval = CMTime(seconds: 0.1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            guard let self else { return }
            let seconds = CMTimeGetSeconds(time)
            if seconds.isFinite {
                scrubTime = seconds
                displayedBPM = bpm(at: seconds)
            }
        }
    }

    private func bpm(at seconds: TimeInterval) -> Int {
        guard !samples.isEmpty else { return 0 }
        let nearest = samples.min(by: { abs($0.t - seconds) < abs($1.t - seconds) })
        return nearest?.bpm ?? 0
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
    }
}
