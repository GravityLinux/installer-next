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

    static func calibration(_ root: URL, address: String, factory: Data) throws -> [FirmwareFile] {
        try RadioCalibration.validateAddress(address)
        let mac = try stride(from: 0, to: 12, by: 2).map { offset -> UInt8 in
            let start = address.index(address.startIndex, offsetBy: offset)
            guard let n = UInt8(address[start..<address.index(start, offsetBy: 2)], radix: 16) else { throw InstallerError("Invalid j700 radio address") }
            return n
        }
        var files: [FirmwareFile] = []
        for (kind, magic, maxSize) in [("calibration", "MT7932C1", 65536), ("precal", "MT7932P1", 409600)] {
            let name = "mediatek/mt7932/\(kind)-\(address).bin"
            let path = root.appending(name)
            try require(fm.fileExists(atPath: path.path), "j700 Wi-Fi requires this radio’s \(kind) cache. Supply the matching calibration directory; another j700’s cache cannot be used.")
            let data = try Data(contentsOf: path)
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
            files.append(FirmwareFile(name: name, data: data))
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
    private func cache(_ resources: URL) -> URL { resources.appending("board-calibration/j700") }
    func validateRecovery(_ context: FirmwareValidationContext, events: EventSink) throws {
        _ = try J700FirmwareCollectors.wifi(context.recovery.appending(J700FirmwareCollectors.wifiDirectory))
        _ = try J700FirmwareCollectors.bluetooth(Data(contentsOf: context.recovery.appending(J700FirmwareCollectors.bluetoothSource)))
        _ = try J700FirmwareCollectors.camera(cameraSource())
        guard let tree = context.deviceTree else { throw InstallerError("j700 firmware validation requires the live device tree") }
        let address = try RadioCalibration.address(in: tree, property: "mac-address-wifi0")
        _ = try J700FirmwareCollectors.calibration(cache(context.resources), address: address, factory: factory().1)
    }
    func collect(_ context: FirmwareCollectionContext, into package: FirmwarePackage, events: EventSink) throws -> [FirmwareArchiveSource] {
        let saved = context.raw.appending("neo-board-data")
        events(InstallEvent(.wifi, help: "Collecting the j700 MT7932 firmware and validating this radio’s factory calibration."))
        try package.add(J700FirmwareCollectors.wifi(context.recovery.appending(J700FirmwareCollectors.wifiDirectory)))
        let factoryRecord = try factory(), address = try RadioCalibration.address(in: context.deviceTree, property: "mac-address-wifi0")
        let calibration = try J700FirmwareCollectors.calibration(cache(context.resources), address: address, factory: factoryRecord.1)
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
        let metadata: [String: Any] = ["version": 1, "board": "j700", "wifi_address": address,
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
        let calibration = try J700FirmwareCollectors.calibration(saved, address: string(metadata["wifi_address"]), factory: raw)
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
