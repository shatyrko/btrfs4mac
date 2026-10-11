import Foundation
import Security

/// The app used to be called G-Drive. Carries its settings, saved passphrase and files over, once.
func migrateFromGDrive() {
    let defaults = UserDefaults.standard
    guard !defaults.bool(forKey: "migratedFromGDrive") else { return }
    defer { defaults.set(true, forKey: "migratedFromGDrive") }

    let oldDomain = "local.g-drive"
    if let old = defaults.persistentDomain(forName: oldDomain) {
        for key in ["keepAlive", "lastScrub", "diskName"] where defaults.object(forKey: key) == nil {
            if let value = old[key] { defaults.set(value, forKey: key) }
        }
        defaults.removePersistentDomain(forName: oldDomain)
    }

    // Saved passphrase: moved only if there is one (looking for it does not prompt, reading it may).
    let oldItem: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                  kSecAttrService as String: "g-drive.luks"]
    var attributes: CFTypeRef?
    var lookup = oldItem
    lookup[kSecReturnAttributes as String] = true
    lookup[kSecMatchLimit as String] = kSecMatchLimitOne
    if SecItemCopyMatching(lookup as CFDictionary, &attributes) == errSecSuccess {
        var read = oldItem
        read[kSecReturnData as String] = true
        read[kSecMatchLimit as String] = kSecMatchLimitOne
        var data: CFTypeRef?
        if SecItemCopyMatching(read as CFDictionary, &data) == errSecSuccess, let bytes = data as? Data,
           let passphrase = String(data: bytes, encoding: .utf8) {
            Keychain.save(passphrase)
            SecItemDelete(oldItem as CFDictionary)
        }
    }

    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser
    try? fm.removeItem(at: home.appendingPathComponent("Library/Application Support/G-Drive"))
    let oldLog = home.appendingPathComponent("Library/Logs/G-Drive.log")
    let newLog = home.appendingPathComponent("Library/Logs/btrfs4mac.log")
    if fm.fileExists(atPath: oldLog.path), !fm.fileExists(atPath: newLog.path) { try? fm.moveItem(at: oldLog, to: newLog) }
    if let mount = scanMount() {
        try? fm.removeItem(atPath: mount.point + "/.g-drive-keepalive")
        try? fm.removeItem(atPath: mount.point + "/._.g-drive-keepalive")
    }
    log("migrated settings from G-Drive")
}
