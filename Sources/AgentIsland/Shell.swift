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

    @discardableResult
    static func runSync(_ path: String, _ args: [String]) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: path)
        task.arguments = args
        let out = Pipe()
        task.standardOutput = out
        task.standardError = Pipe()
        guard (try? task.run()) != nil else { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
