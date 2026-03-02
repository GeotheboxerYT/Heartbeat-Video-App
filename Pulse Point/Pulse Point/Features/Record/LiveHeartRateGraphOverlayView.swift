import QuartzCore
import SwiftUI
import UIKit

struct LiveHeartRateGraphOverlayView: UIViewRepresentable {
    let bpmPoints: [Int]

    func makeUIView(context: Context) -> HeartRateGraphContainerView {
        let view = HeartRateGraphContainerView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: HeartRateGraphContainerView, context: Context) {
        uiView.updateGraph(with: bpmPoints)
    }
}

final class HeartRateGraphContainerView: UIView {
    private let graphLayer = CAShapeLayer()
    private let glowLayer = CAShapeLayer()

    private let minBPM: CGFloat = 60
    private let maxBPM: CGFloat = 202

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        glowLayer.strokeColor = UIColor.systemRed.withAlphaComponent(0.25).cgColor
        glowLayer.fillColor = UIColor.clear.cgColor
        glowLayer.lineWidth = 5
        glowLayer.lineJoin = .round
        glowLayer.lineCap = .round

        graphLayer.strokeColor = UIColor.systemRed.cgColor
        graphLayer.fillColor = UIColor.clear.cgColor
        graphLayer.lineWidth = 2
        graphLayer.lineJoin = .round
        graphLayer.lineCap = .round

        layer.addSublayer(glowLayer)
        layer.addSublayer(graphLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glowLayer.frame = bounds
        graphLayer.frame = bounds
    }

    func updateGraph(with bpmPoints: [Int]) {
        guard bounds.width > 0, bounds.height > 0 else { return }

        let path = UIBezierPath()
        if bpmPoints.count < 2 {
            graphLayer.path = nil
            glowLayer.path = nil
            return
        }

        let clamped = bpmPoints.map { min(max(CGFloat($0), minBPM), maxBPM) }
        let stepX = bounds.width / CGFloat(max(1, clamped.count - 1))

        for (idx, bpm) in clamped.enumerated() {
            let normalized = (bpm - minBPM) / max(1, (maxBPM - minBPM))
            let y = bounds.height - (normalized * bounds.height)
            let point = CGPoint(x: CGFloat(idx) * stepX, y: y)
            if idx == 0 {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }

        graphLayer.path = path.cgPath
        glowLayer.path = path.cgPath
    }
}
