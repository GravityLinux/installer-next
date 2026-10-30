// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Testing
@testable import GravityCore

private struct UnusedFirmware: BoardFirmwareLoading {
    func validateRecovery(_ context: FirmwareValidationContext, events: EventSink) throws { throw InstallerError("Planning touched firmware") }
    func collect(_ context: FirmwareCollectionContext, into package: FirmwarePackage, events: EventSink) throws -> [FirmwareArchiveSource] { throw InstallerError("Planning touched firmware") }
    func rebuild(_ context: FirmwareRebuildContext, into package: FirmwarePackage, events: EventSink) throws { throw InstallerError("Planning touched firmware") }
}
private final class ReadOnlyInspectionCommands: CommandRunning, @unchecked Sendable {
    let root: URL
    let group = "00000000-1111-2222-3333-444444444444"
    var calls: [(String, [String])] = []
    var capacityFree: Int64 = 200_000_000_000
    init(root: URL) { self.root = root }
    func run(_ executable: String, _ arguments: [String], input: Data?) throws -> Data {
        calls.append((executable, arguments))
        var chip = Data(), board = Data(); chip.appendLE(0xf001); board.appendLE(1)
        var value: [String: Any] = [:]
        if executable.hasSuffix("ioreg") {
            value = ["IORegistryEntryChildren": [["IOObjectClass": "IOPlatformExpertDevice", "compatible": Data("testreadonlyap\0".utf8),
                "IORegistryEntryChildren": [["IORegistryEntryName": "chosen", "chip-id": chip, "board-id": board, "boot-uuid": Data(group.utf8)],
                    ["IORegistryEntryName": "product", "product-name": Data("Test Mac".utf8)]]]]]
        } else if executable.hasSuffix("nvram") { value = ["boot-volume": "a:b:" + group] }
        else if executable.hasSuffix("scutil") { return Data("kCGSSessionUserNameKey : testadmin\n".utf8) }
        else if executable.hasSuffix("diskutil") {
            let system: [String: Any] = ["DeviceIdentifier": "disk3s1", "Name": "Macintosh HD", "Roles": ["System"]]
            let data: [String: Any] = ["DeviceIdentifier": "disk3s2", "Name": "Data", "Roles": ["Data"]]
            let preboot: [String: Any] = ["DeviceIdentifier": "disk3s3", "APFSVolumeUUID": UUID().uuidString, "Roles": ["Preboot"]]
            let recovery: [String: Any] = ["DeviceIdentifier": "disk3s4", "APFSVolumeUUID": UUID().uuidString, "Roles": ["Recovery"]]
            switch arguments {
            case ["list", "-plist"]:
                value = ["WholeDisks": ["disk0"], "AllDisksAndPartitions": [["DeviceIdentifier": "disk0", "Size": 510_000_000_000,
                    "Partitions": [["DeviceIdentifier": "disk0s1", "Content": "Apple_APFS_ISC"], ["DeviceIdentifier": "disk0s2", "Content": "Apple_APFS"]]]]]
            case ["apfs", "list", "-plist"]:
                value = ["Containers": [["ContainerReference": "disk3", "DesignatedPhysicalStore": "disk0s2", "CapacityCeiling": 500_000_000_000,
                    "CapacityFree": capacityFree, "Volumes": [system, data, preboot, recovery]]]]
            case ["apfs", "listVolumeGroups", "disk3", "-plist"]:
                value = ["Containers": [["VolumeGroups": [["APFSVolumeGroupUUID": group, "Volumes": [["DeviceIdentifier": "disk3s1", "Role": "System"], ["DeviceIdentifier": "disk3s2", "Role": "Data"]]]]]]]
            case ["apfs", "resizeContainer", "disk0s2", "limits", "-plist"]: value = ["MinimumSizeNoGuard": 300_000_000_000, "MinimumSizePreferred": 350_000_000_000]
            case ["info", "-plist", "/"]: value = ["APFSSnapshot": true, "APFSVolumeGroupID": group]
            case ["info", "-plist", "disk0"]: value = ["Internal": true, "VirtualOrPhysical": "Physical", "Content": "GUID_partition_scheme"]
            case ["info", "-plist", "disk0s1"]: value = ["DeviceIdentifier": "disk0s1", "PartitionMapPartitionOffset": 20480, "Size": 500_000_000, "Content": "Apple_APFS_ISC", "DiskUUID": "isc"]
            case ["info", "-plist", "disk0s2"]: value = ["DeviceIdentifier": "disk0s2", "PartitionMapPartitionOffset": 500_020_480, "Size": 500_000_000_000, "Content": "Apple_APFS", "DiskUUID": "macos"]
            case ["info", "-plist", "disk3s1"]: value = ["MountPoint": root.appending("System").path]
            case ["info", "-plist", "disk3s2"]: value = ["MountPoint": root.appending("Data").path]
            case ["info", "-plist", "disk3s3"]: value = ["MountPoint": root.appending("Preboot").path]
            case ["info", "-plist", "disk3s4"]: value = [:]
            default: throw InstallerError("Read-only inspection attempted disk action: \(arguments)")
            }
        } else { throw InstallerError("Read-only inspection attempted privileged command: \(executable)") }
        return try PropertyListSerialization.data(fromPropertyList: value, format: .xml, options: 0)
    }
}
@Test func inspectionAndReviewNeverMountVolumesOrReadBootPolicy() async throws {
    let temp = try TemporaryDirectory(), commands = ReadOnlyInspectionCommands(root: temp.url)
    try mkdir(temp.url.appending("System/Library")); try mkdir(temp.url.appending("Data"))
    try writePlist(["ProductVersion": "1.0"], temp.url.appending("System/System/Library/CoreServices/SystemVersion.plist"))
    try writePlist(["testadmin": [:]], temp.url.appending("Preboot/\(commands.group)/var/db/AdminUserRecoveryInfo.plist"))
    let profile = BoardProfile(id: "testreadonly", deviceClass: "testreadonlyap", chipID: 0xf001, minimumMacOS: "1.0",
        restore: RestoreProfile(version: "1.0", url: URL(fileURLWithPath: "/unused.ipsw"), member: "unused.dmg", decodedSHA256: String(repeating: "0", count: 64), encoding: .dmg),
        firmwareMachine: "testreadonly", firmware: UnusedFirmware(), presentation: BoardPresentation(status: "Test", notes: "", powerButtonHelp: ""))
    let catalog = temp.url.appending("images.json")
    var config = EngineConfiguration(resourceDirectory: temp.url, catalogURL: catalog); config.developer = true
    let engine = InstallerEngine(configuration: config, commands: commands, boards: try BoardRegistry(profiles: [profile]))
    let info = try await engine.inspect(), target = try #require(info.targets.first)
    #expect(info.administrator == "testadmin" && info.software.isEmpty)
    #expect(!fm.fileExists(atPath: catalog.path)) // Startup cannot have queried this missing source.
    try write(Data("{\"os_list\":[]}".utf8), to: catalog)
    let choices = try await engine.availableSoftware()
    #expect(info.macOSReserveBytes == 2_000_000_000)
    #expect(target.unallocatedBytes > 0 && info.targets.count == 1)
    let plan = try await engine.plan(InstallSelection(targetID: target.id, softwareID: choices[0].id, bytes: target.unallocatedBytes))
    #expect(plan.fingerprint != nil && plan.software.mode == .bootloader)
    #expect(plan.macOSAfterBytes == nil && plan.changes.first == "Use existing unallocated space")
    let extra = alignDown(5_000_000_000)
    let larger = try await engine.plan(InstallSelection(targetID: target.id, softwareID: choices[0].id, bytes: target.unallocatedBytes + extra))
    #expect(larger.macOSAfterBytes == alignDown(target.totalBytes - extra))
    let smaller = try await engine.plan(InstallSelection(targetID: target.id, softwareID: choices[0].id, bytes: target.unallocatedBytes - 1_048_576))
    #expect(smaller.macOSAfterBytes == alignDown(target.totalBytes + 1_048_576))
    #expect(smaller.changes.first?.hasPrefix("Grow Macintosh HD") == true)
    await #expect(throws: (any Error).self) { try await engine.plan(InstallSelection(targetID: target.id, softwareID: choices[0].id, bytes: 0)) }
    #expect(!commands.calls.contains { $0.0.hasSuffix("bputil") || $0.1.first == "mount" })
    commands.capacityFree = 5_000_000_000
    let smallerMargin = try await engine.inspect()
    let shrinkable = try #require(smallerMargin.targets.first { $0.kind == "resize" })
    #expect(shrinkable.maximumBytes > shrinkable.unallocatedBytes)
    commands.capacityFree = 1_000_000_000
    let constrained = try await engine.inspect()
    let resize = try #require(constrained.targets.first { $0.kind == "resize" })
    #expect(resize.maximumBytes == resize.unallocatedBytes && resize.unavailableReason == nil)
}
