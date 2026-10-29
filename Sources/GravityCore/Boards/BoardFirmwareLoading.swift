// SPDX-License-Identifier: GPL-2.0-only
import Foundation

public struct FirmwareValidationContext {
    public let recovery: URL
    public let hardware: HardwareIdentity
    public let resources: URL
    public let commands: any CommandRunning
    public let deviceTree: Any?
    public init(recovery: URL, hardware: HardwareIdentity, resources: URL, deviceTree: Any? = nil, commands: any CommandRunning = SystemCommands()) {
        self.recovery = recovery; self.hardware = hardware; self.resources = resources; self.deviceTree = deviceTree; self.commands = commands
    }
}
public struct FirmwareCollectionContext {
    public let recovery: URL
    public let fud: URL
    public let kernel: URL?
    public let raw: URL
    public let deviceTree: Any
    public let hardware: HardwareIdentity
    public let commands: any CommandRunning
    public let resources: URL
    public let restore: URL
    public let restoreIdentity: [String: Any]
    public init(recovery: URL, fud: URL, kernel: URL?, raw: URL, deviceTree: Any, hardware: HardwareIdentity,
                resources: URL, restore: URL, restoreIdentity: [String: Any], commands: any CommandRunning = SystemCommands()) {
        self.recovery = recovery; self.fud = fud; self.kernel = kernel; self.raw = raw; self.deviceTree = deviceTree
        self.hardware = hardware; self.commands = commands
        self.resources = resources; self.restore = restore; self.restoreIdentity = restoreIdentity
    }
}
public struct FirmwareRebuildContext {
    public let raw: URL
    public let installerData: URL
    public let hardware: HardwareIdentity?
    public let commands: any CommandRunning
    public let resources: URL
    public init(raw: URL, installerData: URL, resources: URL, hardware: HardwareIdentity? = nil, commands: any CommandRunning = SystemCommands()) {
        self.raw = raw; self.installerData = installerData; self.hardware = hardware; self.commands = commands
        self.resources = resources
    }
}
public struct FirmwareArchiveSource {
    public let source: URL
    public let name: String
    public init(source: URL, name: String) { self.source = source; self.name = name }
}
public protocol BoardFirmwareLoading: Sendable {
    /// Must reject incomplete firmware before any disk changes.
    func validateRecovery(_ context: FirmwareValidationContext, events: EventSink) throws
    /// Collect runtime firmware and return additional raw archive inputs.
    func collect(_ context: FirmwareCollectionContext, into package: FirmwarePackage, events: EventSink) throws -> [FirmwareArchiveSource]
    /// Rebuild the same outputs from an archived collection, without host probing.
    func rebuild(_ context: FirmwareRebuildContext, into package: FirmwarePackage, events: EventSink) throws
}

struct FirmwareArchiveInfo: Codable {
    let version: Int
    let boardProfileID: String
    let hardware: HardwareIdentity
}
enum FirmwareArchive {
    static let metadataName = "board-profile.json"
    static func create(at output: URL, sources: [FirmwareArchiveSource], commands: CommandRunning) throws {
        try require(!sources.isEmpty && Set(sources.map(\.name)).count == sources.count, "Missing or duplicate raw firmware archive inputs")
        let tar = output.deletingPathExtension()
        for (index, entry) in sources.enumerated() {
            try require(!entry.name.isEmpty && !entry.name.hasPrefix("/") && !entry.name.split(separator: "/").contains("..") && !entry.name.contains("|") && !entry.name.contains("&") && !entry.name.contains("\\"), "Invalid raw firmware archive name")
            // Separate append operations scope each name transformation to its
            // own source, even when two boards' inputs share a basename.
            let basename = entry.source.lastPathComponent
            let pattern = basename.reduce("") { $0 + (".[]\\*^$|".contains($1) ? "\\" : "") + String($1) }
            _ = try commands.run("/usr/bin/tar", ["--no-mac-metadata", "--no-fflags", "--no-acls", "--no-xattrs", index == 0 ? "-cf" : "-rf", tar.path, "-s", "|^\(pattern)|\(entry.name)|", "-C", entry.source.deletingLastPathComponent().path, "--", basename], input: nil)
        }
        _ = try commands.run("/usr/bin/gzip", ["-f", tar.path], input: nil)
    }
}
