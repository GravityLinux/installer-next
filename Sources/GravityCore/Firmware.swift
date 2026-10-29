// SPDX-License-Identifier: GPL-2.0-only
// Port of the Gravity/Asahi firmware collectors. See LICENSE for attribution.
import Foundation
import Compression

struct DERNode {
    let tag: UInt8
    let data: Data
    var text: String { String(decoding: data, as: UTF8.self) }
    func integer() throws -> UInt64 {
        try require(tag == 2 && !data.isEmpty && data.count <= 8 && data[0] & 0x80 == 0, "Invalid DER integer")
        var result: UInt64 = 0; for byte in data { result = result << 8 | UInt64(byte) }; return result
    }
    func children() throws -> [DERNode] { try DERNode.parse(data) }
    static func parse(_ data: Data) throws -> [DERNode] {
        var result: [DERNode] = []; var pos = 0
        while pos < data.count {
            let tag = data[pos]; pos += 1
            try require(tag & 0x1f != 0x1f && pos < data.count, "Invalid DER tag")
            var length = Int(data[pos]); pos += 1
            if length & 0x80 != 0 {
                let bytes = length & 0x7f
                try require(bytes > 0 && bytes <= 4, "Invalid DER length")
                length = Int(try data.uint(pos, bytes, big: true)); pos += bytes
                try require(length >= 128, "Noncanonical DER length")
            }
            let value = try data.part(pos, length); pos += length; result.append(DERNode(tag: tag, data: value))
        }
        return result
    }
    static func sequence(_ data: Data) throws -> [DERNode] {
        let nodes = try parse(data); try require(nodes.count == 1 && nodes[0].tag == 0x30, "Expected one DER sequence")
        return try nodes[0].children()
    }
}
struct IM4P {
    static func extract(_ data: Data) throws -> (name: String, data: Data) {
        let nodes = try DERNode.sequence(data)
        try require(nodes.count >= 4 && nodes[0].tag == 0x16 && nodes[0].text == "IM4P" && nodes[1].tag == 0x16 && nodes[2].tag == 0x16 && nodes[3].tag == 4, "Invalid IM4P")
        if nodes.count == 4 { return (nodes[1].text, nodes[3].data) }
        try require(nodes[4].tag == 0x30, "Invalid IM4P compression metadata")
        let compression = try nodes[4].children()
        try require(compression.count == 2 && compression[0].integer() == 1, "Unsupported IM4P compression")
        let size = try compression[1].integer(); try require(size > 0 && size <= 1_073_741_824, "Invalid IM4P decompressed size")
        var decoded = Data(count: Int(size))
        let count = decoded.withUnsafeMutableBytes { dest in
            nodes[3].data.withUnsafeBytes { source in
                compression_decode_buffer(dest.bindMemory(to: UInt8.self).baseAddress!, Int(size), source.bindMemory(to: UInt8.self).baseAddress!, nodes[3].data.count, nil, COMPRESSION_LZFSE)
            }
        }
        try require(count == size, "LZFSE IM4P decompression failed")
        return (nodes[1].text, decoded)
    }
}

public struct FirmwareFile: Sendable {
    public let name: String
    public let data: Data
    public let includeInBootloader: Bool
    public init(name: String, data: Data, includeInBootloader: Bool = false) {
        self.name = name; self.data = data; self.includeInBootloader = includeInBootloader
    }
}
/// Byte-compatible newc and USTAR firmware outputs, including deduplicated links.
public final class FirmwarePackage {
    public let root: URL
    private let tar: FileHandle, cpio: FileHandle
    private var hashes: [String: String] = [:], manifest: [String] = []
    private var inode: UInt64 = 1
    private var directories = Set<String>()
    private var inodeMap: [String: (inode: UInt64, links: [UInt64])] = [:]
    private var closed = false
    public init(_ root: URL) throws {
        self.root = root; try mkdir(root)
        fm.createFile(atPath: root.appending("firmware.tar").path, contents: nil)
        fm.createFile(atPath: root.appending("firmware.cpio").path, contents: nil)
        tar = try FileHandle(forWritingTo: root.appending("firmware.tar")); cpio = try FileHandle(forWritingTo: root.appending("firmware.cpio"))
    }
    public func add(_ files: [FirmwareFile]) throws { for file in files { try add(file) } }
    public func add(_ file: FirmwareFile) throws {
        try require(!closed && !file.name.hasPrefix("/") && !file.name.split(separator: "/").contains(".."), "Invalid firmware path")
        let hash = file.data.sha256; let link = hashes[hash]
        manifest.append(link.map { "LINK \(file.name) \($0)" } ?? "FILE \(file.name) SHA256 \(hash)")
        try tarEntry(name: file.name, data: link == nil ? file.data : Data(), link: link)
        try cpioEntry(name: "vendorfw/" + file.name, data: link == nil ? file.data : Data(), mode: 0o100644, target: link.map { "vendorfw/" + $0 })
        if link == nil { hashes[hash] = file.name }
        if file.includeInBootloader {
            try write(file.data, to: root.appending("u-boot/" + file.name))
        }
    }
    private func tarEntry(name: String, data: Data, link: String?) throws {
        var header = Data(count: 512)
        func put(_ text: String, _ offset: Int, _ width: Int) throws {
            let bytes = Data(text.utf8); try require(bytes.count <= width, "USTAR field too long")
            header.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        }
        if name.utf8.count > 100, let split = name.lastIndex(of: "/") {
            try put(String(name[..<split]), 345, 155); try put(String(name[name.index(after: split)...]), 0, 100)
        } else { try put(name, 0, 100) }
        try put("0000644\0", 100, 8); try put("0000000\0", 108, 8); try put("0000000\0", 116, 8)
        try put(String(format: "%011llo", UInt64(data.count)) + "\0", 124, 12); try put("00000000000\0", 136, 12)
        try put("        ", 148, 8); header[156] = link == nil ? 48 : 49
        if let link { try put(link, 157, 100) }
        try put("ustar\0", 257, 6); try put("00", 263, 2)
        let checksum = header.reduce(0) { $0 + Int($1) }; try put(String(format: "%06o", checksum) + "\0 ", 148, 8)
        try tar.write(contentsOf: header); var body = data; body.pad(to: 512); try tar.write(contentsOf: body)
    }
    private func cpioEntry(name: String, data: Data, mode: UInt64, target: String? = nil) throws {
        var path = ""
        for component in name.split(separator: "/").dropLast() {
            path += (path.isEmpty ? "" : "/") + component
            if directories.insert(path).inserted { try cpioEntry(name: path, data: Data(), mode: 0o040755) }
        }
        let start = try cpio.offset()
        var entryInode = inode
        var linkOffsets: [UInt64] = []
        if let target {
            guard let existing = inodeMap[target] else { throw InstallerError("Missing CPIO hardlink target") }
            entryInode = existing.inode; linkOffsets = existing.links
            let count = Data(String(format: "%08x", linkOffsets.count + 1).utf8)
            for offset in linkOffsets { try cpio.seek(toOffset: offset); try cpio.write(contentsOf: count) }
            try cpio.seek(toOffset: start)
        } else { inode += 1 }
        linkOffsets.append(start + 38)
        inodeMap[name] = (entryInode, linkOffsets)
        if let target { inodeMap[target] = (entryInode, linkOffsets) }
        let nameData = Data(name.utf8) + Data([0])
        let fields: [UInt64] = [entryInode, mode, 0, 0, UInt64(linkOffsets.count), 0, UInt64(data.count), 0, 0, 0, 0, UInt64(nameData.count), 0]
        var bytes = Data(("070701" + fields.map { String(format: "%08llx", $0) }.joined()).utf8)
        bytes.append(nameData); bytes.pad(to: 4); bytes.append(data); bytes.pad(to: 4); try cpio.write(contentsOf: bytes)
    }
    public func close() throws {
        if closed { return }; closed = true
        let text = Data((manifest.joined(separator: "\n") + "\n").utf8)
        try cpioEntry(name: "vendorfw/.vendorfw.manifest", data: text, mode: 0o100644)
        try cpioEntry(name: "TRAILER!!!", data: Data(), mode: 0o100644)
        try tar.write(contentsOf: Data(count: 1024)); try tar.close(); try cpio.close()
        try write(text, to: root.appending("manifest.txt"))
    }
    deinit { try? tar.close(); try? cpio.close() }
}
