import Foundation
import Security

enum Config {
    /// Pins the app to one drive by the media name macOS reports (see `diskutil info`); without it the first
    /// external drive that holds a filesystem macOS cannot read is used.
    /// Set with: defaults write local.btrfs4mac diskName "My Drive"
    static var pinnedDiskName: String? { UserDefaults.standard.string(forKey: "diskName") }
    /// Where the volume is mounted (read from the system's mount table, so any volume label works).
    static var mountPoint: String { activeMount?.point ?? "/Volumes/backup" }
    static let anylinuxfs = "/opt/homebrew/bin/anylinuxfs"
    static let keepAliveInterval: TimeInterval = 20
    static let keepAliveFile = ".btrfs4mac-keepalive"
    static let keychainService = "btrfs4mac.luks"
    static let keychainAccount = "luks"
}

/// sudo asks for the Mac password through this helper, which shows a native dialog.
enum Askpass {
    static var path: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/btrfs4mac/askpass.sh").path
    }

    static func install() {
        let script = """
        #!/bin/sh
        /usr/bin/osascript -e 'text returned of (display dialog "btrfs4mac needs your Mac password to read the disk." default answer "" with hidden answer with title "btrfs4mac" buttons {"Cancel", "OK"} default button "OK" with icon caution)'
        """
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? script.write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
    }
}

struct CommandResult {
    let status: Int32
    let output: String
}

/// Runs a command off the main thread and hands the result back on it.
func run(_ path: String, _ args: [String], env: [String: String] = [:],
         done: @escaping (CommandResult) -> Void) {
    DispatchQueue.global().async {
        let result = runSync(path, args, env: env)
        DispatchQueue.main.async { done(result) }
    }
}

func runSync(_ path: String, _ args: [String], env: [String: String] = [:]) -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    for (key, value) in env { environment[key] = value }
    process.environment = environment
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    process.standardInput = FileHandle.nullDevice
    do {
        try process.run()
    } catch {
        return CommandResult(status: -1, output: "\(error)")
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
}

enum Keychain {
    private static func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: Config.keychainService,
         kSecAttrAccount as String: Config.keychainAccount]
    }

    static func load() -> String? {
        var q = query()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ passphrase: String) {
        delete()
        var q = query()
        q[kSecValueData as String] = Data(passphrase.utf8)
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete(query() as CFDictionary)
    }
}

/// A volume that anylinuxfs serves over NFS: "disk5s1.local:/mnt/backup" mounted on "/Volumes/backup".
struct ActiveMount {
    let device: String   // disk5s1
    let point: String    // /Volumes/backup
    let vmPath: String   // /mnt/backup, the same volume inside the VM
}

private let mountLock = NSLock()
private var lastMount: ActiveMount?
var activeMount: ActiveMount? {
    mountLock.lock()
    defer { mountLock.unlock() }
    return lastMount
}

/// Looks for an anylinuxfs share in the mount table. Reading the table (unlike `statfs` on the share)
/// never blocks on a dead NFS server.
@discardableResult
func scanMount() -> ActiveMount? {
    var found: ActiveMount?
    let capacity = Int(getfsstat(nil, 0, MNT_NOWAIT))
    if capacity > 0 {
        var table: [statfs] = Array(repeating: statfs(), count: capacity)
        let count = Int(getfsstat(&table, Int32(MemoryLayout<statfs>.stride * capacity), MNT_NOWAIT))
        func text<T>(_ field: T) -> String {
            withUnsafePointer(to: field) {
                $0.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { String(cString: $0) }
            }
        }
        let pattern = try! NSRegularExpression(pattern: #"^(disk[0-9]+s[0-9]+)\.local:(/mnt/.+)$"#)
        for entry in table.prefix(max(count, 0)) where text(entry.f_fstypename) == "nfs" {
            let from = text(entry.f_mntfromname)
            let range = NSRange(from.startIndex..., in: from)
            if let match = pattern.firstMatch(in: from, range: range),
               let device = Range(match.range(at: 1), in: from), let vm = Range(match.range(at: 2), in: from) {
                found = ActiveMount(device: String(from[device]), point: text(entry.f_mntonname), vmPath: String(from[vm]))
                break
            }
        }
    }
    mountLock.lock()
    lastMount = found
    mountLock.unlock()
    if let found {
        let name = (found.vmPath as NSString).lastPathComponent
        if !name.isEmpty && name != volumeName { UserDefaults.standard.set(name, forKey: "volumeName") }
    }
    return found
}

func isMounted() -> Bool { scanMount() != nil }

/// The volume's label as seen at the last mount: the folder name inside the VM, without the "-1", "-2"
/// macOS adds to the folder under /Volumes.
var volumeName: String? { UserDefaults.standard.string(forKey: "volumeName") }

/// Shell that removes leftover mount folders: /Volumes/<name> and /Volumes/<name>-N that are not mounted
/// and hold nothing but Finder's .DS_Store. Finder writes that file into the bare folder when the volume
/// goes away while a window is open on it; the folder is then not empty and stays, so the next mount
/// lands on <name>-1, then <name>-2 and so on. Needs root (/Volumes belongs to root); the name is $1.
let staleMountCleanup = #"""
n="$1"
if [ -n "$n" ]; then
  for d in "/Volumes/$n" "/Volumes/$n"-*; do
    [ -d "$d" ] && [ ! -L "$d" ] || continue
    case "${d#"/Volumes/$n"}" in "") ;; -|-*[!0-9]*) continue ;; -*) ;; *) continue ;; esac
    /sbin/mount | /usr/bin/grep -qF " on $d (" && continue
    [ -z "$(/bin/ls -A "$d" | /usr/bin/grep -vx '.DS_Store')" ] || continue
    /bin/rm -f "$d/.DS_Store" && /bin/rmdir "$d" && echo "removed leftover $d"
  done
fi
"""#

/// Partition the mounted volume was served from, e.g. "disk4s1".
func mountedDevice() -> String? { scanMount()?.device }

struct DriveInfo {
    let disk: String        // disk5
    let partition: String   // disk5s1
    let name: String        // media name of the enclosure, e.g. "G-DRIVE"
    let size: Double
}

/// External drives with a partition that macOS cannot read itself (no volume, no mount point, an unknown
/// partition type such as a raw GUID or "Linux"): the candidates for Btrfs, with or without LUKS.
func findDrives() -> [DriveInfo] {
    let list = runSync("/usr/sbin/diskutil", ["list", "-plist", "external", "physical"])
    guard let data = list.output.data(using: .utf8),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let disks = plist["AllDisksAndPartitions"] as? [[String: Any]] else { return [] }
    var drives: [DriveInfo] = []
    for disk in disks {
        guard let id = disk["DeviceIdentifier"] as? String else { continue }
        for partition in disk["Partitions"] as? [[String: Any]] ?? [] {
            guard let partitionID = partition["DeviceIdentifier"] as? String,
                  partition["MountPoint"] == nil, partition["VolumeName"] == nil || (partition["VolumeName"] as? String) == "",
                  let size = (partition["Size"] as? NSNumber)?.doubleValue, size >= 1_000_000_000,
                  let content = partition["Content"] as? String,
                  content.range(of: "^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$",
                                options: .regularExpression) != nil || content.localizedCaseInsensitiveContains("linux")
            else { continue }
            let info = runSync("/usr/sbin/diskutil", ["info", "-plist", id])
            var name = ""
            if let infoData = info.output.data(using: .utf8),
               let fields = try? PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any] {
                name = (fields["MediaName"] as? String) ?? ""
            }
            drives.append(DriveInfo(disk: id, partition: partitionID, name: name.isEmpty ? "External drive" : name, size: size))
            break
        }
    }
    return drives
}

/// The drive to work with: the pinned one, else the first candidate.
func findDrive() -> DriveInfo? {
    let drives = findDrives()
    if let pinned = Config.pinnedDiskName { return drives.first { $0.name == pinned } }
    return drives.first
}

/// Processes anylinuxfs leaves behind while its VM is up.
/// Names of the Mac programs with a file open under `path` (e.g. Finder, a copy, VeraCrypt), from `lsof`.
/// Plain `lsof` filtered here: `lsof +D` walks the whole volume and takes forever on a big drive.
func appsUsing(_ path: String) -> [String] {
    let result = runSync("/usr/sbin/lsof", ["-n", "-w", "-F", "cn"])
    var names: [String] = []
    var command = ""
    for line in result.output.split(separator: "\n") {
        if line.hasPrefix("c") { command = String(line.dropFirst()) }
        if line.hasPrefix("n"), line.dropFirst().hasPrefix(path), !names.contains(command) { names.append(command) }
    }
    return names
}

/// Why `anylinuxfs mount` failed, from its output, so the user sees a plain sentence instead of the VM log.
enum UnlockFailure {
    case wrongPassphrase
    /// sudo got no Mac password: the dialog was cancelled or the password was wrong.
    case macPassword
    /// Anything else, with the error lines of the log (or its tail).
    case other(String)

    init(output: String) {
        if output.contains("No key available with this passphrase") {
            self = .wrongPassphrase
        } else if output.contains("sudo:") && (output.contains("password") || output.contains("askpass")) {
            self = .macPassword
        } else {
            let errors = output.split(separator: "\n").filter { $0.contains("Error") || $0.contains("error") }
                .map { $0.replacingOccurrences(of: "Linux: ", with: "").replacingOccurrences(of: "macOS: ", with: "") }
            self = .other(errors.isEmpty ? String(output.suffix(800)) : errors.suffix(6).joined(separator: "\n"))
        }
    }
}

func vmProcessesRunning() -> Bool {
    ["anylinuxfs", "vmnet-helper", "gvproxy"].contains { runSync("/usr/bin/pgrep", ["-x", $0]).status == 0 }
}
