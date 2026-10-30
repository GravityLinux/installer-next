// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import Testing
@testable import GravityCore

private struct ResizeLimits: CommandRunning {
    let hard: Int64
    let preferred: Int64
    func run(_ executable: String, _ arguments: [String], input: Data?) throws -> Data {
        try require(executable == "/usr/sbin/diskutil" && arguments == ["apfs", "resizeContainer", "disk0s2", "limits", "-plist"], "Unexpected mutation while reading resize limits")
        return try PropertyListSerialization.data(fromPropertyList: ["MinimumSizeNoGuard": hard, "MinimumSizePreferred": preferred], format: .xml, options: 0)
    }
}
@Test func resizeLeavesTwoGBAndRespectsTheAPFSHardFloor() throws {
    let partition = DiskPartition(name: "disk0s2", offset: 0, size: 80_000_000_000, free: false, type: "Apple_APFS", uuid: "macOS",
        container: ["CapacityCeiling": Int64(80_000_000_000), "CapacityFree": Int64(20_000_000_000)])
    let margin = BoardStoragePolicy().macOSReserveBytes
    #expect(margin == 2_000_000_000)
    let available = try DiskManager(commands: ResizeLimits(hard: 60_000_000_000, preferred: 70_000_000_000)).maximumResize(partition, reserveBytes: margin)
    #expect(available == alignDown(80_000_000_000 - alignUp(62_000_000_000)))
    #expect(alignDown(partition.size - available) - 60_000_000_000 >= margin)
    #expect(try DiskManager(commands: ResizeLimits(hard: partition.size, preferred: partition.size)).maximumResize(partition, reserveBytes: margin) == 0)
}
@Test func allocationShrinksMacOSOnlyAfterUsingExistingSpace() {
    let existing = alignDown(80_000_000_000), extra = alignDown(10_000_000_000)
    var target = StorageTarget(id: "macOS", name: "Macintosh HD", kind: "resize", totalBytes: 80_000_000_000, freeBytes: 20_000_000_000, maximumBytes: existing + extra)
    target.existingFreeBytes = existing
    #expect(target.diagramTotalBytes == target.totalBytes + existing)
    #expect(target.boundedAllocation(0) == 0)
    #expect(target.shrinkBytes(for: existing) == 0)
    #expect(target.resizedMacOSBytes(for: existing) == nil)
    #expect(target.shrinkBytes(for: existing) == 0)
    #expect(target.shrinkBytes(for: existing + extra) == extra)
    #expect(target.resizedMacOSBytes(for: existing + extra) == alignDown(target.totalBytes - extra))
    #expect(target.shrinkBytes(for: existing - extra) == 0)
    #expect(target.resizedMacOSBytes(for: existing - extra) == nil)
    #expect(target.unusedBytes(for: existing - extra) == extra)
    #expect(target.unusedBytes(for: existing + extra) == 0)
    #expect(target.resizedMacOSBytes(for: 0) == nil)
    #expect(target.unusedBytes(for: 0) == existing)
    #expect(!target.canAllocate(0, minimumBytes: 30_000_000_000))
    #expect(target.canAllocate(alignDown(30_000_000_000), minimumBytes: 30_000_000_000))
    #expect(target.boundedAllocation(Int64.max) == target.maximumBytes)
}
