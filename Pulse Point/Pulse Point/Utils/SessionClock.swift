import QuartzCore

final class SessionClock {
    private var startMonotonicTime: CFTimeInterval?
    private var elapsedOffset: TimeInterval = 0

    func start(elapsedOffset: TimeInterval = 0) {
        self.elapsedOffset = max(0, elapsedOffset)
        startMonotonicTime = CACurrentMediaTime()
    }

    func elapsedTime() -> TimeInterval {
        guard let startMonotonicTime else { return 0 }
        return elapsedOffset + (CACurrentMediaTime() - startMonotonicTime)
    }
}
