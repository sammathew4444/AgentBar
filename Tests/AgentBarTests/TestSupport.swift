import Foundation

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
