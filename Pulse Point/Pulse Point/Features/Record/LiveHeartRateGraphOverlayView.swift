import QuartzCore
import SwiftUI
import UIKit

struct LiveHeartRateGraphOverlayView: UIViewRepresentable {
    let bpmPoints: [Int]
    let primaryStrapPoints: [Int]?
    let secondaryStrapPoints: [Int]?
    let recordingElapsedSeconds: TimeInterval
    let isLiveRecording: Bool

    init(
        bpmPoints: [Int],
        primaryStrapPoints: [Int]? = nil,
        secondaryStrapPoints: [Int]? = nil,
        recordingElapsedSeconds: TimeInterval = 0,
        isLiveRecording: Bool = false
    ) {
        self.bpmPoints = bpmPoints
        self.primaryStrapPoints = primaryStrapPoints
        self.secondaryStrapPoints = secondaryStrapPoints
        self.recordingElapsedSeconds = recordingElapsedSeconds
        self.isLiveRecording = isLiveRecording
    }

    func makeUIView(context: Context) -> HeartRateGraphContainerView {
        let view = HeartRateGraphContainerView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: HeartRateGraphContainerView, context: Context) {
        uiView.updateGraph(
            aggregatePoints: bpmPoints,
            primaryPoints: primaryStrapPoints,
            secondaryPoints: secondaryStrapPoints,
            recordingElapsedSeconds: recordingElapsedSeconds,
            isLiveRecording: isLiveRecording
        )
    }
}

final class HeartRateGraphContainerView: UIView {
    private let aggregateGlowLayer = CAShapeLayer()
    private let aggregateLayer = CAShapeLayer()
    private let primaryGlowLayer = CAShapeLayer()
    private let primaryLayer = CAShapeLayer()
    private let secondaryGlowLayer = CAShapeLayer()
    private let secondaryLayer = CAShapeLayer()

    // Visual-only domain floor so low-BPM traces remain readable above control overlays.
    private let absoluteMinBPM: CGFloat = 30
    private let absoluteMaxBPM: CGFloat = 260
    private let minimumDisplaySpan: CGFloat = 24
    private let dynamicPadding: CGFloat = 3
    private let verticalContentInset: CGFloat = 12
    private let minBPMVerticalAnchor: CGFloat = 0.68
    private let minDualHalfSeparationBPM: CGFloat = 0.7
    private let minLiveLineWidthFactor: CGFloat = 0.22
    private let liveLineGrowthDuration: TimeInterval = 55

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        configure(
            glow: aggregateGlowLayer,
            stroke: aggregateLayer,
            glowColor: UIColor.white.withAlphaComponent(0.28),
            strokeColor: UIColor.white,
            glowWidth: 5,
            strokeWidth: 2.4
        )

        configure(
            glow: primaryGlowLayer,
            stroke: primaryLayer,
            glowColor: UIColor.systemBlue.withAlphaComponent(0.32),
            strokeColor: UIColor.systemBlue,
            glowWidth: 4.8,
            strokeWidth: 2.2
        )

        configure(
            glow: secondaryGlowLayer,
            stroke: secondaryLayer,
            glowColor: UIColor.systemRed.withAlphaComponent(0.32),
            strokeColor: UIColor.systemRed,
            glowWidth: 4.8,
            strokeWidth: 2.2
        )

        layer.addSublayer(aggregateGlowLayer)
        layer.addSublayer(aggregateLayer)
        layer.addSublayer(primaryGlowLayer)
        layer.addSublayer(primaryLayer)
        layer.addSublayer(secondaryGlowLayer)
        layer.addSublayer(secondaryLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let allLayers = [
            aggregateGlowLayer,
            aggregateLayer,
            primaryGlowLayer,
            primaryLayer,
            secondaryGlowLayer,
            secondaryLayer
        ]
        for layer in allLayers {
            layer.frame = bounds
        }
    }

    func updateGraph(
        aggregatePoints: [Int],
        primaryPoints: [Int]?,
        secondaryPoints: [Int]?,
        recordingElapsedSeconds: TimeInterval,
        isLiveRecording: Bool
    ) {
        guard bounds.width > 0, bounds.height > 0 else { return }

        let activeSeries: [[Int]] = [aggregatePoints, primaryPoints ?? [], secondaryPoints ?? []]
        let displayRange = yDisplayRange(for: activeSeries, isLiveRecording: isLiveRecording)
        let widthFactor = xLengthFactor(recordingElapsedSeconds: recordingElapsedSeconds, isLiveRecording: isLiveRecording)

        if let primaryPoints,
           let secondaryPoints,
           let adjusted = adjustedDualSeries(primary: primaryPoints, secondary: secondaryPoints),
           let primaryPath = path(for: adjusted.primary, yRange: displayRange, xLengthFactor: widthFactor),
           let secondaryPath = path(for: adjusted.secondary, yRange: displayRange, xLengthFactor: widthFactor) {
            primaryLayer.path = primaryPath
            primaryGlowLayer.path = primaryPath
            secondaryLayer.path = secondaryPath
            secondaryGlowLayer.path = secondaryPath
            aggregateLayer.path = nil
            aggregateGlowLayer.path = nil
            return
        }

        let aggregatePath = path(
            for: aggregatePoints.map(CGFloat.init),
            yRange: displayRange,
            xLengthFactor: widthFactor
        )
        aggregateLayer.path = aggregatePath
        aggregateGlowLayer.path = aggregatePath
        primaryLayer.path = nil
        primaryGlowLayer.path = nil
        secondaryLayer.path = nil
        secondaryGlowLayer.path = nil
    }

    private func configure(
        glow: CAShapeLayer,
        stroke: CAShapeLayer,
        glowColor: UIColor,
        strokeColor: UIColor,
        glowWidth: CGFloat,
        strokeWidth: CGFloat
    ) {
        glow.strokeColor = glowColor.cgColor
        glow.fillColor = UIColor.clear.cgColor
        glow.lineWidth = glowWidth
        glow.lineJoin = .round
        glow.lineCap = .round

        stroke.strokeColor = strokeColor.cgColor
        stroke.fillColor = UIColor.clear.cgColor
        stroke.lineWidth = strokeWidth
        stroke.lineJoin = .round
        stroke.lineCap = .round
    }

    private func path(
        for bpmPoints: [CGFloat],
        yRange: ClosedRange<CGFloat>,
        xLengthFactor: CGFloat
    ) -> CGPath? {
        guard bpmPoints.count >= 2 else { return nil }

        let path = UIBezierPath()
        let clamped = bpmPoints.map { min(max($0, yRange.lowerBound), yRange.upperBound) }
        let drawWidth = max(1, bounds.width * max(minLiveLineWidthFactor, min(1, xLengthFactor)))
        let xOffset: CGFloat = 0
        let stepX = drawWidth / CGFloat(max(1, clamped.count - 1))
        let span = max(1, yRange.upperBound - yRange.lowerBound)
        let drawableHeight = max(1, bounds.height - (verticalContentInset * 2))

        for (idx, bpm) in clamped.enumerated() {
            let normalized = (bpm - yRange.lowerBound) / span
            let y = (bounds.height - verticalContentInset) - (normalized * drawableHeight)
            let point = CGPoint(x: xOffset + (CGFloat(idx) * stepX), y: y)
            if idx == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }

        return path.cgPath
    }

    private func yDisplayRange(for series: [[Int]], isLiveRecording: Bool) -> ClosedRange<CGFloat> {
        let values = series
            .flatMap { $0 }
            .map(CGFloat.init)
            .filter { $0 > 0 }

        guard let observedMin = values.min(), let observedMax = values.max() else {
            return absoluteMinBPM...absoluteMaxBPM
        }

        let paddedMin = observedMin - dynamicPadding
        let paddedMax = observedMax + dynamicPadding
        let observedSpan = max(1, paddedMax - paddedMin)
        let observedMidpoint = (observedMin + observedMax) / 2
        let intensity = normalized(
            observedMidpoint,
            lower: 60,
            upper: 200
        )

        // Low BPM -> tighter zoom (more dramatic line motion).
        // High BPM -> wider zoom (less clipping, more context).
        let targetMinimumSpan = isLiveRecording
            ? lerp(from: 10, to: 34, progress: intensity)
            : lerp(from: 14, to: 38, progress: intensity)
        let spanMultiplier = isLiveRecording
            ? lerp(from: 0.78, to: 2.85, progress: intensity)
            : lerp(from: 1.00, to: 2.40, progress: intensity)

        // Keep lower BPM visibly higher so bottom controls never hide the trace.
        var span = max(targetMinimumSpan, observedSpan * spanMultiplier)
        let absoluteSpan = absoluteMaxBPM - absoluteMinBPM
        span = min(span, absoluteSpan)

        var lower = paddedMin - (span * minBPMVerticalAnchor)
        var upper = lower + span

        // Always keep room above the current observed peak so lines never look clipped.
        let baselinePeakPadding: CGFloat = isLiveRecording ? 4 : 6
        if upper < (paddedMax + baselinePeakPadding) {
            let shift = (paddedMax + baselinePeakPadding) - upper
            upper += shift
            lower += shift
        }

        if lower < absoluteMinBPM {
            upper += (absoluteMinBPM - lower)
            lower = absoluteMinBPM
        }

        if upper > absoluteMaxBPM {
            lower -= (upper - absoluteMaxBPM)
            upper = absoluteMaxBPM
        }

        if lower < absoluteMinBPM {
            lower = absoluteMinBPM
        }

        if (upper - lower) < targetMinimumSpan {
            upper = min(absoluteMaxBPM, lower + targetMinimumSpan)
            lower = max(absoluteMinBPM, upper - targetMinimumSpan)
        }

        // Add aggressive extra headroom only when BPM is high so the chart zooms out at high effort.
        let highIntensity = normalized(
            paddedMax,
            lower: 150,
            upper: 205
        )
        let extraHeadroom = isLiveRecording
            ? lerp(from: 0, to: 92, progress: highIntensity)
            : lerp(from: 0, to: 72, progress: highIntensity)
        let targetUpper = min(absoluteMaxBPM, paddedMax + baselinePeakPadding + extraHeadroom)
        if upper < targetUpper {
            upper = targetUpper
        }

        return lower...upper
    }

    private func normalized(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        guard upper > lower else { return 0 }
        let clamped = min(max(value, lower), upper)
        return (clamped - lower) / (upper - lower)
    }

    private func lerp(from: CGFloat, to: CGFloat, progress: CGFloat) -> CGFloat {
        from + ((to - from) * progress)
    }

    private func xLengthFactor(recordingElapsedSeconds: TimeInterval, isLiveRecording: Bool) -> CGFloat {
        guard isLiveRecording else { return 1 }
        guard recordingElapsedSeconds > 0 else { return minLiveLineWidthFactor }
        let progress = CGFloat(recordingElapsedSeconds / liveLineGrowthDuration)
        return max(minLiveLineWidthFactor, min(1, progress))
    }

    private func adjustedDualSeries(
        primary: [Int],
        secondary: [Int]
    ) -> (primary: [CGFloat], secondary: [CGFloat])? {
        let pairCount = min(primary.count, secondary.count)
        guard pairCount >= 2 else { return nil }

        let primaryTail = Array(primary.suffix(pairCount))
        let secondaryTail = Array(secondary.suffix(pairCount))

        var adjustedPrimary: [CGFloat] = []
        var adjustedSecondary: [CGFloat] = []
        adjustedPrimary.reserveCapacity(pairCount)
        adjustedSecondary.reserveCapacity(pairCount)

        for index in 0..<pairCount {
            let a = CGFloat(primaryTail[index])
            let b = CGFloat(secondaryTail[index])
            let midpoint = (a + b) / 2
            let halfSeparation = max(abs(a - b) / 2, minDualHalfSeparationBPM)

            if abs(a - b) < 0.001 {
                adjustedPrimary.append(midpoint + halfSeparation)
                adjustedSecondary.append(midpoint - halfSeparation)
            } else if a > b {
                adjustedPrimary.append(midpoint + halfSeparation)
                adjustedSecondary.append(midpoint - halfSeparation)
            } else {
                adjustedPrimary.append(midpoint - halfSeparation)
                adjustedSecondary.append(midpoint + halfSeparation)
            }
        }

        return (adjustedPrimary, adjustedSecondary)
    }
}
