import Foundation

final class PVTSessionStorage {
    private let fileManager = FileManager.default

    private var sessionsRootURL: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("PVTSessions", isDirectory: true)
    }

    private var sessionsFileURL: URL {
        sessionsRootURL.appendingPathComponent("pvt_sessions.json")
    }

    func listSessions() -> [PVTSessionRecord] {
        try? ensureRootDirectory()
        guard let data = try? Data(contentsOf: sessionsFileURL),
              let sessions = try? JSONDecoder().decode([PVTSessionRecord].self, from: data) else {
            return []
        }
        return sessions.sorted(by: { $0.completedAt > $1.completedAt })
    }

    func saveSession(_ session: PVTSessionRecord) throws {
        var sessions = listSessions()
        sessions.removeAll { $0.id == session.id }
        sessions.append(session)
        sessions.sort(by: { $0.completedAt > $1.completedAt })
        try writeSessions(sessions)
    }

    private func writeSessions(_ sessions: [PVTSessionRecord]) throws {
        try ensureRootDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(sessions)
        try data.write(to: sessionsFileURL, options: .atomic)
    }

    private func ensureRootDirectory() throws {
        try fileManager.createDirectory(at: sessionsRootURL, withIntermediateDirectories: true)
    }
}
