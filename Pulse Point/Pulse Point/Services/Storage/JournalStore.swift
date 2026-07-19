import Foundation

final class JournalStore {
    private let fileManager = FileManager.default

    private var rootURL: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("JournalEntries", isDirectory: true)
    }

    func listEntries(for email: String?) -> [JournalEntry] {
        try? ensureRootDirectory()
        let fileURL = entriesFileURL(for: email)
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([JournalEntry].self, from: data) else {
            return []
        }
        return decoded.sorted(by: { $0.updatedAt > $1.updatedAt })
    }

    func saveEntries(_ entries: [JournalEntry], for email: String?) throws {
        try ensureRootDirectory()
        let sortedEntries = entries.sorted(by: { $0.updatedAt > $1.updatedAt })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(sortedEntries)
        try data.write(to: entriesFileURL(for: email), options: .atomic)
    }

    private func entriesFileURL(for email: String?) -> URL {
        rootURL.appendingPathComponent("journal_\(safeIdentifier(for: email)).json")
    }

    private func ensureRootDirectory() throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }

    private func safeIdentifier(for email: String?) -> String {
        let normalized = email?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? "default"

        guard !normalized.isEmpty else { return "default" }

        let allowed = CharacterSet.alphanumerics
        let safe = normalized.unicodeScalars
            .map { allowed.contains($0) ? String($0) : "_" }
            .joined()

        return safe.isEmpty ? "default" : safe
    }
}
