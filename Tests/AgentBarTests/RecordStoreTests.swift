import Foundation
import Testing
@testable import AgentBar

@Suite("Record store")
struct RecordStoreTests {
    @Test("The default directory is under Application Support")
    func defaultDirectory() {
        #expect(RecordStore.defaultDirectory.path(percentEncoded: false).hasSuffix("/Library/Application Support/AgentBar/records/"))
    }

    @Test("A written record reads back unchanged from <id>.json")
    func writeThenLoad() throws {
        let temp = try TemporaryDirectory()
        let store = RecordStore(directory: temp.url.appending(path: "records"))
        let record = try RecordStore.decode(TestPaths.fixture("claude"))

        try store.write(record)

        let file = temp.url.appending(path: "records/claude.json")
        #expect(FileManager.default.fileExists(atPath: file.path(percentEncoded: false)))
        #expect(try Data(contentsOf: file).last == 0x0A)
        #expect(try store.load(id: "claude") == record)
    }

    @Test("Writing replaces the previous record")
    func overwrite() throws {
        let temp = try TemporaryDirectory()
        let store = RecordStore(directory: temp.url)
        var record = try RecordStore.decode(TestPaths.fixture("claude"))
        try store.write(record)
        record.usageStatusText = "Sign-in expired"
        try store.write(record)
        #expect(try store.load(id: "claude").usageStatusText == "Sign-in expired")
        #expect(TestPaths.jsonFiles(in: temp.url).count == 1)
    }

    @Test("loadAll reads every good record, ordered by file name, and skips the rest")
    func loadAllSkipsBadFiles() throws {
        let temp = try TemporaryDirectory()
        let store = RecordStore(directory: temp.url)
        for name in ["fireworks", "claude", "codex"] {
            try TestPaths.fixture(name).write(to: temp.url.appending(path: "\(name).json"))
        }
        let junk: [String: String] = [
            "broken.json": "{not json",
            "anonymous.json": #"{"name":"No id"}"#,
            "notes.txt": #"{"id":"notes"}"#,
            // omarchy-agent-usage-update's in-flight temp file.
            ".claude.a1B2c3": #"{"id":"claude-partial"}"#,
        ]
        for (name, contents) in junk {
            try Data(contents.utf8).write(to: temp.url.appending(path: name))
        }
        try FileManager.default.createDirectory(at: temp.url.appending(path: "nested"), withIntermediateDirectories: true)
        try TestPaths.fixture("claude").write(to: temp.url.appending(path: "nested/deep.json"))

        #expect(store.loadAll().map(\.id) == ["claude", "codex", "fireworks"])
    }

    @Test("loadAll on a directory that doesn't exist yet is empty")
    func missingDirectory() throws {
        let temp = try TemporaryDirectory()
        #expect(RecordStore(directory: temp.url.appending(path: "absent")).loadAll().isEmpty)
    }

    @Test("Ids that would escape the directory are refused", arguments: ["", "../claude", "a/b", ".hidden", "claude.json/..", "sp ace"])
    func invalidIDs(id: String) throws {
        let temp = try TemporaryDirectory()
        let store = RecordStore(directory: temp.url)
        var record = try RecordStore.decode(TestPaths.fixture("claude"))
        record.id = id
        #expect(throws: RecordStore.StoreError.invalidID(id)) { try store.write(record) }
        #expect(throws: RecordStore.StoreError.invalidID(id)) { try store.load(id: id) }
    }

    @Test("Collector-style ids are accepted", arguments: ["claude", "codex", "fireworks", "open_code-2", "pi.dev"])
    func validIDs(id: String) {
        #expect(RecordStore.isValidID(id))
    }
}
