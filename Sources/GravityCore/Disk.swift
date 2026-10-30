// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import CInstallerSupport

struct MacSystem {
    var hardware: HardwareIdentity { HardwareIdentity(deviceClass: device, chipID: chip, boardID: board) }
    let tree: [String: Any], chosen: [String: Any]
    let device: String, model: String, chip: Int64, board: Int64
    let bootUUID: String, bootVGID: String, defaultBoot: String, bootMode: String
    let macOS: String, loginUser: String
    static func hardware(in tree: [String: Any]) throws -> HardwareIdentity {
        guard let platform = array(tree["IORegistryEntryChildren"]).first(where: { string($0["IOObjectClass"]) == "IOPlatformExpertDevice" }),
              let chosen = array(platform["IORegistryEntryChildren"]).first(where: { string($0["IORegistryEntryName"]) == "chosen" }),
              let compatible = platform["compatible"] as? Data,
              let chip = chosen["chip-id"] as? Data, let board = chosen["board-id"] as? Data else {
            throw InstallerError("Missing Apple Silicon hardware identity")
        }
        return HardwareIdentity(deviceClass: String(decoding: compatible.prefix { $0 != 0 }, as: UTF8.self),
            chipID: Int64(try chip.uint(0, 4)), boardID: Int64(try board.uint(0, 4)))
    }
    init(commands: CommandRunning, readOnly: Bool = false) throws {
        tree = try Self.deviceTree(try commands.run("/usr/sbin/ioreg", ["-alp", "IODeviceTree"], input: nil))
        guard let platform = array(tree["IORegistryEntryChildren"]).first(where: { string($0["IOObjectClass"]) == "IOPlatformExpertDevice" }),
              let chosen = array(platform["IORegistryEntryChildren"]).first(where: { string($0["IORegistryEntryName"]) == "chosen" }),
              let product = array(platform["IORegistryEntryChildren"]).first(where: { string($0["IORegistryEntryName"]) == "product" }) else { throw InstallerError("Missing Apple Silicon device tree") }
        self.chosen = chosen
        func text(_ value: Any?) -> String {
            if let data = value as? Data { return String(decoding: data.prefix { $0 != 0 }, as: UTF8.self) }; return string(value)
        }
        let hardware = try Self.hardware(in: tree)
        device = hardware.deviceClass; chip = hardware.chipID; board = hardware.boardID; model = text(product["product-name"])
        bootUUID = text(chosen["boot-uuid"])
        let associated = text(chosen["associated-volume-group"] ?? chosen["apfs-preboot-uuid"])
        let bootPath = text(chosen["boot-objects-path"]).components(separatedBy: "/")
        bootVGID = !associated.isEmpty ? associated : (bootPath.count > 1 ? bootPath[1] : bootUUID)
        let nvram = try plist(commands.run("/usr/sbin/nvram", ["-xp"], input: nil))
        let boot = text(nvram["boot-volume"]).components(separatedBy: ":")
        defaultBoot = boot.count >= 3 ? boot[2] : ""
        var policy = ""
        for vgid in [bootVGID, defaultBoot] where !readOnly && !vgid.isEmpty {
            if let data = try? commands.run("/usr/bin/bputil", ["-d", "-v", vgid], input: nil) { policy = String(decoding: data, as: UTF8.self); break }
        }
        if readOnly {
            let root = try plist(commands.run("/usr/sbin/diskutil", ["info", "-plist", "/"], input: nil))
            bootMode = root["APFSSnapshot"] as? Bool == true && !string(root["APFSVolumeGroupID"]).isEmpty ? "macOS" : Self.environment(policy)
        } else { bootMode = Self.environment(policy) }
        macOS = string(try plist(URL(fileURLWithPath: "/System/Library/CoreServices/SystemVersion.plist"))["ProductVersion"])
        let console = String(decoding: try commands.run("/usr/sbin/scutil", [], input: Data("show State:/Users/ConsoleUser\n".utf8)), as: UTF8.self)
        loginUser = console.components(separatedBy: "\n").first { $0.contains("kCGSSessionUserNameKey : ") }?.components(separatedBy: " : ").last?.trimmingCharacters(in: .whitespaces) ?? ""
    }
    static func deviceTree(_ data: Data) throws -> [String: Any] {
        var raw = data
        // Tabs, carriage returns and newlines are legal XML whitespace.
        // Replacing indentation with '?' makes the entire ioreg plist invalid.
        for i in raw.indices where raw[i] < 32 && ![9, 10, 13].contains(raw[i]) { raw[i] = 63 }
        let value = try PropertyListSerialization.propertyList(from: raw, options: [], format: nil)
        if let tree = value as? [String: Any] { return tree }
        if let trees = value as? [[String: Any]], trees.count == 1 { return trees[0] }
        throw InstallerError("Expected one IODeviceTree root")
    }
    static func environment(_ policy: String) -> String {
        for line in policy.components(separatedBy: "\n") {
            if let range = line.range(of: "Current OS environment: ") { return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces) }
            if line.contains("OS Type"), let range = line.range(of: ": ") { return String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces) }
        }
        return "Unknown"
    }
    func validate(board: BoardProfile) throws {
        try require(board.matches(hardware), "The selected board profile does not match this Mac")
        try require(versionAtLeast(macOS, board.minimumMacOS), "Update macOS to \(board.minimumMacOS) or later before installing")
        try require(bootMode != "Unknown", "Could not determine the current boot environment")
        if bootMode == "macOS" { try require(!loginUser.isEmpty && !["unknown", "_mbsetupuser"].contains(loginUser), "A macOS administrator must be logged in at the local console") }
    }
}

struct DiskPartition {
    let name: String, offset: Int64, size: Int64, free: Bool, type: String, uuid: String
    var label: String = ""
    var container: [String: Any] = [:]
    var id: String { free ? "free:\(name):\(offset):\(size)" : uuid }
}
struct InstalledOS {
    let partition: DiskPartition, vgid: String, label: String, systemDevice: String, dataDevice: String
    let system: URL, data: URL?, preboot: URL, recovery: URL, recoveryUUID: String, prebootUUID: String
    let stub: Bool, version: String, administrators: [String], paired: Bool, registered: Bool
    var resources: URL { system.appending("Finish Installation.app/Contents/Resources") }
}
final class DiskManager {
    let commands: CommandRunning
    private(set) var list: [String: [String: Any]] = [:], disks: [String: [String: Any]] = [:], containers: [String: [String: Any]] = [:]
    init(commands: CommandRunning) { self.commands = commands }
    @discardableResult func action(_ args: [String]) throws -> Data { try commands.run("/usr/sbin/diskutil", args, input: nil) }
    func get(_ args: [String]) throws -> [String: Any] { try plist(action(args)) }
    func refresh() throws {
        list = [:]; disks = [:]; containers = [:]
        let raw = try get(["list", "-plist"])
        for disk in array(raw["AllDisksAndPartitions"]) { list[string(disk["DeviceIdentifier"])] = disk }
        for name in raw["WholeDisks"] as? [String] ?? [] { disks[name] = try get(["info", "-plist", name]) }
        for var container in array(try get(["apfs", "list", "-plist"])["Containers"]) {
            let reference = string(container["ContainerReference"])
            let groups = try get(["apfs", "listVolumeGroups", reference, "-plist"])
            container["VolumeGroups"] = array(groups["Containers"]).first?["VolumeGroups"]
            containers[string(container["DesignatedPhysicalStore"])] = container
        }
    }
    func systemDisk() throws -> String {
        let matches = disks.filter { name, disk in
            string(disk["VirtualOrPhysical"]) != "Virtual" && disk["Internal"] as? Bool == true && string(array(list[name]?["Partitions"]).first?["Content"]) == "Apple_APFS_ISC"
        }
        try require(matches.count == 1, "Could not uniquely identify the internal Apple system disk")
        return matches.first!.key
    }
    func partition(_ name: String) throws -> DiskPartition {
        let info = try get(["info", "-plist", name])
        var result = DiskPartition(name: string(info["DeviceIdentifier"]), offset: int(info["PartitionMapPartitionOffset"]), size: int(info["Size"]), free: false, type: string(info["Content"]), uuid: string(info["DiskUUID"]))
        if let container = containers[name] {
            result.container = container
            let volumes = array(container["Volumes"])
            result.label = string((volumes.first { $0["Roles"] as? [String] == ["System"] } ?? volumes.first { $0["Roles"] as? [String] == ["Data"] } ?? volumes.first)?["Name"])
        }
        return result
    }
    func partitions(_ disk: String) throws -> [DiskPartition] {
        let data = list[disk] ?? [:]
        let end = alignDown(int(data["Size"]) - 34 * 512, 4096)
        var offset: Int64 = 40 * 512; var previous = disk; var result: [DiskPartition] = []
        let parts = try array(data["Partitions"]).map { try partition(string($0["DeviceIdentifier"])) }.sorted { $0.offset < $1.offset }
        for part in parts {
            if part.offset - offset > 16 * 1024 * 1024 { result.append(DiskPartition(name: previous, offset: offset, size: part.offset - offset, free: true, type: "free", uuid: "")) }
            result.append(part); offset = part.offset + part.size; previous = part.name
        }
        if end - offset > 16 * 1024 * 1024 { result.append(DiskPartition(name: previous, offset: offset, size: end - offset, free: true, type: "free", uuid: "")) }
        return result
    }
    func mount(_ name: String) throws -> URL {
        _ = try action(["mount", name]); let info = try get(["info", "-plist", name]); let path = string(info["MountPoint"])
        try require(!path.isEmpty, "No mount point for \(name)"); return URL(fileURLWithPath: path)
    }
    func addPartition(after: String, type: String, label: String, size: Int64, disk: String) throws -> DiskPartition {
        let before = Set(try partitions(disk).filter { !$0.free }.map(\.uuid))
        _ = try action(["addPartition", after, type, label, String(size)]); try refresh()
        func canonical(_ value: String) -> String {
            let v = value.trimmingCharacters(in: CharacterSet(charactersIn: "%")).lowercased()
            return v == "linux" ? "linux filesystem" : (v == "apfs" ? "apple_apfs" : v)
        }
        let candidates = try partitions(disk).filter { !$0.free && !before.contains($0.uuid) && canonical($0.type) == canonical(type) }
        try require(candidates.count == 1, "Could not uniquely identify the new \(type) partition")
        return candidates[0]
    }
    func prepareVolumes(_ part: DiskPartition) throws -> DiskPartition {
        let reference = string(part.container["ContainerReference"])
        try require(!reference.isEmpty, "Missing APFS container")
        let volumes = array(part.container["Volumes"])
        for role in ["Preboot", "Recovery", "Data", "System"] {
            try require(volumes.filter { $0["Roles"] as? [String] == [role] }.count <= 1, "Multiple \(role) volumes")
        }
        var data = volumes.first { $0["Roles"] as? [String] == ["Data"] }
        if data == nil {
            if let empty = volumes.first(where: { ($0["Roles"] as? [String] ?? []).isEmpty }) {
                _ = try action(["apfs", "changeVolumeRole", string(empty["DeviceIdentifier"]), "D"])
                _ = try action(["rename", string(empty["DeviceIdentifier"]), part.label + " - Data"])
            } else { _ = try action(["apfs", "addVolume", reference, "apfs", part.label + " - Data", "-role", "D"]) }
            try refresh(); data = array(containers[part.name]?["Volumes"]).first { $0["Roles"] as? [String] == ["Data"] }
        }
        guard let data else { throw InstallerError("Missing Data volume") }
        if !volumes.contains(where: { $0["Roles"] as? [String] == ["System"] }) {
            _ = try action(["apfs", "addVolume", reference, "apfs", part.label, "-role", "S", "-groupWith", string(data["DeviceIdentifier"])])
        }
        for (role, flag) in [("Preboot", "B"), ("Recovery", "R")] where !volumes.contains(where: { $0["Roles"] as? [String] == [role] }) {
            _ = try action(["apfs", "addVolume", reference, "apfs", role, "-role", flag])
        }
        try refresh(); return try partition(part.name)
    }
    func operatingSystems(_ part: DiskPartition, system: MacSystem, readOnly: Bool = false) throws -> [InstalledOS] {
        if part.container.isEmpty || part.type != "Apple_APFS" { return [] }
        let volumes = array(part.container["Volumes"])
        guard let preboot = volumes.first(where: { $0["Roles"] as? [String] == ["Preboot"] }), let recovery = volumes.first(where: { $0["Roles"] as? [String] == ["Recovery"] }) else { return [] }
        var result: [InstalledOS] = []
        for group in array(part.container["VolumeGroups"]) {
            let members = array(group["Volumes"])
            let systems = members.filter { string($0["Role"]) == "System" }, datas = members.filter { string($0["Role"]) == "Data" }
            guard systems.count == 1, datas.count == 1 else { continue }
            let vgid = string(group["APFSVolumeGroupUUID"])
            let systemName = string(systems[0]["DeviceIdentifier"]), dataName = string(datas[0]["DeviceIdentifier"])
            guard let systemVolume = volumes.first(where: { string($0["DeviceIdentifier"]) == systemName }) else { continue }
            var mountName = systemName
            if system.bootUUID == vgid {
                let snapshots = array(list[string(part.container["ContainerReference"])]?["APFSVolumes"]).first { string($0["DeviceIdentifier"]) == systemName }
                let mounted = array(snapshots?["MountedSnapshots"])
                if mounted.count == 1 { mountName = string(mounted[0]["SnapshotBSD"]) }
            }
            let systemMount: URL, prebootMount: URL, recoveryMount: URL, dataMount: URL?
            if readOnly {
                func mounted(_ name: String) throws -> URL? {
                    let path = string(try get(["info", "-plist", name])["MountPoint"])
                    return path.isEmpty ? nil : URL(fileURLWithPath: path)
                }
                let root = try get(["info", "-plist", "/"])
                let current = string(root["APFSVolumeGroupID"]) == vgid
                guard let mountedSystem = try mounted(mountName) ?? (current ? URL(fileURLWithPath: "/") : nil),
                      let mountedPreboot = try mounted(string(preboot["DeviceIdentifier"])) ?? (current ? URL(fileURLWithPath: "/System/Volumes/Preboot") : nil) else { continue }
                systemMount = mountedSystem; prebootMount = mountedPreboot
                recoveryMount = try mounted(string(recovery["DeviceIdentifier"])) ?? URL(fileURLWithPath: "/System/Volumes/Recovery")
                dataMount = try mounted(dataName) ?? (current ? URL(fileURLWithPath: "/System/Volumes/Data") : nil)
            } else {
                systemMount = try mount(mountName); prebootMount = try mount(string(preboot["DeviceIdentifier"])); recoveryMount = try mount(string(recovery["DeviceIdentifier"]))
                dataMount = try? mount(dataName)
            }
            var version = ""
            for filename in ["SystemVersion.plist", "SystemVersion-disabled.plist"] {
                if let value = try? plist(systemMount.appending("System/Library/CoreServices/" + filename)) { version = string(value["ProductVersion"]); break }
            }
            let admins = (try? plist(prebootMount.appending("\(vgid)/var/db/AdminUserRecoveryInfo.plist")))?.keys.sorted() ?? []
            let policy = readOnly ? "" : String(decoding: (try? commands.run("/usr/bin/bputil", ["-d", "-v", vgid], input: nil)) ?? Data(), as: UTF8.self)
            let registered = policy.components(separatedBy: "\n").contains { $0.contains("(coih): ") && !$0.contains("absent") }
            result.append(InstalledOS(partition: part, vgid: vgid, label: string(systemVolume["Name"]), systemDevice: systemName, dataDevice: dataName, system: systemMount, data: dataMount, preboot: prebootMount, recovery: recoveryMount, recoveryUUID: string(recovery["APFSVolumeUUID"]), prebootUUID: string(preboot["APFSVolumeUUID"]), stub: !fm.fileExists(atPath: systemMount.appending("Library").path), version: version, administrators: admins, paired: policy.contains(": Paired"), registered: registered))
        }
        return result
    }
    func maximumResize(_ part: DiskPartition, reserveBytes: Int64) throws -> Int64 {
        let limits = try get(["apfs", "resizeContainer", part.name, "limits", "-plist"])
        let total = int(part.container["CapacityCeiling"]), free = int(part.container["CapacityFree"])
        let hardMinimum = int(limits["MinimumSizeNoGuard"] ?? limits["MinimumSizePreferred"])
        let minimum = alignUp(max(alignUp(total - free + reserveBytes), hardMinimum))
        return max(0, alignDown(total - minimum))
    }
}
