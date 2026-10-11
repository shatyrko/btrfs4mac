import Foundation
import Security

enum Config {
    /// Media name macOS reports for the enclosure (`diskutil info` → "Device / Media Name").
    /// Override with: defaults write local.g-drive diskName "My Drive"
    static var diskName: String { UserDefaults.standard.string(forKey: "diskName") ?? "G-DRIVE" }
    /// Name of the Btrfs volume (its label); anylinuxfs mounts it at /Volumes/<label>.
    /// Override with: defaults write local.g-drive volumeName "mylabel"
    static var mountPoint: String { "/Volumes/" + (UserDefaults.standard.string(forKey: "volumeName") ?? "backup") }
    static let anylinuxfs = "/opt/homebrew/bin/anylinuxfs"
    static let keepAliveInterval: TimeInterval = 20
    static let keepAliveFile = ".g-drive-keepalive"
    static let keychainService = "g-drive.luks"
}

/// sudo asks for the Mac password through this helper, which shows a native dialog.
enum Askpass {
    static var path: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/G-Drive/askpass.sh").path
    }

    static func install() {
        let script = """
        #!/bin/sh
        /usr/bin/osascript -e 'text returned of (display dialog "G-Drive needs your Mac password to read the disk." default answer "" with hidden answer with title "G-Drive" buttons {"Cancel", "OK"} default button "OK" with icon caution)'
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
         kSecAttrAccount as String: Config.diskName]
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

/// True when something is mounted exactly at `Config.mountPoint`.
func isMounted() -> Bool {
    var info = statfs()
    guard statfs(Config.mountPoint, &info) == 0 else { return false }
    let mountedOn = withUnsafePointer(to: &info.f_mntonname) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
    }
    return mountedOn == Config.mountPoint
}

/// Partition the mounted volume was served from, e.g. "disk4s1".
func mountedDevice() -> String? {
    var info = statfs()
    guard statfs(Config.mountPoint, &info) == 0 else { return nil }
    let from = withUnsafePointer(to: &info.f_mntfromname) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
    }
    return from.components(separatedBy: ".local:").first
}

/// Finds the first partition of the external disk called `Config.diskName`.
/// Returns (whole disk, partition), e.g. ("disk4", "disk4s1").
func findDrive() -> (disk: String, partition: String)? {
    let list = runSync("/usr/sbin/diskutil", ["list", "-plist", "external", "physical"])
    guard let data = list.output.data(using: .utf8),
          let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
          let disks = plist["AllDisksAndPartitions"] as? [[String: Any]] else { return nil }
    for disk in disks {
        guard let id = disk["DeviceIdentifier"] as? String else { continue }
        let info = runSync("/usr/sbin/diskutil", ["info", "-plist", id])
        guard let infoData = info.output.data(using: .utf8),
              let fields = try? PropertyListSerialization.propertyList(from: infoData, format: nil) as? [String: Any],
              (fields["MediaName"] as? String) == Config.diskName else { continue }
        let partitions = disk["Partitions"] as? [[String: Any]] ?? []
        if let partition = partitions.first?["DeviceIdentifier"] as? String {
            return (id, partition)
        }
    }
    return nil
}

/// Processes anylinuxfs leaves behind while its VM is up.
func vmProcessesRunning() -> Bool {
    ["anylinuxfs", "vmnet-helper", "gvproxy"].contains { runSync("/usr/bin/pgrep", ["-x", $0]).status == 0 }
}
