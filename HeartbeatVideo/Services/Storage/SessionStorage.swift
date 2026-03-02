import Foundation

struct SessionFiles {
    let sessionID: String
    let directoryURL: URL
    let videoURL: URL
    let heartRateURL: URL
    let metadataURL: URL
}

final class SessionStorage {
    private let fileManager = FileManager.default

    private var sessionsRootURL: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("WorkoutSessions", isDirectory: true)
    }

    func createSessionFiles() throws -> SessionFiles {
        try fileManager.createDirectory(at: sessionsRootURL, withIntermediateDirectories: true)

        let sessionID = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let sessionDirectory = sessionsRootURL.appendingPathComponent(sessionID, isDirectory: true)
        try fileManager.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)

        return SessionFiles(
            sessionID: sessionID,
            directoryURL: sessionDirectory,
            videoURL: sessionDirectory.appendingPathComponent("video.mov"),
            heartRateURL: sessionDirectory.appendingPathComponent("heartRate.json"),
            metadataURL: sessionDirectory.appendingPathComponent("session.json")
        )
    }

    func saveHeartRateSamples(_ samples: [HeartRateSample], to url: URL) throws {
        let data = try JSONEncoder.prettyPrinted.encode(samples)
        try data.write(to: url, options: .atomic)
    }

    func saveMetadata(_ metadata: WorkoutSessionMetadata, to url: URL) throws {
        let data = try JSONEncoder.prettyPrinted.encode(metadata)
        try data.write(to: url, options: .atomic)
    }

    func listSessions() -> [SessionFiles] {
        guard let directories = try? fileManager.contentsOfDirectory(
            at: sessionsRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return directories.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).map { directory in
            SessionFiles(
                sessionID: directory.lastPathComponent,
                directoryURL: directory,
                videoURL: directory.appendingPathComponent("video.mov"),
                heartRateURL: directory.appendingPathComponent("heartRate.json"),
                metadataURL: directory.appendingPathComponent("session.json")
            )
        }
    }

    func loadHeartRateSamples(from url: URL) -> [HeartRateSample] {
        guard let data = try? Data(contentsOf: url),
              let samples = try? JSONDecoder().decode([HeartRateSample].self, from: data) else {
            return []
        }
        return samples
    }
}

private extension JSONEncoder {
    static var prettyPrinted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
