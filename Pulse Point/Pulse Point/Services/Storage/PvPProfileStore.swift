import Foundation

final class PvPProfileStore {
    private let fileManager = FileManager.default

    private var rootURL: URL {
        let docs = fileManager.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("PvPProfiles", isDirectory: true)
    }

    func loadBundle(ownerKey: String) -> PvPProfileBundle {
        try? ensureRootDirectory()
        let url = bundleFileURL(ownerKey: ownerKey)
        guard let data = try? Data(contentsOf: url),
              let bundle = try? JSONDecoder().decode(PvPProfileBundle.self, from: data) else {
            return .empty
        }
        return bundle
    }

    func saveBundle(_ bundle: PvPProfileBundle, ownerKey: String) throws {
        try ensureRootDirectory()
        let url = bundleFileURL(ownerKey: ownerKey)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(bundle)
        try data.write(to: url, options: .atomic)
    }

    private func bundleFileURL(ownerKey: String) -> URL {
        let safeOwner = sanitize(ownerKey)
        return rootURL.appendingPathComponent("\(safeOwner).json")
    }

    private func sanitize(_ value: String) -> String {
        let raw = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if raw.isEmpty {
            return "default"
        }
        return raw.replacingOccurrences(
            of: #"[^a-z0-9._-]+"#,
            with: "_",
            options: .regularExpression
        )
    }

    private func ensureRootDirectory() throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    }
}
