import Foundation

enum Shell {
    static let claude = "/opt/homebrew/bin/claude"

    /// Run a command off the main thread; completion is delivered on the main queue.
    static func run(_ path: String, _ args: [String], done: @escaping (String, Int32) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: path)
            task.arguments = args
            let out = Pipe()
            task.standardOutput = out
            task.standardError = Pipe()
            do { try task.run() } catch {
                DispatchQueue.main.async { done("", -1) }
                return
            }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            let text = String(data: data, encoding: .utf8) ?? ""
            let code = task.terminationStatus
            DispatchQueue.main.async { done(text, code) }
        }
    }

    /// Reading into a box rather than a captured var keeps the timeout path free of a data race:
    /// on timeout we abandon the reader and never look at what it wrote.
    private final class Out: @unchecked Sendable { var data = Data() }

    /// A refresh shells out dozens of times, so this has to be airtight on two counts: every
    /// descriptor is closed on every path (leaked pipes eventually exhaust the 256-fd limit and
    /// children then spawn into a broken state), and every call has a deadline.
    @discardableResult
    static func runSync(_ path: String, _ args: [String], timeout: TimeInterval = 10) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let out = Pipe()
        task.standardOutput = out
        // No pipe for the streams we never read: one fewer pair to leak, and a child that writes
        // a lot to stderr can no longer block forever on a full buffer nobody drains.
        task.standardError = FileHandle.nullDevice
        task.standardInput = FileHandle.nullDevice
        guard (try? task.run()) != nil else {
            try? out.fileHandleForReading.close()
            try? out.fileHandleForWriting.close()
            return ""
        }
        // The parent's own write end must go, or the reader never sees EOF.
        try? out.fileHandleForWriting.close()
        defer { try? out.fileHandleForReading.close() }

        // A dedicated thread, not a global queue: rebuild already runs on the utility queue, and
        // blocking one of its threads on a semaphore signalled from the same queue can starve.
        let box = Out()
        let done = DispatchSemaphore(value: 0)
        Thread.detachNewThread {
            box.data = out.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            task.terminate()
            // Let the child die so the reader hits EOF and the thread unwinds.
            if done.wait(timeout: .now() + 2) == .timedOut { kill(task.processIdentifier, SIGKILL) }
            _ = done.wait(timeout: .now() + 1)
            Diagnostics.log("timeout after \(Int(timeout))s: \(path) \(args.first ?? "")")
            return ""
        }
        task.waitUntilExit()
        return String(data: box.data, encoding: .utf8) ?? ""
    }
}
