// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Testing
@testable import GravityCore

/// This deliberately fictitious board is registered only in these tests. Adding
/// it exercises the same extension points a production board definition uses.
private final class FixtureFirmwareState: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func record(_ value: String) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    var calls: [String] { lock.lock(); defer { lock.unlock() }; return values }
}
private struct FixtureFirmware: BoardFirmwareLoading {
    let state: FixtureFirmwareState
    func validateRecovery(_ context: FirmwareValidationContext, events: EventSink) throws {
        state.record("validate")
        _ = try Data(contentsOf: context.recovery.appending("fixture-radio.bin"))
    }
    func collect(_ context: FirmwareCollectionContext, into package: FirmwarePackage, events: EventSink) throws -> [FirmwareArchiveSource] {
        state.record("collect")
        let data = try Data(contentsOf: context.recovery.appending("fixture-radio.bin"))
        // Neither this pathname nor this board's loader is known by core code.
        try package.add(FirmwareFile(name: "fixture/radio.fw", data: data, includeInBootloader: true))
        events(InstallEvent(.boardFirmware, help: "Collecting the fixture board’s own firmware.", title: "Extracting fixture firmware"))
        try write(data, to: context.raw.appending("fixture-saved/radio.bin"))
        return [FirmwareArchiveSource(source: context.raw.appending("fixture-saved"), name: "fixture-extra")]
    }
    func rebuild(_ context: FirmwareRebuildContext, into package: FirmwarePackage, events: EventSink) throws {
        state.record("rebuild")
        let data = try Data(contentsOf: context.raw.appending("fixture-extra/radio.bin"))
        try package.add(FirmwareFile(name: "fixture/radio.fw", data: data, includeInBootloader: true))
    }
}
private let fixtureHardware = HardwareIdentity(deviceClass: "fixtureboardap", chipID: 0xf00d, boardID: 0x12)
private func fixtureBoard(state: FixtureFirmwareState = FixtureFirmwareState(), id: String = "fixture-board", boardIDs: Set<Int64>? = [0x12], digest: String = Data("qualified fixture image".utf8).sha256) -> BoardProfile {
    BoardProfile(id: id, deviceClass: fixtureHardware.deviceClass, chipID: fixtureHardware.chipID, boardIDs: boardIDs,
        minimumMacOS: "1.0", restore: RestoreProfile(version: "1.2.3", url: URL(fileURLWithPath: "/fixture.ipsw"), member: "fixture.dmg",
            decodedSHA256: digest, encoding: .dmg, variant: "Fixture Customer", restoreBundleFallback: "fixture-restore"),
        firmwareMachine: "fixture", firmware: FixtureFirmware(state: state),
        boot: BoardBootAssets(directory: "fixture/assets", stage1: "fixture.bin", registration: BootRegistration(alignment: 16384, entryPoint: 12288, lowestVirtualAddress: 8192)),
        storage: BoardStoragePolicy(stubBytes: 3_000_000_000, macOSReserveBytes: 48_000_000_000, minimumLinuxBytes: 36_000_000_000),
        presentation: BoardPresentation(status: "Test only", notes: "Synthetic board", powerButtonHelp: "Fixture power instructions"))
}

@Test func registryRejectsUnknownHardwareAndAmbiguousRegistrations() throws {
    let board = fixtureBoard(), registry = try BoardRegistry(profiles: BoardRegistry.builtIn.profiles + [board])
    #expect(try registry.resolve(fixtureHardware).id == board.id)
    #expect(try registry.resolve(HardwareIdentity(deviceClass: "j773gap", chipID: 0x8132, boardID: 1)).id == "j773g")
    for hardware in [HardwareIdentity(deviceClass: "anotherboardap", chipID: 0xf00d, boardID: 0x12),
                     HardwareIdentity(deviceClass: fixtureHardware.deviceClass, chipID: 0x8132, boardID: 0x12),
                     HardwareIdentity(deviceClass: fixtureHardware.deviceClass, chipID: 0xf00d, boardID: 0x13)] {
        #expect(throws: (any Error).self) { try registry.resolve(hardware) }
    }
    #expect(throws: (any Error).self) { try BoardRegistry(profiles: [board, board]) }
    #expect(throws: (any Error).self) { try BoardRegistry(profiles: [board, fixtureBoard(id: "overlap", boardIDs: nil)]) }
    let disjoint = try BoardRegistry(profiles: [board, fixtureBoard(id: "another-revision", boardIDs: [0x13])])
    #expect(try disjoint.resolve(HardwareIdentity(deviceClass: fixtureHardware.deviceClass, chipID: 0xf00d, boardID: 0x13)).id == "another-revision")
    #expect(Set(BoardRegistry.builtIn.profiles.map(\.id)) == ["j773g", "j700"])
}
@Test func catalogScopingAndStoragePolicyComeFromBoard() throws {
    func template(_ fields: String) throws -> SoftwareTemplate {
        try JSONDecoder().decode(SoftwareTemplate.self, from: Data("{\"name\":\"Test Linux\",\"default_os_name\":\"Gravity\",\"boot_object\":\"fixture.bin\",\"partitions\":[{\"name\":\"Linux\",\"type\":\"Linux\",\"size\":\"5GB\",\"expand\":true}]\(fields)}".utf8))
    }
    let board = fixtureBoard(), legacy = try template("")
    #expect(legacy.supports(J773g.profile))
    #expect(!legacy.supports(board))
    #expect(try template(",\"supported_boards\":[\"fixture-board\"]").supports(board))
    #expect(try !template(",\"supported_boards\":[\"j773g\"]").supports(board))
    #expect(try template(",\"supported_devices\":[\"fixtureboardap\"],\"supported_fw\":[\"1.2.3\"]").supports(board))
    #expect(try !template(",\"supported_devices\":[\"fixtureboardap\"],\"supported_fw\":[\"26.6.2\"]").supports(board))
    #expect(try legacy.software(id: "fixture", storage: board.storage).minimumBytes == 36_000_000_000)
    #expect(try board.boot.resource(board.boot.stage1, in: URL(fileURLWithPath: "/resources")).path == "/resources/boot/fixture/assets/fixture.bin")
    #expect(try BootObject.build(Data("boot".utf8), variables: [], alignment: board.boot.registration.alignment).count == 16384)
}
@Test func restoreIdentitySelectionUsesBoardChipAndDevice() throws {
    let board = fixtureBoard()
    let identity: [String: Any] = ["ApBoardID": "0x12", "ApChipID": "0xF00D", "Info": ["DeviceClass": "fixtureboardap", "RestoreBehavior": "Erase", "Variant": "Fixture Customer"]]
    #expect(try board.restore.selectIdentity(in: ["BuildIdentities": [identity]], hardware: fixtureHardware)["ApBoardID"] as? String == "0x12")
    #expect(throws: (any Error).self) { try board.restore.selectIdentity(in: ["BuildIdentities": [identity]], hardware: HardwareIdentity(deviceClass: "fixtureboardap", chipID: 0xf00d, boardID: 0x13)) }
    #expect(throws: (any Error).self) { try board.restore.selectIdentity(in: ["BuildIdentities": [identity, identity]], hardware: fixtureHardware) }
    #expect(try board.restore.restoreBundlePath(bootcaches: [:]) == "fixture-restore")
    #expect(try board.restore.restoreBundlePath(bootcaches: ["bless2": ["RestoreBundlePath": "declared"]]) == "declared")
}
private final class FixtureRecoveryCommands: CommandRunning, @unchecked Sendable {
    var attached = false
    func run(_ executable: String, _ arguments: [String], input: Data?) throws -> Data {
        if executable.hasSuffix("hdiutil") && arguments.first == "attach" {
            let index = try #require(arguments.firstIndex(of: "-mountpoint"))
            let mount = URL(fileURLWithPath: arguments[index + 1]); attached = true
            try writePlist(["ProductVersion": "1.2.3"], mount.appending("System/Library/CoreServices/SystemVersion.plist"))
            try write(Data("fixture radio".utf8), to: mount.appending("fixture-radio.bin"))
        }
        return Data()
    }
}
@Test func anotherBoardQualifiesDMGWithoutM4FirmwareChecks() throws {
    let temp = try TemporaryDirectory(), zip = temp.url.appending("fixture.ipsw"), state = FixtureFirmwareState()
    let bytes = Data("qualified fixture image".utf8), board = fixtureBoard(state: state)
    try storedZIP(name: "fixture.dmg", data: bytes).write(to: zip)
    let commands = FixtureRecoveryCommands()
    let image = try RecoveryImage(archive: ZIPArchive(zip), member: board.restore.member, profile: board.restore, commands: commands, validateFirmware: { try board.firmware.validateRecovery(FirmwareValidationContext(recovery: $0, hardware: fixtureHardware, resources: temp.url), events: { _ in }) }, events: { _ in })
    #expect(try Data(contentsOf: image.url) == bytes && state.calls == ["validate"])
    let wrong = fixtureBoard(digest: Data("different image".utf8).sha256), rejected = FixtureRecoveryCommands()
    #expect(throws: (any Error).self) { try RecoveryImage(archive: ZIPArchive(zip), member: wrong.restore.member, profile: wrong.restore, commands: rejected, validateFirmware: { try wrong.firmware.validateRecovery(FirmwareValidationContext(recovery: $0, hardware: fixtureHardware, resources: temp.url), events: { _ in }) }, events: { _ in }) }
    #expect(!rejected.attached)
}
@Test func anotherBoardCollectsAndRebuildsThroughSharedPipeline() async throws {
    let temp = try TemporaryDirectory(), state = FixtureFirmwareState(), board = fixtureBoard(state: state)
    let registry = try BoardRegistry(profiles: [J773g.profile, board], legacyProfileID: J773g.profile.id)
    let recovery = temp.url.appending("recovery"), fud = temp.url.appending("fud"), raw = temp.url.appending("raw"), source = temp.url.appending("source")
    try mkdir(fud); try mkdir(source); try write(Data("fixture radio".utf8), to: recovery.appending("fixture-radio.bin"))
    let archive = source.appending("all_firmware.tar.gz"), output = temp.url.appending("collected")
    let progress = FixtureFirmwareState()
    try FirmwarePipeline.collect(board: board, hardware: fixtureHardware, context: FirmwareCollectionContext(recovery: recovery, fud: fud, kernel: nil, raw: raw, deviceTree: [:], hardware: fixtureHardware, resources: temp.url, restore: temp.url, restoreIdentity: [:]), destination: output, archive: archive, commands: SystemCommands(), events: { progress.record("\($0.step.rawValue)|\($0.title)|\($0.help)") })
    #expect(progress.calls.contains("boardFirmware|Extracting fixture firmware|Collecting the fixture board’s own firmware."))
    #expect(try Data(contentsOf: output.appending("u-boot/fixture/radio.fw")) == Data("fixture radio".utf8))
    let engine = InstallerEngine(configuration: EngineConfiguration(resourceDirectory: temp.url, demo: true), boards: registry)
    let rebuilt = temp.url.appending("rebuilt")
    try await engine.rebuildFirmware(source: source, destination: rebuilt)
    #expect(state.calls == ["collect", "rebuild"])
    for name in ["manifest.txt", "firmware.cpio", "firmware.tar", "u-boot/fixture/radio.fw"] {
        #expect(try Data(contentsOf: output.appending(name)) == Data(contentsOf: rebuilt.appending(name)))
    }
    do { try await engine.rebuildFirmware(source: source, destination: temp.url.appending("wrong"), boardID: "j773g"); Issue.record("Cross-board firmware rebuild accepted") } catch {}
    #expect(state.calls == ["collect", "rebuild"])
}
@Test func archiveInputsWithSameBasenameStaySeparate() throws {
    let temp = try TemporaryDirectory(), first = temp.url.appending("a/firmware"), second = temp.url.appending("b/firmware")
    try write(Data("one".utf8), to: first.appending("first.bin")); try write(Data("two".utf8), to: second.appending("second.bin"))
    let archive = temp.url.appending("all_firmware.tar.gz"), dest = temp.url.appending("unpacked"); try mkdir(dest)
    try FirmwareArchive.create(at: archive, sources: [FirmwareArchiveSource(source: first, name: "firmware"), FirmwareArchiveSource(source: second, name: "board-specific")], commands: SystemCommands())
    _ = try SystemCommands().run("/usr/bin/tar", ["-xf", archive.path, "-C", dest.path], input: nil)
    #expect(try String(contentsOf: dest.appending("firmware/first.bin")) == "one")
    #expect(try String(contentsOf: dest.appending("board-specific/second.bin")) == "two")
}
@Test func anotherBoardUsesItsSavedRegistrationInStage2() throws {
    let temp = try TemporaryDirectory(), config = try stage2Fixture(temp), board = fixtureBoard(), registry = try BoardRegistry(profiles: [board])
    var record = try JSONDecoder().decode(Stage2Record.self, from: Data(contentsOf: config))
    record.boardProfileID = board.id; record.hardware = fixtureHardware
    try write(JSONEncoder().encode(record), to: config)
    let commands = CommandSpy(policy: "Current OS environment: one true recoveryOS\nPairing: Paired\n")
    let context = try Stage2Context(config, boards: registry)
    try context.finalize(commands: commands, credentials: Credentials(username: "fixture", password: "fixture"), events: { _ in })
    let registration = try #require(commands.calls.first { $0.0.hasSuffix("kmutil") })
    #expect(registration.1 == board.boot.registration.arguments(bootObject: context.resources.appending("boot.bin"), system: context.system))
    #expect(registration.1.contains("12288") && registration.1.contains("8192"))
    record.boardProfileID = "unknown"; try write(JSONEncoder().encode(record), to: config)
    #expect(throws: (any Error).self) { try Stage2Context(config, boards: registry) }
}
@Test func savedProfilesAndLegacyMappingFailClosed() throws {
    let registry = BoardRegistry.builtIn
    #expect(try registry.savedProfile(id: nil).id == "j773g")
    #expect(throws: (any Error).self) { try registry.savedProfile(id: "unknown") }
    #expect(throws: (any Error).self) { try registry.savedProfile(id: "j773g", hardware: fixtureHardware) }
    #expect(throws: (any Error).self) { try BoardRegistry(profiles: [fixtureBoard()]).savedProfile(id: nil) }
}
@Test func clientsReceiveBoardPresentationWithoutModelBranches() async throws {
    let board = fixtureBoard(), registry = try BoardRegistry(profiles: [board])
    let engine = InstallerEngine(configuration: EngineConfiguration(resourceDirectory: URL(fileURLWithPath: "/fixture"), demo: true), boards: registry)
    let info = try await engine.inspect(), stage2 = try await engine.stage2Status()
    #expect(info.boardProfileID == board.id && info.board?.productNumber == board.id)
    #expect(info.macOSReserveBytes == 48_000_000_000 && info.software.first?.minimumBytes == 36_000_000_000)
    #expect(stage2.board?.powerButtonHelp == "Fixture power instructions")
}

@Test func legacyM4FirmwareArchiveStillRebuildsWithTheSameOutputs() async throws {
    let temp = try TemporaryDirectory(), source = temp.url.appending("source"), raw = temp.url.appending("raw"), wifi = raw.appending("apple_bcmwlan_firmware"), bluetooth = raw.appending("firmware/bluetooth")
    try mkdir(source); try mkdir(raw.appending("fud_firmware"))
    for (name, path) in J773gFirmwareCollectors.wifiAliases {
        try write(Data((name.hasSuffix(".txt") ? "boardrev =0x14\n" : name).utf8), to: wifi.appending(path))
    }
    for ext in ["bin", "ptb"] { try write(Data(("radio " + ext).utf8), to: bluetooth.appending("BCM4388C2_fixture_PCIE_macOS_Willamette_Sakhalin_CLPC_3ANT_OS_AMKOR_fixture.\(ext)")) }
    let calibration = RadioCalibration(kind: .bluetooth, address: "021122334455", data: Data("BLOB-fixture".utf8), provenance: [])
    try calibration.writeRaw(to: raw)
    var kernel = Data("2214A_RCFG".utf8); kernel.append(Data(count: 0x2f - kernel.count)); kernel.appendLE(0x18000); kernel.append(Data(repeating: 0x42, count: 0x18000))
    try write(seq([ascii("IM4P"), ascii("krnl"), ascii("synthetic"), der(4, kernel)]), to: source.appending("kernelcache.fixture"))
    _ = try SystemCommands().run("/usr/bin/tar", ["-czf", source.appending("all_firmware.tar.gz").path, "-C", raw.path, "."], input: nil)
    let output = temp.url.appending("output"), engine = InstallerEngine(configuration: EngineConfiguration(resourceDirectory: temp.url, demo: true))
    try await engine.rebuildFirmware(source: source, destination: output)
    let expected = try J773gFirmwareCollectors.wifi(wifi) + J773gFirmwareCollectors.bluetooth(bluetooth) + [calibration.file] + J773gFirmwareCollectors.kernel(source.appending("kernelcache.fixture"))
    let unpacked = temp.url.appending("unpacked"); try mkdir(unpacked)
    _ = try SystemCommands().run("/usr/bin/tar", ["-xf", output.appending("firmware.tar").path, "-C", unpacked.path], input: nil)
    for file in expected { #expect(try Data(contentsOf: unpacked.appending(file.name)) == file.data) }
    #expect(try Data(contentsOf: output.appending("u-boot/" + calibration.file.name)) == calibration.data)
    #expect(try Data(contentsOf: output.appending("u-boot/asmedia/asm2214a-apple.bin")) == Data(repeating: 0x42, count: 0x18000))
}
