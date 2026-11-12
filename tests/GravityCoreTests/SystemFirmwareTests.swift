// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Testing
@testable import GravityCore

private final class FirmwareVersionCommands: CommandRunning, @unchecked Sendable {
    let data: Data?
    var calls = 0
    init(_ value: Any?) throws {
        data = try value.map { try PropertyListSerialization.data(fromPropertyList: ["ProductVersion": $0], format: .xml, options: 0) }
    }
    func run(_ executable: String, _ arguments: [String], input: Data?) throws -> Data {
        calls += 1
        #expect(executable == "/usr/bin/plutil")
        #expect(arguments == ["-convert", "xml1", "-o", "-", SystemFirmware.versionPath])
        #expect(input == nil)
        guard let data else { throw InstallerError("Firmware metadata is unreadable") }
        return data
    }
}

@Test(arguments: ["26.6.2", "26.6.3", "26.6.10", "26.7", "27.0"])
func systemFirmwareAcceptsRequiredAndNewerReleases(version: String) throws {
    let commands = try FirmwareVersionCommands(version)
    try SystemFirmware.validate(minimum: "26.6.2", commands: commands)
    #expect(commands.calls == 1)
}

@Test(arguments: ["26.5.9", "26.6", "26.6.0", "26.6.1"])
func oldSystemFirmwareRequiresUpdatingMacOS(version: String) throws {
    do {
        try SystemFirmware.validate(minimum: "26.6.2", commands: FirmwareVersionCommands(version))
        Issue.record("Old system firmware passed preflight")
    } catch let error as InstallerError {
        #expect(error.localizedDescription.contains("system firmware is \(version)"))
        #expect(error.localizedDescription.contains("26.6.2"))
        #expect(error.localizedDescription.contains("Update macOS"))
    }
}

@Test func missingUnreadableAndMalformedFirmwareCannotPassPreflight() throws {
    for value: Any? in [nil, 2662, "", "26", "26..6.2", "26.6.2.1", "26.6.2 beta", "iBoot-18000.161.10", "9999999999999999999999999999.0"] {
        do {
            try SystemFirmware.validate(minimum: "26.6.2", commands: FirmwareVersionCommands(value))
            Issue.record("Unknown or malformed system firmware passed preflight")
        } catch let error as InstallerError {
            #expect(error.localizedDescription.contains("Couldn’t verify"))
            #expect(error.localizedDescription.contains("Update macOS to 26.6.2 or later"))
        }
    }
}

@Test func firmwarePrerequisitesBelongToBoardProfiles() throws {
    for board in [J773g.profile, J700.profile] {
        #expect(board.minimumSystemFirmware == "26.6.2")
    }
    // A profile without a firmware prerequisite must not probe this source.
    let commands = try FirmwareVersionCommands(nil)
    try SystemFirmware.validate(minimum: nil, commands: commands)
    #expect(commands.calls == 0)
}
