// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import CInstallerSupport

final class StubInstaller {
    let board: BoardProfile
    let system: MacSystem, disk: DiskManager, archive: ZIPArchive, recoveryImage: RecoveryImage
    let resources: URL, app: URL, events: EventSink, temporary: TemporaryDirectory
    let identity: [String: Any], bootcaches: [String: Any]
    var manifest: [String: Any], installed: InstalledOS?
    var installerData: [(URL, String)] = [], stubInfo: [String: Any] = [:]
    let restorePath: String
    init(system: MacSystem, disk: DiskManager, board: BoardProfile, resources: URL, app: URL, events: @escaping EventSink) throws {
        self.board = board; self.system = system; self.disk = disk; self.resources = resources; self.app = app; self.events = events
        temporary = try TemporaryDirectory(prefix: "gravity-install")
        events(InstallEvent(.ipsw)); archive = try ZIPArchive(board.restore.url)
        manifest = try plist(archive.data("BuildManifest.plist")); bootcaches = try plist(archive.data("usr/standalone/bootcaches.plist"))
        let identity = try board.restore.selectIdentity(in: manifest, hardware: system.hardware)
        restorePath = try board.restore.restoreBundlePath(bootcaches: bootcaches)
        self.identity = identity; manifest["BuildIdentities"] = [identity]
        let base = string(dict(dict(dict(identity["Manifest"])["BaseSystem"])["Info"])["Path"])
        recoveryImage = try RecoveryImage(archive: archive, member: base, profile: board.restore, commands: disk.commands, validateFirmware: {
            try board.firmware.validateRecovery(FirmwareValidationContext(recovery: $0, hardware: system.hardware, resources: resources, deviceTree: system.tree, commands: disk.commands), events: events)
        }, events: events)
    }
    func extract(_ name: String, _ destination: URL) throws { try archive.extract(name, to: destination) }
    func extractPath(_ name: String, _ root: URL) throws { try extract(name, root.appending(name)) }
    func install(into part: DiskPartition, authenticatingWith current: InstalledOS) throws -> InstalledOS {
        events(InstallEvent(.volumes)); let part = try disk.prepareVolumes(part)
        let found = try disk.operatingSystems(part, system: system); try require(found.count == 1, "Startup container must have exactly one volume group")
        let os = found[0]; installed = os
        guard let dataVolume = os.data else { throw InstallerError("Could not mount the new Data volume") }
        let preboot = os.preboot.appending(os.vgid), restore = preboot.appending(restorePath), cs = os.system.appending("System/Library/CoreServices")
        var sysver = try plist(archive.data("SystemVersion.plist")); sysver["ProductUserVisibleVersion"] = string(sysver["ProductUserVisibleVersion"]) + " (stub)"
        stubInfo = ["board_profile": board.id, "vgid": os.vgid, "system_version": sysver, "manifest_info": ["build_number": dict(identity["Info"])["BuildNumber"] ?? "", "variant": board.restore.variant, "device_class": system.device, "board_id": identity["ApBoardID"] ?? "", "chip_id": identity["ApChipID"] ?? ""]]
        events(InstallEvent(.systemVolume)); try extractPath("usr/standalone/bootcaches.plist", os.system)
        try copy(resources.appending("logo.icns"), os.system.appending(".VolumeIcon.icns")); try mkdir(cs)
        try extract("PlatformSupport.plist", cs.appending("PlatformSupport.plist"))
        _ = try? disk.commands.run("/usr/bin/xattr", ["-wx", "com.apple.FinderInfo", "0000000000000000040000000000000000000000000000000000000000000000", os.system.path], input: nil)
        try require(os.system.path.withCString { gravity_bootable($0, 1) } == 1, "Failed to mark the new APFS system volume bootable")
        events(InstallEvent(.dataVolume)); try mkdir(dataVolume.appending("private/var/db/dslocal"))
        events(InstallEvent(.preboot)); try mkdir(restore)
        try writePlist(manifest, restore.appending("BuildManifest.plist")); installerData.append((restore.appending("BuildManifest.plist"), "BuildManifest.plist"))
        for name in ["SystemVersion.plist", "RestoreVersion.plist", "usr/standalone/bootcaches.plist"] { try extractPath(name, restore) }
        installerData.append((restore.appending("RestoreVersion.plist"), "RestoreVersion.plist"))
        events(InstallEvent(.bootability))
        try archive.extractTree("BootabilityBundle/Restore/Bootability", to: restore.appending("Bootability"))
        try extract("BootabilityBundle/Restore/Firmware/Bootability.dmg.trustcache", restore.appending("Bootability/Bootability.trustcache"))
        try archive.extractTree("Firmware/Manifests/restore/\(board.restore.variant)/", to: restore)
        events(InstallEvent(.restoreFirmware)); var copied = Set<String>()
        for (key, value) in dict(identity["Manifest"]).sorted(by: { $0.key < $1.key }) {
            if ["BaseSystem", "OS", "Ap,SystemVolumeCanonicalMetadata", "RestoreRamDisk", "RestoreTrustCache"].contains(key) || key.hasPrefix("Cryptex") { continue }
            let path = string(dict(dict(value)["Info"])["Path"])
            try require(!path.isEmpty, "Missing restore firmware path")
            if copied.insert(path).inserted { try extractPath(path, restore) }
            if path.hasPrefix("kernelcache.") { installerData.append((restore.appending(path), URL(fileURLWithPath: path).lastPathComponent)) }
        }
        try copyAdministrators(from: current, to: os)
        let restoreLink = os.system.appending(restorePath)
        if fm.fileExists(atPath: restoreLink.path) { try fm.removeItem(at: restoreLink) }
        try fm.createSymbolicLink(at: restoreLink, withDestinationURL: restore)
        events(InstallEvent(.recoveryVolume))
        let base = os.recovery.appending("\(os.vgid)/usr/standalone/firmware/arm64eBaseSystem.dmg")
        try APFSCompression.compress(source: recoveryImage.url, destination: base, crc: recoveryImage.crc, events: events)
        try writePlist(sysver, cs.appending("SystemVersion.plist")); installerData.append((cs.appending("SystemVersion.plist"), "SystemVersion.plist"))
        events(InstallEvent(.stage2App)); try copy(app, os.system.appending("Finish Installation.app"))
        // App selection automatically enters stage2 whenever this record is present.
        try writePlist(["AppName": "Finish Installation.app", "ProductBuildVersion": "00A191", "ProductVersion": "12.1"], os.system.appending(".IAPhysicalMedia"))
        return os
    }
    func copyAdministrators(from current: InstalledOS, to target: InstalledOS) throws {
        events(InstallEvent(.administrators))
        let source = current.preboot.appending("\(current.vgid)/var/db/AdminUserRecoveryInfo.plist")
        let dest = target.preboot.appending("\(target.vgid)/var/db/AdminUserRecoveryInfo.plist")
        if fm.fileExists(atPath: dest.path) { _ = try disk.commands.run("/usr/bin/chflags", ["noschg", dest.path], input: nil) }
        try copy(source, dest); _ = try disk.commands.run("/usr/bin/chflags", ["schg", dest.path], input: nil)
        installerData.append((dest, "AdminUserRecoveryInfo.plist"))
        let users = try plist(dest); var admins: [String: Any] = [:]
        for (name, info) in users { admins[name] = ["uid": dict(info)["GeneratedUID"] ?? "", "real_name": dict(info)["RealName"] ?? ""] }
        stubInfo["admin_users"] = admins
    }
    func collectFirmware(_ os: InstalledOS) throws -> URL {
        let root = temporary.url.appending("vendorfw"), raw = try TemporaryDirectory(prefix: "gravity-raw-firmware")
        let fud = temporary.url.appending("fud_firmware"); try mkdir(fud)
        var copied = Set<String>(); var kernel: URL?
        let restore = os.preboot.appending("\(os.vgid)/\(restorePath)")
        for (key, value) in dict(identity["Manifest"]).sorted(by: { $0.key < $1.key }) {
            if ["BaseSystem", "OS", "Ap,SystemVolumeCanonicalMetadata", "StaticTrustCache", "SystemVolume"].contains(key) { continue }
            let info = dict(dict(value)["Info"]), path = string(info["Path"])
            if path.hasPrefix("kernelcache.") && kernel == nil { kernel = restore.appending(path) }
            guard info["IsFUDFirmware"] as? Bool == true, info["IsLoadedByiBoot"] as? Bool != true, info["IsLoadedByiBootStage1"] as? Bool != true, path.hasSuffix(".im4p") else { continue }
            if copied.insert(path).inserted { try extractPath(path, fud) }
            let machine = fud.appending(board.firmwareMachine); try mkdir(machine)
            try fm.createSymbolicLink(atPath: machine.appending(key + ".im4p").path, withDestinationPath: "../" + path)
        }
        let mount = try MountedRecovery(image: os.recovery.appending("\(os.vgid)/usr/standalone/firmware/arm64eBaseSystem.dmg"), commands: disk.commands)
        let archive = temporary.url.appending("all_firmware.tar.gz")
        let context = FirmwareCollectionContext(recovery: mount.url, fud: fud, kernel: kernel, raw: raw.url, deviceTree: system.tree, hardware: system.hardware,
            resources: resources, restore: restore, restoreIdentity: identity, commands: disk.commands)
        try FirmwarePipeline.collect(board: board, hardware: system.hardware, context: context, destination: root, archive: archive, commands: disk.commands, events: events)
        try mount.detach(); installerData.append((archive, "all_firmware.tar.gz")); return root
    }
    func collectInstallerData(_ target: URL) throws {
        events(InstallEvent(.installerData)); try mkdir(target)
        for (source, name) in installerData { try copy(source, target.appending(name)) }
        try write(jsonData(stubInfo), to: target.appending("stub_info.json"))
    }
}
