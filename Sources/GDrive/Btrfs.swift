import Foundation

/// Runs a command inside the anylinuxfs VM. `vm exec` only works on a terminal,
/// so it goes through `script`, which also hands back the command's exit status.
func vmExec(_ argv: [String]) -> CommandResult {
    let result = runSync("/usr/bin/script", ["-q", "/dev/null", Config.anylinuxfs, "vm", "exec", "--"] + argv)
    let cleaned = String(result.output.unicodeScalars.filter { $0 != "\r" && $0 != "\u{04}" && $0 != "\u{08}" })
    // script echoes the EOF character it sends as a literal "^D"
    return CommandResult(status: result.status, output: cleaned.hasPrefix("^D") ? String(cleaned.dropFirst(2)) : cleaned)
}

let vmMountPoint = "/mnt/" + (Config.mountPoint as NSString).lastPathComponent
let snapshotDir = vmMountPoint + "/.snapshots"
private let btrfs = "/sbin/btrfs"

struct BtrfsInfo {
    var errors: Int?
    var scrub: String = "never run"
    var scrubRunning = false
    var snapshots: [String] = []
    var subvolumes: [String] = []
}

func fetchBtrfsInfo() -> BtrfsInfo? {
    let script = "\(btrfs) device stats \(vmMountPoint); echo ===; \(btrfs) scrub status \(vmMountPoint); echo ===; ls -1 \(snapshotDir) 2>/dev/null; echo ===; \(btrfs) subvolume list \(vmMountPoint)"
    let result = vmExec(["sh", "-c", script])
    let parts = result.output.components(separatedBy: "===\n")
    guard parts.count == 4 else { return nil }

    var info = BtrfsInfo()
    var total = 0
    var counters = 0
    for line in parts[0].split(separator: "\n") {
        if let last = line.split(separator: " ").last, let n = Int(last) { total += n; counters += 1 }
    }
    if counters > 0 { info.errors = total }

    let status = parts[1]
    func field(_ name: String) -> String? {
        status.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { $0.hasPrefix(name + ":") }
            .map { String($0.dropFirst(name.count + 1)).trimmingCharacters(in: .whitespaces) }
    }
    if let state = field("Status") {
        info.scrubRunning = state == "running"
        let summary = field("Error summary") ?? ""
        info.scrub = summary.isEmpty ? state : "\(state), \(summary)"
    }

    info.snapshots = parts[2].split(separator: "\n").map(String.init)
        .filter { $0.range(of: "^[0-9A-Za-z_-]+$", options: .regularExpression) != nil }
        .sorted(by: >)
    info.subvolumes = subvolumePaths(parts[3]).filter { !$0.hasPrefix(".snapshots/") }.sorted()
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
func takeSnapshot() -> (ok: Bool, name: String, output: String) {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd_HHmmss"
    let name = f.string(from: Date())
    let dir = snapshotDir + "/" + name
    let mk = vmExec(["mkdir", "-p", dir])
    guard mk.status == 0 else { return (false, name, mk.output) }

    let list = vmExec([btrfs, "subvolume", "list", vmMountPoint])
    let subvolumes = subvolumePaths(list.output).filter { !$0.hasPrefix(".snapshots/") }
    var targets = [(source: vmMountPoint, label: "_root")]
    for path in subvolumes {
        targets.append((vmMountPoint + "/" + path, path.replacingOccurrences(of: "/", with: "__")))
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

func startScrub() -> CommandResult { vmExec([btrfs, "scrub", "start", vmMountPoint]) }
func cancelScrub() -> CommandResult { vmExec([btrfs, "scrub", "cancel", vmMountPoint]) }

func formatBytes(_ bytes: Double) -> String {
    let units = ["B", "KB", "MB", "GB", "TB", "PB"]
    var value = bytes
    var unit = 0
    while value >= 1000 && unit < units.count - 1 { value /= 1000; unit += 1 }
    return unit < 3 ? String(format: "%.0f %@", value, units[unit]) : String(format: "%.2f %@", value, units[unit])
}

/// Used and free space straight from statfs (no VM involved).
func spaceUsage() -> (used: String, free: String)? {
    var info = statfs()
    guard statfs(Config.mountPoint, &info) == 0 else { return nil }
    let size = Double(info.f_blocks) * Double(info.f_bsize)
    let free = Double(info.f_bavail) * Double(info.f_bsize)
    return ("\(formatBytes(size - free)) used", "\(formatBytes(free)) free of \(formatBytes(size))")
}
