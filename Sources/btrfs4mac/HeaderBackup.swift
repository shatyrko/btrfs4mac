import Foundation

/// Bytes at the start of the partition that hold the LUKS header and keyslots,
/// i.e. where the encrypted data begins. nil when the data is not a LUKS header.
func luksHeaderSize(_ data: Data) -> Int? {
    let bytes = [UInt8](data)
    guard bytes.count >= 4096, Array(bytes[0..<6]) == [0x4c, 0x55, 0x4b, 0x53, 0xba, 0xbe] else { return nil }
    let version = Int(bytes[6]) << 8 | Int(bytes[7])

    func bigEndian(_ at: Int, _ count: Int) -> UInt64 {
        bytes[at..<at + count].reduce(0) { $0 << 8 | UInt64($1) }
    }

    if version == 1 {
        // payload-offset, in 512-byte sectors
        return Int(bigEndian(108, 4)) * 512
    }
    guard version == 2 else { return nil }
    let binaryHeader = Int(bigEndian(8, 8))
    guard binaryHeader >= 4096, binaryHeader <= bytes.count else { return nil }
    let jsonArea = Data(bytes[4096..<binaryHeader])
    let end = jsonArea.firstIndex(of: 0) ?? jsonArea.endIndex
    guard let json = try? JSONSerialization.jsonObject(with: jsonArea[jsonArea.startIndex..<end]) as? [String: Any],
          let segments = json["segments"] as? [String: Any],
          let first = segments["0"] as? [String: Any],
          let offset = (first["offset"] as? String).flatMap({ Int($0) }) else { return nil }
    return offset
}

enum HeaderBackupError: Error, CustomStringConvertible {
    case read(String)
    case notLUKS
    case tooLarge(Int)
    case write(String)

    var description: String {
        switch self {
        case .read(let text): return "Could not read the disk:\n\(text)"
        case .notLUKS: return "The start of the partition is not a LUKS header."
        case .tooLarge(let n): return "The header is \(n) bytes, more than the 32 MiB that were read."
        case .write(let text): return "Could not write the file:\n\(text)"
        }
    }
}

/// UUID of the LUKS container (LUKS1 and LUKS2 keep it at offset 168).
func luksUUID(_ data: Data) -> String? {
    let bytes = [UInt8](data)
    guard bytes.count >= 208 else { return nil }
    let field = bytes[168..<208].prefix { $0 != 0 }
    return String(decoding: field, as: UTF8.self)
}

/// Reads the first 32 MiB of /dev/<partition> (needs root, asks via sudo).
func readHeaderArea(partition: String) -> Result<Data, HeaderBackupError> {
    let fm = FileManager.default
    let temp = URL(fileURLWithPath: Askpass.path).deletingLastPathComponent().appendingPathComponent("header.tmp")
    fm.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600])
    defer { try? fm.removeItem(at: temp) }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
    process.arguments = ["-A", "/bin/dd", "if=/dev/r\(partition)", "bs=1048576", "count=32"]
    var environment = ProcessInfo.processInfo.environment
    environment["SUDO_ASKPASS"] = Askpass.path
    process.environment = environment
    let errors = Pipe()
    process.standardError = errors
    process.standardInput = FileHandle.nullDevice
    do {
        let out = try FileHandle(forWritingTo: temp)
        process.standardOutput = out
        try process.run()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        try? out.close()
        guard process.terminationStatus == 0 else {
            return .failure(.read(String(decoding: errorData, as: UTF8.self)))
        }
    } catch {
        return .failure(.read("\(error)"))
    }
    guard let data = try? Data(contentsOf: temp), !data.isEmpty else { return .failure(.read("empty read")) }
    return .success(data)
}

/// Copies the LUKS header of /dev/<partition> to `destination`.
/// Returns the size of the saved file.
func backupLUKSHeader(partition: String, to destination: URL) -> Result<Int, HeaderBackupError> {
    let data: Data
    switch readHeaderArea(partition: partition) {
    case .success(let d): data = d
    case .failure(let e): return .failure(e)
    }
    guard let size = luksHeaderSize(data) else { return .failure(.notLUKS) }
    guard size <= data.count else { return .failure(.tooLarge(size)) }
    do {
        try data.prefix(size).write(to: destination)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    } catch {
        return .failure(.write("\(error.localizedDescription)"))
    }
    return .success(size)
}

enum VerifyResult {
    case matches(size: Int, uuid: String)
    case headerChanged(uuid: String)
    case otherDrive(file: String, drive: String)
    case notAHeader
    case failed(String)
}

/// Compares a saved header file with the header that is on the drive now.
func verifyHeaderBackup(partition: String, file: URL) -> VerifyResult {
    guard let saved = try? Data(contentsOf: file), luksHeaderSize(saved) != nil,
          let savedUUID = luksUUID(saved) else { return .notAHeader }
    switch readHeaderArea(partition: partition) {
    case .failure(let error):
        return .failed("\(error)")
    case .success(let disk):
        let savedSize = saved.count
        guard let driveUUID = luksUUID(disk), disk.count >= savedSize else { return .failed("The drive has no LUKS header.") }
        if savedUUID != driveUUID { return .otherDrive(file: savedUUID, drive: driveUUID) }
        return disk.prefix(savedSize) == saved ? .matches(size: savedSize, uuid: driveUUID)
                                               : .headerChanged(uuid: driveUUID)
    }
}
