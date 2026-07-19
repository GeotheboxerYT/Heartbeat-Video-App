import Foundation

struct SleepSessionFiles {
    let sessionID: String
    let directoryURL: URL
    let heartRateURL: URL
    let metadataURL: URL
}

struct ActiveSleepSessionState: Codable, Hashable {
    let sessionID: String
    let startedAt: Date
    let sourceRawValue: String
    let selectedBluetoothDeviceID: UUID?
    let elapsedSecondsAtCheckpoint: TimeInterval
    let lastCheckpointAt: Date
}

final class SleepSessionStorage {
    private let fileManager = FileManager.default

    private var sessionsRootURL: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("SleepSessions", isDirectory: true)
    }

    private var activeSessionStateURL: URL {
        sessionsRootURL.appendingPathComponent("active-session.json")
    }

    func createSessionFiles() throws -> SleepSessionFiles {
        try ensureRootDirectory()

        let sessionID = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let sessionDirectory = sessionDirectoryURL(for: sessionID)
        try fileManager.createDirectory(at: sessionDirectory, withIntermediateDirectories: true)

        return makeFiles(for: sessionID)
    }

    func sessionFiles(for sessionID: String) -> SleepSessionFiles {
        makeFiles(for: sessionID)
    }

    func saveHeartRateSamples(_ samples: [HeartRateSample], to url: URL) throws {
        let data = try prettyJSONEncoded(samples)
        try data.write(to: url, options: .atomic)
    }

    func saveMetadata(_ metadata: SleepSessionMetadata, to url: URL) throws {
        let data = try prettyJSONEncoded(metadata)
        try data.write(to: url, options: .atomic)
    }

    func loadMetadata(from url: URL) -> SleepSessionMetadata? {
        guard let data = try? Data(contentsOf: url),
              let metadata = try? JSONDecoder().decode(SleepSessionMetadata.self, from: data) else {
            return nil
        }
        return metadata
    }

    func loadHeartRateSamples(from url: URL) -> [HeartRateSample] {
        guard let data = try? Data(contentsOf: url),
              let samples = try? JSONDecoder().decode([HeartRateSample].self, from: data) else {
            return []
        }
        return samples
    }

    func listSessions() -> [SleepSessionFiles] {
        try? ensureRootDirectory()
        guard let directories = try? fileManager.contentsOfDirectory(
            at: sessionsRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let sessionDirectories = directories.filter { directory in
            let values = try? directory.resourceValues(forKeys: [.isDirectoryKey])
            return values?.isDirectory == true
        }

        return sessionDirectories.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).map { directory in
            makeFiles(for: directory.lastPathComponent)
        }
    }

    func saveActiveSessionState(_ state: ActiveSleepSessionState) throws {
        try ensureRootDirectory()
        let data = try prettyJSONEncoded(state)
        try data.write(to: activeSessionStateURL, options: .atomic)
    }

    func loadActiveSessionState() -> ActiveSleepSessionState? {
        guard let data = try? Data(contentsOf: activeSessionStateURL),
              let state = try? JSONDecoder().decode(ActiveSleepSessionState.self, from: data) else {
            return nil
        }
        return state
    }

    func clearActiveSessionState() {
        try? fileManager.removeItem(at: activeSessionStateURL)
    }

    private func makeFiles(for sessionID: String) -> SleepSessionFiles {
        let sessionDirectory = sessionDirectoryURL(for: sessionID)
        return SleepSessionFiles(
            sessionID: sessionID,
            directoryURL: sessionDirectory,
            heartRateURL: sessionDirectory.appendingPathComponent("heartRate.json"),
            metadataURL: sessionDirectory.appendingPathComponent("sleep.json")
        )
    }

    private func sessionDirectoryURL(for sessionID: String) -> URL {
        sessionsRootURL.appendingPathComponent(sessionID, isDirectory: true)
    }

    private func ensureRootDirectory() throws {
        try fileManager.createDirectory(at: sessionsRootURL, withIntermediateDirectories: true)
    }

    private func prettyJSONEncoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(value)
    }
}
