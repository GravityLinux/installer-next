// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Testing
@testable import GravityCore

/// Export synthetic inputs and native outputs for the separately shipped Linux
/// consumer's integration suite. No Python runtime is used by the macOS app.
@Test(.enabled(if: ProcessInfo.processInfo.environment["GRAVITY_FIRMWARE_COMPAT_FIXTURES"] != nil),
      arguments: ["j700", "j773g"])
func exportLinuxFirmwareCompatibilityFixtures(boardID: String) throws {
    let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GRAVITY_FIRMWARE_COMPAT_FIXTURES"]!).appending(boardID)
    try writeLinuxFirmwareFixture(boardID: boardID, root: root)
}

@Test func j773gCollectionAndArchiveRebuildMatchWithBothRadioCalibrations() throws {
    let temporary = try TemporaryDirectory()
    try writeLinuxFirmwareFixture(boardID: "j773g", root: temporary.url)
}

private func writeLinuxFirmwareFixture(boardID: String, root: URL) throws {
    let raw = root.appending("raw"), source = root.appending("source"), expected = root.appending("expected")
    try mkdir(raw); try mkdir(source)
    let hardware = HardwareIdentity(deviceClass: boardID + "ap", chipID: boardID == "j700" ? 0x8140 : 0x8132, boardID: boardID == "j700" ? 0x64 : 0)
    try write(JSONEncoder().encode(FirmwareArchiveInfo(version: 1, boardProfileID: boardID, hardware: hardware)), to: raw.appending(FirmwareArchive.metadataName))
    // Include a data blob and dictionaries with nontrivial key order: this
    // exercises the Linux and Swift HIDF serializers and alignment rules.
    let commands: [[String: Any]] = [
        ["Type": "Config", "Config": ["Interface Config": [["bInterfaceNumber": 1]]]],
        ["Type": "Binary", "Payload": Data("synthetic-trackpad".utf8), "Address": 4096]
    ]
    let family = boardID == "j700" ? "C1FE0,0" : "C1FD0,0"
    let xml = try PropertyListSerialization.data(fromPropertyList: [family: commands], format: .xml, options: 0)
    let document = try XMLDocument(data: xml), dictionary = try #require(document.rootElement()?.elements(forName: "dict").first)
    try write(seq([ascii("IM4P"), ascii("mtfw"), ascii("synthetic"), der(4, Data(dictionary.xmlString.utf8))]),
              to: raw.appending("fud_firmware/\(boardID)/Multitouch.im4p"))
    if boardID == "j700" {
        let saved = raw.appending("neo-board-data"), address = "021122334455"
        let factory = try factoryBWC2(factoryOCATable()), calibration = try J700FactoryCalibration.generate(factory: factory, address: address)
        try write(factory, to: saved.appending("factory/BWC2-fixture"))
        for file in calibration { try write(file.data, to: saved.appending(file.name)) }
        for (name, input) in J700FirmwareCollectors.wifiAliases {
            try write(Data(name.utf8), to: raw.appending("neo-wifi/" + input))
        }
        let bluetooth = FirmwareFile(name: J700FirmwareCollectors.bluetoothName, data: Data("synthetic-bluetooth-not-an-Apple-binary".utf8))
        let camera = FirmwareFile(name: J700FirmwareCollectors.cameraName, data: j700Setfile(1))
        try write(bluetooth.data, to: saved.appending(bluetooth.name)); try write(camera.data, to: saved.appending(camera.name))
        try write(Data("synthetic-audio-tuning".utf8), to: saved.appending("audio/AID44/fixture.bin"))
        let metadata: [String: Any] = ["version": 1, "board": boardID, "wifi_address": address, "calibration_generated_locally": true,
            "factory_sha256": factory.sha256, "camera_sha256": camera.data.sha256, "bluetooth_sha256": bluetooth.data.sha256,
            "calibration": calibration.map { ["name": $0.name, "sha256": $0.data.sha256] }]
        try write(jsonData(metadata), to: saved.appending("metadata.json"))
        let package = try FirmwarePackage(expected)
        try package.add(J700FirmwareCollectors.wifi(raw.appending("neo-wifi"))); try package.add(calibration)
        try package.add([bluetooth, camera]); try package.add(Multitouch.files(raw.appending("fud_firmware"), requireTrackpadFor: boardID))
        try package.close()
        // The Linux test replaces only the Bluetooth release hash for this
        // explicit synthetic fixture. Production always enforces the real pin.
        try write(jsonData(["synthetic": true, "bluetooth_sha256": bluetooth.data.sha256]), to: root.appending("fixture.json"))
    } else {
        for (name, input) in J773gFirmwareCollectors.wifiAliases {
            let data = name.hasSuffix(".txt") ? Data("boardrev =0x14\nmacaddr=00:00:00:00:00:00\n".utf8) : Data("duplicate-wifi-data".utf8)
            try write(data, to: raw.appending("apple_bcmwlan_firmware/" + input))
        }
        for ext in ["bin", "ptb"] {
            try write(Data(("bluetooth-" + ext).utf8), to: raw.appending("firmware/bluetooth/BCM4388C2_23.5_PCIE_macOS_Willamette_Sakhalin_CLPC_3ANT_OS_AMKOR_20251203." + ext))
        }
        for kind in RadioKind.allCases {
            try RadioCalibration(kind: kind, address: "021122334455", data: Data(("BLOB-" + kind.rawValue).utf8), provenance: []).writeRaw(to: raw)
        }
        var kernel = Data("2214A_RCFG".utf8); kernel.append(Data(count: 0x2f - kernel.count)); kernel.appendLE(0x18000)
        kernel.append(Data(repeating: 0x42, count: 0x18000))
        try write(seq([ascii("IM4P"), ascii("krnl"), ascii("synthetic"), der(4, kernel)]), to: source.appending("kernelcache.fixture"))
    }
    let inputs = try fm.contentsOfDirectory(at: raw, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
    try FirmwareArchive.create(at: source.appending("all_firmware.tar.gz"), sources: inputs.map { FirmwareArchiveSource(source: $0, name: $0.lastPathComponent) }, commands: SystemCommands())
    if boardID == "j773g" {
        let recovery = root.appending("recovery"), factoryRoot = root.appending("factory")
        try copy(raw.appending("apple_bcmwlan_firmware"), recovery.appending("usr/share/firmware/wifi"))
        try copy(raw.appending("firmware/bluetooth"), recovery.appending("usr/share/firmware/bluetooth"))
        let records = try RadioKind.allCases.map { kind in
            seq([integer(try Data(kind.record.utf8).uint(0, 4)), ascii("synthetic"), der(4, Data(("BLOB-" + kind.rawValue).utf8))])
        }
        let payload = seq([integer(try Data("BWCl".utf8).uint(0, 4))] + records)
        try write(seq([ascii("IMG4"), seq([ascii("IM4P"), ascii("BWCl"), ascii("synthetic"), der(4, payload)])]),
                  to: factoryRoot.appending("BWCl-sakhalin-4388-C2-fixture"))
        let tree: [[String: Any]] = [["IORegistryEntryName": "chosen", "mac-address-wifi0": Data([2,17,34,51,68,85]), "mac-address-bluetooth0": Data([2,17,34,51,68,85])]]
        let board = BoardProfile(id: boardID, deviceClass: hardware.deviceClass, chipID: hardware.chipID,
            minimumMacOS: "26.5", restore: J773g.restore, firmwareMachine: boardID, firmware: J773gFirmware(factory: factoryRoot), presentation: J773g.profile.presentation)
        let context = FirmwareCollectionContext(recovery: recovery, fud: raw.appending("fud_firmware"),
            kernel: source.appending("kernelcache.fixture"), raw: raw, deviceTree: tree, hardware: hardware,
            resources: root, restore: root, restoreIdentity: [:])
        try FirmwarePipeline.collect(board: board, hardware: hardware, context: context, destination: expected,
            archive: source.appending("all_firmware.tar.gz"), commands: SystemCommands(), events: { _ in })
        let rebuilt = root.appending("rebuilt")
        try FirmwarePipeline.rebuild(source: source, destination: rebuilt, resources: root, boardID: boardID,
                                     registry: .builtIn, commands: SystemCommands(), events: { _ in })
        for name in ["manifest.txt", "firmware.tar", "firmware.cpio"] {
            #expect(try Data(contentsOf: expected.appending(name)) == Data(contentsOf: rebuilt.appending(name)))
        }
    }
}
