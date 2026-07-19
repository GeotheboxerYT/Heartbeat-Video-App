@preconcurrency import AVFoundation
import CoreImage
import Foundation
import Photos
import UIKit

enum BPMOverlayVideoExporter {
    private final class ExportSessionBox: @unchecked Sendable {
        let session: AVAssetExportSession

        init(session: AVAssetExportSession) {
            self.session = session
        }
    }

    private final class OverlayImageCache: @unchecked Sendable {
        private let cache = NSCache<NSNumber, CIImage>()

        func image(for bpm: Int) -> CIImage? {
            cache.object(forKey: NSNumber(value: bpm))
        }

        func set(_ image: CIImage, for bpm: Int) {
            cache.setObject(image, forKey: NSNumber(value: bpm))
        }
    }

    enum ExportError: LocalizedError {
        case missingVideoTrack
        case couldNotCreateExportSession
        case exportFailed
        case exportCancelled
        case photosPermissionDenied
        case photoSaveFailed

        var errorDescription: String? {
            switch self {
            case .missingVideoTrack:
                return "Could not find a video track to export."
            case .couldNotCreateExportSession:
                return "Could not create export session."
            case .exportFailed:
                return "Video export failed."
            case .exportCancelled:
                return "Video export was cancelled."
            case .photosPermissionDenied:
                return "Photo Library permission denied."
            case .photoSaveFailed:
                return "Could not save video to Photo Library."
            }
        }
    }

    private static let overlaySize = CGSize(width: 168, height: 52)
    private static let overlayMargin: CGFloat = 14
    private static let topEdgeCompensation: CGFloat = 180

    static func exportToPhotoLibrary(
        sourceVideoURL: URL,
        samples: [HeartRateSample]
    ) async throws {
        try await requestPhotoLibraryAccess()

        let asset = AVAsset(url: sourceVideoURL)
        let duration = try await asset.load(.duration)
        let videoTracks = try await asset.loadTracks(withMediaType: .video)

        guard let sourceVideoTrack = videoTracks.first else {
            throw ExportError.missingVideoTrack
        }

        let composition = AVMutableComposition()
        guard let compositionVideoTrack = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw ExportError.couldNotCreateExportSession
        }

        let timeRange = CMTimeRange(start: .zero, duration: duration)
        try compositionVideoTrack.insertTimeRange(timeRange, of: sourceVideoTrack, at: .zero)
        compositionVideoTrack.preferredTransform = try await sourceVideoTrack.load(.preferredTransform)

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        if let sourceAudioTrack = audioTracks.first,
           let compositionAudioTrack = composition.addMutableTrack(
            withMediaType: .audio,
            preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            try? compositionAudioTrack.insertTimeRange(timeRange, of: sourceAudioTrack, at: .zero)
        }

        let cache = OverlayImageCache()
        let sanitizedSamples = samples.sorted { $0.t < $1.t }

        let videoComposition = AVMutableVideoComposition(asset: composition) { request in
            autoreleasepool {
                let seconds = CMTimeGetSeconds(request.compositionTime)
                let bpm = bpmAt(seconds: seconds, samples: sanitizedSamples)
                let sourceImage = request.sourceImage
                let overlayImage = overlayImage(
                    bpm: bpm,
                    extent: sourceImage.extent,
                    cache: cache
                )

                let composed = overlayImage.composited(over: sourceImage).cropped(to: sourceImage.extent)
                request.finish(with: composed, context: nil)
            }
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("bpm_overlay_\(UUID().uuidString)")
            .appendingPathExtension("mov")

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw ExportError.couldNotCreateExportSession
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mov
        exportSession.videoComposition = videoComposition
        exportSession.shouldOptimizeForNetworkUse = true

        do {
            try await runExport(exportSession)
            try await saveVideoToPhotoLibrary(url: outputURL)
        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }

        try? FileManager.default.removeItem(at: outputURL)
    }

    private static func runExport(_ session: AVAssetExportSession) async throws {
        let sessionBox = ExportSessionBox(session: session)
        try await withCheckedThrowingContinuation { continuation in
            sessionBox.session.exportAsynchronously {
                switch sessionBox.session.status {
                case .completed:
                    continuation.resume(returning: ())
                case .failed:
                    continuation.resume(throwing: sessionBox.session.error ?? ExportError.exportFailed)
                case .cancelled:
                    continuation.resume(throwing: ExportError.exportCancelled)
                default:
                    continuation.resume(throwing: sessionBox.session.error ?? ExportError.exportFailed)
                }
            }
        }
    }

    private static func requestPhotoLibraryAccess() async throws {
        let currentStatus = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        if currentStatus == .authorized || currentStatus == .limited {
            return
        }

        if currentStatus == .notDetermined {
            let newStatus = await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                    continuation.resume(returning: status)
                }
            }
            if newStatus == .authorized || newStatus == .limited {
                return
            }
        }

        throw ExportError.photosPermissionDenied
    }

    private static func saveVideoToPhotoLibrary(url: URL) async throws {
        try await withCheckedThrowingContinuation { continuation in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
            }, completionHandler: { success, error in
                if success {
                    continuation.resume(returning: ())
                } else {
                    continuation.resume(throwing: error ?? ExportError.photoSaveFailed)
                }
            })
        }
    }

    private static func overlayImage(
        bpm: Int,
        extent: CGRect,
        cache: OverlayImageCache
    ) -> CIImage {
        let textImage: CIImage
        if let cached = cache.image(for: bpm) {
            textImage = cached
        } else {
            let rendered = renderBPMTextImage(bpm: bpm)
            let ciImage = CIImage(image: rendered) ?? CIImage(color: .clear).cropped(to: CGRect(origin: .zero, size: overlaySize))
            cache.set(ciImage, for: bpm)
            textImage = ciImage
        }

        let x = extent.minX + overlayMargin
        let maxTopY = extent.maxY - overlaySize.height - overlayMargin - topEdgeCompensation
        let minTopY = extent.minY + overlayMargin
        let y = max(minTopY, maxTopY)
        return textImage.transformed(by: CGAffineTransform(translationX: x, y: y))
    }

    private static func renderBPMTextImage(bpm: Int) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: overlaySize)
        let text = "\(max(0, bpm)) BPM"
        return renderer.image { context in
            let bounds = CGRect(origin: .zero, size: overlaySize)

            let bgPath = UIBezierPath(roundedRect: bounds, cornerRadius: 14)
            UIColor.black.withAlphaComponent(0.55).setFill()
            bgPath.fill()

            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .left

            let attributes: [NSAttributedString.Key: Any] = [
                .font: UIFont.systemFont(ofSize: 24, weight: .black),
                .foregroundColor: bpmColor(for: bpm),
                .paragraphStyle: paragraph
            ]

            let drawRect = CGRect(
                x: 12,
                y: (overlaySize.height - 30) / 2,
                width: overlaySize.width - 16,
                height: 30
            )
            text.draw(in: drawRect, withAttributes: attributes)

            context.cgContext.setShadow(
                offset: CGSize(width: 0, height: 1),
                blur: 3,
                color: UIColor.black.withAlphaComponent(0.7).cgColor
            )
            context.cgContext.setStrokeColor(UIColor.white.withAlphaComponent(0.2).cgColor)
            context.cgContext.setLineWidth(1)
            context.cgContext.stroke(bounds.insetBy(dx: 0.5, dy: 0.5))
        }
    }

    private static func bpmColor(for bpm: Int) -> UIColor {
        switch bpm {
        case ..<121:
            return UIColor(white: 0.85, alpha: 1.0)
        case ..<141:
            return UIColor(red: 0.49, green: 0.81, blue: 1.0, alpha: 1.0)
        case ..<162:
            return UIColor.systemGreen
        case ..<182:
            return UIColor.systemYellow
        default:
            return UIColor.systemRed
        }
    }

    private static func bpmAt(seconds: TimeInterval, samples: [HeartRateSample]) -> Int {
        guard seconds.isFinite, !samples.isEmpty else { return 0 }
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

        let upperIndex = left
        let lowerIndex = max(0, upperIndex - 1)
        let lower = samples[lowerIndex]
        let upper = samples[upperIndex]
        return abs(lower.t - seconds) <= abs(upper.t - seconds) ? lower.bpm : upper.bpm
    }
}
