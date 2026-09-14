import Foundation

/// Watches a directory for files appearing, disappearing or being replaced. Collectors (ours,
/// or any from the Omarchy ecosystem) and Omarchy's theme switch both replace files by rename,
/// which is a write to the directory itself. Used for the records directory, as Agent.qml
/// watches each record, and for a custom theme folder.
@MainActor
final class DirectoryWatcher {
    private let source: DispatchSourceFileSystemObject?

    init(directory: URL, createIfMissing: Bool = true, onChange: @escaping @MainActor () -> Void) {
        if createIfMissing {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        let descriptor = open(directory.path(percentEncoded: false), O_EVTONLY)
        guard descriptor >= 0 else {
            source = nil
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main
        )
        source.setEventHandler {
            MainActor.assumeIsolated { onChange() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        self.source = source
    }

    func stop() {
        source?.cancel()
    }
}
