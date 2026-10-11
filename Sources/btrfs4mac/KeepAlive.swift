import Foundation

/// Writes and syncs a tiny file to the volume on a timer, so the drive's own
/// idle timer never expires. The sync matters: without it the write stays in
/// the VM's page cache and never reaches the disk.
final class KeepAlive {
    private let queue = DispatchQueue(label: "btrfs4mac.keepalive")
    private var timer: DispatchSourceTimer?
    private(set) var lastOK: Date?
    private(set) var lastError: String?

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: Config.keepAliveInterval)
        source.setEventHandler { [weak self] in self?.tick() }
        source.resume()
        timer = source
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        let path = Config.mountPoint + "/" + Config.keepAliveFile
        let stamp = ISO8601DateFormatter().string(from: Date())
        do {
            guard isMounted() else { throw CocoaError(.fileNoSuchFile) }
            try Data(stamp.utf8).write(to: URL(fileURLWithPath: path))
            let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
            defer { try? handle.close() }
            try handle.synchronize()
            DispatchQueue.main.async { self.lastOK = Date(); self.lastError = nil }
        } catch {
            DispatchQueue.main.async { self.lastError = error.localizedDescription }
        }
    }
}
