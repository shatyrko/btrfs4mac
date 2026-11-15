import Foundation

/// Appends a timestamped line to ~/Library/Logs/btrfs4mac.log, so automatic actions can be explained later.
func log(_ message: String) {
    let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/btrfs4mac.log")
    let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

enum Versions {
    static var app: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "Btrfs4MacCommit") as? String ?? "dev"
    }

    /// "0.20.1" from `anylinuxfs --version`.
    static func anylinuxfs() -> String? {
        let result = runSync(Config.anylinuxfs, ["--version"])
        guard result.status == 0 else { return nil }
        return result.output.split(whereSeparator: \.isWhitespace).last.map(String.init)
    }
}
