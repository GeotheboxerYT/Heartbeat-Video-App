import QuartzCore

final class SessionClock {
    private var startMonotonicTime: CFTimeInterval?

    func start() {
        startMonotonicTime = CACurrentMediaTime()
    }

    func elapsedTime() -> TimeInterval {
        guard let startMonotonicTime else { return 0 }
        return CACurrentMediaTime() - startMonotonicTime
    }
}
