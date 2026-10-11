import Foundation

/// Runs a command inside the anylinuxfs VM. `vm exec` only works on a terminal,
/// so it goes through `script`, which also hands back the command's exit status.
func vmExec(_ argv: [String]) -> CommandResult {
    let result = runSync("/usr/bin/script", ["-q", "/dev/null", Config.anylinuxfs, "vm", "exec", "--"] + argv)
    let cleaned = String(result.output.unicodeScalars.filter { $0 != "\r" && $0 != "\u{04}" && $0 != "\u{08}" })
    // script echoes the EOF character it sends as a literal "^D"
    return CommandResult(status: result.status, output: cleaned.hasPrefix("^D") ? String(cleaned.dropFirst(2)) : cleaned)
}

/// The mounted volume as the VM sees it, e.g. /mnt/backup.
var vmMountPoint: String { activeMount?.vmPath ?? "/mnt/backup" }
var snapshotDir: String { vmMountPoint + "/.snapshots" }
private let btrfs = "/sbin/btrfs"

struct BtrfsInfo {
    var errors: Int?
    var scrub: String = "Never run"
    var scrubRunning = false
    var scrubPercent: Double?
    var snapshots: [String] = []
    var subvolumes: [String] = []
    /// Bytes per subvolume, from `btrfs filesystem du`; filled in by the app, which caches it.
    var sizes: [String: Double] = [:]
    var sizesBusy = false
}

func fetchBtrfsInfo() -> BtrfsInfo? {
    // The VM's root file system is read-only, so btrfs cannot record scrub progress and `scrub status` is
    // useless; whether a scrub runs is read from the process list instead.
    let script = "\(btrfs) device stats \(vmMountPoint); echo ===; \(btrfs) subvolume list \(vmMountPoint); echo ===; ps | grep -c '[s]crub start'"
    let result = vmExec(["sh", "-c", script])
    let parts = result.output.components(separatedBy: "===\n")
    guard parts.count == 3 else { return nil }

    var info = BtrfsInfo()
    var total = 0
    var counters = 0
    for line in parts[0].split(separator: "\n") {
        if let last = line.split(separator: " ").last, let n = Int(last) { total += n; counters += 1 }
    }
    if counters > 0 { info.errors = total }

    info.scrubRunning = (Int(parts[2].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) > 0

    // Snapshots are the folders under .snapshots that hold snapshot subvolumes.
    let all = subvolumePaths(parts[1])
    let names = all.compactMap { path -> String? in
        let pieces = path.split(separator: "/")
        return pieces.count >= 3 && pieces[0] == ".snapshots" ? String(pieces[1]) : nil
    }
    info.snapshots = Array(Set(names)).filter { $0.range(of: safeName, options: .regularExpression) != nil }.sorted(by: >)
    info.subvolumes = all.filter { !$0.hasPrefix(".snapshots/") }.sorted()
    return info
}

/// Paths from `btrfs subvolume list` ("ID 256 gen 7 top level 5 path name").
func subvolumePaths(_ listing: String) -> [String] {
    listing.split(separator: "\n").compactMap { line in
        line.range(of: " path ").map { String(line[$0.upperBound...]) }
    }
}

private let safeName = "^[0-9A-Za-z_-]+$"
private let safeSubvolumeName = "^[0-9A-Za-z_][0-9A-Za-z_.-]*$"

/// Snapshots the top level and every subvolume (a snapshot of the top level alone
/// holds only empty folders where subvolumes are) into .snapshots/<time>/.
/// With `only`, snapshots just that subvolume into .snapshots/<time>-<name>/.
func takeSnapshot(only: String? = nil) -> (ok: Bool, name: String, output: String) {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd_HHmmss"
    var name = f.string(from: Date())
    var targets = [(source: String, label: String)]()
    if let only {
        let label = String(only.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" })
        name += "-" + label
        targets = [(vmMountPoint + "/" + only, label)]
    }
    let dir = snapshotDir + "/" + name
    let mk = vmExec(["mkdir", "-p", dir])
    guard mk.status == 0 else { return (false, name, mk.output) }

    if only == nil {
        let list = vmExec([btrfs, "subvolume", "list", vmMountPoint])
        let subvolumes = subvolumePaths(list.output).filter { !$0.hasPrefix(".snapshots/") }
        targets = [(vmMountPoint, "_root")]
        for path in subvolumes {
            targets.append((vmMountPoint + "/" + path, path.replacingOccurrences(of: "/", with: "__")))
        }
    }
    for target in targets {
        let snap = vmExec([btrfs, "subvolume", "snapshot", "-r", target.source, dir + "/" + target.label])
        if snap.status != 0 { return (false, name, snap.output) }
    }
    return (true, name, "")
}

/// Deletes the snapshot subvolumes inside .snapshots/<name>/, then the folder.
func deleteSnapshot(_ name: String) -> CommandResult {
    guard name.range(of: safeName, options: .regularExpression) != nil else {
        return CommandResult(status: 1, output: "bad snapshot name")
    }
    let prefix = ".snapshots/" + name + "/"
    let list = vmExec([btrfs, "subvolume", "list", vmMountPoint])
    for path in subvolumePaths(list.output) where path.hasPrefix(prefix) {
        let result = vmExec([btrfs, "subvolume", "delete", vmMountPoint + "/" + path])
        if result.status != 0 { return result }
    }
    return vmExec(["rmdir", snapshotDir + "/" + name])
}

func createSubvolume(_ name: String) -> CommandResult {
    guard name.range(of: safeSubvolumeName, options: .regularExpression) != nil else {
        return CommandResult(status: 1, output: "Use letters, digits, _ - and . only.")
    }
    return vmExec([btrfs, "subvolume", "create", vmMountPoint + "/" + name])
}

/// Bytes the scrub has to read ("Total to scrub: 501.09GiB" in `btrfs scrub status`).
func scrubTotalBytes() -> Double? {
    let status = vmExec([btrfs, "scrub", "status", vmMountPoint]).output
    guard let line = status.split(separator: "\n").first(where: { $0.contains("Total to scrub") }) else { return nil }
    let value = line.split(separator: " ").last.map(String.init) ?? ""
    guard let match = value.range(of: #"^[0-9.]+"#, options: .regularExpression), let number = Double(value[match]) else { return nil }
    let unit = String(value[match.upperBound...])
    let factors: [String: Double] = ["KiB": 1_024, "MiB": 1_048_576, "GiB": 1_073_741_824,
                                     "TiB": 1_099_511_627_776, "PiB": 1_125_899_906_842_624]
    return number * (factors[unit] ?? 1)
}

/// Runs `btrfs scrub start -B` in the foreground inside the VM and reports how it ended.
final class ScrubRun {
    private var process: Process?
    var isRunning: Bool { process?.isRunning == true }

    func start(done: @escaping (String) -> Void) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        p.arguments = ["-q", "/dev/null", Config.anylinuxfs, "vm", "exec", "--", btrfs, "scrub", "start", "-B", "-d", vmMountPoint]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = environment
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        p.standardInput = FileHandle.nullDevice
        p.terminationHandler = { _ in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(String(decoding: data, as: UTF8.self).unicodeScalars.filter { $0 != "\r" && $0 != "\u{04}" && $0 != "\u{08}" })
            DispatchQueue.main.async { done(Self.summarize(text)) }
        }
        try p.run()
        process = p
    }

    /// "Finished · no errors found · 0:52:10", or "Cancelled".
    static func summarize(_ output: String) -> String {
        func field(_ name: String) -> String? {
            output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix(name + ":") }
                .map { String($0.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces) }
        }
        if output.localizedCaseInsensitiveContains("abort") || output.localizedCaseInsensitiveContains("cancel") {
            return "Cancelled"
        }
        guard let status = field("Status") else { return "Ended without a report" }
        var bits = [status.prefix(1).uppercased() + status.dropFirst()]
        if let errors = field("Error summary") { bits.append(errors) }
        if let duration = field("Duration") { bits.append(duration) }
        return bits.joined(separator: " · ")
    }
}

func cancelScrub() -> CommandResult { vmExec([btrfs, "scrub", "cancel", vmMountPoint]) }

func formatBytes(_ bytes: Double) -> String {
    let units = ["B", "KB", "MB", "GB", "TB", "PB"]
    var value = bytes
    var unit = 0
    while value >= 1000 && unit < units.count - 1 { value /= 1000; unit += 1 }
    return unit < 3 ? String(format: "%.0f %@", value, units[unit]) : String(format: "%.2f %@", value, units[unit])
}

/// Total and free bytes straight from statfs (no VM involved).
func spaceNumbers() -> (size: Double, free: Double)? {
    var info = statfs()
    guard statfs(Config.mountPoint, &info) == 0 else { return nil }
    return (Double(info.f_blocks) * Double(info.f_bsize), Double(info.f_bavail) * Double(info.f_bsize))
}

/// Size in bytes of each subvolume (`btrfs filesystem du -s --raw`, which counts the files it holds).
func fetchSubvolumeSizes(_ paths: [String]) -> [String: Double] {
    guard !paths.isEmpty else { return [:] }
    let script = "for p in \"$@\"; do echo \"@@$p\"; \(btrfs) filesystem du -s --raw \"\(vmMountPoint)/$p\"; done"
    let result = vmExec(["sh", "-c", script, "sh"] + paths)
    var sizes: [String: Double] = [:]
    var current: String?
    for line in result.output.split(separator: "\n") {
        if line.hasPrefix("@@") { current = String(line.dropFirst(2)); continue }
        // the data line is "<total> <exclusive> <shared> <path>"; the header line starts with "Total"
        let fields = line.split(separator: " ")
        if let current, fields.count >= 4, let total = Double(fields[0]) { sizes[current] = total }
    }
    return sizes
}
