// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import CryptoKit
import CInstallerSupport

public struct InstallerError: LocalizedError, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw InstallerError(message) }
}
let fm = FileManager.default
extension URL {
    func appending(_ path: String) -> URL { appendingPathComponent(path) }
}
func mkdir(_ url: URL) throws { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
func write(_ data: Data, to url: URL) throws { try mkdir(url.deletingLastPathComponent()); try data.write(to: url, options: .atomic) }
func copy(_ from: URL, _ to: URL) throws {
    try mkdir(to.deletingLastPathComponent())
    if fm.fileExists(atPath: to.path) { try fm.removeItem(at: to) }
    try fm.copyItem(at: from, to: to)
}
func plist(_ data: Data) throws -> [String: Any] {
    guard let value = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
        throw InstallerError("Expected a property list dictionary")
    }
    return value
}
func plist(_ url: URL) throws -> [String: Any] { try plist(Data(contentsOf: url)) }
func writePlist(_ value: [String: Any], _ url: URL) throws {
    try write(PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0), to: url)
}
func jsonData(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) }
func int(_ value: Any?) -> Int64 { (value as? NSNumber)?.int64Value ?? 0 }
func string(_ value: Any?) -> String { value as? String ?? "" }
func dict(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }
func array(_ value: Any?) -> [[String: Any]] { value as? [[String: Any]] ?? [] }
func alignUp(_ n: Int64, _ a: Int64 = 1_048_576) -> Int64 { (n + a - 1) & ~(a - 1) }
func alignDown(_ n: Int64, _ a: Int64 = 1_048_576) -> Int64 { n & ~(a - 1) }
public func parseSize(_ input: String) throws -> Int64 {
    let s = input.uppercased().replacingOccurrences(of: " ", with: "")
    for (suffix, factor) in [("TIB", 1_099_511_627_776.0), ("GIB", 1_073_741_824.0), ("MIB", 1_048_576.0), ("KIB", 1024.0), ("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("KB", 1e3), ("B", 1.0), ("", 1.0)] {
        if s.hasSuffix(suffix), let n = Double(s.dropLast(suffix.count)), n.isFinite, n >= 0, n * factor < Double(Int64.max) { return Int64(n * factor) }
    }
    throw InstallerError("Invalid size: \(input)")
}
public func sizeText(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .decimal) }
func versionAtLeast(_ version: String, _ minimum: String) -> Bool {
    version.compare(minimum, options: .numeric) != .orderedAscending
}
extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
    var sha256: String { Data(SHA256.hash(data: self)).hex }
    var crc32: UInt32 { withUnsafeBytes { gravity_crc32(0, $0.bindMemory(to: UInt8.self).baseAddress, count) } }
    func uint(_ offset: Int, _ bytes: Int, big: Bool = false) throws -> UInt64 {
        try require(offset >= 0 && bytes > 0 && bytes <= 8 && offset <= count - bytes, "Truncated binary data")
        var n: UInt64 = 0
        for i in 0..<bytes { n |= UInt64(self[startIndex + offset + i]) << ((big ? bytes - 1 - i : i) * 8) }
        return n
    }
    func part(_ offset: Int, _ count: Int) throws -> Data {
        try require(offset >= 0 && count >= 0 && offset <= self.count - count, "Truncated binary data")
        return subdata(in: offset..<(offset + count))
    }
    mutating func appendLE(_ n: UInt64, bytes: Int = 4) { for i in 0..<bytes { append(UInt8(truncatingIfNeeded: n >> (8*i))) } }
    mutating func pad(to alignment: Int) { append(Data(count: (alignment - count % alignment) % alignment)) }
}
func checksums(_ url: URL) throws -> (sha256: String, crc: UInt32, size: Int64) {
    let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
    try require(descriptor >= 0, "Could not open \(url.lastPathComponent) for checksum verification (errno \(errno))")
    defer { close(descriptor) }
    var hash = SHA256(); var crc: UInt32 = 0; var size: Int64 = 0
    var buffer = Data(count: 1_048_576)
    while true {
        let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
        if count < 0 && errno == EINTR { continue }
        try require(count >= 0, "Could not read \(url.lastPathComponent) for checksum verification (errno \(errno))")
        if count == 0 { break }
        let data = buffer.prefix(count)
        hash.update(data: data); crc = data.withUnsafeBytes { gravity_crc32(crc, $0.bindMemory(to: UInt8.self).baseAddress, data.count) }; size += Int64(data.count)
    }
    return (Data(hash.finalize()).hex, crc, size)
}

/// Commands are argument arrays, never shell text. Credential arguments are not logged.
public protocol CommandRunning: Sendable {
    func run(_ executable: String, _ arguments: [String], input: Data?) throws -> Data
    func authenticated(_ executable: String, _ arguments: [String], credentials: Credentials) throws
}
public extension CommandRunning {
    func authenticated(_ executable: String, _ arguments: [String], credentials: Credentials) throws {
        _ = try run(executable, arguments, input: Data((credentials.username + "\n" + credentials.password + "\n").utf8))
    }
}
public struct SystemCommands: CommandRunning {
    public init() {}
    public func run(_ executable: String, _ arguments: [String], input: Data? = nil) throws -> Data {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        // File output avoids pipe deadlocks on large ioreg/diskutil output.
        let temp = try TemporaryDirectory(prefix: "gravity-command")
        let out = temp.url.appending("stdout"); let err = temp.url.appending("stderr")
        fm.createFile(atPath: out.path, contents: nil); fm.createFile(atPath: err.path, contents: nil)
        let stdout = try FileHandle(forWritingTo: out), stderr = try FileHandle(forWritingTo: err)
        defer { try? stdout.close(); try? stderr.close() }
        process.standardOutput = stdout; process.standardError = stderr
        if let input {
            let stdin = Pipe(); process.standardInput = stdin
            try process.run()
            try stdin.fileHandleForWriting.write(contentsOf: input)
            try stdin.fileHandleForWriting.close()
            process.waitUntilExit()
        } else {
            process.standardInput = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
        }
        let data = try Data(contentsOf: out)
        if process.terminationStatus != 0 {
            let detail = String(decoding: (try Data(contentsOf: err)) + data.prefix(131072), as: UTF8.self)
            throw InstallerError("\(URL(fileURLWithPath: executable).lastPathComponent) failed (\(process.terminationStatus)). \(detail)")
        }
        return data
    }
}
final class TemporaryDirectory {
    let url: URL
    init(prefix: String = "gravity") throws {
        url = fm.temporaryDirectory.appending("\(prefix)-\(UUID().uuidString)")
        try fm.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    }
    deinit { try? fm.removeItem(at: url) }
}

extension SystemCommands {
    /// fork/exec under a controlling PTY. Passwords are sent only while ECHO is off.
    /// bputil/kmutil confirmations are answered from their text prompts.
    public func authenticated(_ executable: String, _ arguments: [String], credentials: Credentials) throws {
        try require(!credentials.username.contains("\n") && !credentials.password.contains("\n") && !credentials.password.contains("\0"), "Invalid administrator credentials")
        var strings = ([executable] + arguments).map { strdup($0) }; strings.append(nil)
        defer { for pointer in strings { free(pointer) } }
        var fd: Int32 = -1
        let pid = strings.withUnsafeMutableBufferPointer { argv in executable.withCString { gravity_spawn_pty($0, argv.baseAddress, &fd) } }
        try require(pid > 0 && fd >= 0, "Could not create an authentication terminal")
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var pending = "", answers = 0, passwords = 0
        var passwordSent = false
        var reaped = false
        var lastActivity = Date()
        do {
            while true {
                let readable = gravity_poll_readable(fd, 100)
                try require(readable >= 0, "Authentication terminal failed")
                if readable > 0 {
                    let data = handle.availableData
                    if data.isEmpty { break }
                    pending += String(decoding: data, as: UTF8.self).lowercased()
                    lastActivity = Date()
                }
                try require(Date().timeIntervalSince(lastActivity) < 120, "Apple authentication timed out")
                if pending.count > 8192 { pending = String(pending.suffix(8192)) }
                let prompt = pending.components(separatedBy: .newlines).last ?? ""
                var response: String?
                let echo = gravity_terminal_echo(fd)
                if echo == 1 { passwordSent = false }
                if echo == 0 && !passwordSent {
                    passwords += 1; try require(passwords <= 3, "Apple rejected the administrator password")
                    response = credentials.password; passwordSent = true
                } else if echo == 1 {
                    if prompt.range(of: #"(\([yn]/[yn]\)|\[[yn]/[yn]\]|\byes/no\b|type ['\"]?y['\"]? to|enter ['\"]?y['\"]? to)"#, options: .regularExpression) != nil {
                        response = "y"
                    } else if prompt.range(of: #"(user ?name|user)[^\r\n]*[:?]\s*$"#, options: .regularExpression) != nil { response = credentials.username }
                }
                if let response {
                    answers += 1; try require(answers <= 12, "Apple authentication failed; check your macOS administrator login")
                    try handle.write(contentsOf: Data((response + "\n").utf8)); pending = ""
                    lastActivity = Date()
                }
            }
            let result = gravity_wait_pty(pid)
            reaped = true
            try require(result == 0, "\(URL(fileURLWithPath: executable).lastPathComponent) authentication or boot registration failed (\(result))")
        } catch {
            if !reaped { kill(pid, SIGTERM); _ = gravity_wait_pty(pid) }
            throw error
        }
    }
}
