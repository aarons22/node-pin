import Foundation

/// When enabled in Settings, appends timestamped lines to ~/Library/Logs/NodePin.log.
/// Never pass passwords here.
nonisolated enum DebugLog {
    static let defaultsKey = "diagnosticsLogging"
    static var path: String { url.path }

    private static let url = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/NodePin.log")
    private static let queue = DispatchQueue(label: "nodepin.debuglog")

    static func write(_ message: String) {
        guard UserDefaults.standard.bool(forKey: defaultsKey) else { return }
        NSLog("NodePin: %@", message)
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        queue.async {
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
