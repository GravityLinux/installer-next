// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Testing
@testable import GravityCore

private let j700Hardware = HardwareIdentity(deviceClass: "j700ap", chipID: 0x8140, boardID: 0x64)
private struct HardwareProbe: CommandRunning {
    let hardware: HardwareIdentity
    func run(_ executable: String, _ arguments: [String], input: Data?) throws -> Data {
        try require(executable == "/usr/sbin/ioreg" && arguments == ["-alp", "IODeviceTree"], "Board preflight performed an unexpected operation")
        var chip = Data(), board = Data(); chip.appendLE(UInt64(hardware.chipID)); board.appendLE(UInt64(hardware.boardID))
        return try PropertyListSerialization.data(fromPropertyList: [["IORegistryEntryChildren": [
            ["IOObjectClass": "IOPlatformExpertDevice", "compatible": Data((hardware.deviceClass + "\0").utf8),
             "IORegistryEntryChildren": [["IORegistryEntryName": "chosen", "chip-id": chip, "board-id": board]]]
        ]]], format: .xml, options: 0)
    }
}

@Test func boardsAreGatedInTheSharedRegistryAndUseOnlyProductNumbers() throws {
    let registry = BoardRegistry.builtIn
    #expect(registry.availableProfiles().map(\.id) == ["j773g"])
    #expect(Set(registry.availableProfiles(developer: true).map(\.id)) == ["j700", "j773g"])
    do { _ = try registry.resolve(j700Hardware); Issue.record("Developer board was available without developer mode") }
    catch let error as BoardSupportError {
        #expect(error.reason == .developerRequired && error.productNumber == "j700")
        #expect(error.hardware == j700Hardware && error.supportedBoards == ["j773g"])
    }
    #expect(throws: BoardSupportError.self) { try registry.profile(id: "j700") }
    #expect(throws: BoardSupportError.self) { try registry.savedProfile(id: "j700", hardware: j700Hardware) }
    let board = try registry.resolve(j700Hardware, developer: true)
    #expect(board.presentation.productNumber == board.id)
    let data = try JSONEncoder().encode(board.presentation), json = try dict(JSONSerialization.jsonObject(with: data))
    #expect(string(json["productNumber"]) == "j700" && json["name"] == nil)
}

@Test func developerModeNeverAcceptsUnregisteredOrMismatchedHardware() throws {
    for hardware in [HardwareIdentity(deviceClass: "j999ap", chipID: 0x8140, boardID: 0x64),
                     HardwareIdentity(deviceClass: "j700ap", chipID: 0x8132, boardID: 0x64),
                     HardwareIdentity(deviceClass: "j700ap", chipID: 0x8140, boardID: 1)] {
        for developer in [false, true] {
            do { _ = try BoardRegistry.builtIn.resolve(hardware, developer: developer); Issue.record("Unknown hardware was accepted") }
            catch let error as BoardSupportError {
                #expect(error.reason == .unsupported && error.productNumber == hardware.productNumber)
                #expect(error.hardware == hardware && !error.supportedBoards.isEmpty)
                #expect(developer || !error.supportedBoards.contains("j700"))
            }
        }
    }
}

@Test func boardPreflightRejectsUnsupportedHardwareWithoutAuthorizationOrDiskAccess() async throws {
    let config = EngineConfiguration(resourceDirectory: URL(fileURLWithPath: "/unused")), unknown = HardwareIdentity(deviceClass: "j999ap", chipID: 0x8140, boardID: 0x64)
    let engine = InstallerEngine(configuration: config, commands: HardwareProbe(hardware: unknown))
    do { _ = try await engine.checkBoardSupport(); Issue.record("Unknown board passed preflight") }
    catch let error as BoardSupportError {
        #expect(error.reason == .unsupported && error.productNumber == "j999")
        #expect(try JSONDecoder().decode(BoardSupportError.self, from: JSONEncoder().encode(error)).reason == .unsupported)
    }
    let gated = InstallerEngine(configuration: config, commands: HardwareProbe(hardware: j700Hardware))
    do { _ = try await gated.checkBoardSupport(); Issue.record("Gated board passed preflight") }
    catch let error as BoardSupportError { #expect(error.reason == .developerRequired) }
    var developerConfig = config; developerConfig.developer = true
    let developer = InstallerEngine(configuration: developerConfig, commands: HardwareProbe(hardware: j700Hardware))
    #expect(try await developer.checkBoardSupport().productNumber == "j700")
}

@Test func recoveryPreservesExplicitDeveloperChoiceAndRejectsMissingChoice() throws {
    let temp = try TemporaryDirectory(), config = try stage2Fixture(temp)
    var record = try JSONDecoder().decode(Stage2Record.self, from: Data(contentsOf: config))
    record.boardProfileID = "j700"; record.hardware = j700Hardware
    try write(JSONEncoder().encode(record), to: config)
    #expect(throws: BoardSupportError.self) { try Stage2Context(config) }
    #expect(try Stage2Context(config, developer: true).board.id == "j700")
    record.developerMode = true; try write(JSONEncoder().encode(record), to: config)
    #expect(try Stage2Context(config).board.id == "j700")
    record.hardware = HardwareIdentity(deviceClass: "j773gap", chipID: 0x8132, boardID: 1)
    try write(JSONEncoder().encode(record), to: config)
    #expect(throws: (any Error).self) { try Stage2Context(config) }
}

@Test func firmwareRebuildCannotBypassDeveloperGateThroughSavedMetadata() async throws {
    let temp = try TemporaryDirectory(), source = temp.url.appending("source"), raw = temp.url.appending("raw"), destination = temp.url.appending("result")
    try mkdir(source)
    try write(JSONEncoder().encode(FirmwareArchiveInfo(version: 1, boardProfileID: "j700", hardware: j700Hardware)), to: raw.appending(FirmwareArchive.metadataName))
    _ = try SystemCommands().run("/usr/bin/tar", ["-czf", source.appending("all_firmware.tar.gz").path, "-C", raw.path, "."], input: nil)
    let engine = InstallerEngine(configuration: EngineConfiguration(resourceDirectory: temp.url, demo: true))
    do { try await engine.rebuildFirmware(source: source, destination: destination); Issue.record("Saved board metadata bypassed developer mode") }
    catch let error as BoardSupportError { #expect(error.reason == .developerRequired) }
    #expect(!fm.fileExists(atPath: destination.path))
}
