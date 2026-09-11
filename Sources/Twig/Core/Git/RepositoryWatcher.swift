import Foundation
import CoreServices

/// Recursive macOS notifications, including external editors and linked-worktree metadata.
final class RepositoryWatcher {
    private var stream: FSEventStreamRef?
    private let metadataRoots: [String]
    private let onChange: (Bool) -> Void

    init?(paths: [URL], metadataRoots: [URL], onChange: @escaping (Bool) -> Void) {
        self.metadataRoots = metadataRoots.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagWatchRoot)
        let roots = Array(Set(paths.map { $0.standardizedFileURL.resolvingSymlinksInPath().path }))
        stream = FSEventStreamCreate(nil, { _, info, count, rawPaths, eventFlags, _ in
            guard let info else { return }
            let owner = Unmanaged<RepositoryWatcher>.fromOpaque(info).takeUnretainedValue()
            let paths = unsafeBitCast(rawPaths, to: NSArray.self) as! [String]
            var changed = false
            var metadata = false
            for index in 0..<count {
                let path = paths[index]
                let dropped = eventFlags[index] & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged) != 0
                if dropped { changed = true; metadata = true; continue }
                if let root = owner.metadataRoots.first(where: { path == $0 || path.hasPrefix($0 + "/") }) {
                    let relative = String(path.dropFirst(root.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    // Ignore object writes, reflog churn and transient locks. The
                    // final HEAD/index/ref notifications trigger the actual update.
                    if relative.hasSuffix(".lock") || relative == "objects" || relative.hasPrefix("objects/") || relative == "logs" || relative.hasPrefix("logs/") { continue }
                    changed = true
                    if relative != "index" { metadata = true }
                } else {
                    changed = true
                }
            }
            if changed { owner.onChange(metadata) }
        }, &context, roots as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.15, flags)
        guard let stream else { return nil }
        FSEventStreamSetDispatchQueue(stream, .main)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
            return nil
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
