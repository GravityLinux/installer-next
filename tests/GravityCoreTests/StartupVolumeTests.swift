// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Testing
@testable import GravityCore

private final class StartupCommands: CommandRunning, @unchecked Sendable {
    let system: URL
    let group = "A1B2C3D4-1111-2222-3333-444444444444"
    let otherGroup = "99999999-1111-2222-3333-444444444444"
    var mountedGroup: String?, selectedGroup: String?
    var useGroupListing = false, groupMemberRole = "System", failBless = false
    var calls: [(String, [String], Data?)] = []
    var completed = false
    var observed: StartupVolume.Selection?
    init(_ system: URL) { self.system = system; mountedGroup = group; selectedGroup = group.lowercased() }
    var startup: StartupVolume { StartupVolume(system: system, group: group, name: "Gravity Linux") }
    func run(_ executable: String, _ arguments: [String], input: Data?) throws -> Data {
        calls.append((executable, arguments, input))
        if executable == "/usr/sbin/diskutil" && arguments == ["info", "-plist", system.path] {
            var info: [String: Any] = ["DeviceIdentifier": "disk17s2", "APFSContainerReference": "disk17"]
            if !useGroupListing, let mountedGroup { info["APFSVolumeGroupID"] = mountedGroup }
            return try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        }
        if executable == "/usr/sbin/diskutil" && arguments == ["apfs", "listVolumeGroups", "disk17", "-plist"] {
            return try PropertyListSerialization.data(fromPropertyList: ["Containers": [["VolumeGroups": [["APFSVolumeGroupUUID": mountedGroup ?? otherGroup,
                "Volumes": [["DeviceIdentifier": "disk17s2", "Role": groupMemberRole]]]]]]], format: .xml, options: 0)
        }
        if executable == "/usr/sbin/bless" {
            #expect(arguments == ["--setBoot", "--device", "/dev/disk17s2", "--user", "owner", "--stdinpass"])
            #expect(input == Data("test-password".utf8))
            #expect(fm.fileExists(atPath: system.appending("System/Library/CoreServices/SystemVersion.plist").path))
            if failBless { throw InstallerError("simulated bless failure") }
            return Data()
        }
        if executable == "/usr/sbin/nvram" && arguments == ["-xp"] {
            let nvram: [String: Any] = selectedGroup.map { ["boot-volume": Data(("container:store:\($0)\0").utf8)] } ?? [:]
            return try PropertyListSerialization.data(fromPropertyList: nvram, format: .xml, options: 0)
        }
        if executable == "/usr/bin/bputil" && arguments == ["-g", "-v", group] { return Data() }
        throw InstallerError("Unexpected startup command: \(executable) \(arguments)")
    }
    func prepare(recovery: Bool = false) throws -> StartupVolume.Selection {
        try startup.prepareRecovery(credentials: Credentials(username: "owner", password: "test-password"), recovery: recovery, commands: self,
            events: { if $0.step == .defaultBoot && $0.fraction == 1 { self.completed = true } }, selectionObserved: { self.observed = $0 })
    }
}

private func startupFixture(_ temp: TemporaryDirectory, disabled: Bool = false) throws -> StartupCommands {
    let system = temp.url.appending("Gravity Linux")
    try write(Data("system-version".utf8), to: system.appending("System/Library/CoreServices/SystemVersion\(disabled ? "-disabled" : "").plist"))
    try write(Data("installer-media".utf8), to: system.appending(disabled ? "IAPhysicalMedia-disabled.plist" : ".IAPhysicalMedia"))
    return StartupCommands(system)
}

@Test func firstStageUsesAsahiBlessArgumentsAndHidesMarkersOnlyAfterVerifiedSelection() throws {
    let temp = try TemporaryDirectory(), commands = try startupFixture(temp)
    let result = try commands.prepare()
    #expect(result.device == "disk17s2" && result.targetGroup == commands.group && result.selectedGroup == commands.group.lowercased())
    #expect(commands.calls.map(\.0) == ["/usr/sbin/diskutil", "/usr/sbin/bless", "/usr/sbin/nvram"])
    #expect(commands.completed)
    #expect(!fm.fileExists(atPath: commands.system.appending("System/Library/CoreServices/SystemVersion.plist").path))
    #expect(try Data(contentsOf: commands.system.appending("System/Library/CoreServices/SystemVersion-disabled.plist")) == Data("system-version".utf8))
    #expect(fm.fileExists(atPath: commands.system.appending(".IAPhysicalMedia").path))
    #expect(!commands.calls.contains { $0.0.hasSuffix("kmutil") || $0.1.first == "-nc" })
    #expect(!commands.calls.flatMap { $0.1 }.contains("test-password"))
}

@Test func recoveryRepairRestoresBlessMetadataAndThenInstallerMedia() throws {
    let temp = try TemporaryDirectory(), commands = try startupFixture(temp, disabled: true)
    _ = try commands.prepare(recovery: true)
    #expect(commands.calls.map(\.0) == ["/usr/sbin/diskutil", "/usr/bin/bputil", "/usr/sbin/bless", "/usr/sbin/nvram"])
    #expect(fm.fileExists(atPath: commands.system.appending(".IAPhysicalMedia").path))
    #expect(!fm.fileExists(atPath: commands.system.appending("IAPhysicalMedia-disabled.plist").path))
    #expect(fm.fileExists(atPath: commands.system.appending("System/Library/CoreServices/SystemVersion-disabled.plist").path))
}

@Test func successfulBlessWithWrongOrUnknownDefaultCannotReportReadyToReboot() throws {
    for selection: String? in [nil, "invalid", "99999999-1111-2222-3333-444444444444"] {
        let temp = try TemporaryDirectory(), commands = try startupFixture(temp)
        commands.selectedGroup = selection
        #expect(throws: (any Error).self) { try commands.prepare() }
        #expect(!commands.completed && commands.calls.count == 3)
        #expect(commands.observed?.selectedGroup == (selection ?? ""))
        #expect(fm.fileExists(atPath: commands.system.appending("System/Library/CoreServices/SystemVersion.plist").path))
        #expect(!fm.fileExists(atPath: commands.system.appending("System/Library/CoreServices/SystemVersion-disabled.plist").path))
    }
}

@Test func wrongMountedGroupAndMissingMarkersStopBeforeBless() throws {
    let temp = try TemporaryDirectory(), commands = try startupFixture(temp, disabled: true)
    commands.mountedGroup = commands.otherGroup
    #expect(throws: (any Error).self) { try commands.prepare() }
    #expect(commands.calls.count == 1 && !commands.completed)
    #expect(!fm.fileExists(atPath: commands.system.appending("System/Library/CoreServices/SystemVersion.plist").path))
    let missing = StartupCommands(temp.url.appending("missing"))
    #expect(throws: (any Error).self) { try missing.prepare() }
    #expect(missing.calls.isEmpty)
}

@Test func blessFailureKeepsSystemVersionVisibleAndDoesNotReadOrClaimDefaultSelection() throws {
    let temp = try TemporaryDirectory(), commands = try startupFixture(temp, disabled: true)
    commands.failBless = true
    #expect(throws: (any Error).self) { try commands.prepare() }
    #expect(commands.calls.count == 2 && !commands.completed)
    #expect(fm.fileExists(atPath: commands.system.appending("System/Library/CoreServices/SystemVersion.plist").path))
}

@Test func startupGroupCanBeVerifiedFromTheContainerListing() throws {
    let temp = try TemporaryDirectory(), commands = try startupFixture(temp)
    commands.useGroupListing = true
    #expect(try commands.prepare().targetGroup == commands.group)
    #expect(commands.calls.count == 4 && commands.completed)
    let wrongTemp = try TemporaryDirectory(), wrong = try startupFixture(wrongTemp)
    wrong.useGroupListing = true; wrong.groupMemberRole = "Data"
    #expect(throws: (any Error).self) { try wrong.prepare() }
    #expect(wrong.calls.count == 2 && !wrong.completed)
}

@Test func bootVolumeParsingHandlesTheNVRAMDataAndStringRepresentations() {
    let group = "A1B2C3D4-1111-2222-3333-444444444444"
    #expect(StartupVolume.defaultGroup(in: ["boot-volume": Data(("container:store:\(group)\0ignored").utf8)]) == group)
    #expect(StartupVolume.defaultGroup(in: ["boot-volume": "container:store:\(group)"]) == group)
    #expect(StartupVolume.defaultGroup(in: [:]).isEmpty)
    #expect(StartupVolume.defaultGroup(in: ["boot-volume": "invalid"]).isEmpty)
}
