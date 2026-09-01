import Foundation
import CoreServices

/// Refreshes when an agent actually writes something, instead of asking on a timer.
///
/// Polling costs the same whether or not anything happened, and it is the wrong shape for this
/// app: a laptop sitting in the notch all day does no work most of the time, and the poll was
/// spawning a Node process every cycle regardless. Agents are file-backed — every vendor appends
/// to a transcript — so the filesystem already knows when there is something to look at.
///
/// FSEvents coalesces bursts for us: `latency` is the quiet period it waits for, which is exactly
/// the debounce a hundred concurrent agents would otherwise need.
final class SourceWatcher {
    private var stream: FSEventStreamRef?
    private let paths: [String]
    private let latency: TimeInterval
    private let onChange: () -> Void

    init(paths: [String], latency: TimeInterval = 2.0, onChange: @escaping () -> Void) {
        self.paths = paths.filter { FileManager.default.fileExists(atPath: $0) }
        self.latency = latency
        self.onChange = onChange
    }

    func start() {
        guard stream == nil, !paths.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil)

        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<SourceWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }

        guard let s = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context, paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency,
            // NoDefer: report the first event immediately, then coalesce the rest of the burst,
            // so the first keystroke of a new session is not held for the whole latency window.
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer
                                     | kFSEventStreamCreateFlagFileEvents))
        else { return }

        FSEventStreamSetDispatchQueue(s, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(s)
        stream = s
    }

    deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
