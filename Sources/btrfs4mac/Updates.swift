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

struct Release {
    let version: String
    let url: String
}

/// Latest anylinuxfs release on GitHub (no account needed).
func fetchLatestRelease(done: @escaping (Release?) -> Void) {
    var request = URLRequest(url: URL(string: "https://api.github.com/repos/nohajc/anylinuxfs/releases/latest")!)
    request.timeoutInterval = 15
    request.setValue("btrfs4mac", forHTTPHeaderField: "User-Agent")
    URLSession.shared.dataTask(with: request) { data, _, _ in
        var release: Release?
        if let data,
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let tag = json["tag_name"] as? String, let url = json["html_url"] as? String {
            release = Release(version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag, url: url)
        }
        DispatchQueue.main.async { done(release) }
    }.resume()
}

/// True when `a` is a higher dotted version than `b` ("0.21.0" > "0.20.1").
func isNewer(_ a: String, than b: String) -> Bool {
    let x = a.split(separator: ".").map { Int($0) ?? 0 }
    let y = b.split(separator: ".").map { Int($0) ?? 0 }
    for i in 0..<max(x.count, y.count) {
        let p = i < x.count ? x[i] : 0
        let q = i < y.count ? y[i] : 0
        if p != q { return p > q }
    }
    return false
}
