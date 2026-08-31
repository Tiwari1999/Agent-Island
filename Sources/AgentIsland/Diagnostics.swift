import Foundation

enum Diagnostics {
    private static let path = "/tmp/agentisland.log"
    static func log(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let h = FileHandle(forWritingAtPath: path) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else {
            FileManager.default.createFile(atPath: path, contents: data)
        }
    }
}
