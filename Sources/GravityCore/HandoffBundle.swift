// SPDX-License-Identifier: GPL-2.0-only
import Foundation

/// Exercise the same board firmware pipeline without creating an installation,
/// changing partitions, writing NVRAM, or configuring a boot policy.
enum HandoffBundle {
    static func collect(destination: URL, ipsw: URL?, resources: URL,
                        boards: BoardRegistry, developer: Bool = false, commands: CommandRunning, events: @escaping EventSink) throws {
        try require(!fm.fileExists(atPath: destination.path), "Handoff destination already exists")
        events(InstallEvent(.inspecting))
        let system = try MacSystem(commands: commands), board = try boards.resolve(system.hardware, developer: developer)
        try require(versionAtLeast(system.macOS, board.minimumMacOS), "Update macOS before collecting this board’s firmware")
        let temp = try TemporaryDirectory(prefix: "gravity-handoff"), raw = temp.url.appending("raw")
        let output = temp.url.appending("output"), fud = temp.url.appending("fud_firmware")
        try mkdir(raw); try mkdir(output); try mkdir(fud)
        let source = ipsw ?? board.restore.url
        events(InstallEvent(.ipsw))
        let archive = try ZIPArchive(source), manifestURL = temp.url.appending("BuildManifest.plist")
        try archive.extract("BuildManifest.plist", to: manifestURL)
        let identity = try board.restore.selectIdentity(in: plist(manifestURL), hardware: system.hardware)
        let image = try RecoveryImage(archive: archive, member: board.restore.member, profile: board.restore,
            commands: commands, validateFirmware: {
                try board.firmware.validateRecovery(FirmwareValidationContext(recovery: $0, hardware: system.hardware,
                    resources: resources, deviceTree: system.tree, commands: commands), events: events)
            }, events: events)
        var copied = Set<String>(), kernel: URL?
        for (name, entry) in dict(identity["Manifest"]).sorted(by: { $0.key < $1.key }) {
            let info = dict(dict(entry)["Info"]), path = string(info["Path"])
            try require(!path.hasPrefix("/") && !path.split(separator: "/").contains(".."), "Invalid restore firmware path")
            if path.hasPrefix("kernelcache.") && kernel == nil {
                let file = temp.url.appending("kernelcache.saved")
                try archive.extract(path, to: file); kernel = file
            }
            guard info["IsFUDFirmware"] as? Bool == true, path.hasSuffix(".im4p") else { continue }
            if copied.insert(path).inserted { try archive.extract(path, to: fud.appending(path)) }
            let machine = fud.appending(board.firmwareMachine); try mkdir(machine)
            try fm.createSymbolicLink(atPath: machine.appending(name + ".im4p").path, withDestinationPath: "../" + path)
        }
        let mount = try MountedRecovery(image: image.url, commands: commands)
        let context = FirmwareCollectionContext(recovery: mount.url, fud: fud, kernel: kernel, raw: raw,
            deviceTree: system.tree, hardware: system.hardware, resources: resources,
            restore: fud, restoreIdentity: identity, commands: commands)
        try FirmwarePipeline.collect(board: board, hardware: system.hardware, context: context, destination: output,
            archive: output.appending("all_firmware.tar.gz"), commands: commands, events: events)
        try mount.detach()
        // Rebuild immediately using the archive alone, including the firmware
        // loader’s saved-data validation. This catches missing archive inputs.
        let rebuilt = temp.url.appending("rebuilt")
        try FirmwarePipeline.rebuild(source: output, destination: rebuilt, resources: resources,
            boardID: board.id, registry: boards, developer: developer, commands: commands, events: events)
        for name in ["manifest.txt", "firmware.tar", "firmware.cpio"] {
            try require(Data(contentsOf: output.appending(name)) == Data(contentsOf: rebuilt.appending(name)),
                        "Handoff archive rebuild differs: \(name)")
        }
        try write(JSONEncoder().encode(system.hardware), to: output.appending("hardware.json"))
        try write(jsonData(["version": 1, "board": board.id, "restore_version": board.restore.version,
            "restore_build": string(dict(identity["Info"])["BuildNumber"]), "host_version": system.macOS,
            "archive_rebuild_identical": true, "disk_changes": false,
            "firmware_manifest_sha256": try Data(contentsOf: output.appending("manifest.txt")).sha256]),
            to: output.appending("handoff.json"))
        try mkdir(destination.deletingLastPathComponent())
        try fm.moveItem(at: output, to: destination)
    }
}
