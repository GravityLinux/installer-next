// SPDX-License-Identifier: GPL-2.0-only
import Foundation

/// Only data containers and firmware payloads are extracted. No executable
/// instruction decoding is used by this collector.
enum J700FirmwareCollectors {
    static let wifiDirectory = "System/Library/DriverExtensions/com.apple.AppleSunriseWLAN.dext/IZUBA"
    static let wifiAliases = [
        "mediatek/W7932_2.bin": "IZUBA_W7932_2.bin",
        "mediatek/WIFI_MT7932_patch_mcu_1_2_hdr.bin": "IZUBA_WIFI_MT7932_patch_mcu_1_2_hdr.bin",
        "mediatek/EEPROM_MT7932_1.bin": "IZUBA_EEPROM_MT7932_1.bin",
        "mediatek/PPR_MT7932.bin": "IZUBA_PPR_MT7932.bin"
    ]
    static let bluetoothSource = "usr/share/firmware/bluetooth/MT7932B1_OS_TypeB_0.1.133.0_260128190103.bin"
    static let bluetoothName = "mediatek/mt793b/neo-25G72.bin"
    static let bluetoothSourceSHA256 = "52d866cdd475875f7290ebea5529fda8dd72c2aec078266860993afe199f98e9"
    static let bluetoothPayloadSHA256 = "9e23414afebeb5ed90aca1fe93a8384252861cbdff6406e09ed66961cbd09492"
    static let bluetoothTrailerSize = 32
    static let cameraName = "apple/isp_1925_03XX.dat"
    static let cameraSize = 0xcba8
    static let cameraMagic: UInt64 = 0x19250306

    static func wifi(_ root: URL) throws -> [FirmwareFile] {
        try wifiAliases.sorted { $0.key < $1.key }.map {
            let data = try Data(contentsOf: root.appending($0.value))
            try require(!data.isEmpty, "Empty j700 Wi-Fi firmware: \($0.value)")
            return FirmwareFile(name: $0.key, data: data)
        }
    }
    static func bluetooth(_ data: Data) throws -> FirmwareFile {
        // The native upload is the source file without its MTK build footer.
        // Pin both hashes for this qualified release rather than guessing at
        // offsets in an unknown firmware build.
        try require(data.sha256 == bluetoothSourceSHA256, "Unqualified j700 Bluetooth firmware build")
        let payload = Data(data.dropLast(bluetoothTrailerSize))
        try require(payload.sha256 == bluetoothPayloadSHA256, "j700 Bluetooth payload checksum mismatch")
        return FirmwareFile(name: bluetoothName, data: payload)
    }
    static func camera(_ data: Data) throws -> FirmwareFile {
        var matches: [Data] = []
        // Existing Gravity/Asahi setfile convention: BE header, 4 KiB alignment.
        for offset in stride(from: 0, through: max(0, data.count - cameraSize), by: 0x1000) {
            if data.count < cameraSize { continue }
            if try data.uint(offset, 4, big: true) != cameraMagic { continue }
            let header = try (0..<8).map { try data.uint(offset + $0 * 4, 4, big: true) }
            try require(header[2] == 0 && header[3] == 0 && header[4] != 0 && header[4] & 0x00ffffff == 0 &&
                        header[5] != 0 && header[5] & 0xffff == 0 && header[6] == 0 && header[7] == 0x03c00000,
                        "Invalid j700 IMX558 calibration header")
            matches.append(try data.part(offset, cameraSize))
        }
        let unique = Dictionary(grouping: matches, by: \.sha256)
        try require(unique.count == 1, "Missing or conflicting j700 IMX558 setfiles in appleh16camerad")
        return FirmwareFile(name: cameraName, data: unique.values.first![0])
    }
    static func validateCamera(_ data: Data) throws {
        try require(data.count == cameraSize && data.uint(0, 4, big: true) == cameraMagic, "Invalid saved j700 camera setfile")
    }

    static func validateCalibration(_ files: [FirmwareFile], address: String, factory: Data) throws -> [FirmwareFile] {
        try require(files.count == 2 && Set(files.map(\.name)).count == 2, "Missing or duplicate generated j700 calibration files")
        try RadioCalibration.validateAddress(address)
        let mac = try stride(from: 0, to: 12, by: 2).map { offset -> UInt8 in
            let start = address.index(address.startIndex, offsetBy: offset)
            guard let n = UInt8(address[start..<address.index(start, offsetBy: 2)], radix: 16) else { throw InstallerError("Invalid j700 radio address") }
            return n
        }
        for (kind, magic, maxSize) in [("calibration", "MT7932C1", 65536), ("precal", "MT7932P1", 409600)] {
            let name = "mediatek/mt7932/\(kind)-\(address).bin"
            guard let file = files.first(where: { $0.name == name }) else { throw InstallerError("Missing generated j700 \(kind) file") }
            let data = file.data
            try require((20...maxSize).contains(data.count) && data.prefix(8) == Data(magic.utf8) && data.subdata(in: 8..<14) == Data(mac), "j700 calibration cache belongs to another radio or has an invalid header")
            let count = Int(try data.uint(kind == "calibration" ? 16 : 14, kind == "calibration" ? 4 : 2))
            try require((1...128).contains(count), "Invalid j700 calibration record count")
            if kind == "precal" { try require(data.uint(16, 4) == UInt64(data.count), "Invalid j700 precal file length") }
            var pos = 20
            for _ in 0..<count {
                let header = kind == "calibration" ? 8 : 20
                try require(pos <= data.count - header, "Truncated j700 calibration record")
                let length = Int(try data.uint(pos + 4, 4))
                try require(length > 0 && length <= 1536 && pos + header <= data.count - length, "Invalid j700 calibration record bounds")
                let body = try data.part(pos + header, length)
                if kind == "precal" {
                    let category = data[pos]
                    try require([1:1080, 2:604, 3:16][Int(category)] == length && data[pos + 1] == 0,
                                "Unsupported j700 operating calibration record")
                    try require(factory.range(of: body) != nil, "j700 operating RF calibration does not match factory data")
                } else {
                    let cid = data[pos], ext = data[pos + 1]
                    try require(data[pos + 2] <= 1 && data[pos + 3] <= 1, "Invalid j700 calibration command flags")
                    switch cid {
                    case 0xd7:
                        try require(ext == 0 && length == 1, "Unsupported j700 calibration selector")
                    case 0xed:
                        try require(ext == 0x21 && (4...1028).contains(length) && body[0] == 3 &&
                                    body.uint(2, 2) == UInt64(length - 4), "Invalid j700 efuse calibration record")
                        try require(factory.range(of: Data(body.dropFirst(4))) != nil, "j700 efuse cache does not match factory data")
                    case 0xd6:
                        try require(ext == 0 && length > 20 && body[0] <= 3, "Unsupported j700 RF calibration record")
                        try require(factory.range(of: Data(body.dropFirst(20))) != nil, "j700 RF cache does not match factory data")
                    default: throw InstallerError("Unsupported command in j700 calibration cache")
                    }
                }
                pos += header + length
            }
            try require(pos == data.count, "Unexpected trailing j700 calibration data")
        }
        return files
    }
}

struct J700Firmware: BoardFirmwareLoading {
    let host: URL
    init(host: URL = URL(fileURLWithPath: "/")) { self.host = host }
    private func cameraSource() throws -> Data {
        for path in ["usr/libexec/appleh16camerad", "usr/sbin/appleh16camerad"] {
            let url = host.appending(path)
            if fm.fileExists(atPath: url.path) { return try Data(contentsOf: url) }
        }
        throw InstallerError("j700 camera setfile source appleh16camerad is missing")
    }
    private func factory() throws -> (URL, Data) {
        let root = host.appending(String(RadioCalibration.factoryPath.dropFirst()))
        let paths = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("BWC2-") }
        try require(paths.count == 1, "Expected one j700 BWC2 factory record")
        let data = try Data(contentsOf: paths[0])
        try require((100...1_048_576).contains(data.count), "Invalid j700 factory calibration size")
        let outer = try DERNode.sequence(data)
        try require(outer.count >= 2 && outer[0].text == "IMG4", "Invalid j700 factory container")
        let payload = try outer[1].children()
        try require(payload.count >= 4 && payload[0].text == "IM4P" && payload[1].text == "BWC2" && payload[3].tag == 4,
                    "Expected a j700 BWC2 calibration payload")
        return (paths[0], data)
    }
    func validateRecovery(_ context: FirmwareValidationContext, events: EventSink) throws {
        _ = try J700FirmwareCollectors.wifi(context.recovery.appending(J700FirmwareCollectors.wifiDirectory))
        _ = try J700FirmwareCollectors.bluetooth(Data(contentsOf: context.recovery.appending(J700FirmwareCollectors.bluetoothSource)))
        _ = try J700FirmwareCollectors.camera(cameraSource())
        guard let tree = context.deviceTree else { throw InstallerError("j700 firmware validation requires the live device tree") }
        let address = try RadioCalibration.address(in: tree, property: "mac-address-wifi0")
        _ = try J700FactoryCalibration.generate(factory: factory().1, address: address)
    }
    func collect(_ context: FirmwareCollectionContext, into package: FirmwarePackage, events: EventSink) throws -> [FirmwareArchiveSource] {
        let saved = context.raw.appending("neo-board-data")
        events(InstallEvent(.wifi, help: "Collecting the j700 MT7932 firmware and validating this radio’s factory calibration."))
        try package.add(J700FirmwareCollectors.wifi(context.recovery.appending(J700FirmwareCollectors.wifiDirectory)))
        let factoryRecord = try factory(), address = try RadioCalibration.address(in: context.deviceTree, property: "mac-address-wifi0")
        let calibration = try J700FactoryCalibration.generate(factory: factoryRecord.1, address: address)
        try package.add(calibration)
        for file in calibration { try write(file.data, to: saved.appending(file.name)) }
        try write(factoryRecord.1, to: saved.appending("factory/" + factoryRecord.0.lastPathComponent))
        events(InstallEvent(.bluetooth, help: "Collecting the j700 MT793B B1 production firmware."))
        let bluetooth = try J700FirmwareCollectors.bluetooth(Data(contentsOf: context.recovery.appending(J700FirmwareCollectors.bluetoothSource)))
        try package.add(bluetooth); try write(bluetooth.data, to: saved.appending(bluetooth.name))
        events(InstallEvent(.boardFirmware, help: "Extracting the IMX558 camera setfile and saving j700 audio tuning data."))
        let camera = try J700FirmwareCollectors.camera(cameraSource())
        try package.add(camera); try write(camera.data, to: saved.appending(camera.name))
        events(InstallEvent(.multitouch)); try package.add(Multitouch.files(context.fud))
        try saveAudio(from: host.appending("System/Library/Audio/Tunings/AID44"), to: saved.appending("audio/AID44"))
        let metadata: [String: Any] = ["version": 1, "board": "j700", "wifi_address": address, "calibration_generated_locally": true,
            "factory_sha256": factoryRecord.1.sha256, "camera_sha256": camera.data.sha256,
            "bluetooth_sha256": bluetooth.data.sha256,
            "calibration": calibration.map { ["name": $0.name, "sha256": $0.data.sha256] }]
        try write(jsonData(metadata), to: saved.appending("metadata.json"))
        return [FirmwareArchiveSource(source: context.recovery.appending(J700FirmwareCollectors.wifiDirectory), name: "neo-wifi"),
                FirmwareArchiveSource(source: saved, name: "neo-board-data")]
    }
    func rebuild(_ context: FirmwareRebuildContext, into package: FirmwarePackage, events: EventSink) throws {
        let saved = context.raw.appending("neo-board-data")
        let metadata = dict(try JSONSerialization.jsonObject(with: Data(contentsOf: saved.appending("metadata.json"))))
        try require(int(metadata["version"]) == 1 && string(metadata["board"]) == "j700", "Invalid saved j700 firmware metadata")
        let factory = saved.appending("factory")
        let entries = try fm.contentsOfDirectory(at: factory, includingPropertiesForKeys: nil)
        try require(entries.count == 1, "Missing or ambiguous saved j700 factory calibration")
        let raw = try Data(contentsOf: entries[0])
        try require(raw.sha256 == string(metadata["factory_sha256"]), "Saved j700 factory checksum mismatch")
        let calibration = try J700FactoryCalibration.generate(factory: raw, address: string(metadata["wifi_address"]))
        let expected = array(metadata["calibration"])
        for file in calibration { try require(expected.contains { string($0["name"]) == file.name && string($0["sha256"]) == file.data.sha256 }, "Saved j700 calibration checksum mismatch") }
        try package.add(J700FirmwareCollectors.wifi(context.raw.appending("neo-wifi"))); try package.add(calibration)
        for (name, key) in [(J700FirmwareCollectors.bluetoothName, "bluetooth_sha256"), (J700FirmwareCollectors.cameraName, "camera_sha256")] {
            let data = try Data(contentsOf: saved.appending(name))
            try require(data.sha256 == string(metadata[key]), "Saved j700 firmware checksum mismatch")
            if name == J700FirmwareCollectors.cameraName { try J700FirmwareCollectors.validateCamera(data) }
            else { try require(data.sha256 == J700FirmwareCollectors.bluetoothPayloadSHA256, "Unqualified saved j700 Bluetooth payload") }
            try package.add(FirmwareFile(name: name, data: data))
        }
        try package.add(Multitouch.files(context.raw.appending("fud_firmware")))
    }
    private func saveAudio(from source: URL, to target: URL) throws {
        try require(fm.fileExists(atPath: source.path), "j700 AID44 audio tuning is missing")
        guard let entries = fm.enumerator(at: source, includingPropertiesForKeys: [.isDirectoryKey]) else { throw InstallerError("Cannot read j700 audio tuning") }
        for case let path as URL in entries {
            if try path.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true { continue }
            let relative = String(path.path.dropFirst(source.path.count + 1))
            try write(Data(contentsOf: path), to: target.appending(relative))
        }
    }
}

/// Converts this Mac's BWC2 data to the existing MT7932 Linux cache ABI.
/// Only protocol metadata is constructed here; all opaque RF bytes are read
/// from the local factory record. The operating bank follows the driver's
/// explicit qualified 6 GHz group 28 policy, not an inferred all-channel map.
enum J700FactoryCalibration {
    private static func nodes(_ data: Data) throws -> [DERNode] {
        var result: [DERNode] = [], position = 0
        while position < data.count {
            let tag = data[position]; position += 1
            if tag & 31 == 31 {
                var bytes = 0
                while true {
                    try require(position < data.count && bytes < 6, "Invalid BWC2 extended DER tag")
                    let value = data[position]; position += 1; bytes += 1
                    try require(bytes != 1 || value & 127 != 0, "Noncanonical BWC2 extended DER tag")
                    if value & 128 == 0 { break }
                }
            }
            try require(position < data.count, "Truncated BWC2 DER length")
            var length = Int(data[position]); position += 1
            if length & 128 != 0 {
                let bytes = length & 127
                try require((1...4).contains(bytes), "Invalid BWC2 DER length")
                length = Int(try data.uint(position, bytes, big: true)); position += bytes
                try require(length >= 128, "Noncanonical BWC2 DER length")
            }
            result.append(DERNode(tag: tag, data: try data.part(position, length))); position += length
        }
        return result
    }
    static func records(_ factory: Data) throws -> [String: Data] {
        try require((100...1_048_576).contains(factory.count), "Invalid BWC2 factory record size")
        let outer = try DERNode.sequence(factory)
        try require(outer.count >= 2 && outer[0].text == "IMG4" && outer[1].tag == 0x30, "Expected BWC2 IMG4")
        let im4p = try outer[1].children()
        try require(im4p.count == 4 && im4p[0].text == "IM4P" && im4p[1].text == "BWC2" && im4p[3].tag == 4, "Expected uncompressed BWC2 IM4P")
        let roots = try nodes(im4p[3].data)
        try require(roots.count == 1 && roots[0].tag == 0x30, "Invalid BWC2 payload")
        let fields = try nodes(roots[0].data)
        try require(fields.count >= 3 && fields[0].integer() == Data("BWC2".utf8).uint(0, 4) && fields[1].integer() == 0x03000300, "Unsupported BWC2 factory format")
        var records: [String: Data] = [:]
        let names = ["BCAL", "OCA2", "OCAL", "WCA0", "WCAL"]
        func visit(_ entries: [DERNode], depth: Int) throws {
            try require(depth <= 8, "BWC2 nesting exceeds limit")
            for entry in entries where entry.tag & 32 != 0 {
                let children = try nodes(entry.data)
                if entry.tag == 0x30, children.count >= 1, children[0].tag == 2 {
                    let identifier = try children[0].integer()
                    if let name = try names.first(where: { try Data($0.utf8).uint(0, 4) == identifier }) {
                        try require(children.count == 3 && children[1].tag == 0x16 && children[2].tag == 4 && records[name] == nil, "Malformed or duplicate BWC2 calibration record")
                        records[name] = children[2].data; continue
                    }
                }
                try visit(children, depth: depth + 1)
            }
        }
        try visit(fields, depth: 0)
        try require(records["OCA2"] != nil && records["WCAL"] != nil, "BWC2 is missing Wi-Fi factory calibration")
        return records
    }
    /// Big-endian OCA2 table. Each section repeats its ID and bounds, has a
    /// byte-sum checksum, and is contiguous with its neighbors.
    static func sections(_ blob: Data) throws -> [Int: Data] {
        try require((16...409600).contains(blob.count) && blob.prefix(4) == Data("BLOB".utf8), "Invalid OCA2 blob")
        let header = Int(try blob.uint(4, 4, big: true)), version = try blob.uint(8, 2, big: true), count = Int(try blob.uint(10, 2, big: true))
        try require(version == 12 && (1...1024).contains(count) && header == 16 + count * 20 && header <= blob.count && blob.uint(12, 4) == 0, "Unsupported OCA2 table")
        var result: [Int: Data] = [:], expected = header
        for index in 0..<count {
            let at = 16 + index * 20, id = Int(try blob.uint(at, 2, big: true))
            let offset = Int(try blob.uint(at + 4, 4, big: true)), length = Int(try blob.uint(at + 8, 4, big: true))
            try require(blob.uint(at + 2, 2, big: true) == 12 && blob.uint(at + 16, 4) == 0 && offset == expected && length >= 8 && result[id] == nil, "Invalid OCA2 section table")
            let body = try blob.part(offset, length)
            try require(body.uint(0, 2, big: true) == UInt64(id) && body.uint(2, 2, big: true) == 12 && body.uint(4, 4, big: true) == UInt64(length), "Invalid OCA2 section header")
            let sum = body.reduce(UInt64(0)) { $0 + UInt64($1) }
            try require(blob.uint(at + 12, 4, big: true) == sum, "OCA2 section checksum mismatch")
            result[id] = try body.part(8, length - 8); expected += length
        }
        try require(expected == blob.count, "Unexpected OCA2 trailing bytes")
        return result
    }
    static func generate(factory: Data, address: String) throws -> [FirmwareFile] {
        try RadioCalibration.validateAddress(address)
        let records = try records(factory), table = try sections(records["OCA2"]!)
        let mac = Data(try stride(from: 0, to: 12, by: 2).map { index -> UInt8 in
            let start = address.index(address.startIndex, offsetBy: index)
            guard let value = UInt8(address[start..<address.index(start, offsetBy: 2)], radix: 16) else { throw InstallerError("Invalid j700 MAC") }; return value
        })
        func section(_ id: Int, bytes: Int) throws -> Data {
            guard let data = table[id], data.count == bytes else { throw InstallerError("Missing or unsupported OCA2 section \(String(id, radix: 16))") }; return data
        }
        func rf(_ kind: UInt8, id: UInt16, selector: UInt32, frequency: UInt32 = 0, control: UInt32 = 0, data: Data, operation: UInt8) -> Data {
            var result = Data([kind, operation]); result.appendLE(UInt64(id), bytes: 2); result.appendLE(UInt64(data.count))
            for word in [selector, frequency, control] { result.appendLE(UInt64(word)) }
            result.append(data); return result
        }
        func startupRecord(_ body: Data, cid: UInt8 = 0xd6, ext: UInt8 = 0, setting: UInt8 = 1, ack: UInt8 = 0) throws -> Data {
            try require((1...1536).contains(body.count), "Invalid generated calibration command size")
            var record = Data([cid, ext, setting, ack]); record.appendLE(UInt64(body.count)); record.append(body); return record
        }
        var startup = [try startupRecord(Data([1]), cid: 0xd7)]
        let wcal = records["WCAL"]!
        try require((16...1024).contains(wcal.count) && wcal.prefix(4) == Data("BLOB".utf8), "Invalid WCAL overlay")
        var overlay = Data([3, 0]); overlay.appendLE(UInt64(wcal.count), bytes: 2); overlay.append(wcal)
        startup.append(try startupRecord(overlay, cid: 0xed, ext: 0x21, setting: 0, ack: 1))
        for (source, id, selector, bytes) in [(0x1001, 0x130, 0, 328), (0x1002, 0x131, 0, 20), (0x1003, 0x132, 0, 20),
            (0x1011, 0x120, 1, 336), (0x1012, 0x121, 1, 320), (0x1021, 0x120, 2, 336), (0x1022, 0x121, 2, 600)] {
            startup.append(try startupRecord(rf(0, id: UInt16(id), selector: UInt32(selector), data: section(source, bytes: bytes), operation: 0xff)))
        }
        func startupGroup(_ source: Int, selector: UInt32, bytes: Int) throws {
            let group = try section(source, bytes: bytes * 2)
            for chain in 0..<2 {
                startup.append(try startupRecord(rf(1, id: UInt16(0x120 + chain), selector: selector, data: group.part(chain * bytes, bytes), operation: 0xff)))
            }
        }
        try startupGroup(0x2000, selector: 0, bytes: 792)
        startup.append(try startupRecord(rf(1, id: 0x110, selector: 0x10000, data: section(0x2080, bytes: 712), operation: 0xff)))
        try startupGroup(0x2008, selector: 8, bytes: 1080)
        try startupGroup(0x2010, selector: 16, bytes: 1080)
        try startupGroup(0x2000, selector: 0x10000000, bytes: 792)
        func channelInfo(_ source: Int, selector: UInt32, operation: UInt8) throws -> Data {
            let block = try section(source, bytes: 20)
            return rf(3, id: 0x110, selector: selector, frequency: UInt32(try block.uint(0, 4)), data: try block.part(4, 16), operation: operation)
        }
        func channel(_ source: Int, lane: Int, id: UInt16, selector: UInt32, bytes: Int, operation: UInt8) throws -> Data {
            let lanes = try section(source, bytes: bytes), block = try lanes.part(lane * 612, 612)
            return rf(2, id: id, selector: selector, frequency: UInt32(try block.uint(0, 4)), control: UInt32(try block.uint(4, 4)), data: try block.part(8, 604), operation: operation)
        }
        startup.append(try startupRecord(channelInfo(0x4006, selector: 0x10000006, operation: 0xff)))
        startup.append(try startupRecord(channel(0x3086, lane: 0, id: 0x110, selector: 0x100d0006, bytes: 2448, operation: 0xff)))
        for lane in 0..<3 {
            startup.append(try startupRecord(channel(0x3006, lane: lane, id: UInt16(0x130 + lane), selector: 0x100c0006, bytes: 4896, operation: 0xff)))
        }
        var operating: [Data] = []
        let group = try section(0x201c, bytes: 2160)
        for selector: UInt32 in [0x041e001c, 28] {
            for chain in 0..<2 { operating.append(rf(1, id: UInt16(0x120 + chain), selector: selector, data: try group.part(chain * 1080, 1080), operation: 0)) }
        }
        operating.append(try channelInfo(0x420f, selector: 0x200f, operation: 0))
        for lane in 0..<2 { operating.append(try channel(0x320f, lane: lane, id: UInt16(0x120 + lane), selector: 0x821e200f, bytes: 1224, operation: 0)) }
        var first = Data("MT7932C1".utf8) + mac + Data([0, 0]); first.appendLE(UInt64(startup.count)); first.append(startup.reduce(Data(), +))
        var second = Data("MT7932P1".utf8) + mac; second.appendLE(UInt64(operating.count), bytes: 2)
        second.appendLE(UInt64(20 + operating.reduce(0) { $0 + $1.count })); second.append(operating.reduce(Data(), +))
        try require(first.count <= 65536 && second.count <= 409600, "Generated j700 calibration exceeds the driver limits")
        return try J700FirmwareCollectors.validateCalibration([
            FirmwareFile(name: "mediatek/mt7932/calibration-\(address).bin", data: first),
            FirmwareFile(name: "mediatek/mt7932/precal-\(address).bin", data: second)], address: address, factory: factory)
    }
}
