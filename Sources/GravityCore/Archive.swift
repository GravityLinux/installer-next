// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import CInstallerSupport

protocol RandomAccessSource: AnyObject {
    var size: Int64 { get }
    func read(offset: Int64, count: Int) throws -> Data
}
final class LocalSource: RandomAccessSource {
    let file: FileHandle
    let size: Int64
    init(_ url: URL) throws {
        file = try FileHandle(forReadingFrom: url); size = Int64(try file.seekToEnd()); try file.seek(toOffset: 0)
    }
    func read(offset: Int64, count: Int) throws -> Data {
        try require(offset >= 0 && offset <= size - Int64(count), "Read outside archive")
        try file.seek(toOffset: UInt64(offset))
        let data = try file.read(upToCount: count) ?? Data()
        try require(data.count == count, "Truncated archive")
        return data
    }
    deinit { try? file.close() }
}
final class HTTPResult: @unchecked Sendable {
    var data: Data?; var response: URLResponse?; var error: Error?
}
final class HTTPRangeSource: RandomAccessSource {
    let url: URL
    let size: Int64
    let session: URLSession
    let validator: String?
    private var cache: [Int64: Data] = [:]
    private var order: [Int64] = []
    private let blockSize: Int64 = 1_048_576
    static func request(_ request: URLRequest, session: URLSession) throws -> (Data, HTTPURLResponse) {
        let result = HTTPResult(); let semaphore = DispatchSemaphore(value: 0)
        session.dataTask(with: request) { data, response, error in
            result.data = data; result.response = response; result.error = error; semaphore.signal()
        }.resume()
        semaphore.wait()
        if let error = result.error { throw error }
        guard let response = result.response as? HTTPURLResponse else { throw InstallerError("Invalid HTTP response") }
        return (result.data ?? Data(), response)
    }
    init(_ url: URL) throws {
        try require(url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(url.host ?? "")), "Downloads require HTTPS")
        self.url = url
        let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 120
        session = URLSession(configuration: config)
        var request = URLRequest(url: url); request.httpMethod = "HEAD"; request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        let (_, response) = try Self.request(request, session: session)
        guard response.statusCode == 200, let value = response.value(forHTTPHeaderField: "Content-Length"), let size = Int64(value), size > 0 else {
            throw InstallerError("Server must provide archive Content-Length")
        }
        self.size = size; validator = response.value(forHTTPHeaderField: "ETag") ?? response.value(forHTTPHeaderField: "Last-Modified")
    }
    func read(offset: Int64, count: Int) throws -> Data {
        try require(offset >= 0 && count >= 0 && offset <= size - Int64(count), "Read outside HTTP archive")
        if count == 0 { return Data() }
        var result = Data(); var pos = offset
        while result.count < count {
            let block = pos / blockSize
            if cache[block] == nil {
                let start = block * blockSize, length = min(8 * blockSize, size - start)
                var request = URLRequest(url: url)
                request.setValue("bytes=\(start)-\(start + length - 1)", forHTTPHeaderField: "Range")
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                if let validator { request.setValue(validator, forHTTPHeaderField: "If-Range") }
                var fetched: Data?
                for attempt in 0..<5 {
                    do {
                        let (data, response) = try Self.request(request, session: session)
                        try require(response.statusCode == 206, "Archive server does not support byte ranges, or the archive changed")
                        try require(response.value(forHTTPHeaderField: "Content-Range") == "bytes \(start)-\(start + length - 1)/\(size)", "Invalid HTTP Content-Range")
                        try require(data.count == Int(length), "Truncated HTTP range")
                        fetched = data; break
                    } catch {
                        if attempt == 4 { throw error }
                        Thread.sleep(forTimeInterval: Double(attempt + 1))
                    }
                }
                guard let data = fetched else { throw InstallerError("Download failed") }
                for i in stride(from: 0, to: data.count, by: Int(blockSize)) {
                    let key = block + Int64(i) / blockSize
                    cache[key] = data.subdata(in: i..<min(i + Int(blockSize), data.count)); order.append(key)
                    if order.count > 128 { cache.removeValue(forKey: order.removeFirst()) }
                }
            }
            guard let data = cache[block] else { throw InstallerError("Archive cache error") }
            let start = Int(pos % blockSize); let n = min(data.count - start, count - result.count)
            result.append(data.subdata(in: start..<(start + n))); pos += Int64(n)
        }
        return result
    }
    deinit { session.invalidateAndCancel() }
}

struct ZIPEntry: Sendable {
    let name: String
    let method: UInt64
    let crc: UInt32
    let size: Int64
    let compressedSize: Int64
    let offset: Int64
    let mode: UInt64
    var isDirectory: Bool { name.hasSuffix("/") }
    var isSymlink: Bool { mode & 0o170000 == 0o120000 }
}
final class ZIPArchive {
    let source: RandomAccessSource
    private(set) var entries: [ZIPEntry] = []
    private var byName: [String: ZIPEntry] = [:]
    init(_ url: URL) throws {
        source = try url.isFileURL ? LocalSource(url) : HTTPRangeSource(url)
        try readDirectory()
    }
    init(source: RandomAccessSource) throws { self.source = source; try readDirectory() }
    private func readDirectory() throws {
        try require(source.size >= 22, "Invalid ZIP archive")
        let tailSize = Int(min(source.size, 65_557)); let tailOffset = source.size - Int64(tailSize)
        let tail = try source.read(offset: tailOffset, count: tailSize)
        var eocd: Int?
        for i in stride(from: tail.count - 22, through: 0, by: -1) {
            if try tail.uint(i, 4) == 0x06054b50, i + 22 + Int(try tail.uint(i + 20, 2)) == tail.count { eocd = i; break }
        }
        guard let end = eocd else { throw InstallerError("Missing ZIP central directory") }
        try require(try tail.uint(end + 4, 2) == 0 && tail.uint(end + 6, 2) == 0, "Multi-disk ZIP is unsupported")
        var count = try tail.uint(end + 10, 2), directorySize = try tail.uint(end + 12, 4), offset = try tail.uint(end + 16, 4)
        if count == 0xffff || directorySize == 0xffffffff || offset == 0xffffffff {
            let locator = try source.read(offset: tailOffset + Int64(end) - 20, count: 20)
            try require(try locator.uint(0, 4) == 0x07064b50 && locator.uint(4, 4) == 0 && locator.uint(16, 4) == 1, "Invalid ZIP64 locator")
            let recordOffset = try locator.uint(8, 8)
            try require(recordOffset <= UInt64(Int64.max), "Invalid ZIP64 offset")
            let record = try source.read(offset: Int64(recordOffset), count: 56)
            try require(try record.uint(0, 4) == 0x06064b50 && record.uint(16, 4) == 0 && record.uint(20, 4) == 0, "Invalid ZIP64 directory")
            count = try record.uint(32, 8); directorySize = try record.uint(40, 8); offset = try record.uint(48, 8)
        }
        try require(count <= 1_000_000 && directorySize <= 256_000_000 && offset <= UInt64(source.size) && directorySize <= UInt64(source.size) - offset, "Invalid ZIP directory bounds")
        let data = try source.read(offset: Int64(offset), count: Int(directorySize)); var pos = 0
        for _ in 0..<count {
            try require(try data.uint(pos, 4) == 0x02014b50, "Invalid ZIP entry")
            let flags = try data.uint(pos + 8, 2); let method = try data.uint(pos + 10, 2)
            try require(flags & 1 == 0 && [0, 8].contains(method), "Encrypted or unsupported ZIP entry")
            let crc = UInt32(try data.uint(pos + 16, 4))
            var packed = try data.uint(pos + 20, 4), size = try data.uint(pos + 24, 4), offset = try data.uint(pos + 42, 4)
            let nameSize = Int(try data.uint(pos + 28, 2)), extraSize = Int(try data.uint(pos + 30, 2)), commentSize = Int(try data.uint(pos + 32, 2))
            let nameData = try data.part(pos + 46, nameSize)
            guard let name = String(data: nameData, encoding: .utf8) else { throw InstallerError("Invalid ZIP filename") }
            let extra = try data.part(pos + 46 + nameSize, extraSize); var x = 0
            while x < extra.count {
                let type = try extra.uint(x, 2), length = Int(try extra.uint(x + 2, 2)); let field = try extra.part(x + 4, length)
                if type == 1 {
                    var z = 0
                    if size == 0xffffffff { size = try field.uint(z, 8); z += 8 }
                    if packed == 0xffffffff { packed = try field.uint(z, 8); z += 8 }
                    if offset == 0xffffffff { offset = try field.uint(z, 8) }
                }
                x += length + 4
            }
            try require(size <= UInt64(Int64.max) && packed <= UInt64(source.size) && offset <= UInt64(source.size), "Invalid ZIP member size")
            try require(byName[name] == nil, "Duplicate ZIP filename: \(name)")
            let entry = ZIPEntry(name: name, method: method, crc: crc, size: Int64(size), compressedSize: Int64(packed), offset: Int64(offset), mode: try data.uint(pos + 38, 4) >> 16)
            byName[name] = entry; entries.append(entry); pos += 46 + nameSize + extraSize + commentSize
        }
    }
    func entry(_ name: String) throws -> ZIPEntry {
        guard let e = byName[name] else { throw InstallerError("Missing archive member: \(name)") }; return e
    }
    func data(_ name: String, limit: Int64 = 256_000_000) throws -> Data {
        let entry = try entry(name); try require(entry.size <= limit, "Archive member exceeds memory limit")
        var result = Data(); try stream(entry) { result.append($0) }; return result
    }
    func stream(_ entry: ZIPEntry, progress: ((Double) -> Void)? = nil, consume: (Data) throws -> Void) throws {
        let header = try source.read(offset: entry.offset, count: 30)
        try require(try header.uint(0, 4) == 0x04034b50, "Invalid ZIP local header")
        let start = entry.offset + 30 + Int64(try header.uint(26, 2)) + Int64(try header.uint(28, 2))
        try require(start <= source.size - entry.compressedSize, "ZIP member outside archive")
        let state = entry.method == 8 ? gravity_inflate_create() : nil
        if entry.method == 8 { try require(state != nil, "Could not initialize ZIP decoder") }
        defer { gravity_inflate_destroy(state) }
        var read: Int64 = 0, written: Int64 = 0; var crc: UInt32 = 0; var ended = entry.method == 0
        func output(_ bytes: Data) throws {
            try require(written <= entry.size - Int64(bytes.count), "ZIP member exceeds declared size")
            crc = bytes.withUnsafeBytes { gravity_crc32(crc, $0.bindMemory(to: UInt8.self).baseAddress, bytes.count) }
            try consume(bytes); written += Int64(bytes.count)
            progress?(entry.size == 0 ? 1 : Double(written) / Double(entry.size))
        }
        while read < entry.compressedSize {
            let chunk = try source.read(offset: start + read, count: Int(min(1_048_576, entry.compressedSize - read)))
            read += Int64(chunk.count)
            if entry.method == 0 { try output(chunk); continue }
            var pos = 0
            repeat {
                var used = chunk.count - pos; var produced = 1_048_576; var buffer = Data(count: produced)
                let result = chunk.withUnsafeBytes { input in
                    buffer.withUnsafeMutableBytes { out in
                        gravity_inflate(state, input.bindMemory(to: UInt8.self).baseAddress!.advanced(by: pos), &used, out.bindMemory(to: UInt8.self).baseAddress!, &produced)
                    }
                }
                try require(result == 0 || result == 1, "Invalid ZIP deflate stream")
                try require(used > 0 || produced > 0 || result == 1, "ZIP decoder made no progress")
                pos += used; buffer.count = produced; try output(buffer)
                if result == 1 { ended = true; break }
                if pos == chunk.count && produced < 1_048_576 { break }
            } while true
            if ended { try require(read == entry.compressedSize && pos == chunk.count, "Trailing ZIP deflate data"); break }
        }
        try require(ended && written == entry.size && crc == entry.crc, "ZIP member size or CRC mismatch: \(entry.name)")
    }
    func extract(_ name: String, to destination: URL, progress: ((Double) -> Void)? = nil) throws {
        let entry = try entry(name); try mkdir(destination.deletingLastPathComponent())
        fm.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination); defer { try? handle.close() }
        try stream(entry, progress: progress) { try handle.write(contentsOf: $0) }
    }
    func extractTree(_ prefix: String, to destination: URL) throws {
        let prefix = prefix.hasSuffix("/") ? prefix : prefix + "/"
        try mkdir(destination)
        for entry in entries where entry.name.hasPrefix(prefix) {
            let relative = String(entry.name.dropFirst(prefix.count))
            if relative.isEmpty { continue }
            try require(!relative.hasPrefix("/") && !relative.split(separator: "/").contains(".."), "Unsafe ZIP path")
            let target = destination.appending(relative)
            try mkdir(target.deletingLastPathComponent())
            try require(target.deletingLastPathComponent().resolvingSymlinksInPath().path.hasPrefix(destination.resolvingSymlinksInPath().path + "/") || target.deletingLastPathComponent().resolvingSymlinksInPath() == destination.resolvingSymlinksInPath(), "ZIP path escapes destination")
            if entry.isDirectory { try mkdir(target) }
            else if entry.isSymlink {
                let link = String(decoding: try data(entry.name, limit: 4096), as: UTF8.self)
                let resolved = target.deletingLastPathComponent().appending(link).standardizedFileURL
                try require(!link.hasPrefix("/") && resolved.path.hasPrefix(destination.standardizedFileURL.path + "/"), "Unsafe ZIP symlink")
                try fm.createSymbolicLink(atPath: target.path, withDestinationPath: link)
            } else { try extract(entry.name, to: target) }
        }
    }
}
