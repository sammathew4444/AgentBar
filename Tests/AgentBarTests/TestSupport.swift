import Foundation
import SQLite3

enum TestPaths {
    static let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    static let repoRoot = testsDirectory.deletingLastPathComponent().deletingLastPathComponent()
    static let fixtures = testsDirectory.appending(path: "Fixtures", directoryHint: .isDirectory)
    /// Records captured from a real Omarchy install (CLAUDE.md, Phase 0).
    static let capturedRecordsDirectory = repoRoot.appending(path: "reference/records", directoryHint: .isDirectory)

    static var capturedRecords: [URL] { jsonFiles(in: capturedRecordsDirectory) }

    static func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: fixtures.appending(path: name + ".json"))
    }

    static func jsonFiles(in directory: URL) -> [URL] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}

/// An opencode `message` table like the ones Omarchy's collector tests build.
enum OpencodeFixture {
    static func create(at url: URL, table: Bool = true) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try exec(at: url, table
            ? "CREATE TABLE message (id text PRIMARY KEY, session_id text NOT NULL, time_created integer NOT NULL, time_updated integer NOT NULL, data text NOT NULL);"
            : "CREATE TABLE unrelated (id text PRIMARY KEY);")
    }

    static func message(_ id: String, _ provider: String, _ model: String, role: String = "assistant",
                        input: Int = 0, output: Int = 0, reasoning: Int = 0, read: Int = 0, write: Int = 0,
                        created: Int = 1_789_390_800_000) -> String {
        #"{"role":"\#(role)","providerID":"\#(provider)","modelID":"\#(model)","tokens":{"input":\#(input),"output":\#(output),"reasoning":\#(reasoning),"cache":{"read":\#(read),"write":\#(write)}},"time":{"created":\#(created)}}"#
    }

    /// Inserts raw `data` for each id; single quotes in data are escaped for SQL.
    static func insert(at url: URL, _ rows: [(id: String, data: String)]) throws {
        let sql = rows.map { row in
            "INSERT INTO message VALUES ('\(row.id)', 'ses_1', 0, 0, '\(row.data.replacingOccurrences(of: "'", with: "''"))');"
        }.joined(separator: "\n")
        try exec(at: url, sql)
    }

    private static func exec(at url: URL, _ sql: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(url.path(percentEncoded: false), &db) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
        defer { sqlite3_close(db) }
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw CocoaError(.fileWriteUnknown) }
    }
}

/// A fresh directory under the system temp dir, removed when the test is done with it.
struct TemporaryDirectory: ~Copyable {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appending(path: "AgentBarTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: url)
    }
}
