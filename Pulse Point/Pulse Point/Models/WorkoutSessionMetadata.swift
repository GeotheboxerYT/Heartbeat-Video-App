import Foundation

struct WorkoutSessionMetadata: Codable, Identifiable, Hashable {
    enum UploadState: String, Codable {
        case pending
        case syncing
        case synced
        case failed
    }

    let id: String
    let startedAt: Date
    let duration: TimeInterval
    let videoFileName: String?
    let heartRateFileName: String
    var uploadState: UploadState
    var uploadErrorMessage: String?

    init(
        id: String,
        startedAt: Date,
        duration: TimeInterval,
        videoFileName: String? = nil,
        heartRateFileName: String,
        uploadState: UploadState = .pending,
        uploadErrorMessage: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.duration = duration
        self.videoFileName = videoFileName
        self.heartRateFileName = heartRateFileName
        self.uploadState = uploadState
        self.uploadErrorMessage = uploadErrorMessage
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case startedAt
        case duration
        case videoFileName
        case heartRateFileName
        case uploadState
        case uploadErrorMessage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        duration = try container.decode(TimeInterval.self, forKey: .duration)
        videoFileName = try container.decodeIfPresent(String.self, forKey: .videoFileName)
        heartRateFileName = try container.decode(String.self, forKey: .heartRateFileName)
        uploadState = try container.decodeIfPresent(UploadState.self, forKey: .uploadState) ?? .pending
        uploadErrorMessage = try container.decodeIfPresent(String.self, forKey: .uploadErrorMessage)
    }
}
