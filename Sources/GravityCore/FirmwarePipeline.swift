// SPDX-License-Identifier: GPL-2.0-only
import Foundation

enum FirmwarePipeline {
    static func collect(board: BoardProfile, hardware: HardwareIdentity, context: FirmwareCollectionContext,
                        destination: URL, archive: URL, commands: CommandRunning, events: EventSink) throws {
        try require(board.matches(hardware) && context.hardware == hardware, "Firmware profile does not match this board")
        let package = try FirmwarePackage(destination)
        let additional = try board.firmware.collect(context, into: package, events: events)
        try package.close()
        let metadata = context.raw.appending(FirmwareArchive.metadataName)
        try write(JSONEncoder().encode(FirmwareArchiveInfo(version: 1, boardProfileID: board.id, hardware: hardware)), to: metadata)
        events(InstallEvent(.firmwareArchive))
        try FirmwareArchive.create(at: archive, sources: [FirmwareArchiveSource(source: context.fud, name: "fud_firmware"), FirmwareArchiveSource(source: metadata, name: FirmwareArchive.metadataName)] + additional, commands: commands)
    }
    static func rebuild(source: URL, destination: URL, resources: URL, boardID: String?, registry: BoardRegistry, developer: Bool = false,
                        commands: CommandRunning, events: EventSink) throws {
        let raw = try TemporaryDirectory(prefix: "gravity-fwextract")
        _ = try commands.run("/usr/bin/tar", ["-xf", source.appending("all_firmware.tar.gz").path, "-C", raw.url.path], input: nil)
        let metadataURL = raw.url.appending(FirmwareArchive.metadataName)
        let profile: BoardProfile
        let hardware: HardwareIdentity?
        if fm.fileExists(atPath: metadataURL.path) {
            let metadata = try JSONDecoder().decode(FirmwareArchiveInfo.self, from: Data(contentsOf: metadataURL))
            try require(metadata.version == 1, "Unsupported raw firmware metadata version")
            if let boardID { try require(boardID == metadata.boardProfileID, "Requested board does not match the firmware archive") }
            profile = try registry.savedProfile(id: metadata.boardProfileID, hardware: metadata.hardware, developer: developer)
            hardware = metadata.hardware
        } else { profile = try registry.savedProfile(id: boardID, developer: developer); hardware = nil }
        let package = try FirmwarePackage(destination)
        try profile.firmware.rebuild(FirmwareRebuildContext(raw: raw.url, installerData: source, resources: resources, hardware: hardware, commands: commands), into: package, events: events)
        try package.close()
    }
}
