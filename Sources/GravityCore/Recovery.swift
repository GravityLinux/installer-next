// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Compression
import CInstallerSupport

final class MountedRecovery {
    let temporary: TemporaryDirectory
    let commands: CommandRunning
    var url: URL { temporary.url }
    init(image: URL, commands: CommandRunning) throws {
        self.commands = commands; temporary = try TemporaryDirectory(prefix: "gravity-mount")
        _ = try commands.run("/usr/bin/hdiutil", ["attach", "-readonly", "-nobrowse", "-mountpoint", url.path, image.path], input: nil)
    }
    func detach() throws {
        if !detached { _ = try commands.run("/usr/bin/hdiutil", ["detach", url.path], input: nil); detached = true }
    }
    private var detached = false
    deinit { if !detached { _ = try? commands.run("/usr/bin/hdiutil", ["detach", url.path], input: nil) } }
}
final class RecoveryImage {
    let temporary: TemporaryDirectory
    let url: URL
    let crc: UInt32
    let size: Int64
    init(archive: ZIPArchive, member: String, profile: RestoreProfile, commands: CommandRunning,
         validateFirmware: (URL) throws -> Void, events: @escaping EventSink) throws {
        try require(member == profile.member, "Unqualified recovery image: \(profile.version): \(member)")
        let free = try fm.attributesOfFileSystem(forPath: fm.temporaryDirectory.path)
        let required: Int64
        switch profile.encoding { case .aea: required = 4 * 1024 * 1024 * 1024; case .dmg: required = 2 * 1024 * 1024 * 1024 }
        try require(int(free[.systemFreeSize]) >= required, "Need at least \(sizeText(required)) of temporary free space to validate recovery")
        temporary = try TemporaryDirectory(prefix: "gravity-recovery"); url = temporary.url.appending("BaseSystem.dmg")
        events(InstallEvent(.validateRecovery))
        switch profile.encoding {
        case let .aea(encryptedSHA256, releaseKey):
            let encrypted = temporary.url.appending("BaseSystem.dmg.aea"), key = temporary.url.appending("aea.key")
            try archive.extract(member, to: encrypted) { events(InstallEvent(.validateRecovery, fraction: $0)) }
            try require(try checksums(encrypted).sha256 == encryptedSHA256, "AEA recovery SHA-256 mismatch")
            try write(Data(releaseKey.utf8), to: key); try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: key.path)
            events(InstallEvent(.decodeRecovery))
            _ = try commands.run("/usr/bin/aea", ["decrypt", "-i", encrypted.path, "-o", url.path, "-key", key.path], input: nil)
            try fm.removeItem(at: encrypted); try fm.removeItem(at: key)
        case .dmg:
            try archive.extract(member, to: url) { events(InstallEvent(.validateRecovery, fraction: $0)) }
        }
        events(InstallEvent(.verifyRecovery))
        let sums = try checksums(url); crc = sums.crc; size = sums.size
        try require(sums.sha256 == profile.decodedSHA256, "Decoded recovery DMG SHA-256 mismatch")
        _ = try commands.run("/usr/bin/hdiutil", ["verify", url.path], input: nil)
        let mount = try MountedRecovery(image: url, commands: commands)
        let sysver = try plist(mount.url.appending("System/Library/CoreServices/SystemVersion.plist"))
        try require(string(sysver["ProductVersion"]) == profile.version, "Unexpected recovery version")
        try validateFirmware(mount.url)
        try mount.detach()
    }
}

enum APFSCompression {
    private static func operation<T>(_ name: String, _ action: () throws -> T) throws -> T {
        do { return try action() }
        catch { throw InstallerError("APFS recovery compression, \(name): \(error)") }
    }
    static func compress(source: URL, destination: URL, crc: UInt32, events: @escaping EventSink) throws {
        let input = try FileHandle(forReadingFrom: source); defer { try? input.close() }
        let size = Int64(try input.seekToEnd()); try input.seek(toOffset: 0)
        try require(size > 0, "Empty recovery image")
        try mkdir(destination.deletingLastPathComponent()); fm.createFile(atPath: destination.path, contents: nil)
        let chunks = (size + 65535) / 65536; var position = UInt64((chunks + 1) * 4); var offsets: [UInt64] = []
        let fd = open(destination.path + "/..namedfork/rsrc", O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        try require(fd >= 0, "Could not create the recovery resource fork (errno \(errno))")
        let resource = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? resource.close() }
        try operation("writing the resource fork header") { try resource.write(contentsOf: Data(count: Int(position))) }
        var scratch = Data(count: compression_encode_scratch_buffer_size(COMPRESSION_LZFSE))
        for i in 0..<chunks {
            let data = try input.read(upToCount: 65536) ?? Data(); try require(!data.isEmpty, "Truncated recovery image")
            var compressed = Data(count: 131072)
            let n = scratch.withUnsafeMutableBytes { workspace in
                compressed.withUnsafeMutableBytes { output in data.withUnsafeBytes { input in
                    compression_encode_buffer(output.bindMemory(to: UInt8.self).baseAddress!, 131072, input.bindMemory(to: UInt8.self).baseAddress!, data.count, workspace.baseAddress, COMPRESSION_LZFSE)
                } }
            }
            try require(n > 0 && position + UInt64(n) <= UInt32.max, "Recovery resource fork compression failed")
            offsets.append(position); compressed.count = n
            try operation("writing compressed chunk \(i)") { try resource.write(contentsOf: compressed) }
            position += UInt64(n)
            events(InstallEvent(.compressRecovery, fraction: Double(i + 1) / Double(chunks)))
        }
        offsets.append(position)
        try operation("seeking to the resource fork table") { try resource.seek(toOffset: 0) }
        var table = Data(); for offset in offsets { table.appendLE(offset) }
        try operation("writing the resource fork table") { try resource.write(contentsOf: table) }
        try operation("synchronizing the resource fork") { try resource.synchronize() }
        try operation("closing the resource fork") { try resource.close() }
        let result = destination.path.withCString { gravity_set_compressed($0, UInt64(size)) }
        try require(result == 0, "Could not enable APFS compression (\(result))")
        try operation("verifying compressed readback") { try require(try checksums(destination).crc == crc, "Compressed recovery readback CRC mismatch") }
    }
}

public enum BootObject {
    public static func build(_ data: Data, variables: [String], alignment: Int = 65536) throws -> Data {
        try require(variables.allSatisfy { $0.canBeConverted(to: .ascii) && !$0.contains("\n") && !$0.contains("\0") }, "Invalid m1n1 variables")
        var result = data + Data((variables.map { $0 + "\n" }.joined()).utf8) + Data(count: 4)
        try require(alignment > 0 && alignment <= 16 * 1024 * 1024 && alignment & (alignment - 1) == 0, "Invalid boot object alignment")
        result.pad(to: alignment); return result
    }
    public static func variables(_ data: Data) throws -> [String] {
        guard let marker = data.range(of: Data("STACKBOT".utf8)), let end = data[marker.upperBound...].firstIndex(of: 0), let text = String(data: data.subdata(in: marker.upperBound..<end), encoding: .ascii) else {
            throw InstallerError("Could not read the installed m1n1 variables")
        }
        return text.components(separatedBy: "\n").filter { !$0.isEmpty }
    }
}
