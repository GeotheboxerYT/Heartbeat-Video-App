import Foundation
import HealthKit

@MainActor
final class AppleHealthHeartRateMonitor: ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var isAuthorized = false
    @Published private(set) var currentBPM: Int = 0
    @Published private(set) var samples: [HeartRateSample] = []
    @Published private(set) var statusMessage: String = "Needs Health permission"

    private let healthStore = HKHealthStore()
    private let heartRateType = HKQuantityType.quantityType(forIdentifier: .heartRate)
    private let bpmUnit = HKUnit.count().unitDivided(by: .minute())

    private var anchoredQuery: HKAnchoredObjectQuery?
    private var anchor: HKQueryAnchor?
    private weak var sessionClock: SessionClock?
    private var isSessionCaptureEnabled = false
    private var pollingTask: Task<Void, Never>?
    private var lastSampleEndDate: Date?
    private let pollIntervalNanoseconds: UInt64 = 15_000_000_000
    private let staleStatusThresholdSeconds: TimeInterval = 120
    private let veryStaleStatusThresholdSeconds: TimeInterval = 5 * 60

    func requestAuthorization() async {
        guard HKHealthStore.isHealthDataAvailable() else {
            statusMessage = "Health data not available on this device"
            isAuthorized = false
            return
        }

        guard let heartRateType else {
            statusMessage = "Heart rate type unavailable"
            isAuthorized = false
            return
        }

        let outcome: (Bool, Error?) = await withCheckedContinuation { (continuation: CheckedContinuation<(Bool, Error?), Never>) in
            healthStore.requestAuthorization(toShare: [], read: [heartRateType]) { success, error in
                continuation.resume(returning: (success, error))
            }
        }

        let granted = outcome.0
        let error = outcome.1
        isAuthorized = granted
        if granted {
            statusMessage = "Health access granted"
            await fetchMostRecentHeartRateSample()
        } else if let error {
            statusMessage = "Health access failed: \(error.localizedDescription)"
        } else {
            statusMessage = "Health access denied. Enable it in iPhone Settings > Privacy & Security > Health."
        }
    }

    func startStreaming(sessionClock: SessionClock) {
        self.sessionClock = sessionClock
        self.isSessionCaptureEnabled = true
        samples.removeAll()
        currentBPM = 0
        isConnected = false
        lastSampleEndDate = nil
        stopQuery()

        Task { @MainActor [weak self] in
            guard let self else { return }
            if !self.isAuthorized {
                await self.requestAuthorization()
            }
            guard self.isAuthorized else { return }
            await self.fetchMostRecentHeartRateSample()
            self.startAnchoredQuery()
        }
    }

    func startPreviewMonitoring() {
        sessionClock = nil
        isSessionCaptureEnabled = false
        samples.removeAll()
        currentBPM = 0
        isConnected = false
        lastSampleEndDate = nil
        stopQuery()

        Task { @MainActor [weak self] in
            guard let self else { return }
            if !self.isAuthorized {
                await self.requestAuthorization()
            }
            guard self.isAuthorized else { return }
            await self.fetchMostRecentHeartRateSample()
            self.startAnchoredQuery()
        }
    }

    func stopStreaming() {
        stopQuery()
        isConnected = false
        currentBPM = 0
        sessionClock = nil
        isSessionCaptureEnabled = false
        lastSampleEndDate = nil
        statusMessage = isAuthorized ? "Disconnected from Apple Watch heart-rate stream" : "Needs Health permission"
    }

    func forceRefresh() {
        guard isAuthorized else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.fetchMostRecentHeartRateSample()
            self.updateStaleStatusIfNeeded()
        }
    }

    private func stopQuery() {
        pollingTask?.cancel()
        pollingTask = nil

        if let anchoredQuery {
            healthStore.stop(anchoredQuery)
        }
        anchoredQuery = nil
    }

    private func startAnchoredQuery() {
        guard let heartRateType else {
            statusMessage = "Heart rate type unavailable"
            return
        }

        statusMessage = "Waiting for Apple Watch heart-rate updates..."
        isConnected = true
        let predicate = HKQuery.predicateForSamples(
            withStart: Date().addingTimeInterval(-10 * 60),
            end: nil,
            options: .strictStartDate
        )
        let query = HKAnchoredObjectQuery(
            type: heartRateType,
            predicate: predicate,
            anchor: anchor,
            limit: HKObjectQueryNoLimit
        ) { [weak self] _, samplesOrNil, _, newAnchor, error in
            Task { @MainActor in
                self?.handle(samplesOrNil: samplesOrNil, newAnchor: newAnchor, error: error)
            }
        }

        query.updateHandler = { [weak self] _, samplesOrNil, _, newAnchor, error in
            Task { @MainActor in
                self?.handle(samplesOrNil: samplesOrNil, newAnchor: newAnchor, error: error)
            }
        }

        anchoredQuery = query
        healthStore.execute(query)
        startPollingLatestSample()
    }

    private func startPollingLatestSample() {
        pollingTask?.cancel()
        pollingTask = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.fetchMostRecentHeartRateSample()
                self.updateStaleStatusIfNeeded()
                try? await Task.sleep(nanoseconds: self.pollIntervalNanoseconds)
            }
        }
    }

    private func updateStaleStatusIfNeeded() {
        guard isAuthorized, isConnected else { return }
        guard let lastSampleEndDate else {
            if currentBPM == 0 {
                statusMessage = "Connected: Apple Watch. Waiting for heart-rate sample..."
            }
            return
        }

        let age = Date().timeIntervalSince(lastSampleEndDate)
        if age >= veryStaleStatusThresholdSeconds {
            statusMessage = "Connected: Apple Watch (last update \(formattedAge(age)) ago). Updates can be slower without a workout."
        } else if age >= staleStatusThresholdSeconds {
            statusMessage = "Connected: Apple Watch (last update \(formattedAge(age)) ago)."
        }
    }

    private func fetchMostRecentHeartRateSample() async {
        guard let heartRateType else { return }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let sort = NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)
            let query = HKSampleQuery(
                sampleType: heartRateType,
                predicate: nil,
                limit: 1,
                sortDescriptors: [sort]
            ) { [weak self] _, samples, error in
                Task { @MainActor in
                    defer { continuation.resume(returning: ()) }
                    guard let self else { return }

                    if let error {
                        self.statusMessage = "Health query error: \(error.localizedDescription)"
                        return
                    }

                    guard let sample = samples?.first as? HKQuantitySample else {
                        if self.currentBPM == 0 {
                            self.statusMessage = "Connected: Apple Watch. Waiting for heart-rate sample..."
                        } else {
                            self.updateStaleStatusIfNeeded()
                        }
                        return
                    }

                    self.applySample(sample)
                }
            }
            healthStore.execute(query)
        }
    }

    private func handle(samplesOrNil: [HKSample]?, newAnchor: HKQueryAnchor?, error: Error?) {
        if let newAnchor {
            anchor = newAnchor
        }

        if let error {
            statusMessage = "Health stream error: \(error.localizedDescription)"
            isConnected = false
            return
        }

        guard let samplesOrNil else { return }
        let quantitySamples = samplesOrNil.compactMap { $0 as? HKQuantitySample }
        guard !quantitySamples.isEmpty else {
            updateStaleStatusIfNeeded()
            return
        }

        for sample in quantitySamples.sorted(by: { $0.endDate < $1.endDate }) {
            applySample(sample)
        }

        isConnected = true
        updateStaleStatusIfNeeded()
    }

    private func applySample(_ sample: HKQuantitySample) {
        if let lastSampleEndDate, sample.endDate <= lastSampleEndDate {
            return
        }
        lastSampleEndDate = sample.endDate

        let bpm = Int(round(sample.quantity.doubleValue(for: bpmUnit)))
        currentBPM = bpm

        if isSessionCaptureEnabled, let sessionClock {
            let t = sessionClock.elapsedTime()
            if let last = samples.last {
                let dt = t - last.t
                if dt > 0.2 || last.bpm != bpm {
                    samples.append(HeartRateSample(t: t, bpm: bpm))
                }
            } else {
                samples.append(HeartRateSample(t: t, bpm: bpm))
            }
        }

        isConnected = true
        statusMessage = "Connected: Apple Watch (\(bpm) bpm)"
    }

    private func formattedAge(_ age: TimeInterval) -> String {
        let seconds = Int(max(0, age.rounded()))
        if seconds < 60 {
            return "\(seconds)s"
        }
        let minutes = seconds / 60
        let rem = seconds % 60
        if rem == 0 {
            return "\(minutes)m"
        }
        return "\(minutes)m \(rem)s"
    }
}
