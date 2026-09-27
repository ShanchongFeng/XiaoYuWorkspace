import CoreServices
import Foundation

/// FSEvents observes the entire selected project tree without opening every directory.
@MainActor
final class ProjectChangeMonitor {
    private var stream: FSEventStreamRef?
    private let onChange: @MainActor () -> Void

    init(root: URL, onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(version: 0,
                                           info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, _, _, _ in
            guard count > 0, let info else { return }
            let monitor = Unmanaged<ProjectChangeMonitor>.fromOpaque(info).takeUnretainedValue()
            // The stream is scheduled on the main queue below.
            MainActor.assumeIsolated { monitor.onChange() }
        }
        guard let created = FSEventStreamCreate(nil, callback, &context,
                                                [root.path] as CFArray,
                                                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                                0.3,
                                                FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)) else {
            return
        }
        FSEventStreamSetDispatchQueue(created, .main)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return
        }
        stream = created
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        MainActor.assumeIsolated { stop() }
    }
}
