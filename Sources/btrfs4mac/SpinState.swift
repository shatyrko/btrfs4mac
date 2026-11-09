import Foundation

// MARK: - macOS disk sleep

/// Minutes before macOS spins idle disks down (0 = never), from `pmset -g`.
/// Runs a subprocess: call it off the main thread.
func diskSleepMinutes() -> Int? {
    let result = runSync("/usr/bin/pmset", ["-g"])
    guard result.status == 0 else { return nil }
    for line in result.output.split(separator: "\n") {
        // Lines are indented, so drop the empty leading field.
        let parts = line.split(separator: " ", omittingEmptySubsequences: true)
        if parts.count >= 2, parts[0] == "disksleep" { return Int(parts[1]) }
    }
    return nil
}

/// `diskSleepMinutes()` at most once a minute: `refresh()` runs every few seconds and the
/// setting almost never changes.
private let diskSleepLock = NSLock()
private var diskSleepCache: (value: Int?, at: Date)?

func cachedDiskSleepMinutes() -> Int? {
    diskSleepLock.lock()
    if let cache = diskSleepCache, Date().timeIntervalSince(cache.at) < 60 {
        diskSleepLock.unlock()
        return cache.value
    }
    diskSleepLock.unlock()
    let value = diskSleepMinutes()
    diskSleepLock.lock()
    diskSleepCache = (value, Date())
    diskSleepLock.unlock()
    return value
}

/// The `pmset` setting as a menu line. The keep-alive and this setting pull in opposite
/// directions, so it is worth showing next to it.
func describeDiskSleep(_ minutes: Int?) -> (text: String, tip: String) {
    guard let minutes else {
        return ("macOS disk sleep: unknown", "pmset did not report a disksleep setting.")
    }
    if minutes == 0 {
        return ("macOS disk sleep: never",
                "macOS never spins idle disks down, so only the enclosure's own timer can park this drive.")
    }
    return ("macOS disk sleep: \(minutes) min",
            "macOS spins idle disks down after \(minutes) minutes. The keep-alive's writes reset that timer too, so it only bites while the drive is not mounted. Change it in System Settings → Battery/Energy, or with: sudo pmset -a disksleep 0")
}

// MARK: - Spin state (read latency)

enum SpinStateError: Error, CustomStringConvertible {
    case badDevice(String)
    case tooSmall
    case read(String)
    case noTimings(String)

    var description: String {
        switch self {
        case .badDevice(let name):
            return "\(name) is not a disk device name."
        case .tooSmall:
            return "The partition is too small to sample."
        case .read(let text):
            return "The drive did not answer the read. If the enclosure powers itself off when idle it may have cut its own power, in which case unplugging and replugging it is the only way back.\n\n\(text)"
        case .noTimings(let text):
            return "dd did not report a transfer time.\n\n\(text)"
        }
    }
}

/// Times reads of random, far-apart 4 KiB blocks on the raw partition. A parked drive takes
/// seconds to answer the first read (it has to spin up); a spinning one answers in
/// milliseconds. Far-apart offsets keep the drive's own cache from answering instead of the
/// platters, and `/dev/r…` is the unbuffered device, so macOS does not cache them either.
///
/// `dd` reports the time of the transfer itself, so starting sudo and the process is left out
/// of the measurement. All the samples run under one sudo, so it asks for the password once.
///
/// Reading the raw device needs root, and on macOS 13 and later also Full Disk Access for the
/// app. Blocks for as long as a spin-up takes: call it off the main thread.
func measureReadLatency(partition: String, size: Double, samples: Int = 3) -> Result<[Double], SpinStateError> {
    guard partition.range(of: "^disk[0-9]+(s[0-9]+)?$", options: .regularExpression) != nil else {
        return .failure(.badDevice(partition))
    }
    let blocks = UInt64(max(size, 0)) / 4096
    // Start a good way in, past the LUKS header, and stop short of the end.
    let first: UInt64 = 262_144   // 1 GiB
    guard blocks > first + 16 else { return .failure(.tooSmall) }
    let offsets = (0..<samples).map { _ in UInt64.random(in: first..<(blocks - 16)) }
    let script = offsets
        .map { "/bin/dd if=/dev/r\(partition) bs=4096 count=1 iseek=\($0) of=/dev/null || exit 1" }
        .joined(separator: "\n")

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
    process.arguments = ["-A", "/bin/sh", "-c", script]
    var environment = ProcessInfo.processInfo.environment
    environment["SUDO_ASKPASS"] = Askpass.path
    process.environment = environment
    let errors = Pipe()
    process.standardError = errors
    process.standardOutput = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    let text: String
    do {
        try process.run()
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else { return .failure(.read(String(text.suffix(1200)))) }
    } catch {
        return .failure(.read("\(error)"))
    }

    // "4096 bytes transferred in 0.014832 secs (276 bytes/sec)", one line per dd.
    var times: [Double] = []
    let pattern = try! NSRegularExpression(pattern: #"transferred in ([0-9.]+) secs"#)
    for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
        if let range = Range(match.range(at: 1), in: text), let seconds = Double(text[range]) {
            times.append(seconds)
        }
    }
    guard times.count == samples else { return .failure(.noTimings(String(text.suffix(1200)))) }
    return .success(times)
}

/// Plain-language reading of `measureReadLatency` for a single drive.
func describeSpinState(_ times: [Double]) -> String {
    func ms(_ seconds: Double) -> String {
        seconds >= 1 ? String(format: "%.1f s", seconds) : String(format: "%.0f ms", seconds * 1000)
    }
    guard !times.isEmpty else { return "No measurement." }
    let slow = times.filter { $0 > 2.0 }
    let fast = times.filter { $0 <= 0.3 }
    if !slow.isEmpty {
        let after = fast.isEmpty ? "" : ", then reads were back to \(fast.map(ms).joined(separator: ", "))"
        return "The drive was spun down: the first read took \(ms(slow[0])) while it spun up\(after). This check woke it."
    }
    if let firstRead = times.first, firstRead > 0.3 {
        let rest = times.dropFirst().map(ms).joined(separator: ", ")
        return "The drive was idle: the first read took \(ms(firstRead))\(rest.isEmpty ? "" : " (then \(rest))"), slower than normal but too quick for a spin-up."
    }
    return "The drive is spinning: reads took \(times.map(ms).joined(separator: ", "))."
}
