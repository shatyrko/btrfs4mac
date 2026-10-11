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
}

func fetchBtrfsInfo() -> BtrfsInfo? {
    let script = "\(btrfs) device stats \(vmMountPoint); echo ===; \(btrfs) scrub status \(vmMountPoint); echo ===; ls -1 \(snapshotDir) 2>/dev/null"
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
    return info
}

func takeSnapshot() -> (ok: Bool, name: String, output: String) {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd_HHmmss"
    let name = f.string(from: Date())
    let mk = vmExec(["mkdir", "-p", snapshotDir])
    guard mk.status == 0 else { return (false, name, mk.output) }
    let snap = vmExec([btrfs, "subvolume", "snapshot", "-r", vmMountPoint, snapshotDir + "/" + name])
    return (snap.status == 0, name, snap.output)
}

func deleteSnapshot(_ name: String) -> CommandResult {
    guard name.range(of: "^[0-9A-Za-z_-]+$", options: .regularExpression) != nil else {
        return CommandResult(status: 1, output: "bad snapshot name")
    }
    return vmExec([btrfs, "subvolume", "delete", snapshotDir + "/" + name])
}

func startScrub() -> CommandResult { vmExec([btrfs, "scrub", "start", vmMountPoint]) }
func cancelScrub() -> CommandResult { vmExec([btrfs, "scrub", "cancel", vmMountPoint]) }

/// "21.9 TB free of 22.0 TB", straight from statfs (no VM involved).
func spaceSummary() -> String? {
    var info = statfs()
    guard statfs(Config.mountPoint, &info) == 0 else { return nil }
    let size = Double(info.f_blocks) * Double(info.f_bsize)
    let free = Double(info.f_bavail) * Double(info.f_bsize)
    func tb(_ v: Double) -> String { String(format: "%.2f TB", v / 1e12) }
    return "\(tb(free)) free of \(tb(size))"
}
