// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Testing
@testable import GravityCore

private final class GapCommands: CommandRunning {
    struct Part {
        let name: String, type: String, uuid: String
        let offset: Int64, size: Int64
    }
    let macOS = Part(name: "disk0s2", type: "Apple_APFS", uuid: "macOS", offset: 1_048_576, size: 40_000_000_000)
    var parts: [Part] = []
    var mutations: [[String]] = []
    var failStartup = false
    var replaceSpacerOnFailure = false
    init() { parts = [macOS] }
    func run(_ executable: String, _ arguments: [String], input: Data?) throws -> Data {
        try require(executable == "/usr/sbin/diskutil", "Unexpected command")
        let object: [String: Any]
        switch arguments.first {
        case "addPartition":
            mutations.append(arguments)
            if arguments[2] == "apfs" && failStartup {
                if replaceSpacerOnFailure, let spacer = parts.last {
                    parts[parts.count-1] = Part(name: spacer.name, type: spacer.type, uuid: "foreign", offset: spacer.offset, size: spacer.size)
                }
                throw InstallerError("Simulated startup creation failure")
            }
            let previous = try #require(parts.first { $0.name == arguments[1] })
            parts.append(Part(name: "disk0s\(parts.count+2)", type: arguments[2] == "apfs" ? "Apple_APFS" : "Linux Filesystem", uuid: UUID().uuidString,
                offset: previous.offset + previous.size, size: try #require(Int64(arguments[4]))))
            return Data()
        case "eraseVolume":
            mutations.append(arguments)
            try require(arguments.prefix(3) == ["eraseVolume", "free", "none"], "Unexpected erase")
            parts.removeAll { $0.name == arguments.last }
            return Data()
        case "list":
            object = ["WholeDisks": ["disk0"], "AllDisksAndPartitions": [["DeviceIdentifier": "disk0", "Size": Int64(80_000_000_000), "Partitions": parts.map { ["DeviceIdentifier": $0.name] }]]]
        case "info":
            if arguments.last == "disk0" { object = ["Internal": true, "VirtualOrPhysical": "Physical"] }
            else {
                let part = try #require(parts.first { $0.name == arguments.last })
                object = ["DeviceIdentifier": part.name, "Content": part.type, "DiskUUID": part.uuid, "PartitionMapPartitionOffset": part.offset, "Size": part.size]
            }
        case "apfs": object = ["Containers": []]
        default: throw InstallerError("Unexpected disk command")
        }
        return try PropertyListSerialization.data(fromPropertyList: object, format: .xml, options: 0)
    }
}

@Test func startupCanBePlacedAfterAnUnallocatedGapWithoutChangingMacOS() throws {
    let commands = GapCommands(), disk = DiskManager(commands: commands)
    try disk.refresh()
    let gap = alignDown(10_000_000_000), size = alignDown(3_000_000_000)
    let startup = try disk.addPartition(after: "disk0s2", type: "apfs", label: "Gravity Linux", size: size, disk: "disk0", leavingFreeBefore: gap)
    #expect(startup.offset == commands.macOS.offset + commands.macOS.size + gap)
    #expect(startup.size == size && commands.parts.count == 2)
    #expect(commands.parts[0].uuid == "macOS" && commands.parts[0].size == commands.macOS.size)
    #expect(try disk.partitions("disk0").contains { $0.free && $0.name == "disk0s2" && $0.size == gap })
    #expect(commands.mutations.count == 3)
    #expect(commands.mutations.last == ["eraseVolume", "free", "none", "disk0s3"])
    #expect(!commands.mutations.contains { $0.first == "apfs" })
}

@Test func failedStartupReleasesOnlyItsOwnEmptyReservation() throws {
    for replace in [false, true] {
        let commands = GapCommands(), disk = DiskManager(commands: commands)
        commands.failStartup = true; commands.replaceSpacerOnFailure = replace
        try disk.refresh()
        #expect(throws: (any Error).self) { try disk.addPartition(after: "disk0s2", type: "apfs", label: "Gravity Linux", size: alignDown(3_000_000_000), disk: "disk0", leavingFreeBefore: alignDown(10_000_000_000)) }
        #expect(commands.parts[0].uuid == "macOS" && commands.parts[0].size == commands.macOS.size)
        if replace {
            #expect(commands.parts.last?.uuid == "foreign")
            #expect(!commands.mutations.contains { $0.first == "eraseVolume" })
        } else {
            #expect(commands.parts.count == 1)
            #expect(commands.mutations.last == ["eraseVolume", "free", "none", "disk0s3"])
        }
    }
}

@Test func oversizedGapIsRejectedBeforeChangingTheDisk() throws {
    let commands = GapCommands(), disk = DiskManager(commands: commands)
    try disk.refresh()
    #expect(throws: (any Error).self) { try disk.addPartition(after: "disk0s2", type: "apfs", label: "Gravity Linux", size: alignDown(3_000_000_000), disk: "disk0", leavingFreeBefore: alignDown(40_000_000_000)) }
    #expect(commands.mutations.isEmpty)
}
