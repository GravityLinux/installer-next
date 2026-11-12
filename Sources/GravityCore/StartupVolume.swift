// SPDX-License-Identifier: GPL-2.0-only
import Foundation

/// First-stage startup selection. Keep Asahi's device-mode bless and installer
/// marker ordering, but verify the mounted group and resulting default before
/// telling the user to shut down into the new paired Recovery.
struct StartupVolume {
    struct Selection {
        let targetGroup: String, selectedGroup: String, device: String
    }
    let system: URL
    let group: String
    let name: String

    static func defaultGroup(in nvram: [String: Any]) -> String {
        let value: String
        if let bytes = nvram["boot-volume"] as? Data { value = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self) }
        else { value = string(nvram["boot-volume"]) }
        let fields = value.components(separatedBy: ":")
        return fields.count >= 3 ? fields[2] : ""
    }

    func prepareRecovery(credentials: Credentials, recovery: Bool, commands: CommandRunning, events: EventSink, selectionObserved: (Selection) -> Void = { _ in }) throws -> Selection {
        let core = system.appending("System/Library/CoreServices")
        let enabled = core.appending("SystemVersion.plist"), disabled = core.appending("SystemVersion-disabled.plist")
        let media = system.appending(".IAPhysicalMedia"), disabledMedia = system.appending("IAPhysicalMedia-disabled.plist")
        try require(fm.fileExists(atPath: enabled.path) || fm.fileExists(atPath: disabled.path), "The startup volume is missing SystemVersion.plist; repair its boot files before continuing")
        try require(fm.fileExists(atPath: media.path) || fm.fileExists(atPath: disabledMedia.path), "The startup volume is missing its installer marker; repair its boot files before continuing")

        // Resolve the currently mounted System volume rather than retaining a
        // BSD device number captured before partitioning and firmware collection.
        let info = try plist(commands.run("/usr/sbin/diskutil", ["info", "-plist", system.path], input: nil))
        let device = string(info["DeviceIdentifier"])
        var mountedGroup = string(info["APFSVolumeGroupID"])
        if mountedGroup.isEmpty {
            let container = string(info["APFSContainerReference"])
            try require(!container.isEmpty, "Could not identify the mounted startup volume's APFS container")
            let listing = try plist(commands.run("/usr/sbin/diskutil", ["apfs", "listVolumeGroups", container, "-plist"], input: nil))
            let matches = array(listing["Containers"]).flatMap { array($0["VolumeGroups"]) }.filter { group in
                array(group["Volumes"]).contains { string($0["DeviceIdentifier"]) == device && string($0["Role"]) == "System" }
            }
            try require(matches.count == 1, "Could not uniquely identify the startup System volume's APFS group")
            mountedGroup = string(matches[0]["APFSVolumeGroupUUID"])
        }
        try require(UUID(uuidString: group) != nil && mountedGroup.caseInsensitiveCompare(group) == .orderedSame,
            "The mounted startup volume does not belong to the reviewed APFS volume group; check the installation before continuing")
        try require(device.range(of: #"^disk[0-9]+s[0-9]+$"#, options: .regularExpression) != nil, "Invalid startup System volume device")

        if !fm.fileExists(atPath: enabled.path) { try fm.moveItem(at: disabled, to: enabled) }
        if recovery {
            events(InstallEvent(.reducedSecurity))
            try commands.authenticated("/usr/bin/bputil", ["-g", "-v", group], credentials: credentials)
        }
        events(InstallEvent(.defaultBoot))
        _ = try commands.run("/usr/sbin/bless", ["--setBoot", "--device", "/dev/" + device, "--user", credentials.username, "--stdinpass"], input: Data(credentials.password.utf8))

        let selected = Self.defaultGroup(in: try plist(commands.run("/usr/sbin/nvram", ["-xp"], input: nil)))
        let selection = Selection(targetGroup: group, selectedGroup: selected, device: device)
        selectionObserved(selection)
        try require(UUID(uuidString: selected) != nil,
            "bless returned successfully, but the default startup volume could not be verified. Recheck startup selection before shutting down.")
        try require(selected.caseInsensitiveCompare(group) == .orderedSame,
            "bless returned successfully, but \(name) is not the default startup volume. The new paired Recovery is not selected. Recheck startup selection before shutting down.")

        // Asahi deliberately hides SystemVersion only after blessing. The
        // installer marker remains active until paired 1TR finalization.
        if fm.fileExists(atPath: disabled.path) { try fm.removeItem(at: disabled) }
        try fm.moveItem(at: enabled, to: disabled)
        if !fm.fileExists(atPath: media.path) { try fm.moveItem(at: disabledMedia, to: media) }
        events(InstallEvent(.defaultBoot, fraction: 1, detail: name))
        return selection
    }
}
