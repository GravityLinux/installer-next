// SPDX-License-Identifier: GPL-2.0-only
// j773g firmware policy, ported without changing its outputs.
import Foundation

enum RadioKind: String, CaseIterable { case bluetooth, wifi
    var record: String { self == .bluetooth ? "BTBF" : "WCAL" }
    var property: String { self == .bluetooth ? "mac-address-bluetooth0" : "mac-address-wifi0" }
    var rawName: String { self == .bluetooth ? "bluetooth-beamforming" : "wifi-calibration" }
    func filename(_ address: String) -> String { self == .bluetooth ? "brcm/brcmbt4388-\(address)-bf.bin" : "brcm/brcmfmac4388-\(address)-cal.bin" }
}
struct RadioCalibration {
    static let factoryPath = "/System/Volumes/Hardware/FactoryData/System/Library/Caches/com.apple.factorydata"
    let kind: RadioKind
    let address: String
    let data: Data
    let provenance: [[String: String]]
    var file: FirmwareFile { FirmwareFile(name: kind.filename(address), data: data, includeInBootloader: true) }
    static func validateBlob(_ data: Data) throws {
        try require((4...32768).contains(data.count) && data.starts(with: Data("BLOB".utf8)), "Invalid radio calibration")
    }
    static func extract(_ data: Data, record: String) throws -> Data {
        try require(data.count <= 1_048_576, "Factory record exceeds size limit")
        let outer = try DERNode.sequence(data)
        try require(outer.count >= 2 && outer[0].tag == 0x16 && outer[0].text == "IMG4" && outer[1].tag == 0x30, "Expected factory IMG4")
        let payload = try outer[1].children()
        try require(payload.count == 4 && payload[0].tag == 0x16 && payload[0].text == "IM4P" && payload[1].tag == 0x16 && payload[1].text == "BWCl" && payload[2].tag == 0x16 && payload[3].tag == 4, "Expected uncompressed BWCl payload")
        let records = try DERNode.sequence(payload[3].data)
        let bwcl = try Data("BWCl".utf8).uint(0, 4)
        try require(!records.isEmpty && records[0].integer() == bwcl, "Incorrect BWCl payload identifier")
        let wanted = try Data(record.utf8).uint(0, 4); var matches: [Data] = []
        func visit(_ nodes: [DERNode], depth: Int) throws {
            try require(depth <= 8, "Factory record nesting exceeds limit")
            for node in nodes where node.tag & 0x20 != 0 {
                let children = try node.children()
                if try node.tag == 0x30 && !children.isEmpty && children[0].tag == 2 && children[0].integer() == wanted {
                    try require(children.count == 3 && children[1].tag == 0x16 && children[2].tag == 4, "Malformed calibration record")
                    try validateBlob(children[2].data); matches.append(children[2].data)
                } else { try visit(children, depth: depth + 1) }
            }
        }
        try visit(records, depth: 0); try require(matches.count == 1, "Expected exactly one calibration record")
        return matches[0]
    }
    static func validateAddress(_ address: String) throws {
        try require(address.count == 12 && address.allSatisfy { "0123456789abcdef".contains($0) }, "Invalid radio address")
        guard let first = UInt8(address.prefix(2), radix: 16) else { throw InstallerError("Invalid radio address") }
        try require(address != String(repeating: "0", count: 12) && address != String(repeating: "f", count: 12) && first & 1 == 0, "Invalid radio address")
    }
    static func address(in tree: Any, property: String) throws -> String {
        var matches: [Data] = []
        func visit(_ object: Any) throws {
            if let node = object as? [String: Any] {
                if string(node["IORegistryEntryName"]) == "chosen", let value = node[property] {
                    guard let data = value as? Data, data.count == 6 else { throw InstallerError("Invalid /chosen radio address") }; matches.append(data)
                }
                for value in node.values { try visit(value) }
            } else if let nodes = object as? [Any] { for node in nodes { try visit(node) } }
        }
        try visit(tree); try require(matches.count == 1, "Missing or ambiguous /chosen radio address")
        let address = matches[0].hex; try validateAddress(address); return address
    }
    static func collect(_ kind: RadioKind, factory: URL = URL(fileURLWithPath: factoryPath), tree: Any) throws -> RadioCalibration? {
        let paths = (try? fm.contentsOfDirectory(at: factory, includingPropertiesForKeys: nil))?.filter { $0.lastPathComponent.hasPrefix("BWCl-sakhalin-4388-C2-") }.sorted { $0.path < $1.path } ?? []
        if paths.isEmpty { return nil }
        let address = try address(in: tree, property: kind.property); var blobs: [String: Data] = [:]; var provenance: [[String: String]] = []
        for path in paths {
            let attributes = try fm.attributesOfItem(atPath: path.path)
            try require(int(attributes[.size]) <= 1_048_576, "Factory record exceeds size limit")
            let raw = try Data(contentsOf: path); let blob = try extract(raw, record: kind.record)
            blobs[blob.sha256] = blob; provenance.append(["file": path.lastPathComponent, "sha256": raw.sha256])
        }
        try require(blobs.count == 1, "Conflicting radio factory calibration records")
        return RadioCalibration(kind: kind, address: address, data: blobs.values.first!, provenance: provenance)
    }
    func writeRaw(to root: URL) throws {
        try write(data, to: root.appending("apple/\(kind.rawName).bin"))
        try write(jsonData(["version": 1, "address": address, "bytes": data.count, "sha256": data.sha256, "factory_records": provenance]), to: root.appending("apple/\(kind.rawName).json"))
    }
    static func fromArchive(_ kind: RadioKind, root: URL) throws -> RadioCalibration? {
        let metadata = root.appending("apple/\(kind.rawName).json")
        if !fm.fileExists(atPath: metadata.path) { return nil }
        let value = dict(try JSONSerialization.jsonObject(with: Data(contentsOf: metadata)))
        let blobURL = root.appending("apple/\(kind.rawName).bin")
        try require(int(try fm.attributesOfItem(atPath: blobURL.path)[.size]) <= 32768, "Saved radio calibration exceeds size limit")
        let blob = try Data(contentsOf: blobURL); let address = string(value["address"])
        try validateAddress(address); try validateBlob(blob)
        try require(int(value["version"]) == 1 && int(value["bytes"]) == blob.count && string(value["sha256"]) == blob.sha256, "Saved radio calibration checksum mismatch")
        return RadioCalibration(kind: kind, address: address, data: blob, provenance: value["factory_records"] as? [[String: String]] ?? [])
    }
}

enum J773gFirmwareCollectors {
    static let wifiAliases = [
        "brcm/brcmfmac4388c0-pcie.bin": "C-4388__s-C2/sakhalin.trx",
        "brcm/brcmfmac4388c0-pcie.txt": "C-4388__s-C2/P-sakhalin-X0_M-WLMT_V-u__m-4.9.txt",
        "brcm/brcmfmac4388c0-pcie.clm_blob": "C-4388__s-C2/sakhalin-X0.clmb",
        "brcm/brcmfmac4388c0-pcie.txcap_blob": "C-4388__s-C2/sakhalin-X0.txcb",
        "brcm/brcmfmac4388c0-pcie.sig": "C-4388__s-C2/sakhalin.sig"
    ]
    static func wifi(_ root: URL) throws -> [FirmwareFile] {
        try wifiAliases.sorted { $0.key < $1.key }.map { name, path in
            var data = try Data(contentsOf: root.appending(path))
            if name.hasSuffix(".txt") {
                guard let text = String(data: data, encoding: .ascii) else { throw InstallerError("Invalid Wi-Fi NVRAM") }
                var result = ""
                for line in text.components(separatedBy: "\n") where !line.isEmpty {
                    guard let split = line.firstIndex(of: "=") else { throw InstallerError("Invalid NVRAM entry") }
                    result += line[..<split].trimmingCharacters(in: .whitespaces) + "=" + line[line.index(after: split)...] + "\n"
                }
                data = Data(result.utf8)
            }
            return FirmwareFile(name: name, data: data)
        }
    }
    static func bluetooth(_ root: URL) throws -> [FirmwareFile] {
        var result: [String: Data] = [:]
        for url in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).sorted(by: { $0.path < $1.path }) {
            guard ["bin", "ptb"].contains(url.pathExtension) else { continue }
            let name = url.deletingPathExtension().lastPathComponent
            if name.contains("_DEV") { continue }
            let parts = name.components(separatedBy: "_")
            guard parts.first?.lowercased() == "bcm4388c2", let index = parts.firstIndex(of: "PCIE") else { continue }
            var board = index + 1
            if board < parts.count && parts[board] == "macOS" { board += 1 }
            if board < parts.count && parts[board] == "Willamette" { board += 1 }
            guard board < parts.count else { continue }
            let boardType = parts[board].replacingOccurrences(of: "ES2", with: "").lowercased()
            let vendors = ["AMKOR", "MUR", "USI", "GEN"].filter { parts.contains($0) }
            guard boardType == "sakhalin", vendors == ["AMKOR"] else { continue }
            let dest = "brcm/brcmbt4388c2-apple,sakhalin-a.\(url.pathExtension)"
            if result[dest] == nil { result[dest] = try Data(contentsOf: url) }
        }
        for ext in ["bin", "ptb"] { try require(result["brcm/brcmbt4388c2-apple,sakhalin-a.\(ext)"] != nil, "Missing Sakhalin AMKOR Bluetooth \(ext)") }
        return result.sorted { $0.key < $1.key }.map { FirmwareFile(name: $0.key, data: $0.value) }
    }
    static func kernel(_ root: URL) throws -> [FirmwareFile] {
        let kernel = try IM4P.extract(Data(contentsOf: root)).data
        guard let range = kernel.range(of: Data("2214A_RCFG".utf8)) else { throw InstallerError("Could not find ASMedia firmware") }
        let start = range.lowerBound; let size = try kernel.uint(start + 0x2f, 4)
        try require(size == 0x18000, "Unexpected ASMedia firmware size")
        return [FirmwareFile(name: "asmedia/asm2214a-apple.bin", data: try kernel.part(start + 0x33, Int(size)), includeInBootloader: true)]
    }
    static func wifiSource(_ root: URL) throws -> URL {
        for relative in ["System/Library/DriverExtensions/com.apple.DriverKit-AppleBCMWLAN.dext/Firmware", "usr/share/firmware/wifi"] {
            let url = root.appending(relative); if fm.fileExists(atPath: url.path) { return url }
        }
        throw InstallerError("Could not find recovery Wi-Fi firmware")
    }
}


struct J773gFirmware: BoardFirmwareLoading {
    func validateRecovery(_ context: FirmwareValidationContext, events: EventSink) throws {
        _ = try J773gFirmwareCollectors.wifi(J773gFirmwareCollectors.wifiSource(context.recovery))
        _ = try J773gFirmwareCollectors.bluetooth(context.recovery.appending("usr/share/firmware/bluetooth"))
    }
    func collect(_ context: FirmwareCollectionContext, into package: FirmwarePackage, events: EventSink) throws -> [FirmwareArchiveSource] {
        events(InstallEvent(.calibration))
        for kind in RadioKind.allCases {
            if let calibration = try RadioCalibration.collect(kind, tree: context.deviceTree) {
                try package.add(calibration.file); try calibration.writeRaw(to: context.raw)
            }
        }
        try mkdir(context.raw.appending("apple"))
        let wifi = try J773gFirmwareCollectors.wifiSource(context.recovery)
        events(InstallEvent(.wifi, help: "Collecting the Sakhalin firmware, signature, NVRAM, and regulatory data required by the M4 Mac mini."))
        try package.add(J773gFirmwareCollectors.wifi(wifi))
        events(InstallEvent(.bluetooth, help: "Collecting the matching BCM4388C2 Sakhalin AMKOR firmware and patch table."))
        try package.add(J773gFirmwareCollectors.bluetooth(context.recovery.appending("usr/share/firmware/bluetooth")))
        events(InstallEvent(.multitouch)); try package.add(Multitouch.files(context.fud))
        guard let kernel = context.kernel else { throw InstallerError("Missing kernel cache for ASMedia firmware") }
        events(InstallEvent(.kernel, help: "Extracting the ASMedia USB firmware from Apple’s kernel cache."))
        try package.add(J773gFirmwareCollectors.kernel(kernel))
        // This release has no M4 ISP/ALS collector or bundled AVD firmware.
        return [FirmwareArchiveSource(source: context.recovery.appending("usr/share/firmware"), name: "firmware"),
                FirmwareArchiveSource(source: wifi, name: "apple_bcmwlan_firmware"),
                FirmwareArchiveSource(source: context.raw.appending("apple"), name: "apple")]
    }
    func rebuild(_ context: FirmwareRebuildContext, into package: FirmwarePackage, events: EventSink) throws {
        let wifi = context.raw.appending("apple_bcmwlan_firmware")
        events(InstallEvent(.wifi)); try package.add(J773gFirmwareCollectors.wifi(fm.fileExists(atPath: wifi.path) ? wifi : context.raw.appending("firmware/wifi")))
        events(InstallEvent(.bluetooth)); try package.add(J773gFirmwareCollectors.bluetooth(context.raw.appending("firmware/bluetooth")))
        for kind in RadioKind.allCases { if let calibration = try RadioCalibration.fromArchive(kind, root: context.raw) { try package.add(calibration.file) } }
        try package.add(Multitouch.files(context.raw.appending("fud_firmware")))
        guard let kernel = try fm.contentsOfDirectory(at: context.installerData, includingPropertiesForKeys: nil).first(where: { $0.lastPathComponent.hasPrefix("kernelcache") }) else { throw InstallerError("Missing saved kernel cache") }
        events(InstallEvent(.kernel)); try package.add(J773gFirmwareCollectors.kernel(kernel))
    }
}
