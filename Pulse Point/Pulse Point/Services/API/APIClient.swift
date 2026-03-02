import Foundation

struct APIHealthResponse: Decodable {
    let status: String
    let db: String?
}

struct APISessionListItem: Decodable, Identifiable {
    let id: Int
    let session_uuid: String
    let title: String?
    let note: String?
    let started_at: String
    let ended_at: String?
    let duration_seconds: Double
    let min_bpm: Int?
    let avg_bpm: Int?
    let max_bpm: Int?
    let video_url: String?
}

struct APIHeartRateSample: Decodable {
    let t_seconds: Double
    let bpm: Int
}

struct APIFullSessionUploadRequest: Encodable {
    struct Session: Encodable {
        let userId: Int
        let sessionUuid: String
        let title: String?
        let note: String?
        let startedAt: String
        let endedAt: String?
        let durationSeconds: Double
        let minBpm: Int?
        let avgBpm: Int?
        let maxBpm: Int?
        let videoUrl: String?
    }

    struct HeartRateSample: Encodable {
        let tSeconds: Double
        let bpm: Int
    }

    struct PVTTrialPoint: Encodable {
        let trialIndex: Int
        let reactionMs: Int
    }

    struct PVTResult: Encodable {
        let phase: String
        let durationSeconds: Int
        let totalStimuli: Int
        let correctTaps: Int
        let incorrectTaps: Int
        let falseStarts: Int
        let misses: Int
        let lapses: Int
        let meanReactionMs: Int
        let medianReactionMs: Int
        let fastestReactionMs: Int
        let slowestReactionMs: Int
        let trialPoints: [PVTTrialPoint]
    }

    let session: Session
    let heartRateSamples: [HeartRateSample]
    let prePvt: PVTResult?
    let postPvt: PVTResult?
}

struct APIFullSessionUploadResponse: Decodable {
    let workoutSessionId: Int
    let heartRateSampleCount: Int
}

struct APIVideoUploadResponse: Decodable {
    let videoUrl: String
    let fileName: String?
}

enum APIClientError: LocalizedError {
    case invalidBaseURL
    case badStatusCode(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Invalid API base URL in settings."
        case .badStatusCode(let code, let body):
            return "API request failed (\(code)): \(body)"
        }
    }
}

final class APIClient {
    static let shared = APIClient()

    private let session: URLSession
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(session: URLSession = .shared) {
        self.session = session

        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        self.encoder = enc

        self.decoder = JSONDecoder()
    }

    func healthCheck() async throws -> APIHealthResponse {
        let data = try await request(path: "/health", method: "GET", body: nil, includeAPIKey: false)
        return try decoder.decode(APIHealthResponse.self, from: data)
    }

    func listSessions(userId: Int) async throws -> [APISessionListItem] {
        let data = try await request(path: "/api/sessions?userId=\(userId)", method: "GET", body: nil)
        return try decoder.decode([APISessionListItem].self, from: data)
    }

    func heartRateSamples(sessionId: Int) async throws -> [HeartRateSample] {
        let data = try await request(path: "/api/sessions/\(sessionId)/heart-rate", method: "GET", body: nil)
        let apiSamples = try decoder.decode([APIHeartRateSample].self, from: data)
        return apiSamples.map { HeartRateSample(t: $0.t_seconds, bpm: $0.bpm) }
    }

    func uploadFullSession(_ payload: APIFullSessionUploadRequest) async throws -> APIFullSessionUploadResponse {
        let body = try encoder.encode(payload)
        let data = try await request(path: "/api/sessions/full", method: "POST", body: body)
        return try decoder.decode(APIFullSessionUploadResponse.self, from: data)
    }

    func uploadVideo(fileURL: URL) async throws -> APIVideoUploadResponse {
        let boundary = "Boundary-\(UUID().uuidString)"
        var request = try makeRequest(path: "/api/upload/video", method: "POST", includeAPIKey: true)
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let fileData = try Data(contentsOf: fileURL)
        var body = Data()
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"video\"; filename=\"\(fileURL.lastPathComponent)\"\r\n")
        body.append("Content-Type: video/quicktime\r\n\r\n")
        body.append(fileData)
        body.append("\r\n--\(boundary)--\r\n")

        request.httpBody = body
        let (data, response) = try await session.data(for: request)
        try validateStatus(response: response, data: data)
        return try decoder.decode(APIVideoUploadResponse.self, from: data)
    }

    private func request(
        path: String,
        method: String,
        body: Data?,
        includeAPIKey: Bool = true
    ) async throws -> Data {
        var request = try makeRequest(path: path, method: method, includeAPIKey: includeAPIKey)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await session.data(for: request)
        try validateStatus(response: response, data: data)

        return data
    }

    private func makeRequest(path: String, method: String, includeAPIKey: Bool) throws -> URLRequest {
        let trimmedBase = AppSettings.apiBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let normalizedPath = path.hasPrefix("/") ? path : "/\(path)"
        let fullURLString = "\(trimmedBase)\(normalizedPath)"
        guard let url = URL(string: fullURLString) else {
            throw APIClientError.invalidBaseURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        if includeAPIKey {
            request.setValue(AppSettings.apiKey, forHTTPHeaderField: "x-api-key")
        }
        return request
    }

    private func validateStatus(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200...299).contains(http.statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? "(no response body)"
            throw APIClientError.badStatusCode(http.statusCode, bodyText)
        }
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
