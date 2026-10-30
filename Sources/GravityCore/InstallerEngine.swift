// SPDX-License-Identifier: GPL-2.0-only
import Foundation

/// The client-independent API. All disk work is serialized on this actor.
/// Clients inspect, request a reviewable plan, then explicitly commit its ID.
public actor InstallerEngine {
    public let configuration: EngineConfiguration
    private let boards: BoardRegistry
    private let commands: CommandRunning
    private let events: EventSink
    private let log: InstallationLog
    private var templates: [String: SoftwareTemplate] = [:]
    private var plans: [String: (InstallPlan, String)] = [:]
    private var maintenancePlans: [String: MaintenancePlan] = [:]
    public init(configuration: EngineConfiguration, commands: CommandRunning = SystemCommands(), boards: BoardRegistry = .builtIn, events: @escaping EventSink = { _ in }) {
        self.configuration = configuration; self.commands = commands; self.boards = boards
        let log = InstallationLog(enabled: !configuration.demo && geteuid() == 0)
        self.log = log
        self.events = { event in log.append(event); events(event) }
    }
    private func root() throws { try require(configuration.demo || geteuid() == 0, "Administrator authorization is required. Run this client with sudo, or authorize in the graphical app.") }
    /// Read-only preflight, usable before authorization or downloads.
    public func checkBoardSupport() throws -> BoardPresentation {
        if configuration.demo { return try demoBoard().presentation }
        if let url = configuration.stage2URL { return try Stage2Context(url, boards: boards, developer: configuration.developer).board.presentation }
        let tree = try MacSystem.deviceTree(commands.run("/usr/sbin/ioreg", ["-alp", "IODeviceTree"], input: nil))
        return try boards.resolve(MacSystem.hardware(in: tree), developer: configuration.developer).presentation
    }
    private struct Scan {
        let board: BoardProfile
        let system: MacSystem, disk: DiskManager, name: String, partitions: [DiskPartition], systems: [InstalledOS], current: InstalledOS
        var fingerprint: String {
            Data(([board.id, system.hardware.deviceClass, String(system.hardware.chipID), String(system.hardware.boardID)] + partitions.map { "\($0.name):\($0.offset):\($0.size):\($0.type):\($0.uuid)" }).joined(separator: "\n").utf8).sha256
        }
    }
    private func scan(readOnly: Bool = false) throws -> Scan {
        if !readOnly { try root() }; events(InstallEvent(.inspecting))
        let system = try MacSystem(commands: commands, readOnly: readOnly)
        let board = try boards.resolve(system.hardware, developer: configuration.developer); try system.validate(board: board)
        let disk = DiskManager(commands: commands); try disk.refresh(); let name = try disk.systemDisk(), parts = try disk.partitions(name)
        try require(string(disk.disks[name]?["Content"]) == "GUID_partition_scheme", "The internal disk must use a GUID partition map")
        let systems = try parts.flatMap { try disk.operatingSystems($0, system: system, readOnly: readOnly) }
        let macOS = systems.filter { !$0.stub && !$0.version.isEmpty }
        let rootGroup = readOnly ? string(try disk.get(["info", "-plist", "/"])["APFSVolumeGroupID"]) : ""
        let current = macOS.first { $0.vgid == system.bootUUID || $0.vgid == system.bootVGID || (!rootGroup.isEmpty && $0.vgid == rootGroup) } ?? macOS.first { $0.vgid == system.defaultBoot }
        guard let current else { throw InstallerError("Could not identify the macOS installation used for machine-owner authentication. Start from your primary macOS installation or its paired recovery.") }
        try require(!current.administrators.filter { $0 != "_mbsetupuser" }.isEmpty, "No machine-owner administrator records found. Run diskutil apfs updatePreboot on your macOS volume and try again.")
        if system.bootMode == "macOS" { try require(current.administrators.contains(system.loginUser), "The local macOS session must belong to a machine-owner administrator") }
        return Scan(board: board, system: system, disk: disk, name: name, partitions: parts, systems: systems, current: current)
    }
    private func loadReleases(for board: BoardProfile) throws {
        templates = [:]
        events(InstallEvent(.metadata))
        templates = try ReleaseCatalog.candidates(ReleaseCatalog.fetch(configuration.catalogURL), board: board,
            developer: configuration.developer, repository: configuration.repositoryURL)
        if board.installationModes.contains(.bootloader) { templates[board.id + ":local:bootloader"] = .bootloaderOnly }
    }
    private func targets(_ scan: Scan) throws -> [StorageTarget] {
        var result: [StorageTarget] = []
        for part in scan.partitions {
            if part.free && part.size >= scan.board.storage.stubBytes {
                result.append(StorageTarget(id: part.id, name: "Available space after \(part.name)", kind: "free", totalBytes: part.size, freeBytes: part.size, maximumBytes: alignDown(part.size)))
            } else if part.uuid == scan.current.partition.uuid {
                let maximum = try scan.disk.maximumResize(part, reserveBytes: scan.board.storage.macOSReserveBytes)
                if maximum >= scan.board.storage.stubBytes {
                    result.append(StorageTarget(id: part.id, name: scan.current.label, kind: "resize", totalBytes: part.size, freeBytes: int(part.container["CapacityFree"]), maximumBytes: maximum))
                }
            }
        }
        return result
    }
    public func inspect() throws -> Inspection {
        if configuration.demo { return try demoInspection() }
        let scan = try scan(readOnly: true)
        let existing = scan.systems.filter { $0.stub && fm.fileExists(atPath: $0.resources.appending("boot.bin").path) }.map { os in
            let record = try? JSONDecoder().decode(Stage2Record.self, from: Data(contentsOf: os.resources.appending("stage2.json")))
            return ExistingInstallation(id: os.vgid, name: os.label, needsFinalization: record.map { !$0.complete } ?? !os.registered, canUninstall: record?.ready == true && record?.managedLayout == true)
        }
        if existing.isEmpty { try loadReleases(for: scan.board) } else { templates = [:] }
        let software = try templates.sorted { $0.key < $1.key }.map { try $0.value.software(id: $0.key, storage: scan.board.storage) }
        return Inspection(model: scan.board.id, bootMode: scan.system.bootMode, administrator: scan.system.loginUser.isEmpty ? scan.current.administrators[0] : scan.system.loginUser, administrators: scan.current.administrators, targets: try targets(scan), software: software, existing: existing, board: scan.board.presentation, boardProfileID: scan.board.id, macOSReserveBytes: scan.board.storage.macOSReserveBytes)
    }
    public func plan(_ selection: InstallSelection) throws -> InstallPlan {
        if configuration.demo {
            let info = try demoInspection()
            guard let target = info.targets.first(where: { $0.id == selection.targetID }), let software = info.software.first(where: { $0.id == selection.softwareID }) else { throw InstallerError("Invalid demo selection") }
            let plan = try makePlan(selection, target: target, software: software, expandable: true)
            plans[plan.id] = (plan, "demo"); return plan
        }
        let scan = try scan(readOnly: true)
        guard let target = try targets(scan).first(where: { $0.id == selection.targetID }), let template = templates[selection.softwareID], selection.softwareID.hasPrefix(scan.board.id + ":") else { throw InstallerError("Your selection changed; check this Mac again") }
        var plan = try makePlan(selection, target: target, software: template.software(id: selection.softwareID, storage: scan.board.storage), expandable: template.expandable, layoutBytes: scan.board.storage.stubBytes + template.minimum)
        plan.fingerprint = scan.fingerprint; plans.removeAll(); plans[plan.id] = (plan, scan.fingerprint); return plan
    }
    private func makePlan(_ selection: InstallSelection, target: StorageTarget, software: Software, expandable: Bool, layoutBytes: Int64? = nil) throws -> InstallPlan {
        var selection = selection; selection.bytes = alignDown(selection.bytes)
        selection.name = selection.name.trimmingCharacters(in: .whitespacesAndNewlines)
        try require(!selection.name.isEmpty && selection.name.utf8.count <= 64 && !selection.name.contains("/") && !selection.name.unicodeScalars.contains { $0.value < 32 }, "Choose a volume name of at most 64 bytes without slashes or control characters")
        try require(selection.bytes >= software.minimumBytes && selection.bytes <= target.maximumBytes, "Choose an installation size between \(sizeText(software.minimumBytes)) and \(sizeText(target.maximumBytes))")
        let after = target.kind == "resize" ? alignDown(target.totalBytes - selection.bytes) : nil
        var changes = [after.map { "Shrink \(target.name) from \(sizeText(target.totalBytes)) to \(sizeText($0))" } ?? "Use existing unallocated space"]
        if software.mode == .linux {
            changes += ["Create the startup and Linux partitions for \(software.name)"]
            let fixed = layoutBytes ?? software.minimumBytes
            if !expandable && selection.bytes > fixed { changes.append("Leave \(sizeText(selection.bytes - fixed)) unallocated") }
        } else {
            changes += [software.mode == .uefi ? "Create only the startup stub and EFI System Partition" : "Create only the startup stub", "Leave \(sizeText(selection.bytes - software.minimumBytes)) unallocated for a future operating system"]
        }
        changes += ["Prepare paired recovery and select \(selection.name) in startup options"]
        return InstallPlan(id: UUID().uuidString, selection: selection, target: target, software: software, macOSAfterBytes: after, changes: changes)
    }
    private func validate(_ credentials: Credentials, _ current: InstalledOS) throws {
        try require(current.administrators.contains(credentials.username) && !credentials.password.isEmpty && !credentials.password.contains("\n") && !credentials.password.contains("\0"), "Enter a valid macOS machine-owner administrator login")
        // Validate before changing partitions, using the macOS authentication node.
        if !current.stub {
            try commands.authenticated("/usr/bin/dscl", ["/Local/Default", "-authonly", credentials.username], credentials: credentials)
        }
    }
    public func install(planID: String, credentials: Credentials) throws {
        guard let (plan, fingerprint) = plans.removeValue(forKey: planID) else { throw InstallerError("This plan expired or was already used; review a new plan") }
        if configuration.demo {
            for step in InstallStep.allCases.filter({ ![.complete, .check1TR, .externalPreboot, .securityPolicy, .registerBoot, .finish, .repair, .uninstall].contains($0) }) {
                events(InstallEvent(step, fraction: 0)); Thread.sleep(forTimeInterval: 0.08); events(InstallEvent(step, fraction: 1))
            }; return
        }
        try root()
        let lock = try MutationLock(); defer { withExtendedLifetime(lock) {} }
        let power = PowerAssertion(); defer { withExtendedLifetime(power) {} }
        guard let template = templates[plan.selection.softwareID], let app = configuration.appBundle else { throw InstallerError("Install from the packaged app, with its boot resources") }
        try require(fm.fileExists(atPath: app.appending("Contents/MacOS/gravity-installer").path), "The offline recovery app is missing")
        let first = try scan(); try require(first.fingerprint == fingerprint, "Disk layout changed after review; review a new plan")
        try require(first.system.bootMode == "macOS", "Begin a new installation from macOS. Use --stage2 in paired recovery to finish.")
        try validate(credentials, first.current)
        events(InstallEvent(.package))
        let archive = try template.package.map { try ZIPArchive(resolvePackage($0)) }
        // Resolve required boot assets and the image inventory before any mutation.
        _ = try Data(contentsOf: first.board.boot.resource(template.boot_object, in: configuration.resourceDirectory))
        _ = try Data(contentsOf: configuration.resourceDirectory.appending("logo.icns"))
        for partition in template.layout {
            if let image = partition.image { guard let archive else { throw InstallerError("Release image has no package") }; _ = try archive.entry(image) }
        }
        let stub = try StubInstaller(system: first.system, disk: first.disk, board: first.board, resources: configuration.resourceDirectory, app: app, events: events)
        let fresh = try scan(); try require(fresh.fingerprint == fingerprint, "Disk layout changed during downloads; review a new plan")
        guard let selected = fresh.partitions.first(where: { $0.id == plan.selection.targetID }), let target = try targets(fresh).first(where: { $0.id == selected.id }) else { throw InstallerError("Selected space no longer exists") }
        try require(plan.selection.bytes <= target.maximumBytes, "Available space changed; review a smaller installation")
        var after = selected.name
        if target.kind == "resize" {
            events(InstallEvent(.resize)); _ = try fresh.disk.action(["apfs", "resizeContainer", selected.name, String(alignDown(selected.size - plan.selection.bytes))])
            try fresh.disk.refresh()
            guard let free = try fresh.disk.partitions(fresh.name).first(where: { $0.free && $0.name == selected.name }) else { throw InstallerError("Resize completed but no adjacent free space was found; check the disk before continuing") }
            try require(free.size >= plan.selection.bytes, "The freed space is smaller than the reviewed installation")
            after = free.name
        }
        events(InstallEvent(.createStub))
        let startup = try fresh.disk.addPartition(after: after, type: "apfs", label: plan.selection.name, size: fresh.board.storage.stubBytes, disk: fresh.name)
        let os = try stub.install(into: startup, authenticatingWith: fresh.current)
        var record = Stage2Record(version: 1, vgid: os.vgid, prebootUUID: os.prebootUUID, name: plan.selection.name, macOSPartitionUUID: fresh.current.partition.uuid, partitions: [SavedPartition(startup)], ready: false, complete: false)
        record.developerMode = configuration.developer; record.boardProfileID = fresh.board.id; record.hardware = fresh.system.hardware
        let stage2 = os.resources.appending("stage2.json")
        try write(JSONEncoder().encode(record), to: stage2)
        var parts: [DiskPartition] = [], previous = startup.name
        let expansion = template.expandable ? plan.selection.bytes - fresh.board.storage.stubBytes - (try template.minimum) : 0
        for partition in template.layout {
            events(InstallEvent(.partition, detail: partition.name))
            let size = try partition.bytes + (partition.expand == true ? expansion : 0)
            let part = try fresh.disk.addPartition(after: previous, type: "%\(partition.type)%", label: "%noformat%", size: size, disk: fresh.name)
            parts.append(part); previous = part.name; record.partitions.append(SavedPartition(part))
            try write(JSONEncoder().encode(record), to: stage2)
            if partition.format == "fat" {
                events(InstallEvent(.format))
                let invalid = CharacterSet(charactersIn: "*?/\\|,;:+=<>[]\"")
                let label = (partition.name + " - " + plan.selection.name).components(separatedBy: invalid).joined().folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX")).filter { $0.isASCII }
                var args = ["-F", "32", "-v", String(label.prefix(11))]
                if let id = partition.volume_id { args += ["-I", id] }; args.append("/dev/r" + part.name)
                _ = try commands.run("/sbin/newfs_msdos", args, input: nil)
            }
        }
        try fresh.disk.refresh()
        let currentParts = try fresh.disk.partitions(fresh.name)
        parts = try parts.map { saved in
            let matches = currentParts.filter { !$0.free && $0.uuid == saved.uuid && $0.type == saved.type && $0.size == saved.size }
            try require(matches.count == 1, "A new installation partition changed before writing its image")
            return matches[0]
        }
        let firmware = try template.layout.contains { $0.copy_firmware == true } ? stub.collectFirmware(os) : nil
        var idata: [URL] = []
        if let icon = template.icon { try archive?.extract(icon, to: os.system.appending(".VolumeIcon.icns")) }
        for (partition, part) in zip(template.layout, parts) {
            if let image = partition.image, let archive {
                events(InstallEvent(.systemImage, detail: partition.name)); let entry = try archive.entry(image)
                try require(entry.size <= part.size && entry.size % 4096 == 0, "Linux image exceeds its partition or is not aligned to 4 KiB")
                let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: "/dev/r" + part.name)); defer { try? handle.close() }
                try archive.stream(entry, progress: { self.events(InstallEvent(.systemImage, fraction: $0, detail: partition.name)) }) { try handle.write(contentsOf: $0) }
                try handle.synchronize()
            }
            if let source = partition.source, let archive {
                events(InstallEvent(.systemFiles, detail: partition.name)); try archive.extractTree(source, to: fresh.disk.mount(part.name))
            }
            if partition.copy_firmware == true, let firmware { try copy(firmware, fresh.disk.mount(part.name).appending("vendorfw")) }
            if partition.copy_installer_data == true { let dest = try fresh.disk.mount(part.name).appending("gravity"); try mkdir(dest); idata.append(dest) }
        }
        let efi = parts.first { $0.type == "EFI" }
        if let extras = template.extras, !extras.isEmpty, template.mode != .bootloader {
            guard let efi else { throw InstallerError("Additional files require an EFI partition") }
            let dest = try fresh.disk.mount(efi.name).appending("gravity/extras"); try mkdir(dest)
            for value in extras {
                events(InstallEvent(.extras, detail: URL(string: value)?.lastPathComponent))
                guard let url = URL(string: value), url.scheme == "https" else { throw InstallerError("Extras require HTTPS") }
                let source = try HTTPRangeSource(url); let output = dest.appending(url.lastPathComponent)
                fm.createFile(atPath: output.path, contents: nil); let handle = try FileHandle(forWritingTo: output); defer { try? handle.close() }
                var offset: Int64 = 0
                while offset < source.size { let chunk = try source.read(offset: offset, count: Int(min(1_048_576, source.size - offset))); try handle.write(contentsOf: chunk); offset += Int64(chunk.count); events(InstallEvent(.extras, fraction: Double(offset) / Double(source.size))) }
            }
        }
        events(InstallEvent(.bootObject)); var variables: [String] = []
        if let efi { variables.append("chosen.gravity,efi-system-partition=\(efi.uuid.lowercased())") }
        if let next = template.next_object, template.mode != .bootloader {
            guard let efi else { throw InstallerError("Chainloading requires an EFI partition") }; variables.append("chainload=\(efi.uuid.lowercased());\(next)")
        }
        try write(BootObject.build(Data(contentsOf: fresh.board.boot.resource(template.boot_object, in: configuration.resourceDirectory)), variables: variables, alignment: fresh.board.boot.registration.alignment), to: os.resources.appending("boot.bin"))
        var finishedRecord = record; finishedRecord.ready = true
        for dest in idata {
            try stub.collectInstallerData(dest)
            try write(JSONEncoder().encode(finishedRecord), to: dest.appending("installation.json"))
            if let url = log.url { try copy(url, dest.appending("installer.log")) }
        }
        record = finishedRecord; try write(JSONEncoder().encode(record), to: stage2)
        try prepareBoot(os, credentials: credentials, recovery: false)
        events(InstallEvent(.restart, fraction: 1))
    }
    private func resolvePackage(_ name: String) throws -> URL {
        try ReleaseCatalog.packageURL(name, repository: configuration.repositoryURL)
    }
    private func prepareBoot(_ os: InstalledOS, credentials: Credentials, recovery: Bool) throws {
        let core = os.system.appending("System/Library/CoreServices"), enabled = core.appending("SystemVersion.plist"), disabled = core.appending("SystemVersion-disabled.plist")
        if !fm.fileExists(atPath: enabled.path) && fm.fileExists(atPath: disabled.path) { try fm.moveItem(at: disabled, to: enabled) }
        if recovery {
            events(InstallEvent(.reducedSecurity)); try commands.authenticated("/usr/bin/bputil", ["-g", "-v", os.vgid], credentials: credentials)
        }
        events(InstallEvent(.defaultBoot))
        _ = try commands.run("/usr/sbin/bless", ["--setBoot", "--device", "/dev/" + os.systemDevice, "--user", credentials.username, "--stdinpass"], input: Data(credentials.password.utf8))
        if fm.fileExists(atPath: enabled.path) { if fm.fileExists(atPath: disabled.path) { try fm.removeItem(at: disabled) }; try fm.moveItem(at: enabled, to: disabled) }
        let media = os.system.appending(".IAPhysicalMedia"), disabledMedia = os.system.appending("IAPhysicalMedia-disabled.plist")
        if !fm.fileExists(atPath: media.path), fm.fileExists(atPath: disabledMedia.path) { try fm.moveItem(at: disabledMedia, to: media) }
    }
    public func stage2Status() throws -> Stage2Status {
        if configuration.demo { return Stage2Status(name: "Gravity Linux", ready: true, in1TR: true, paired: true, complete: false, board: try demoBoard().presentation, boardProfileID: try demoBoard().id) }
        guard let url = configuration.stage2URL else { throw InstallerError("Pass --stage2 with the installed stage2.json path") }
        if geteuid() != 0 {
            let context = try Stage2Context(url, boards: boards, developer: configuration.developer)
            return Stage2Status(name: context.record.name, ready: context.record.ready, in1TR: false, paired: false, complete: context.record.complete, board: context.board.presentation, boardProfileID: context.board.id)
        }
        let context = try Stage2Context(url, boards: boards, developer: configuration.developer), policy = try context.status(commands: commands)
        return Stage2Status(name: context.record.name, ready: context.record.ready, in1TR: MacSystem.environment(policy) == "one true recoveryOS", paired: policy.contains(": Paired"), complete: context.record.complete, board: context.board.presentation, boardProfileID: context.board.id)
    }
    public func finalize(credentials: Credentials) throws {
        if configuration.demo {
            for step in [InstallStep.check1TR, .securityPolicy, .registerBoot, .finish, .complete] { events(InstallEvent(step)); Thread.sleep(forTimeInterval: 0.2) }; return
        }
        try root(); guard let url = configuration.stage2URL else { throw InstallerError("No stage2 configuration") }
        let lock = try MutationLock(); defer { withExtendedLifetime(lock) {} }
        let power = PowerAssertion(); defer { withExtendedLifetime(power) {} }
        try Stage2Context(url, boards: boards, developer: configuration.developer).finalize(commands: commands, credentials: credentials, events: events)
    }
    public func powerOff(restart: Bool) throws {
        if configuration.demo { return }; try root()
        let lock = try MutationLock(); defer { withExtendedLifetime(lock) {} }
        _ = try commands.run("/sbin/shutdown", [restart ? "-r" : "-h", "now"], input: nil)
    }
    private func demoBoard() throws -> BoardProfile {
        if let board = boards.availableProfiles(developer: configuration.developer).first { return board }
        guard let board = boards.profiles.first else { throw InstallerError("No boards are registered") }
        return try boards.profile(id: board.id, developer: configuration.developer)
    }
    private func demoInspection() throws -> Inspection {
        let board = try demoBoard()
        return Inspection(model: board.presentation.productNumber, bootMode: "macOS", administrator: "demo", administrators: ["demo"],
            targets: [StorageTarget(id: "demo-storage", name: "Macintosh HD", kind: "resize", totalBytes: 494_000_000_000, freeBytes: 300_000_000_000, maximumBytes: 260_000_000_000)],
            software: ["KDE Plasma", "GNOME", "Sway", "Minimal", "UEFI only"].enumerated().map {
                Software(id: "demo-\($0.offset)", name: $0.element, minimumBytes: $0.offset == 4 ? board.storage.stubBytes + alignUp(500_000_000) : board.storage.minimumLinuxBytes,
                         recommendedBytes: board.storage.minimumLinuxBytes, developer: false, mode: $0.offset == 4 ? .uefi : .linux)
            }.filter { board.installationModes.contains($0.mode) }, existing: [], board: board.presentation, boardProfileID: board.id, macOSReserveBytes: board.storage.macOSReserveBytes)
    }
}
public struct Stage2Status: Codable, Sendable {
    public let name: String, ready: Bool, in1TR: Bool, paired: Bool, complete: Bool
    public var board: BoardPresentation? = nil
    public var boardProfileID: String? = nil
}
public struct MaintenancePlan: Codable, Identifiable, Sendable {
    public let id: String, installationID: String, operation: String, changes: [String]
    let fingerprint: String
    public func hasSameReview(as other: MaintenancePlan) -> Bool {
        installationID == other.installationID && operation == other.operation && changes == other.changes && fingerprint == other.fingerprint
    }
}
extension InstallerEngine {
    /// A new privileged process reconstructs the plan; a GUI-created plan ID
    /// cannot grant authority or bypass changed-layout and review checks.
    public func installReviewed(_ reviewed: InstallPlan, credentials: Credentials) throws {
        try root(); _ = try inspect()
        let fresh = try plan(reviewed.selection)
        try require(fresh.hasSameReview(as: reviewed), "The installation plan changed after review. Review it again before installing.")
        try install(planID: fresh.id, credentials: credentials)
    }
    public func maintainReviewed(_ reviewed: MaintenancePlan, credentials: Credentials) throws {
        try root()
        let fresh = try planMaintenance(installationID: reviewed.installationID, operation: reviewed.operation)
        try require(fresh.hasSameReview(as: reviewed), "The maintenance plan changed after review. Review it again before continuing.")
        try maintain(planID: fresh.id, credentials: credentials)
    }
}
extension InstallerEngine {
    public func planMaintenance(installationID: String, operation: String) throws -> MaintenancePlan {
        try require(!configuration.demo, "Maintenance is unavailable in demo mode")
        try require(["repair", "upgrade", "uninstall"].contains(operation), "Unknown maintenance operation")
        let scan = try scan(readOnly: true)
        guard let os = scan.systems.first(where: { $0.vgid == installationID && $0.stub }) else { throw InstallerError("Installation not found") }
        if operation == "uninstall" { _ = try uninstallPartitions(os, scan: scan) }
        let changes = operation == "uninstall" ? ["Permanently delete \(os.label), including its Linux files and settings", "Restore macOS as the default startup volume", "Return adjacent free space to \(scan.current.label)"] : ["Refresh machine-owner authentication for \(os.label)", operation == "upgrade" ? "Replace m1n1 stage 1, preserving its boot variables" : "Keep the existing boot object and Linux files", "Select \(os.label) for startup and finish in paired recovery"]
        let plan = MaintenancePlan(id: UUID().uuidString, installationID: installationID, operation: operation, changes: changes, fingerprint: scan.fingerprint)
        maintenancePlans.removeAll(); maintenancePlans[plan.id] = plan; return plan
    }
    private func uninstallPartitions(_ os: InstalledOS, scan: Scan) throws -> [DiskPartition] {
        let record = try JSONDecoder().decode(Stage2Record.self, from: Data(contentsOf: os.resources.appending("stage2.json")))
        try require(record.ready && record.managedLayout && record.vgid == os.vgid && record.macOSPartitionUUID == scan.current.partition.uuid && !record.partitions.isEmpty, "Uninstall requires a complete partition manifest from this Swift installer")
        var selected: [DiskPartition] = []
        for saved in record.partitions {
            let matches = scan.partitions.filter { !$0.free && $0.uuid == saved.uuid && $0.type == saved.type && $0.size == saved.bytes }
            try require(matches.count == 1, "An installation partition changed; automatic uninstall cannot continue"); selected.append(matches[0])
        }
        try require(selected[0].uuid == os.partition.uuid && Set(selected.map(\.uuid)).count == selected.count, "Invalid installation partition manifest")
        let ordered = scan.partitions.filter { !$0.free }; guard let macIndex = ordered.firstIndex(where: { $0.uuid == scan.current.partition.uuid }), let start = ordered.firstIndex(where: { $0.uuid == os.partition.uuid }) else { throw InstallerError("Invalid disk order") }
        try require(start == macIndex + 1 && start + selected.count <= ordered.count && Array(ordered[start..<(start + selected.count)]).map(\.uuid) == selected.map(\.uuid), "Only an adjacent, unchanged installation can be removed automatically")
        try require(selected.dropFirst().allSatisfy { ["EFI", "Linux Filesystem", "Linux"].contains($0.type) }, "Unrecognized installation partition type")
        return selected
    }
    public func maintain(planID: String, credentials: Credentials) throws {
        guard let plan = maintenancePlans.removeValue(forKey: planID) else { throw InstallerError("Review a new maintenance plan") }
        try root()
        let lock = try MutationLock(); defer { withExtendedLifetime(lock) {} }
        let power = PowerAssertion(); defer { withExtendedLifetime(power) {} }
        let scan = try scan(); try require(scan.fingerprint == plan.fingerprint, "Disk layout changed; review the operation again")
        guard let os = scan.systems.first(where: { $0.vgid == plan.installationID && $0.stub }) else { throw InstallerError("Installation not found") }
        try validate(credentials, scan.current)
        if plan.operation == "uninstall" {
            let parts = try uninstallPartitions(os, scan: scan)
            try require(scan.system.bootMode == "macOS", "Uninstall must be run from macOS")
            events(InstallEvent(.defaultBoot))
            _ = try commands.run("/usr/sbin/bless", ["--setBoot", "--device", "/dev/" + scan.current.systemDevice, "--user", credentials.username, "--stdinpass"], input: Data(credentials.password.utf8))
            for part in parts.reversed() {
                try scan.disk.refresh()
                let matches = try scan.disk.partitions(scan.name).filter { !$0.free && $0.uuid == part.uuid && $0.type == part.type && $0.size == part.size }
                try require(matches.count == 1, "Partition identity changed during uninstall")
                var target = matches[0]
                events(InstallEvent(.uninstall, detail: target.name))
                if target.type == "Apple_APFS" {
                    _ = try scan.disk.action(["apfs", "deleteContainer", target.name])
                    try scan.disk.refresh()
                    let converted = try scan.disk.partitions(scan.name).filter { !$0.free && $0.offset == target.offset && $0.size == target.size }
                    try require(converted.count == 1, "Could not identify the deleted APFS container's replacement partition")
                    target = converted[0]
                }
                _ = try scan.disk.action(["eraseVolume", "free", "none", target.name])
            }
            try scan.disk.refresh()
            guard let macOS = try scan.disk.partitions(scan.name).first(where: { $0.uuid == scan.current.partition.uuid }) else { throw InstallerError("Could not identify macOS after removing Linux") }
            _ = try scan.disk.action(["apfs", "resizeContainer", macOS.name, "0"])
            return
        }
        events(InstallEvent(.repair)); _ = try commands.run("/sbin/mount", ["-u", "-w", os.system.path], input: nil)
        let source = scan.current.preboot.appending("\(scan.current.vgid)/var/db/AdminUserRecoveryInfo.plist"), dest = os.preboot.appending("\(os.vgid)/var/db/AdminUserRecoveryInfo.plist")
        if fm.fileExists(atPath: dest.path) { _ = try commands.run("/usr/bin/chflags", ["noschg", dest.path], input: nil) }
        try copy(source, dest); _ = try commands.run("/usr/bin/chflags", ["schg", dest.path], input: nil)
        let boot = os.resources.appending("boot.bin")
        let existingBoot = try Data(contentsOf: boot)
        let recordURL = os.resources.appending("stage2.json")
        var record: Stage2Record
        if let saved = try? JSONDecoder().decode(Stage2Record.self, from: Data(contentsOf: recordURL)) {
            _ = try boards.savedProfile(id: saved.boardProfileID, hardware: saved.hardware, developer: configuration.developer)
            try require(saved.boardProfileID == nil ? boards.savedProfile(id: nil, developer: configuration.developer).id == scan.board.id : saved.boardProfileID == scan.board.id, "Installed board profile does not match this Mac")
            record = saved
        } else {
            // Upgrade the legacy recovery launcher to this same native app,
            // without inferring ownership of neighboring Linux partitions.
            guard let app = configuration.appBundle else { throw InstallerError("Repair requires the packaged native app") }
            try copy(app, os.system.appending("Finish Installation.app"))
            try write(existingBoot, to: boot)
            record = Stage2Record(version: 1, vgid: os.vgid, prebootUUID: os.prebootUUID, name: os.label, macOSPartitionUUID: scan.current.partition.uuid, partitions: [], ready: true, complete: false)
            record.managedLayout = false
        }
        if plan.operation == "upgrade" {
            let vars = try BootObject.variables(existingBoot)
            try write(BootObject.build(Data(contentsOf: scan.board.boot.resource(scan.board.boot.stage1, in: configuration.resourceDirectory)), variables: vars, alignment: scan.board.boot.registration.alignment), to: boot)
        }
        record.complete = false
        record.developerMode = configuration.developer; record.boardProfileID = scan.board.id; record.hardware = scan.system.hardware
        try write(JSONEncoder().encode(record), to: recordURL)
        try prepareBoot(os, credentials: credentials, recovery: scan.system.bootMode.contains("recoveryOS"))
        events(InstallEvent(.restart))
    }
    public func collectHandoffBundle(destination: URL, ipsw: URL? = nil) throws {
        try require(!configuration.demo, "Firmware collection requires real hardware")
        try HandoffBundle.collect(destination: destination, ipsw: ipsw,
            resources: configuration.resourceDirectory, boards: boards, developer: configuration.developer, commands: commands, events: events)
    }
    public func rebuildFirmware(source: URL, destination: URL, boardID: String? = nil) throws {
        try FirmwarePipeline.rebuild(source: source, destination: destination, resources: configuration.resourceDirectory, boardID: boardID, registry: boards, developer: configuration.developer, commands: commands, events: events)
    }
}
