import Foundation

struct SessionFiles {
    let sessionID: String
    let directoryURL: URL
    let videoURL: URL
    let heartRateURL: URL
    let heartRateDeviceSeriesURL: URL
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
            heartRateDeviceSeriesURL: sessionDirectory.appendingPathComponent("heartRateDevices.json"),
            metadataURL: sessionDirectory.appendingPathComponent("session.json")
        )
    }

    func saveHeartRateSamples(_ samples: [HeartRateSample], to url: URL) throws {
        let data = try JSONEncoder.prettyPrinted.encode(samples)
        try data.write(to: url, options: .atomic)
    }

    func saveHeartRateDeviceSeries(_ series: [HeartRateDeviceSeries], to url: URL) throws {
        let data = try JSONEncoder.prettyPrinted.encode(series)
        try data.write(to: url, options: .atomic)
    }

    func saveMetadata(_ metadata: WorkoutSessionMetadata, to url: URL) throws {
        let data = try JSONEncoder.prettyPrinted.encode(metadata)
        try data.write(to: url, options: .atomic)
    }

    func loadMetadata(from url: URL) -> WorkoutSessionMetadata? {
        guard let data = try? Data(contentsOf: url),
              let metadata = try? JSONDecoder().decode(WorkoutSessionMetadata.self, from: data) else {
            return nil
        }
        return metadata
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
                heartRateDeviceSeriesURL: directory.appendingPathComponent("heartRateDevices.json"),
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

    func loadHeartRateDeviceSeries(from url: URL) -> [HeartRateDeviceSeries] {
        guard let data = try? Data(contentsOf: url),
              let series = try? JSONDecoder().decode([HeartRateDeviceSeries].self, from: data) else {
            return []
        }
        return series
    }

    func clearAllSessions() throws {
        guard fileManager.fileExists(atPath: sessionsRootURL.path) else { return }
        try fileManager.removeItem(at: sessionsRootURL)
    }

    func hasLocalSessionFiles(_ files: SessionFiles) -> Bool {
        let rootPath = canonicalPath(for: sessionsRootURL)
        let sessionPath = canonicalPath(for: files.directoryURL)
        let isWithinSessionsRoot = sessionPath == rootPath || sessionPath.hasPrefix(rootPath + "/")
        return isWithinSessionsRoot && fileManager.fileExists(atPath: sessionPath)
    }

    func deleteSession(_ files: SessionFiles) throws {
        let rootPath = canonicalPath(for: sessionsRootURL)
        let sessionPath = canonicalPath(for: files.directoryURL)
        let isWithinSessionsRoot = sessionPath == rootPath || sessionPath.hasPrefix(rootPath + "/")
        guard isWithinSessionsRoot else { return }
        guard fileManager.fileExists(atPath: sessionPath) else { return }
        try fileManager.removeItem(atPath: sessionPath)
    }

    func totalStorageBytes() -> Int64 {
        guard fileManager.fileExists(atPath: sessionsRootURL.path) else { return 0 }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
        guard let enumerator = fileManager.enumerator(
            at: sessionsRootURL,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let size = values.fileSize else {
                continue
            }
            total += Int64(size)
        }
        return total
    }

    private func canonicalPath(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

private extension JSONEncoder {
    static var prettyPrinted: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
