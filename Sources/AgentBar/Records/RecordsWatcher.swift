import Foundation

/// Watches the records directory, as Agent.qml watches each record file, so a record written by
/// any collector (ours, or one from the Omarchy ecosystem) shows up without waiting for a
/// refresh. Collectors replace files by rename, which is a write to the directory itself.
@MainActor
final class RecordsWatcher {
    private let source: DispatchSourceFileSystemObject?

    init(directory: URL, onChange: @escaping @MainActor () -> Void) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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
