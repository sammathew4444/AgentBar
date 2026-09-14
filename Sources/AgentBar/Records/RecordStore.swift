import Foundation
import OSLog

/// Reads and writes usage records as `<directory>/<id>.json`, the same layout and schema as
/// Omarchy's `~/.local/state/omarchy/agents/usage/`, so Omarchy-ecosystem collectors can be
/// pointed at this directory and just work.
struct RecordStore: Sendable {
    enum StoreError: Error, Equatable {
        /// Ids become file names, so they are limited to what a collector name can be.
        case invalidID(String)
    }

    let directory: URL

    static var defaultDirectory: URL {
        URL.applicationSupportDirectory
            .appending(path: "AgentBar", directoryHint: .isDirectory)
            .appending(path: "records", directoryHint: .isDirectory)
    }

    init(directory: URL = RecordStore.defaultDirectory) {
        self.directory = directory
    }

    /// Every readable record, ordered by file name. Like Main.qml this lists `*.json` one level
    /// deep, and a file that fails to parse is skipped rather than failing the rest.
    func loadAll() -> [UsageRecord] {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )
        } catch {
            // A missing directory just means nothing has been collected yet.
            return []
        }
        return files
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                do {
                    return try Self.decode(Data(contentsOf: url))
                } catch {
                    Logger.store.error("Ignoring bad usage record \(url.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
                    return nil
                }
            }
    }

    func load(id: String) throws -> UsageRecord {
        try Self.decode(Data(contentsOf: url(for: id)))
    }

    /// Atomic replace, so a reader never sees half a record.
    func write(_ record: UsageRecord) throws {
        let target = try url(for: record.id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var data = try Self.encoder.encode(record)
        data.append(0x0A)
        try data.write(to: target, options: .atomic)
    }

    func url(for id: String) throws -> URL {
        guard Self.isValidID(id) else { throw StoreError.invalidID(id) }
        return directory.appending(path: id + ".json", directoryHint: .notDirectory)
    }

    static func decode(_ data: Data) throws -> UsageRecord {
        try JSONDecoder().decode(UsageRecord.self, from: data)
    }

    static func isValidID(_ id: String) -> Bool {
        id.range(of: #"^[A-Za-z0-9_-][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        // omarchy-agent-usage-claude prints with sort_keys; matching it keeps files diffable.
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
}
